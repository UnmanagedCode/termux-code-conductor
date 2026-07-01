/* dohshim.c — LD_PRELOAD getaddrinfo() interposer that adds a DNS-over-HTTPS
 * fallback for Claude Code (Bun) on Termux/glibc.
 *
 * Why: Claude (claude.exe, a Bun binary) resolves via glibc -> hardcoded
 * 8.8.8.8. Captive/hotel networks block direct external DNS, so resolution
 * fails (EAI_AGAIN) even though HTTPS/443 works. This shim, on a system
 * resolution failure, performs DoH over 443 via the system `curl` (bionic,
 * which uses Android's own resolver / port 443) and returns the answer.
 *
 * Design:
 *  - Fast path: call the real getaddrinfo first. On success, pass through
 *    (zero overhead on healthy networks).
 *  - On failure (or if CLAUDE_DOH_FORCE=1), resolve via DoH and synthesize a
 *    glibc-compatible addrinfo chain.
 *  - Once DoH has succeeded at least once, prefer DoH first (skip the slow,
 *    doomed system lookup) until the process exits.
 *  - Compiled -nostdlib so it carries no libc DT_NEEDED; all libc symbols
 *    (and the real getaddrinfo via RTLD_NEXT) resolve from the glibc process.
 *
 * struct addrinfo is defined manually to match glibc's aarch64 layout
 * (ai_addr BEFORE ai_canonname — opposite of bionic). Each result node is one
 * malloc block [addrinfo | sockaddr], with ai_canonname=NULL, which matches
 * glibc's freeaddrinfo() (frees ai_canonname then the node).
 *
 * connect() fallback (Bun >= 1.4.0): the getaddrinfo interposer only covers
 * callers that use glibc's resolver symbol. Bun 1.4.0 added an internal c-ares
 * resolver (its default DNS backend on Linux) that bypasses getaddrinfo and
 * talks raw DNS. On Android there is no /etc/resolv.conf (/etc -> /system/etc,
 * absent), so c-ares defaults its nameserver to 127.0.0.1:53 — which nothing
 * answers (non-root can't bind 53), giving an ECONNREFUSED storm and flaky
 * resolution. We therefore also interpose connect(): a connect to 127.0.0.1:53
 * is redirected to a loopback ephemeral port served by a tiny forked responder
 * that speaks the DNS wire protocol and answers via the SAME DoH path. See the
 * "connect() DoH fallback" section below. Never binds 53; never edits host DNS.
 */
#define _GNU_SOURCE
#include <dlfcn.h>

/* ---- minimal libc decls (no headers, to avoid bionic/glibc header clash) ---- */
typedef unsigned long size_t;
typedef long ssize_t;
typedef int pid_t;
typedef unsigned int socklen_t;
typedef unsigned short sa_family_t;
typedef unsigned short in_port_t;

extern void *malloc(size_t);
extern void  free(void *);
extern void *memcpy(void *, const void *, size_t);
extern void *memset(void *, int, size_t);
extern size_t strlen(const char *);
extern int    strcmp(const char *, const char *);
extern int    strncmp(const char *, const char *, size_t);
extern char  *strstr(const char *, const char *);
extern char  *getenv(const char *);
extern int    snprintf(char *, size_t, const char *, ...);
extern int    pipe(int[2]);
extern pid_t  fork(void);
extern int    dup2(int, int);
extern int    close(int);
extern ssize_t read(int, void *, size_t);
extern ssize_t write(int, const void *, size_t);
extern int    execve(const char *, char *const[], char *const[]);
extern pid_t  waitpid(pid_t, int *, int);
extern void   _exit(int);
extern int    inet_pton(int, const char *, void *);
extern unsigned short htons(unsigned short);
extern char **environ;

#define AF_UNSPEC 0
#define AF_INET   2
#define AF_INET6  10
#define SOCK_STREAM 1
#define SOCK_DGRAM  2
#define IPPROTO_TCP 6
#define SOL_SOCKET     1
#define SO_REUSEADDR   2
#define POLLIN         1
#define PR_SET_PDEATHSIG 1
#define SIG_TERM       15

struct in_addr  { unsigned int s_addr; };
struct in6_addr { unsigned char s6_addr[16]; };
struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
struct sockaddr_in {
    sa_family_t sin_family; in_port_t sin_port;
    struct in_addr sin_addr; unsigned char sin_zero[8];
};
struct sockaddr_in6 {
    sa_family_t sin6_family; in_port_t sin6_port; unsigned int sin6_flowinfo;
    struct in6_addr sin6_addr; unsigned int sin6_scope_id;
};
struct pollfd { int fd; short events; short revents; };

/* socket/DNS-responder syscalls (dns-doh connect() fallback, see below).
 * Declared here — after the struct definitions above — so the sockaddr/pollfd
 * pointer types match the file-scope structs. */
extern int     socket(int, int, int);
extern int     bind(int, const struct sockaddr *, socklen_t);
extern int     listen(int, int);
extern int     accept(int, struct sockaddr *, socklen_t *);
extern int     getsockname(int, struct sockaddr *, socklen_t *);
extern int     setsockopt(int, int, int, const void *, socklen_t);
extern ssize_t recvfrom(int, void *, size_t, int, struct sockaddr *, socklen_t *);
extern ssize_t sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
extern int     poll(struct pollfd *, unsigned long, int);
extern int     prctl(int, unsigned long, unsigned long, unsigned long, unsigned long);
struct addrinfo {                 /* glibc aarch64 layout */
    int ai_flags, ai_family, ai_socktype, ai_protocol;
    socklen_t ai_addrlen;
    struct sockaddr *ai_addr;     /* glibc: addr before canonname */
    char *ai_canonname;
    struct addrinfo *ai_next;
};

typedef int (*gai_t)(const char *, const char *, const struct addrinfo *, struct addrinfo **);

static int atoi_simple(const char *);

typedef int (*execve_t)(const char *, char *const[], char *const[]);
typedef int (*execvpe_t)(const char *, char *const[], char *const[]);
typedef int (*spawn_t)(pid_t *, const char *, const void *, const void *,
                       char *const[], char *const[]);

typedef int (*connect_t)(int, const struct sockaddr *, socklen_t);

static gai_t real_gai = 0;
static char **clean_env = 0;      /* environ minus LD_PRELOAD */
static volatile int prefer_doh = 0;
static execve_t  real_execve  = 0;
static execvpe_t real_execvpe = 0;
static spawn_t   real_spawn   = 0;
static spawn_t   real_spawnp  = 0;
static connect_t real_connect = 0;
static volatile int doh_resolver_port = 0;  /* host order; 0 = responder not up */

/* Return a copy of envp with every LD_PRELOAD= entry removed. This is what stops
 * the shim from propagating into exec'd children: a Bionic binary (e.g. ssh
 * resolving github.com) that inherited LD_PRELOAD would load this glibc shim and
 * read a glibc-layout addrinfo in the wrong field order -> SIGSEGV. Returns envp
 * unchanged when there's nothing to strip or on malloc failure (exec beats
 * abort); NULL stays NULL to preserve execve/posix_spawn empty-env semantics.
 * The tiny array leak per call is irrelevant — the image is replaced on success. */
static char **strip_preload(char *const envp[]) {
    if (!envp) return (char **)envp;
    int n = 0, has = 0;
    while (envp[n]) {
        if (strncmp(envp[n], "LD_PRELOAD=", 11) == 0) has = 1;
        n++;
    }
    if (!has) return (char **)envp;
    char **e = (char **)malloc(sizeof(char *) * (n + 1));
    if (!e) return (char **)envp;
    int j = 0;
    for (int i = 0; i < n; i++) {
        if (strncmp(envp[i], "LD_PRELOAD=", 11) == 0) continue;
        e[j++] = envp[i];
    }
    e[j] = 0;
    return e;
}

/* Build an env copy without LD_PRELOAD so the spawned bionic curl never tries
 * to load this glibc shim (which would recurse: curl->getaddrinfo->curl...). */
static void build_clean_env(void) {
    clean_env = strip_preload(environ);
}

/* Opt-in stderr tracing (CLAUDE_DOH_DEBUG=1). Raw write() — the shim is
 * -nostdlib, so no buffered stdio. Silent unless the env var is set, so
 * production stays quiet. */
static void dbg(const char *s) {
    char *d = getenv("CLAUDE_DOH_DEBUG");
    if (d && d[0] == '1') write(2, s, strlen(s));
}

/* Run curl for a DoH JSON query; capture body into out. Returns bytes read. */
static int doh_curl(const char *url, char *out, int outsz) {
    int pf[2];
    if (pipe(pf) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pf[0]); close(pf[1]); return -1; }
    if (pid == 0) {
        dup2(pf[1], 1); close(pf[0]); close(pf[1]);
        char *argv[] = { "curl", "-s", "--max-time", "8",
                         "-H", "accept: application/dns-json",
                         (char *)url, 0 };
        execve("/data/data/com.termux/files/usr/bin/curl", argv,
               clean_env ? clean_env : environ);
        _exit(127);
    }
    close(pf[1]);
    int total = 0; ssize_t r;
    while (total < outsz - 1 &&
           (r = read(pf[0], out + total, outsz - 1 - total)) > 0)
        total += (int)r;
    out[total > 0 ? total : 0] = 0;
    close(pf[0]);
    int st; waitpid(pid, &st, 0);
    return total;
}

/* Allocate one [addrinfo|sockaddr] block; ai_canonname=NULL (glibc-free-safe). */
static struct addrinfo *make_node(int fam, int socktype, int proto,
                                  const void *addr, int port) {
    int sasz = (fam == AF_INET6) ? (int)sizeof(struct sockaddr_in6)
                                 : (int)sizeof(struct sockaddr_in);
    char *blk = (char *)malloc(sizeof(struct addrinfo) + sasz);
    if (!blk) return 0;
    memset(blk, 0, sizeof(struct addrinfo) + sasz);
    struct addrinfo *ai = (struct addrinfo *)blk;
    struct sockaddr *sa = (struct sockaddr *)(blk + sizeof(struct addrinfo));
    ai->ai_family = fam;
    ai->ai_socktype = socktype ? socktype : SOCK_STREAM;
    ai->ai_protocol = proto;
    ai->ai_addrlen = sasz;
    ai->ai_addr = sa;
    ai->ai_canonname = 0;
    ai->ai_next = 0;
    if (fam == AF_INET6) {
        struct sockaddr_in6 *s = (struct sockaddr_in6 *)sa;
        s->sin6_family = AF_INET6;
        s->sin6_port = htons((unsigned short)port);
        memcpy(&s->sin6_addr, addr, 16);
    } else {
        struct sockaddr_in *s = (struct sockaddr_in *)sa;
        s->sin_family = AF_INET;
        s->sin_port = htons((unsigned short)port);
        memcpy(&s->sin_addr, addr, 4);
    }
    return ai;
}

/* Parse all "data":"<ip>" values from DoH JSON, building an addrinfo chain.
 * Non-IP data (e.g. CNAME targets) fail inet_pton and are skipped. */
static struct addrinfo *parse_doh(const char *json, int fam, int socktype,
                                  int proto, int port) {
    struct addrinfo *head = 0, *tail = 0;
    const char *p = json;
    const char *key = "\"data\":\"";
    while ((p = strstr(p, key)) != 0) {
        p += strlen(key);
        char val[64]; int k = 0;
        while (*p && *p != '"' && k < 63) val[k++] = *p++;
        val[k] = 0;
        unsigned char buf[16];
        struct addrinfo *node = 0;
        if (fam == AF_INET6) {
            if (inet_pton(AF_INET6, val, buf) == 1)
                node = make_node(AF_INET6, socktype, proto, buf, port);
        } else {
            if (inet_pton(AF_INET, val, buf) == 1)
                node = make_node(AF_INET, socktype, proto, buf, port);
        }
        if (node) {
            if (!head) head = node; else tail->ai_next = node;
            tail = node;
        }
    }
    return head;
}

static struct addrinfo *doh_lookup(const char *node, int fam, int socktype,
                                   int proto, int port) {
    char url[512], body[8192];
    const char *type = (fam == AF_INET6) ? "AAAA" : "A";
    snprintf(url, sizeof(url),
             "https://1.1.1.1/dns-query?name=%s&type=%s", node, type);
    int n = doh_curl(url, body, (int)sizeof(body));
    if (n <= 0) return 0;
    return parse_doh(body, fam, socktype, proto, port);
}

static int digits_only(const char *s) {
    if (!s || !*s) return 0;
    for (const char *p = s; *p; p++) if (*p < '0' || *p > '9') return 0;
    return 1;
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res) {
    if (!real_gai) real_gai = (gai_t)dlsym(RTLD_NEXT, "getaddrinfo");
    if (!clean_env) build_clean_env();

    int forced = 0;
    char *fe = getenv("CLAUDE_DOH_FORCE");
    if (fe && fe[0] == '1') forced = 1;

    /* Fast path: try the system resolver first unless forced/known-broken. */
    if (!forced && !prefer_doh && real_gai) {
        int rc = real_gai(node, service, hints, res);
        if (rc == 0) return 0;
        /* fall through to DoH on any failure */
    }

    /* DoH only makes sense for real hostnames. Skip null/numeric-IP nodes:
     * defer those to the real resolver (handles IP literals, localhost, etc). */
    if (!node) {
        if (real_gai) return real_gai(node, service, hints, res);
        return -2; /* EAI_NONAME */
    }
    {
        unsigned char tmp[16];
        if (inet_pton(AF_INET, node, tmp) == 1 ||
            inet_pton(AF_INET6, node, tmp) == 1) {
            if (real_gai) return real_gai(node, service, hints, res);
        }
    }

    int fam = hints ? hints->ai_family : AF_UNSPEC;
    int socktype = hints ? hints->ai_socktype : 0;
    int proto = hints ? hints->ai_protocol : 0;
    int port = (service && digits_only(service)) ? atoi_simple(service) : 0;

    struct addrinfo *chain = 0;
    if (fam == AF_INET6) {
        chain = doh_lookup(node, AF_INET6, socktype, proto, port);
    } else if (fam == AF_INET) {
        chain = doh_lookup(node, AF_INET, socktype, proto, port);
    } else { /* AF_UNSPEC: prefer A, then AAAA */
        chain = doh_lookup(node, AF_INET, socktype, proto, port);
        struct addrinfo *v6 = doh_lookup(node, AF_INET6, socktype, proto, port);
        if (!chain) chain = v6;
        else { struct addrinfo *t = chain; while (t->ai_next) t = t->ai_next; t->ai_next = v6; }
    }

    if (chain) {
        prefer_doh = 1;        /* system DNS is down; prefer DoH from now on */
        *res = chain;
        return 0;
    }
    /* DoH failed too — last resort: whatever the real resolver says. */
    if (real_gai) return real_gai(node, service, hints, res);
    return -2; /* EAI_NONAME */
}

/* ---- connect() DoH fallback for Bun 1.4.0's internal c-ares resolver -------
 * getaddrinfo() only covers callers that go through glibc's resolver symbol.
 * Bun >=1.4.0 also ships an internal c-ares resolver (default DNS backend on
 * Linux) that bypasses getaddrinfo entirely and talks raw DNS. On Android there
 * is no /etc/resolv.conf (/etc -> /system/etc, absent), so c-ares defaults its
 * nameserver to 127.0.0.1:53 — which nothing answers (non-root can't bind 53),
 * giving an ECONNREFUSED storm and flaky resolution.
 *
 * We can't run a resolver ON port 53 (privileged), so instead we interpose
 * connect(): a connect to 127.0.0.1:53 is rewritten to 127.0.0.1:<ephemeral>,
 * where a tiny forked responder speaks the DNS wire protocol and answers via
 * the SAME DoH path getaddrinfo already uses. Never binds 53; never modifies
 * host DNS config. The responder is forked once from a library constructor,
 * while the process is still single-threaded, so malloc-after-fork is safe. */

/* Serialize a DoH-resolved A/AAAA answer set into a DNS response packet.
 * q/qlen = raw query (no TCP length prefix). Returns response length in out, or
 * -1 on parse error. On resolution failure returns a SERVFAIL response. */
static int dns_build_response(const unsigned char *q, int qlen,
                              unsigned char *out, int outcap) {
    if (qlen < 12 || outcap < 12) return -1;
    /* --- decode QNAME into a dotted host string --- */
    char host[256]; int hp = 0;
    int pos = 12;
    while (pos < qlen && q[pos] != 0) {
        int lab = q[pos];
        if (lab & 0xC0) return -1;            /* compression in a query: reject */
        pos++;
        if (pos + lab > qlen || hp + lab + 1 >= (int)sizeof(host)) return -1;
        if (hp) host[hp++] = '.';
        for (int i = 0; i < lab; i++) host[hp++] = (char)q[pos++];
    }
    host[hp] = 0;
    if (pos >= qlen) return -1;
    pos++;                                     /* skip QNAME terminator */
    if (pos + 4 > qlen) return -1;
    int qtype  = (q[pos] << 8) | q[pos + 1];
    int qend   = pos + 4;                      /* end of question (QTYPE+QCLASS) */
    int fam    = (qtype == 28) ? AF_INET6 : AF_INET;
    int rdlen  = (fam == AF_INET6) ? 16 : 4;

    /* --- header: echo ID, set QR+RA, RCODE=0; drop AUTH/ADDITIONAL --- */
    if (qend > outcap) return -1;
    for (int i = 0; i < qend; i++) out[i] = q[i];  /* header + question verbatim */
    out[2] = (unsigned char)(q[2] | 0x80);     /* QR=1, keep Opcode/RD */
    out[3] = 0x80;                             /* RA=1, Z=0, RCODE=0 */
    out[6] = 0; out[7] = 0;                     /* ANCOUNT (filled below) */
    out[8] = 0; out[9] = 0;                     /* NSCOUNT */
    out[10] = 0; out[11] = 0;                   /* ARCOUNT (drop EDNS OPT) */

    struct addrinfo *chain = doh_lookup(host, fam, 0, 0, 0);
    if (!chain) { out[3] = 0x82; return qend; } /* SERVFAIL, no answers */

    int o = qend, ancount = 0;
    for (struct addrinfo *n = chain; n; n = n->ai_next) {
        if (o + 12 + rdlen > outcap) break;
        out[o++] = 0xC0; out[o++] = 0x0C;      /* NAME -> pointer to QNAME @12 */
        out[o++] = (unsigned char)(qtype >> 8); out[o++] = (unsigned char)qtype;
        out[o++] = 0x00; out[o++] = 0x01;      /* CLASS IN */
        out[o++] = 0; out[o++] = 0; out[o++] = 0; out[o++] = 60;  /* TTL 60s */
        out[o++] = (unsigned char)(rdlen >> 8); out[o++] = (unsigned char)rdlen;
        if (fam == AF_INET6) {
            struct sockaddr_in6 *s = (struct sockaddr_in6 *)n->ai_addr;
            memcpy(out + o, &s->sin6_addr, 16);
        } else {
            struct sockaddr_in *s = (struct sockaddr_in *)n->ai_addr;
            memcpy(out + o, &s->sin_addr, 4);
        }
        o += rdlen; ancount++;
    }
    /* free the DoH chain: each node is a single malloc block, canonname NULL */
    for (struct addrinfo *n = chain; n; ) { struct addrinfo *nx = n->ai_next; free(n); n = nx; }

    out[6] = (unsigned char)(ancount >> 8); out[7] = (unsigned char)ancount;
    if (ancount == 0) out[3] = 0x82;           /* SERVFAIL if DoH returned nothing usable */
    return o;
}

/* Serve one TCP DNS conn: [2-byte length][query] -> [2-byte length][response]. */
static void responder_tcp(int c) {
    unsigned char lp[2];
    int got = 0; ssize_t r;
    while (got < 2 && (r = read(c, lp + got, 2 - got)) > 0) got += (int)r;
    if (got < 2) return;
    int qlen = (lp[0] << 8) | lp[1];
    if (qlen <= 0 || qlen > 4096) return;
    unsigned char q[4096];
    got = 0;
    while (got < qlen && (r = read(c, q + got, qlen - got)) > 0) got += (int)r;
    if (got < qlen) return;
    unsigned char out[2048];
    int olen = dns_build_response(q, qlen, out, (int)sizeof(out));
    if (olen < 0) return;
    unsigned char olp[2] = { (unsigned char)(olen >> 8), (unsigned char)olen };
    if (write(c, olp, 2) != 2) return;
    write(c, out, olen);
    dbg("[DOHDBG] responder: answered TCP query\n");
}

/* Serve one UDP DNS datagram (no length prefix). */
static void responder_udp(int u) {
    unsigned char q[2048];
    struct sockaddr_in from; socklen_t fl = sizeof(from);
    ssize_t qlen = recvfrom(u, q, sizeof(q), 0, (struct sockaddr *)&from, &fl);
    if (qlen < 12) return;
    unsigned char out[2048];
    int olen = dns_build_response(q, (int)qlen, out, (int)sizeof(out));
    if (olen < 0) return;
    sendto(u, out, olen, 0, (struct sockaddr *)&from, fl);
    dbg("[DOHDBG] responder: answered UDP query\n");
}

/* Long-lived child: poll the TCP+UDP loopback sockets and answer forever. */
static void responder_loop(int tcp_fd, int udp_fd) {
    prctl(PR_SET_PDEATHSIG, SIG_TERM, 0, 0, 0);  /* die with the CLI process */
    dbg("[DOHDBG] responder: started\n");
    struct pollfd pfd[2];
    pfd[0].fd = tcp_fd; pfd[0].events = POLLIN;
    pfd[1].fd = udp_fd; pfd[1].events = POLLIN;
    for (;;) {
        pfd[0].revents = 0; pfd[1].revents = 0;
        if (poll(pfd, 2, -1) < 0) continue;
        if (pfd[0].revents & POLLIN) {
            int c = accept(tcp_fd, 0, 0);
            if (c >= 0) { responder_tcp(c); close(c); }
        }
        if (pfd[1].revents & POLLIN) responder_udp(udp_fd);
    }
}

/* Bring up the loopback DNS responder (once). Binds TCP+UDP on an ephemeral
 * port (shared: bind TCP :0, learn the port, bind UDP to the same), forks the
 * server child, and records the port for the connect() hook. Best-effort: on
 * any failure doh_resolver_port stays 0 and connect() passes through unchanged
 * (falling back to today's behavior). */
static void doh_responder_init(void) {
    if (!clean_env) build_clean_env();
    int t = socket(AF_INET, SOCK_STREAM, 0);
    if (t < 0) return;
    int one = 1; setsockopt(t, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET; a.sin_port = 0;
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (bind(t, (struct sockaddr *)&a, sizeof(a)) != 0) { close(t); return; }
    struct sockaddr_in got; memset(&got, 0, sizeof(got));
    socklen_t gl = sizeof(got);
    if (getsockname(t, (struct sockaddr *)&got, &gl) != 0) { close(t); return; }
    if (listen(t, 16) != 0) { close(t); return; }

    int u = socket(AF_INET, SOCK_DGRAM, 0);
    if (u >= 0) {
        struct sockaddr_in ua; memset(&ua, 0, sizeof(ua));
        ua.sin_family = AF_INET; ua.sin_port = got.sin_port;  /* same port */
        inet_pton(AF_INET, "127.0.0.1", &ua.sin_addr);
        if (bind(u, (struct sockaddr *)&ua, sizeof(ua)) != 0) { close(u); u = -1; }
    }

    pid_t pid = fork();
    if (pid == 0) { responder_loop(t, u); _exit(0); }  /* never returns */
    if (pid < 0) { close(t); if (u >= 0) close(u); return; }
    close(t); if (u >= 0) close(u);          /* parent keeps only the port */
    doh_resolver_port = htons(got.sin_port);  /* got.sin_port is net order */

    char line[96];
    snprintf(line, sizeof(line),
             "[DOHDBG] responder: listening on 127.0.0.1:%d\n", doh_resolver_port);
    dbg(line);
}

/* Is this a connect() to the dead loopback DNS server (127.0.0.1:53 / [::1]:53)? */
static int is_loopback_dns(const struct sockaddr *sa, socklen_t len) {
    if (!sa) return 0;
    if (sa->sa_family == AF_INET && len >= (socklen_t)sizeof(struct sockaddr_in)) {
        struct sockaddr_in *s = (struct sockaddr_in *)sa;
        unsigned char *b = (unsigned char *)&s->sin_addr;
        return s->sin_port == htons(53) &&
               b[0] == 127 && b[1] == 0 && b[2] == 0 && b[3] == 1;
    }
    if (sa->sa_family == AF_INET6 && len >= (socklen_t)sizeof(struct sockaddr_in6)) {
        struct sockaddr_in6 *s = (struct sockaddr_in6 *)sa;
        unsigned char *b = s->sin6_addr.s6_addr;
        int is_lo = 1;
        for (int i = 0; i < 15; i++) if (b[i]) { is_lo = 0; break; }
        return s->sin6_port == htons(53) && is_lo && b[15] == 1;
    }
    return 0;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (!real_connect) real_connect = (connect_t)dlsym(RTLD_NEXT, "connect");
    if (addr && is_loopback_dns(addr, len) && doh_resolver_port) {
        /* Copy before mutating — never write the caller's buffer. Only the IPv4
         * responder is bound; for [::1]:53 we still redirect the port but the
         * addr stays ::1, so a v6-only c-ares (not observed in practice) would
         * miss — acceptable, it fails the same as today. */
        if (addr->sa_family == AF_INET) {
            struct sockaddr_in a;
            memcpy(&a, addr, sizeof(a));
            a.sin_port = htons(doh_resolver_port);
            char line[96];
            snprintf(line, sizeof(line),
                     "[DOHDBG] connect: 127.0.0.1:53 (fd=%d) -> 127.0.0.1:%d\n",
                     fd, doh_resolver_port);
            dbg(line);
            return real_connect(fd, (struct sockaddr *)&a, sizeof(a));
        }
        dbg("[DOHDBG] connect: [::1]:53 seen (v6 responder not bound, passthrough)\n");
    }
    return real_connect(fd, addr, len);
}

/* Fire the responder setup at load time, while single-threaded (safe fork). */
__attribute__((constructor))
static void doh_ctor(void) { doh_responder_init(); }

/* ---- exec-family interposers ----------------------------------------------
 * LD_PRELOAD is inherited by every exec'd child, which force-loads this glibc
 * shim into Bionic Termux binaries (ssh, git) and crashes them. Strip
 * LD_PRELOAD from the child's environment on the way out. Glibc children
 * (claude/node) self-correct: their wrappers unset LD_PRELOAD and the claude
 * wrapper re-sets the shim. Covers the real spawners — bash uses execve,
 * Bun/claude.exe uses posix_spawn. The variadic execl* family is not
 * intercepted (glibc's execl* call execve directly, bypassing our execv*); it
 * is not on the crash path. */
int execve(const char *path, char *const argv[], char *const envp[]) {
    if (!real_execve) real_execve = (execve_t)dlsym(RTLD_NEXT, "execve");
    return real_execve(path, argv, strip_preload(envp));
}
int execvpe(const char *file, char *const argv[], char *const envp[]) {
    if (!real_execvpe) real_execvpe = (execvpe_t)dlsym(RTLD_NEXT, "execvpe");
    return real_execvpe(file, argv, strip_preload(envp));
}
int execv(const char *path, char *const argv[]) {
    if (!real_execve) real_execve = (execve_t)dlsym(RTLD_NEXT, "execve");
    return real_execve(path, argv, strip_preload(environ));
}
int execvp(const char *file, char *const argv[]) {
    /* delegate to the real execvpe so glibc's $PATH search is preserved */
    if (!real_execvpe) real_execvpe = (execvpe_t)dlsym(RTLD_NEXT, "execvpe");
    return real_execvpe(file, argv, strip_preload(environ));
}
int posix_spawn(pid_t *pid, const char *path, const void *file_actions,
                const void *attrp, char *const argv[], char *const envp[]) {
    if (!real_spawn) real_spawn = (spawn_t)dlsym(RTLD_NEXT, "posix_spawn");
    return real_spawn(pid, path, file_actions, attrp, argv, strip_preload(envp));
}
int posix_spawnp(pid_t *pid, const char *file, const void *file_actions,
                 const void *attrp, char *const argv[], char *const envp[]) {
    if (!real_spawnp) real_spawnp = (spawn_t)dlsym(RTLD_NEXT, "posix_spawnp");
    return real_spawnp(pid, file, file_actions, attrp, argv, strip_preload(envp));
}

/* tiny atoi for a digits-only string */
static int atoi_simple(const char *s) {
    int v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    return v;
}

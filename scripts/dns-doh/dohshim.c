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
#define IPPROTO_TCP 6

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

static gai_t real_gai = 0;
static char **clean_env = 0;      /* environ minus LD_PRELOAD */
static volatile int prefer_doh = 0;
static execve_t  real_execve  = 0;
static execvpe_t real_execvpe = 0;
static spawn_t   real_spawn   = 0;
static spawn_t   real_spawnp  = 0;

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

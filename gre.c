// gre_nfqueue_worker.c
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <libnetfilter_queue/libnetfilter_queue.h>
#include <linux/netfilter.h>
#include <netinet/ip.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define GRE_PROTOCOL 47
#define INET4_STRLEN 16
#define HASH_SIZE 4096
#define DEFAULT_TIMEOUT_SEC 50 
#define DEFAULT_QUEUE_ID 0
#define LOG_PREFIX "[gre-worker] "

static volatile int running = 1;
static int queue_id = DEFAULT_QUEUE_ID;
static int timeout_sec = DEFAULT_TIMEOUT_SEC;
static const char *script_path = "./eogre_v4_pppoe.sh";
static const char *wan_dev = "eth0";
static const char *brgre_iface = "brEoGREPPPoE";
static const char *lock_dir = "/run/eogrelocks"; 
typedef struct IpEntry {
    char ip[INET4_STRLEN];
    time_t last_seen;
    struct IpEntry *next;
} IpEntry;
static IpEntry *ip_table[HASH_SIZE];
static pthread_mutex_t ip_mutex = PTHREAD_MUTEX_INITIALIZER;

static void logi(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y/%m/%d-%H:%M:%S", &tm);

    fprintf(stdout, "%s%s [INFO] [q=%d] ", LOG_PREFIX, ts, queue_id);
    vfprintf(stdout, fmt, ap);
    fputc('\n', stdout);
    fflush(stdout);
    va_end(ap);
}
static void loge(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y/%m/%d-%H:%M:%S", &tm);

    fprintf(stderr, "%s%s [ERR ] [q=%d] ", LOG_PREFIX, ts, queue_id);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(ap);
}

static unsigned ip_hash(const char *ip) {
    unsigned h = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)ip; *p; ++p) {
        h ^= *p;
        h *= 16777619u;
    }
    return h & (HASH_SIZE - 1);
}

static int lock_ip(const char *ip) {
    char path[256];
    snprintf(path, sizeof(path), "%s/%s.lock", lock_dir, ip);
    int fd = open(path, O_CREAT | O_RDWR, 0644);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX) < 0) { close(fd); return -1; }
    return fd;
}

static int run_script_gre(const char *action, const char *ip,const char *brgre_iface, const char *wan_dev) {
    int lfd = -1;
    if (ip) {
        lfd = lock_ip(ip);
        if (lfd < 0) {
            loge("lock_ip(%s) failed: %s", ip, strerror(errno));
            return -1;
        }
    }

    char *const argv[] = {
        "bash",
        (char *)script_path,
        "gre",
        (char *)action,
        ip ? (char *)ip : NULL,
        brgre_iface ? (char *)brgre_iface : NULL,
        wan_dev ? (char *)wan_dev : NULL,
        NULL
    };

    pid_t pid = fork();
    if (pid == 0) {
        execvp("bash", argv);
        _exit(127);
    } else if (pid < 0) {
        if (lfd >= 0) { flock(lfd, LOCK_UN); close(lfd); }
        loge("fork failed: %s", strerror(errno));
        return -1;
    }
    int status = 0;
    (void)waitpid(pid, &status, 0);

    if (lfd >= 0) { flock(lfd, LOCK_UN); close(lfd); }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
    loge("script exit status=%d action=%s ip=%s", status, action, ip ? ip : "-");
    return -1;
}

static void ensure_lock_dir(void) {
    struct stat st;
    if (stat(lock_dir, &st) == 0) {
        if (!S_ISDIR(st.st_mode)) {
            loge("lock_dir path exists but not a directory: %s", lock_dir);
            exit(2);
        }
        return;
    }
    if (mkdir(lock_dir, 0755) < 0 && errno != EEXIST) {
        loge("mkdir %s failed: %s", lock_dir, strerror(errno));
        exit(2);
    }
}

static bool ip_exists_and_touch(const char *ip) {
    unsigned h = ip_hash(ip);
    time_t now = time(NULL);
    pthread_mutex_lock(&ip_mutex);
    for (IpEntry *e = ip_table[h]; e; e = e->next) {
        if (strcmp(e->ip, ip) == 0) {
            e->last_seen = now;
            pthread_mutex_unlock(&ip_mutex);
            return true;
        }
    }
    pthread_mutex_unlock(&ip_mutex);
    return false;
}

static void ip_add_new(const char *ip) {
    unsigned h = ip_hash(ip);
    time_t now = time(NULL);
    IpEntry *n = (IpEntry *)calloc(1, sizeof(IpEntry));
    if (!n) return;
    strncpy(n->ip, ip, sizeof(n->ip));
    n->ip[sizeof(n->ip) - 1] = '\0';
    n->last_seen = now;

    pthread_mutex_lock(&ip_mutex);
    n->next = ip_table[h];
    ip_table[h] = n;
    pthread_mutex_unlock(&ip_mutex);
}

static void *timeout_thread(void *arg) {
    (void)arg;
    const int sweep_interval = 2; // 秒
    while (running) {
        sleep(sweep_interval);
        time_t now = time(NULL);
        pthread_mutex_lock(&ip_mutex);
        for (int i = 0; i < HASH_SIZE; ++i) {
            IpEntry **pp = &ip_table[i];
            while (*pp) {
                if ((int)(now - (*pp)->last_seen) > timeout_sec) {
                    char ip[INET4_STRLEN];
                    strncpy(ip, (*pp)->ip, sizeof(ip));
                    ip[sizeof(ip)-1] = '\0';

                    IpEntry *old = *pp;
                    *pp = old->next;
                    pthread_mutex_unlock(&ip_mutex);

                    logi("Del GRE Tunnel: %s (timeout %ds)", ip, timeout_sec);
                    run_script_gre("del", ip,brgre_iface,wan_dev);

                    free(old);
                    pthread_mutex_lock(&ip_mutex);
                } else {
                    pp = &(*pp)->next;
                }
            }
        }
        pthread_mutex_unlock(&ip_mutex);
    }
    return NULL;
}

static int cb(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg,
              struct nfq_data *nfa, void *data) {
    (void)nfmsg; (void)data;
    struct nfqnl_msg_packet_hdr *ph = nfq_get_msg_packet_hdr(nfa);
    uint32_t id = ph ? ntohl(ph->packet_id) : 0;

    unsigned char *payload = NULL;
    int len = nfq_get_payload(nfa, &payload);
    if (len >= (int)sizeof(struct iphdr)) {
        struct iphdr *ip = (struct iphdr *)payload;
        if (ip->version == 4 && ip->protocol == GRE_PROTOCOL) {
            char src[INET4_STRLEN];
            inet_ntop(AF_INET, &ip->saddr, src, sizeof(src));

            if (!ip_exists_and_touch(src)) {
                // 新 IP
                ip_add_new(src);
                logi("Add GRE Tunnel: %s", src);
                run_script_gre("int", src,brgre_iface,wan_dev);
            }
        }
    }
    return nfq_set_verdict(qh, id, NF_ACCEPT, 0, NULL);
}

static void on_sigint(int sig) {
    (void)sig;
    running = 0;
}

static void nfqueue_loop(int fd, struct nfq_handle *h) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int rcvbuf = 64 * 1024 * 1024;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    char buf[8192] __attribute__((aligned));
    while (running) {
        int pr = poll(&pfd, 1, 1000);
        if (pr < 0) {
            if (errno == EINTR) continue;
            loge("poll error: %s", strerror(errno));
            continue;
        }
        if (pr == 0) continue;
        if (pfd.revents & POLLIN) {
            int rv = recv(fd, buf, sizeof(buf), 0);
            if (rv >= 0) {
                nfq_handle_packet(h, buf, rv);
            } else if (errno != EINTR) {
                loge("recv error: %s", strerror(errno));
            }
        }
    }
}

static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s [-q queue_id] [-t timeout_sec] [-s script_path]\n"
        "  default queue_id=0, timeout=50s, script=./eogre_v4_pppoe.sh\n", prog);
}

int main(int argc, char **argv) {
    int opt;
        while ((opt = getopt(argc, argv, "q:t:s:b:w:h")) != -1) {
            switch (opt) {
                case 'q': queue_id = atoi(optarg); break;
                case 't': timeout_sec = atoi(optarg); break;
                case 's': script_path = optarg; break;
                case 'b': brgre_iface = optarg; break; 
                case 'w': wan_dev = optarg; break; 
                case 'h': default: usage(argv[0]); return (opt=='h') ? 0 : 1;
            }
    }
    ensure_lock_dir();
    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);

    pthread_t tid;
    pthread_create(&tid, NULL, timeout_thread, NULL);

    struct nfq_handle *h = nfq_open();
    if (!h) { loge("nfq_open failed"); return 2; }

    if (nfq_bind_pf(h, AF_INET) < 0) {
        loge("nfq_bind_pf failed: %s", strerror(errno));
        nfq_close(h);
        return 2;
    }

    struct nfq_q_handle *qh = nfq_create_queue(h, (uint16_t)queue_id, cb, NULL);
    if (!qh) {
        loge("nfq_create_queue %d failed: %s", queue_id, strerror(errno));
        nfq_close(h);
        return 2;
    }

    if (nfq_set_mode(qh, NFQNL_COPY_PACKET, sizeof(struct iphdr)) < 0) {
        loge("nfq_set_mode failed");
        nfq_destroy_queue(qh);
        nfq_close(h);
        return 2;
    }

    nfq_set_queue_maxlen(qh, 8192);

    int fd = nfq_fd(h);
    logi("Worker started. queue=%d timeout=%ds script=%s", queue_id, timeout_sec, script_path);
    nfqueue_loop(fd, h);

    logi("Shutting down...");
    nfq_destroy_queue(qh);
    nfq_close(h);

    running = 0;
    pthread_join(tid, NULL);
    return 0;
}

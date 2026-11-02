// pam_blitzkvm: before sudo asks for the password, ask BlitzKVM's approvers.
//
// The module only runs `blitzkvm-remote pam …` (as root, inside sudo) with a
// clean environment and stdin from /dev/null, relays each line it prints to
// the user's terminal (PAM_TEXT_INFO), and succeeds only when it exits 0: a
// decision the daemon verified. Anything else (denied, no answer, no daemon,
// a missing or writable binary) is PAM_IGNORE, so the next module asks for
// the password as before. No crypto and no JSON here: all of that is in the
// daemon.
//
// Module arguments (for tests): path=<binary>, timeout=<seconds>.
//
//   auth       sufficient     /usr/local/lib/pam/pam_blitzkvm.so

#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <security/pam_appl.h>
#include <security/pam_modules.h>

#define DEFAULT_PATH "/Library/Application Support/BlitzKVM/Remote/blitzkvm-remote"
#define DEFAULT_TIMEOUT 130 // the daemon's ask lives 120 s
#define MAX_LINE 512

// PAM_SILENT from the caller: no info lines (set per authentication).
static int silent;

static void say(pam_handle_t *pamh, const char *text) {
    if (silent) return;
    const struct pam_conv *conv = NULL;
    if (pam_get_item(pamh, PAM_CONV, (const void **)&conv) != PAM_SUCCESS || conv == NULL || conv->conv == NULL) {
        return;
    }
    struct pam_message msg = {PAM_TEXT_INFO, (char *)text};
    const struct pam_message *msgs[1] = {&msg};
    struct pam_response *resp = NULL;
    if (conv->conv(1, msgs, &resp, conv->appdata_ptr) == PAM_SUCCESS && resp != NULL) {
        free(resp->resp);
        free(resp);
    }
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// Owned by root (or, in tests, the effective user) and writable by nobody
// else.
static int safe(const struct stat *st) {
    return (st->st_uid == 0 || st->st_uid == geteuid()) && (st->st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

// Only a binary nobody but root could have put there: a regular file in
// directories, all the way up, that only root can change (otherwise a user
// could link a root-owned program that exits 0, such as true, into place).
// `real` gets the resolved path, which is what runs.
static int trusted(const char *path, char real[PATH_MAX]) {
    struct stat st;
    if (realpath(path, real) == NULL || stat(real, &st) != 0 || !S_ISREG(st.st_mode) || !safe(&st)) return 0;
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", real);
    for (char *slash = strrchr(dir, '/'); slash != NULL; slash = strrchr(dir, '/')) {
        *slash = 0;
        if (stat(dir[0] ? dir : "/", &st) != 0 || !S_ISDIR(st.st_mode) || !safe(&st)) return 0;
        if (dir[0] == 0) break;
    }
    return 1;
}

static void emit(pam_handle_t *pamh, const char *s, size_t n) {
    if (n > 0 && s[n - 1] == '\r') n--;
    if (n == 0) return;
    char line[MAX_LINE + 1];
    if (n > MAX_LINE) n = MAX_LINE;
    memcpy(line, s, n);
    line[n] = 0;
    say(pamh, line);
}

// Relays the complete lines in buf (a line too long goes in pieces), and
// the rest too when flushing; returns what is left at the start of buf.
static size_t relay(pam_handle_t *pamh, char *buf, size_t len, int flush) {
    size_t start = 0;
    for (size_t i = 0; i < len; i++) {
        if (buf[i] == '\n') {
            emit(pamh, buf + start, i - start);
            start = i + 1;
        }
    }
    while (len - start >= MAX_LINE || (flush && len > start)) {
        size_t n = len - start < MAX_LINE ? len - start : MAX_LINE;
        emit(pamh, buf + start, n);
        start += n;
    }
    memmove(buf, buf + start, len - start);
    return len - start;
}

// Waits for the child until the deadline; then ends it.
static int reap(pid_t child, double deadline, int *status) {
    for (;;) {
        pid_t r = waitpid(child, status, WNOHANG);
        if (r == child) return 1;
        if (r < 0 && errno != EINTR) return 0;
        if (now() >= deadline) break;
        usleep(20000);
    }
    kill(child, SIGTERM);
    for (int i = 0; i < 50; i++) {
        if (waitpid(child, status, WNOHANG) == child) return 0;
        usleep(20000);
    }
    kill(child, SIGKILL);
    while (waitpid(child, status, 0) < 0 && errno == EINTR) {}
    return 0;
}

static int ask(pam_handle_t *pamh, const char *configured, int timeout) {
    char path[PATH_MAX];
    if (!trusted(configured, path)) return PAM_IGNORE;
    const char *user = NULL, *service = NULL, *tty = NULL;
    pam_get_item(pamh, PAM_USER, (const void **)&user);
    pam_get_item(pamh, PAM_SERVICE, (const void **)&service);
    pam_get_item(pamh, PAM_TTY, (const void **)&tty);
    char pid[16];
    snprintf(pid, sizeof pid, "%d", (int)getpid()); // sudo itself
    char *argv[] = {(char *)path, "pam", "--user", (char *)(user ? user : ""), "--service", (char *)(service ? service : ""),
                    "--tty", (char *)(tty ? tty : ""), "--pid", pid, NULL};
    char *envp[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};

    int fds[2];
    if (pipe(fds) != 0) return PAM_IGNORE;
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_init(&attr);
    // Nothing of sudo's but the three descriptors above, its signal mask
    // or its signal handlers reaches the child.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    sigset_t none, defaults;
    sigemptyset(&none);
    posix_spawnattr_setsigmask(&attr, &none);
    sigemptyset(&defaults);
    int sigs[] = {SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGALRM, SIGTERM, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU, SIGUSR1, SIGUSR2};
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaddset(&defaults, sigs[i]);
    posix_spawnattr_setsigdefault(&attr, &defaults);

    pid_t child;
    int rc = posix_spawn(&child, path, &fa, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        return PAM_IGNORE;
    }

    double deadline = now() + timeout;
    char buf[4 * MAX_LINE];
    size_t len = 0;
    int timedOut = 0;
    for (;;) {
        double left = deadline - now();
        if (left <= 0) {
            timedOut = 1;
            break;
        }
        struct pollfd p = {fds[0], POLLIN, 0};
        int n = poll(&p, 1, (int)(left * 1000) + 1);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) continue;
        ssize_t got = read(fds[0], buf + len, sizeof buf - len);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        len = relay(pamh, buf, len + (size_t)got, 0);
    }
    relay(pamh, buf, len, 1);
    close(fds[0]);
    int status = 0;
    int exited = reap(child, timedOut ? now() : deadline, &status);
    if (timedOut) return PAM_IGNORE;
    return exited && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? PAM_SUCCESS : PAM_IGNORE;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    silent = (flags & PAM_SILENT) != 0;
    const char *path = DEFAULT_PATH;
    int timeout = DEFAULT_TIMEOUT;
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "path=", 5) == 0) path = argv[i] + 5;
        if (strncmp(argv[i], "timeout=", 8) == 0) {
            int t = atoi(argv[i] + 8);
            if (t > 0 && t <= DEFAULT_TIMEOUT) timeout = t;
        }
    }
    return ask(pamh, path, timeout);
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}

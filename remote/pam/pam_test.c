// pam_test: runs pam_blitzkvm.so's pam_sm_authenticate without root and
// without sudo: a PAM handle for the "other" service with a conversation
// that records messages, and path= pointing at fake clients.
//
//   ./build/pam_test build/pam_blitzkvm.so

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <security/pam_appl.h>
#include <security/pam_modules.h>

typedef int (*pam_fn)(pam_handle_t *, int, int, const char **);

static char messages[32][600];
static int count;
static int failures;

static int conv(int n, const struct pam_message **msg, struct pam_response **resp, void *data) {
    (void)data;
    for (int i = 0; i < n; i++) {
        if (msg[i]->msg_style == PAM_TEXT_INFO && count < 32) {
            snprintf(messages[count++], sizeof messages[0], "%s", msg[i]->msg);
        }
    }
    *resp = calloc((size_t)n, sizeof **resp);
    return PAM_SUCCESS;
}

static void check(int ok, const char *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static int said(const char *needle) {
    for (int i = 0; i < count; i++) {
        if (strstr(messages[i], needle)) return 1;
    }
    return 0;
}

static void script(const char *dir, const char *name, const char *body, mode_t mode, char *out, size_t size) {
    snprintf(out, size, "%s/%s", dir, name);
    FILE *f = fopen(out, "w");
    fprintf(f, "#!/bin/sh\n%s", body);
    fclose(f);
    chmod(out, mode);
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int run(pam_fn authenticate, const char *path, const char *timeout) {
    struct pam_conv c = {conv, NULL};
    pam_handle_t *pamh = NULL;
    if (pam_start("other", "user", &c, &pamh) != PAM_SUCCESS) {
        fprintf(stderr, "pam_start failed\n");
        exit(2);
    }
    pam_set_item(pamh, PAM_TTY, "ttys001");
    char arg[1100];
    snprintf(arg, sizeof arg, "path=%s", path);
    const char *args[2] = {arg, timeout};
    count = 0;
    int rc = authenticate(pamh, 0, timeout ? 2 : 1, args);
    pam_end(pamh, rc);
    return rc;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: pam_test MODULE\n");
        return 2;
    }
    void *module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!module) {
        fprintf(stderr, "%s\n", dlerror());
        return 2;
    }
    pam_fn authenticate = (pam_fn)dlsym(module, "pam_sm_authenticate");
    pam_fn setcred = (pam_fn)dlsym(module, "pam_sm_setcred");
    if (!authenticate || !setcred) {
        fprintf(stderr, "the module lacks pam_sm_authenticate or pam_sm_setcred\n");
        return 2;
    }
    // Not in /tmp: the module refuses a client in a directory others can
    // write to, and /tmp is one.
    char dir[1024], cwd[900];
    if (!getcwd(cwd, sizeof cwd)) return 2;
    snprintf(dir, sizeof dir, "%s/build/fake.XXXXXX", cwd);
    if (!mkdtemp(dir)) return 2;
    char open[1024], inOpen[1024];
    snprintf(open, sizeof open, "%s/open", dir);
    mkdir(open, 0777);
    chmod(open, 0777);
    char ok[1024], deny[1024], slow[1024], env[1024], writable[1024], missing[1024], quiet[1024];
    script(dir, "ok", "echo 'BlitzKVM: approve on your iPhone or Mac (code 47)…'\necho \"args: $*\"\nexit 0\n", 0755, ok, sizeof ok);
    script(dir, "deny", "echo 'BlitzKVM: approve on your iPhone or Mac (code 12)…'\necho 'BlitzKVM: denied on Owner'\nexit 1\n",
           0755, deny, sizeof deny);
    script(dir, "slow", "echo 'BlitzKVM: waiting'\nexec sleep 30\n", 0755, slow, sizeof slow);
    script(dir, "env", "if read x; then echo 'stdin: data'; else echo 'stdin: empty'; fi\necho \"PATH=$PATH\"\n"
           "echo \"vars: $(env | wc -l | tr -d ' ')\"\nprintf 'no newline at the end'\nexit 0\n", 0755, env, sizeof env);
    script(dir, "writable", "echo 'should not run'\nexit 0\n", 0777, writable, sizeof writable);
    script(dir, "quiet", "exit 0\n", 0755, quiet, sizeof quiet);
    script(open, "ok", "echo 'should not run'\nexit 0\n", 0755, inOpen, sizeof inOpen);
    snprintf(missing, sizeof missing, "%s/missing", dir);

    check(run(authenticate, ok, NULL) == PAM_SUCCESS, "exit 0 is PAM_SUCCESS");
    check(count == 2 && said("(code 47)…"), "both lines relayed as PAM_TEXT_INFO");
    char want[128];
    snprintf(want, sizeof want, "args: pam --user user --service other --tty ttys001 --pid %d", (int)getpid());
    check(said(want), "the client gets user, service, tty and the caller's pid");

    check(run(authenticate, deny, NULL) == PAM_IGNORE, "exit 1 is PAM_IGNORE (the password comes next)");
    check(count == 2 && said("denied on Owner"), "a denial's lines relayed");

    double t0 = now();
    check(run(authenticate, slow, "timeout=1") == PAM_IGNORE, "a client that doesn't finish is PAM_IGNORE");
    double took = now() - t0;
    check(took >= 0.9 && took < 3, "... after the timeout, and killed");
    check(said("BlitzKVM: waiting"), "... with what it said before");

    check(run(authenticate, env, NULL) == PAM_SUCCESS, "env client");
    check(said("stdin: empty"), "stdin is /dev/null");
    check(said("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), "a clean PATH");
    check(said("vars: ") && (said("vars: 1") || said("vars: 2") || said("vars: 3") || said("vars: 4")),
          "a clean environment (the shell adds a few)");
    check(said("no newline at the end"), "a last line without a newline is relayed");

    check(run(authenticate, writable, NULL) == PAM_IGNORE && count == 0, "a group/world-writable client isn't run");
    check(run(authenticate, inOpen, NULL) == PAM_IGNORE && count == 0, "a client in a world-writable directory isn't run");
    check(run(authenticate, "/tmp/../tmp", NULL) == PAM_IGNORE && count == 0, "a directory isn't a client");
    check(run(authenticate, missing, NULL) == PAM_IGNORE && count == 0, "a missing client is PAM_IGNORE");
    check(run(authenticate, quiet, NULL) == PAM_SUCCESS && count == 0, "a silent approval says nothing");
    check(setcred(NULL, 0, 0, NULL) == PAM_SUCCESS, "pam_sm_setcred is PAM_SUCCESS");

    char cmd[1100];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
    system(cmd);
    if (failures) {
        printf("pam_test: %d failed\n", failures);
        return 1;
    }
    printf("pam_test: all checks passed\n");
    return 0;
}

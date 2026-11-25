#include "T3LaunchProtocol.h"

#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static void fail(enum t3_launch_stage stage) {
    t3_failure error = {stage, errno};
    while (write(T3_LAUNCH_STATUS_FD, &error, sizeof(error)) < 0 && errno == EINTR) {}
    _exit(126);
}

static void environment(const char *name, const char *value) {
    if (setenv(name, value, 1) < 0) fail(T3_ENVIRONMENT);
}

static void configure_zsh(void) {
    if (!getenv("PROMPT_EOL_MARK")) environment("PROMPT_EOL_MARK", "");
    char executable[PATH_MAX], resource[PATH_MAX];
    uint32_t length = sizeof(executable);
    if (_NSGetExecutablePath(executable, &length) != 0) return;
    char *leaf = strrchr(executable, '/');
    if (!leaf) return;
    *leaf = 0;
    int used = snprintf(resource, sizeof(resource), "%s/ShellStartup/.zshenv", executable);
    if (used < 0 || (size_t)used >= sizeof(resource) || access(resource, R_OK) != 0) return;
    const char *original = getenv("ZDOTDIR");
    environment("T3RM_HAD_ZDOTDIR", original ? "1" : "0");
    if (original) environment("T3RM_ORIGINAL_ZDOTDIR", original);
    *strrchr(resource, '/') = 0;
    environment("ZDOTDIR", resource);
}

int t3_run_launcher(int argc, char **argv) {
    if (argc != 4 || fcntl(T3_LAUNCH_STATUS_FD, F_SETFD, FD_CLOEXEC) < 0) return 126;
    if (setsid() < 0 || ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0 ||
        tcsetpgrp(STDIN_FILENO, getpgrp()) < 0) fail(T3_TERMINAL);

    const char *shell = argv[1];
    const char *directory = argv[2];
    const struct passwd *user = getpwuid(getuid());
    if (user) {
        environment("USER", user->pw_name);
        environment("LOGNAME", user->pw_name);
        environment("HOME", user->pw_dir);
    }
    environment("TERM", "xterm-256color");
    environment("COLORTERM", "truecolor");
    environment("TERM_PROGRAM", "t3rm");
    environment("LC_TERMINAL", "t3rm");
    environment("SHELL", shell);
    if (*argv[3]) environment("LANG", argv[3]);
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    environment("PATH", "/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin");
#endif
    if (!*directory) directory = getenv("HOME");
    if (chdir(directory && *directory ? directory : "/") < 0) fail(T3_DIRECTORY);
    unsetenv("PWD"); /* the shell computes PWD from its new directory */
    const char *name = strrchr(shell, '/');
    if (name && strcmp(name + 1, "zsh") == 0) configure_zsh();
    execl(shell, name ? name + 1 : shell, "-l", "-i", (char *)NULL);
    fail(T3_EXEC);
    return 126;
}

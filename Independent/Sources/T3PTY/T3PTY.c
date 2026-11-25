#include "T3PTY.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <termios.h>

extern char **environ;

const char *t3_operation(t3_failure failure) {
    switch (failure.stage) {
        case T3_ALLOCATE: return "Open terminal";
        case T3_SPAWN: return "Start terminal launcher";
        case T3_TERMINAL: return "Attach controlling terminal";
        case T3_ENVIRONMENT: return "Set shell environment";
        case T3_DIRECTORY: return "Open shell directory";
        case T3_EXEC: return "Execute shell";
        case T3_HANDSHAKE: return "Read launcher status";
        case T3_MONITOR: return "Monitor terminal";
    }
    return "Start session";
}

int t3_resize(int fd, uint16_t columns, uint16_t rows) {
    struct winsize size = {.ws_col = columns, .ws_row = rows};
    return ioctl(fd, TIOCSWINSZ, &size);
}

static int change(int events, uintptr_t ident, int16_t filter, uint16_t flags,
                  uint32_t fflags, intptr_t data) {
    struct kevent event;
    EV_SET(&event, ident, filter, flags, fflags, data, NULL);
    int result;
    do { result = kevent(events, &event, 1, NULL, 0, NULL); }
    while (result < 0 && errno == EINTR);
    return result;
}

int t3_wake(int events) {
    return change(events, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0);
}

int t3_writable(int events, int master, int enabled) {
    return change(events, master, EVFILT_WRITE, enabled ? EV_ENABLE : EV_DISABLE, 0, 0);
}

int t3_wait_event(int events, int timeout_ms) {
    struct timespec timeout = {0};
    if (timeout_ms >= 0) {
        timeout.tv_sec = timeout_ms / 1000;
        timeout.tv_nsec = (timeout_ms % 1000) * 1000000L;
    }
    struct kevent ready[4];
    int count = kevent(events, NULL, 0, ready, 4, timeout_ms < 0 ? NULL : &timeout);
    return count < 0 && errno == EINTR ? 0 : count;
}

int t3_available(int fd) {
    int available;
    return ioctl(fd, FIONREAD, &available) < 0 ? -1 : available;
}

pid_t t3_foreground(int fd) {
    pid_t group;
    return ioctl(fd, TIOCGPGRP, &group) < 0 ? -1 : group;
}

/* The PTY driver signals its current foreground pgrp under its tty lock. A
   pipeline's group can outlive its leader. Never reuse a saved numeric pgid. */
int t3_signal_foreground(int master, pid_t session, int signal_number) {
    if (tcgetsid(master) != session) return -1;
    // TIOCSIG normally flushes pending output. Preserve its final bytes for
    // the worker's exit drain while shutting down this terminal.
    struct termios settings;
    if (tcgetattr(master, &settings) == 0 && !(settings.c_lflag & NOFLSH)) {
        settings.c_lflag |= NOFLSH;
        tcsetattr(master, TCSANOW, &settings);
    }
    return ioctl(master, TIOCSIG, signal_number);
}

int t3_reap(pid_t child, int *exit_code) {
    int status;
    pid_t result;
    do { result = waitpid(child, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result <= 0) return (int)result;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 1;
}

static void close_fd(int fd) {
    if (fd >= 0) close(fd);
}

/* Keep source descriptors out of the fixed 0..3 child interface, including
   when a caller has started with one of the standard descriptors closed. */
static int reserve_source(int *source) {
    if (*source > T3_LAUNCH_STATUS_FD) return fcntl(*source, F_SETFD, FD_CLOEXEC);
    int copy = fcntl(*source, F_DUPFD_CLOEXEC, T3_LAUNCH_STATUS_FD + 1);
    if (copy < 0) return -1;
    close(*source);
    *source = copy;
    return 0;
}

static int spawn_launcher(pid_t *pid, const char *launcher, const char *shell,
                          const char *directory, const char *locale, int slave, int report) {
    posix_spawn_file_actions_t files;
    int error = posix_spawn_file_actions_init(&files);
    if (error) return error;
    posix_spawnattr_t attributes;
    error = posix_spawnattr_init(&attributes);
    if (error) {
        posix_spawn_file_actions_destroy(&files);
        return error;
    }
    for (int fd = STDIN_FILENO; !error && fd <= STDERR_FILENO; fd++)
        error = posix_spawn_file_actions_adddup2(&files, slave, fd);
    if (!error) error = posix_spawn_file_actions_adddup2(&files, report, T3_LAUNCH_STATUS_FD);
    sigset_t defaults, mask;
    sigfillset(&defaults);
    sigdelset(&defaults, SIGSTOP);
    sigdelset(&defaults, SIGKILL);
    sigemptyset(&mask);
    if (!error) error = posix_spawnattr_setsigdefault(&attributes, &defaults);
    if (!error) error = posix_spawnattr_setsigmask(&attributes, &mask);
    if (!error) error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT |
                                                  POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    if (!error) {
        char *args[] = {"t3rm-pty-helper", (char *)shell, (char *)directory, (char *)locale, NULL};
        error = posix_spawn(pid, launcher, &files, &attributes, args, environ);
    }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&files);
    return error;
}

static int check_launcher(int fd, t3_failure *failure) {
    struct pollfd status = {.fd = fd, .events = POLLIN};
    int ready;
    do { ready = poll(&status, 1, 5000); } while (ready < 0 && errno == EINTR);
    if (ready <= 0) {
        *failure = (t3_failure){T3_HANDSHAKE, ready == 0 ? ETIMEDOUT : errno};
        return -1;
    }
    t3_failure detail;
    ssize_t length;
    do { length = read(fd, &detail, sizeof(detail)); } while (length < 0 && errno == EINTR);
    if (length == 0) return 0;
    *failure = length == sizeof(detail) ? detail : (t3_failure){T3_HANDSHAKE, length < 0 ? errno : EPROTO};
    return -1;
}

int t3_start(const char *launcher, const char *shell, const char *directory, const char *locale,
             uint16_t columns, uint16_t rows, t3_pty *result, t3_failure *failure) {
    t3_pty pty = {-1, -1, -1, -1};
    int report[2] = {-1, -1};
    char slave_path[PATH_MAX];
    failure->stage = T3_ALLOCATE;
    pty.master = posix_openpt(O_RDWR | O_NOCTTY);
    if (pty.master < 0 || fcntl(pty.master, F_SETFD, FD_CLOEXEC) < 0 ||
        grantpt(pty.master) < 0 || unlockpt(pty.master) < 0) goto fail_errno;
    int error = ptsname_r(pty.master, slave_path, sizeof(slave_path));
    if (error) {
        failure->number = error < 0 ? errno : error;
        goto fail;
    }
    pty.slave = open(slave_path, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (pty.slave < 0 || reserve_source(&pty.slave) < 0 ||
        t3_resize(pty.slave, columns, rows) < 0 ||
        fcntl(pty.master, F_SETFL, O_NONBLOCK) < 0) goto fail_errno;

    failure->stage = T3_MONITOR;
    pty.events = kqueue();
    if (pty.events < 0 || fcntl(pty.events, F_SETFD, FD_CLOEXEC) < 0 ||
        change(pty.events, pty.master, EVFILT_READ, EV_ADD, 0, 0) < 0 ||
        change(pty.events, pty.master, EVFILT_WRITE, EV_ADD | EV_DISABLE, 0, 0) < 0 ||
        change(pty.events, 1, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0) < 0) goto fail_errno;

    failure->stage = T3_SPAWN;
    if (pipe(report) < 0 || fcntl(report[0], F_SETFD, FD_CLOEXEC) < 0 ||
        reserve_source(&report[1]) < 0) goto fail_errno;
    error = spawn_launcher(&pty.child, launcher, shell, directory, locale, pty.slave, report[1]);
    if (error) {
        pty.child = -1;
        failure->number = error;
        goto fail;
    }
    close(report[1]);
    report[1] = -1;
    if (check_launcher(report[0], failure) < 0) goto fail;

    /* A process can finish before registration. The worker always calls
       waitpid before sleeping. Restricted process monitoring falls back to a timer. */
    failure->stage = T3_MONITOR;
    if (change(pty.events, pty.child, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0) < 0 &&
        errno != ESRCH && change(pty.events, 2, EVFILT_TIMER, EV_ADD, 0, 250) < 0) goto fail_errno;
    close(report[0]);
    *result = pty;
    return 0;

fail_errno:
    failure->number = errno;
fail:
    if (pty.child > 0) {
        kill(pty.child, SIGKILL);
        while (waitpid(pty.child, NULL, 0) < 0 && errno == EINTR) {}
    }
    close_fd(report[0]);
    close_fd(report[1]);
    close_fd(pty.events);
    close_fd(pty.slave);
    close_fd(pty.master);
    return -1;
}

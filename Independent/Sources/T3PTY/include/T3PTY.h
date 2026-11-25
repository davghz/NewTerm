#ifndef T3_PTY_H
#define T3_PTY_H

#include <stdint.h>
#include <sys/types.h>
#include "T3LaunchProtocol.h"

typedef struct {
    int master, slave, events;
    pid_t child;
} t3_pty;

/* The parent owns all three descriptors and is responsible for reaping child. */
int t3_start(const char *launcher, const char *shell, const char *directory, const char *locale,
             uint16_t columns, uint16_t rows, t3_pty *pty, t3_failure *failure);
const char *t3_operation(t3_failure failure);
int t3_resize(int fd, uint16_t columns, uint16_t rows);
int t3_wake(int events);
int t3_writable(int events, int master, int enabled);
int t3_wait_event(int events, int timeout_ms);
int t3_available(int fd);
pid_t t3_foreground(int fd);
int t3_signal_foreground(int master, pid_t session, int signal_number);
/* 1 reaped, 0 alive, -1 if another process handler has already reaped it. */
int t3_reap(pid_t child, int *exit_code);

#endif

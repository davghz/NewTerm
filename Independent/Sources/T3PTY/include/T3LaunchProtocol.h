#ifndef T3_LAUNCH_PROTOCOL_H
#define T3_LAUNCH_PROTOCOL_H

/* Descriptor private to the launcher. On successful shell exec, CLOEXEC signals EOF. */
#define T3_LAUNCH_STATUS_FD 3

int t3_run_launcher(int argc, char **argv);

enum t3_launch_stage {
    T3_ALLOCATE, T3_SPAWN, T3_TERMINAL, T3_ENVIRONMENT,
    T3_DIRECTORY, T3_EXEC, T3_HANDSHAKE, T3_MONITOR
};

typedef struct {
    enum t3_launch_stage stage;
    int number;
} t3_failure;

#endif

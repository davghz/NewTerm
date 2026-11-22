//
//  NewTermCommon.h
//  NewTerm
//
//  Created by Adam Demasi on 20/6/19.
//

#import <TargetConditionals.h>
#import <spawn.h>
#import <pwd.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <string.h>
#import <stdbool.h>

static inline bool nt_foreground_is_codex(int tty) {
	pid_t group = tcgetpgrp(tty);
	if (group <= 0) return false;
	int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, group };
	struct kinfo_proc info = {0};
	size_t size = sizeof(info);
	return sysctl(mib, 4, &info, &size, NULL, 0) == 0 && size == sizeof(info)
		&& strcmp(info.kp_proc.p_comm, "codex") == 0;
}

#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
static inline int ie_getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t buflen, struct passwd **pwretp) {
	return getpwuid_r(uid, pw, buf, buflen, pwretp);
}

static inline int ie_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
	return posix_spawn(pid, path, file_actions, attrp, argv, envp);
}
#else
extern int ie_getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t buflen, struct passwd **pwretp);
extern int ie_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]);
#endif

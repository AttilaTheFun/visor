// Starting a process on a pseudo-terminal that is its controlling
// terminal. posix_spawn can make a new session but cannot give it a
// controlling terminal on macOS: opening a terminal there never acquires
// one, it takes ioctl(TIOCSCTTY) in the child. Without it a shell has no
// job control or line editing, and Ctrl-C signals nothing.

#ifndef VISOR_PTY_H
#define VISOR_PTY_H

#include <sys/types.h>

/// Starts `path` with `argv` and `envp` in `directory`, as the leader of a
/// new session whose controlling terminal is `terminal` (the slave end of
/// a pseudo-terminal), which also becomes its standard input, output and
/// error. Signal handlers and the signal mask start at their defaults, and
/// no other descriptor is inherited. Returns the child's process id, or -1
/// with errno set.
pid_t visor_spawn_on_terminal(const char *path, char *const argv[], char *const envp[], const char *directory,
                              int terminal);

#endif

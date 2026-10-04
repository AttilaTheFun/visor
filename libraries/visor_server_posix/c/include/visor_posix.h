// The system calls whose shape differs between POSIX systems (macOS and
// Linux): constants Swift cannot import, structures laid out differently,
// and the one thing Swift must not do itself — run code in a forked child.
// Everything else the POSIX platform does is Swift.

#ifndef VISOR_POSIX_H
#define VISOR_POSIX_H

#include <stddef.h>
#include <sys/types.h>

/// Opens a pseudo-terminal: returns its master (close-on-exec), and writes
/// the slave's path into `slave` (`capacity` bytes). -1 with errno set.
int visor_open_terminal(char *slave, size_t capacity);

/// Starts `path` with `argv` and `envp` in `directory`, as the leader of a
/// new session whose controlling terminal is `terminal` (the slave end of
/// a pseudo-terminal), which also becomes its standard input, output and
/// error. Signal handlers and the signal mask start at their defaults, and
/// no other descriptor is inherited. Returns the child's process id, or -1
/// with errno set. (posix_spawn can make a new session but cannot give it a
/// controlling terminal on macOS: that takes ioctl(TIOCSCTTY) in the child.
/// Without it a shell has no job control or line editing, and Ctrl-C
/// signals nothing.)
pid_t visor_spawn_on_terminal(const char *path, char *const argv[], char *const envp[], const char *directory,
                              int terminal);

/// Tells a terminal (the slave end) its shape. 0, or -1 with errno set.
int visor_set_terminal_size(int terminal, unsigned short cols, unsigned short rows);

/// Starts `path` with `argv` and `envp` as the leader of a new session with
/// no terminal — a daemon — its standard input /dev/null and its output and
/// errors `log`. Returns its process id, or -1 with errno set.
pid_t visor_spawn_detached(const char *path, char *const argv[], char *const envp[], int log);

/// A TCP socket listening on 127.0.0.1:`port` (close-on-exec, the address
/// reusable at once). -1 with errno set.
int visor_listen_loopback(unsigned short port);

/// The next connection on a listening socket (close-on-exec, its writes
/// given up after 30 seconds of a peer that reads nothing). -1 with errno
/// set.
int visor_accept(int listener);

/// Ends both directions of a socket, waking whoever is blocked on it.
void visor_shutdown(int socket);

/// Writing to a pipe or socket whose reader has gone fails the write
/// (EPIPE) rather than ending the process.
void visor_ignore_broken_pipes(void);

#endif

// The system calls whose shape differs between POSIX systems (macOS and
// Linux): constants Swift cannot import, structures laid out differently,
// and the one thing Swift must not do itself — run code in a forked child.
// Everything else the POSIX platform does is Swift.

#ifndef VISOR_POSIX_H
#define VISOR_POSIX_H

#include <stddef.h>
#include <sys/types.h>

/// Starts `path` with `argv` and `envp` as the leader of a new session with
/// no terminal — a daemon — its standard input /dev/null and its output and
/// errors `log`. Returns its process id, or -1 with errno set.
pid_t visor_spawn_detached(const char *path, char *const argv[], char *const envp[], int log);

/// Starts `path` with `argv` and `envp` in `directory` on pipes, as the
/// leader of a process group of its own (so it and what it runs can be
/// signalled together): `pipes` gets the end that writes its standard
/// input and the ends that read its output and errors, all close-on-exec.
/// Signal handlers and the mask start at their defaults, and no other
/// descriptor is inherited. Returns the child's process id, or -1 with
/// errno set.
pid_t visor_spawn_piped(const char *path, char *const argv[], char *const envp[], const char *directory, int pipes[3]);

/// Waits for a child to end: 0 with its exit status (or the signal that
/// ended it, with `signaled` set), or -1 with errno set.
int visor_wait(pid_t pid, int *status, int *signaled);

/// A process as the memory guard sees it: who started it, and how much
/// memory it holds (its footprint on macOS, its resident size on Linux).
struct visor_process {
    pid_t pid;
    pid_t parent;
    unsigned long long memory;
    char name[64];
};

/// Every process the system will tell of, into `out` (`capacity` of them):
/// how many were written, or -1 with errno set.
int visor_processes(struct visor_process *out, int capacity);

/// How much memory this computer has, in bytes.
unsigned long long visor_physical_memory(void);

/// A TCP socket listening on 127.0.0.1:`port` (close-on-exec, the address
/// reusable at once). -1 with errno set.
int visor_listen(unsigned short port, int everywhere);

/// A Unix domain socket listening at `path` (a stale file there replaced;
/// the new one readable and writable by its owner alone). -1 with errno set.
int visor_listen_unix(const char *path);

/// A connection to the Unix domain socket at `path` (close-on-exec, its
/// writes given up after 30 seconds of a peer that reads nothing). -1 with
/// errno set.
int visor_connect_unix(const char *path);

/// A TCP connection to `host` (a name or an address) at `port`
/// (close-on-exec, its writes given up after 30 seconds of a peer that
/// reads nothing). -1 with errno set.
int visor_connect_tcp(const char *host, unsigned short port);

/// Whether something listens at the Unix domain socket `path` now: 1 when a
/// connection to it is taken, 0 otherwise (no file, a stale one).
int visor_unix_answers(const char *path);

/// The next connection on a listening socket (close-on-exec, its writes
/// given up after 30 seconds of a peer that reads nothing). -1 with errno
/// set.
int visor_accept(int listener);

/// This computer's address a connected socket arrived on, as text into
/// `out` (of `size`); "" for a socket file or when unknown.
void visor_local_address(int socket, char *out, size_t size);

/// Ends both directions of a socket, waking whoever is blocked on it.
void visor_shutdown(int socket);

/// Writing to a pipe or socket whose reader has gone fails the write
/// (EPIPE) rather than ending the process.
void visor_ignore_broken_pipes(void);

#endif

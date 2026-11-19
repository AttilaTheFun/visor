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
/// errors `log`. Returns its process id once the program has started, or
/// -1 with errno set (the program's own, when it could not be started: not
/// there, say).
pid_t relay_client_spawn_detached(const char *path, char *const argv[], char *const envp[], int log);

/// Starts `path` with `argv` and `envp` in `directory` on pipes, as the
/// leader of a process group of its own (so it and what it runs can be
/// signalled together): `pipes` gets the end that writes its standard
/// input and the ends that read its output and errors, all close-on-exec.
/// Signal handlers and the mask start at their defaults, and no other
/// descriptor is inherited. Returns the child's process id, or -1 with
/// errno set.
pid_t relay_client_spawn_piped(const char *path, char *const argv[], char *const envp[], const char *directory, int pipes[3]);

/// A name resolved as any program resolves it (IPv4, the system's resolver)
/// and a TCP connection to it at `port`, reads and writes waiting at most
/// `seconds`: the connection, with the address written into `address`
/// (`size` bytes); -2 when the name didn't resolve; -1 with errno set when
/// the connection wasn't made.
int relay_client_resolve_connect(const char *host, unsigned short port, int seconds, char *address, size_t size);

/// relay-client's network, set up over netlink in this process's own
/// network namespace (Linux, root there): loopback up, holding `source`
/// (an IPv4 address), the default route through loopback from it, and the
/// nftables table `ip relay_client`, made anew, whose output chain (nat,
/// priority -100) returns for 127.0.0.0/8 and redirects every other TCP
/// connection to `port`. 0, or -1 with what failed written to `problem`.
int relay_client_container_network(unsigned short port, const char *source, char *problem, size_t size);

/// Starts `path` with `argv` and `envp` as a child that keeps this
/// process's standard input, output and errors and its process group
/// (relay-client's workload). Signal handlers and the mask start at
/// their defaults, and no other descriptor is inherited. Returns its
/// process id, or -1 with errno set.
pid_t relay_client_spawn_inheriting(const char *path, char *const argv[], char *const envp[]);

/// Waits for a child to end: 0 with its exit status (or the signal that
/// ended it, with `signaled` set), or -1 with errno set.
int relay_client_wait(pid_t pid, int *status, int *signaled);

/// A process as the memory guard sees it: who started it, and how much
/// memory it holds (its footprint on macOS, its resident size on Linux).
struct relay_client_process {
    pid_t pid;
    pid_t parent;
    unsigned long long memory;
    char name[64];
};

/// Every process the system will tell of, into `out` (`capacity` of them):
/// how many were written, or -1 with errno set.
int relay_client_processes(struct relay_client_process *out, int capacity);

/// How much memory this computer has, in bytes.
unsigned long long relay_client_physical_memory(void);

/// A TCP socket listening on 127.0.0.1:`port` (close-on-exec, the address
/// reusable at once). -1 with errno set.
int relay_client_listen(unsigned short port, int everywhere);

/// A TCP socket listening on every IPv6 address at `port`, IPv6 alone
/// (beside `relay_client_listen`'s IPv4; close-on-exec, the address reusable at
/// once). -1 with errno set.
int relay_client_listen6(unsigned short port);

/// A Unix domain socket listening at `path` (a stale file there replaced;
/// the new one readable and writable by its owner alone). -1 with errno set.
int relay_client_listen_unix(const char *path);

/// A connection to the Unix domain socket at `path` (close-on-exec, its
/// writes given up after 30 seconds of a peer that reads nothing). -1 with
/// errno set.
int relay_client_connect_unix(const char *path);

/// A TCP connection to `host` (a name or an address) at `port`
/// (close-on-exec, its writes given up after 30 seconds of a peer that
/// reads nothing). -1 with errno set.
int relay_client_connect_tcp(const char *host, unsigned short port);

/// As relay_client_connect_tcp, but only to an address off this computer: the
/// name is resolved here and loopback, link-local, unspecified and multicast
/// addresses are skipped (IPv4, IPv6, and IPv4 in IPv6), so a name can't lead
/// a proxied connection back to the computer's own services. -1 with errno
/// EACCES when every address was one of those.
int relay_client_connect_tcp_public(const char *host, unsigned short port);

/// Whether something listens at the Unix domain socket `path` now: 1 when a
/// connection to it is taken, 0 otherwise (no file, a stale one).
int relay_client_unix_answers(const char *path);

/// The next connection on a listening socket (close-on-exec, its writes
/// given up after 30 seconds of a peer that reads nothing). -1 with errno
/// set only once the listener is closed or shut down: a connection's own
/// failure, or a passing shortage, waits for the next one.
int relay_client_accept(int listener);

/// This computer's address a connected socket arrived on, as text into
/// `out` (of `size`); "" for a socket file or when unknown.
void relay_client_local_address(int socket, char *out, size_t size);

/// Ends both directions of a socket, waking whoever is blocked on it.
void relay_client_shutdown(int socket);

/// Ends the sending direction of a socket alone: its peer reads the end,
/// and can still answer.
void relay_client_shutdown_write(int socket);

/// Writing to a pipe or socket whose reader has gone fails the write
/// (EPIPE) rather than ending the process.
void relay_client_ignore_broken_pipes(void);

/// Where a connection redirected to this listener was going, before
/// netfilter's redirect (SO_ORIGINAL_DST, Linux's IPv4): its address,
/// written into `host` (`size` bytes, 46 is enough), and its port. 0, or
/// -1 with errno set (ENOTSUP where there is no such thing).
int relay_client_original_destination(int socket, char *host, size_t size, unsigned short *port);

#endif

// The agent proxy's sockets (AgentProxy): listening, accepting, connecting
// and shutting down, in C because their shapes differ between macOS and
// Linux. Moved from MultiPass's CMultiPassPOSIX (its `visor_` calls), only
// the ones the relay listener and the egress proxy use (Logan, 2026-11-14).

#ifndef AGENT_PROXY_POSIX_H
#define AGENT_PROXY_POSIX_H

#include <stddef.h>

/// A TCP socket listening on 127.0.0.1:`port`, or on every IPv4 address
/// with `everywhere` (close-on-exec, the address reusable at once). -1 with
/// errno set.
int agent_proxy_listen(unsigned short port, int everywhere);

/// A TCP socket listening on every IPv6 address at `port`, IPv6 alone
/// (beside `agent_proxy_listen`'s IPv4; close-on-exec, the address reusable
/// at once). -1 with errno set.
int agent_proxy_listen6(unsigned short port);

/// A TCP connection to `host` (a name or an address) at `port`
/// (close-on-exec, its writes given up after 30 seconds of a peer that
/// reads nothing). -1 with errno set.
int agent_proxy_connect_tcp(const char *host, unsigned short port);

/// A TCP connection for an agent's egress: the name resolved here, and each
/// address it resolves to checked before it is connected to
/// (agent_proxy_address_allowed, with `allowed` and `private_allowed`), so
/// no name leads a proxied connection back to this computer or, unless
/// allowed, to its networks. -1 with errno EACCES when every address was
/// refused.
int agent_proxy_connect_tcp_egress(const char *host, unsigned short port, const char *allowed, int private_allowed);

/// agent_proxy_connect_tcp_egress, each address also within `pin` (CIDRs,
/// or bare addresses, one a line; none or empty: no pin), public or
/// private: a destination `egressAllow` pins (`host:port@CIDR`), so a name
/// rebound elsewhere reaches nothing.
int agent_proxy_connect_tcp_egress_pinned(const char *host, unsigned short port, const char *allowed, int private_allowed,
                                          const char *pin);

/// agent_proxy_connect_tcp_egress with nothing allowed beyond the internet.
int agent_proxy_connect_tcp_public(const char *host, unsigned short port);

/// 1 when this thread's last connection (any of the above) failed reaching
/// a private address (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7)
/// with EHOSTUNREACH or EPERM: on macOS, a process without the Local
/// Network permission (a launchd job can't answer its prompt). Else 0.
int agent_proxy_last_failure_private(void);

/// Whether an agent's egress may reach `address` (IPv4 or IPv6, as text):
/// 1, or 0 when refused. IPv4 carried in IPv6 (mapped ::ffff:0:0/96,
/// compatible ::/96, NAT64 64:ff9b::/96 and, for local use, 64:ff9b:1::/48
/// (the IPv4 after a /96 or a /48, each judged), 6to4 2002::/16, Teredo
/// 2001::/32 (its server's IPv4 and its client's, inverted)) is judged by
/// the IPv4 it carries: refused if any is.
/// - Always refused: this computer's own interfaces' addresses (asked of
///   the system at each call), loopback, unspecified, link-local, multicast,
///   0/8 and 224/4 and above.
/// - Refused unless `private_allowed`, or `allowed` (CIDRs, or bare
///   addresses, one a line) holds it: 10/8, 172.16/12, 192.168/16, 100.64/10
///   (CGNAT, a tailnet's), fc00::/7 (a tailnet's fd7a:115c:a1e0::/48 too).
/// - Anything else, the internet, is allowed.
int agent_proxy_address_allowed(const char *address, const char *allowed, int private_allowed);

/// agent_proxy_address_allowed, and within `pin` too when it names any
/// (agent_proxy_connect_tcp_egress_pinned's check).
int agent_proxy_address_allowed_pinned(const char *address, const char *allowed, int private_allowed, const char *pin);

/// Whether `text` is a CIDR (`10.0.0.0/8`, `fd7a:115c:a1e0::/48`) or a bare
/// address: 1, or 0.
int agent_proxy_cidr_valid(const char *text);

/// This computer's interfaces' addresses, as text, one a line, into `out`
/// (of `size`): how many were written, or -1 with errno set.
int agent_proxy_interface_addresses(char *out, size_t size);

/// Reads on `socket` given up after `seconds` with nothing (0: waited for
/// as long as it takes).
void agent_proxy_set_receive_timeout(int socket, int seconds);

/// Reads on `socket` given up after `milliseconds` (at least 1) with nothing.
void agent_proxy_set_receive_timeout_ms(int socket, int milliseconds);

/// The egress log's file at `path`, opened to append, never through a
/// symbolic link: made (mode 0600) when it isn't there, else opened and
/// set to 0600. The descriptor (close-on-exec), or -1 with errno set.
int agent_proxy_open_log(const char *path);

/// The next connection on a listening socket (close-on-exec, its writes
/// given up after 30 seconds of a peer that reads nothing). -1 with errno
/// set only once the listener is closed or shut down: a connection's own
/// failure, or a passing shortage, waits for the next one.
int agent_proxy_accept(int listener);

/// Ends both directions of a socket, waking whoever is blocked on it.
void agent_proxy_shutdown(int socket);

/// Ends the sending direction of a socket alone: its peer reads the end,
/// and can still answer.
void agent_proxy_shutdown_write(int socket);

/// Writing to a pipe or socket whose reader has gone fails the write
/// (EPIPE) rather than ending the process.
void agent_proxy_ignore_broken_pipes(void);

#endif

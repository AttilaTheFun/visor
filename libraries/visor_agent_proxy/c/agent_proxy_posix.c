// The agent proxy's sockets: agent_proxy_posix.h says what each does.
// Moved from MultiPass's multipass_posix.c as it was (Logan, 2026-11-14).

#define _GNU_SOURCE
#include "agent_proxy_posix.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <ifaddrs.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

int agent_proxy_listen(unsigned short port, int everywhere) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    (void)fcntl(listener, F_SETFD, FD_CLOEXEC);
    int yes = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(everywhere ? INADDR_ANY : INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0 || listen(listener, 64) != 0) {
        int error = errno;
        close(listener);
        errno = error;
        return -1;
    }
    return listener;
}

int agent_proxy_listen6(unsigned short port) {
    int listener = socket(AF_INET6, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    (void)fcntl(listener, F_SETFD, FD_CLOEXEC);
    int yes = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    setsockopt(listener, IPPROTO_IPV6, IPV6_V6ONLY, &yes, sizeof yes);
    struct sockaddr_in6 address;
    memset(&address, 0, sizeof address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(port);
    address.sin6_addr = in6addr_any;
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0 || listen(listener, 64) != 0) {
        int error = errno;
        close(listener);
        errno = error;
        return -1;
    }
    return listener;
}

// The egress policy (NCH's review of #414): what an agent's connection may
// reach, judged on each address a name resolves to, the one then connected
// to, so a name that resolves differently later changes nothing.

enum { REFUSED = 0, PRIVATE = 1, PUBLIC = 2 };

/// An address as the policy sees it: its family and 16 bytes (IPv4's in the
/// first four), and, for IPv6 carrying IPv4, that IPv4 (Teredo carries two:
/// its server's and its client's).
struct agent_proxy_address {
    int family;
    unsigned char bytes[16];
    int carried;
    unsigned char ipv4[2][4];
};

static void agent_proxy_carry(struct agent_proxy_address *to, const unsigned char *ipv4) {
    if (to->carried < 2) memcpy(to->ipv4[to->carried++], ipv4, 4);
}

static void agent_proxy_address_from(const struct sockaddr *from, struct agent_proxy_address *to) {
    memset(to, 0, sizeof *to);
    to->family = from->sa_family;
    if (from->sa_family == AF_INET) {
        memcpy(to->bytes, &((const struct sockaddr_in *)from)->sin_addr, 4);
        return;
    }
    if (from->sa_family != AF_INET6) return;
    const unsigned char *a = ((const struct sockaddr_in6 *)from)->sin6_addr.s6_addr;
    memcpy(to->bytes, a, 16);
    static const unsigned char zero[12] = {0};
    static const unsigned char mapped[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
    static const unsigned char nat64[12] = {0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0};
    static const unsigned char local_nat64[6] = {0, 0x64, 0xff, 0x9b, 0, 0x01};
    static const unsigned char none[4] = {0};
    if (memcmp(a, mapped, 12) == 0 || memcmp(a, nat64, 12) == 0) {
        // ::ffff:a.b.c.d, 64:ff9b::a.b.c.d
        agent_proxy_carry(to, a + 12);
    } else if (memcmp(a, local_nat64, 6) == 0) {
        // 64:ff9b:1::/48 (RFC 8215, NAT64 for local use; NCH's review of
        // #414), its IPv4 where a translator's prefix puts it: after a /96
        // (bytes 12-15) or a /48 (bytes 6, 7, 9 and 10, past RFC 6052's u
        // octet). Each that isn't 0.0.0.0 is judged, so an address read
        // either way is refused if either reading is; one with neither is
        // judged as 0.0.0.0, refused.
        unsigned char at48[4] = {a[6], a[7], a[9], a[10]};
        if (memcmp(a + 12, none, 4) != 0) agent_proxy_carry(to, a + 12);
        if (memcmp(at48, none, 4) != 0) agent_proxy_carry(to, at48);
        if (to->carried == 0) agent_proxy_carry(to, none);
    } else if (memcmp(a, zero, 12) == 0) {
        // ::a.b.c.d (compatible; :: and ::1 among them, judged as IPv6 too)
        agent_proxy_carry(to, a + 12);
    } else if (a[0] == 0x20 && a[1] == 0x02) {
        // 2002:a.b.c.d::/48 (6to4)
        agent_proxy_carry(to, a + 2);
    } else if (a[0] == 0x20 && a[1] == 0x01 && a[2] == 0 && a[3] == 0) {
        // 2001::/32 (Teredo, RFC 4380; NCH's review of #414): its server's
        // IPv4 (bytes 4-7) and its client's (bytes 12-15, obfuscated: each
        // bit inverted).
        unsigned char client[4] = {(unsigned char)~a[12], (unsigned char)~a[13], (unsigned char)~a[14], (unsigned char)~a[15]};
        agent_proxy_carry(to, a + 4);
        agent_proxy_carry(to, client);
    }
}

static int agent_proxy_ipv4_class(const unsigned char *a) {
    if (a[0] == 0 || a[0] == 127 || (a[0] == 169 && a[1] == 254) || a[0] >= 224) return REFUSED;
    if (a[0] == 10 || (a[0] == 172 && (a[1] & 0xf0) == 16) || (a[0] == 192 && a[1] == 168)
        || (a[0] == 100 && (a[1] & 0xc0) == 64)) return PRIVATE;
    return PUBLIC;
}

static int agent_proxy_ipv6_class(const unsigned char *a) {
    static const unsigned char zero[15] = {0};
    // ::, ::1
    if (memcmp(a, zero, 15) == 0 && (a[15] == 0 || a[15] == 1)) return REFUSED;
    // fe80::/10, ff00::/8
    if ((a[0] == 0xfe && (a[1] & 0xc0) == 0x80) || a[0] == 0xff) return REFUSED;
    // fc00::/7 (a tailnet's fd7a:115c:a1e0::/48 among them)
    if ((a[0] & 0xfe) == 0xfc) return PRIVATE;
    return PUBLIC;
}

/// Whether `address` is one of this computer's interfaces' (or an IPv4 it
/// carries is), asked of the system now: an interface's address may come
/// and go (a VPN, a network joined).
static int agent_proxy_is_own(const struct agent_proxy_address *address) {
    struct ifaddrs *interfaces = 0;
    if (getifaddrs(&interfaces) != 0) return 1;  // Unknown: refused.
    int own = 0;
    for (struct ifaddrs *each = interfaces; each && !own; each = each->ifa_next) {
        if (!each->ifa_addr) continue;
        if (each->ifa_addr->sa_family == AF_INET) {
            const unsigned char *b = (const unsigned char *)&((const struct sockaddr_in *)each->ifa_addr)->sin_addr;
            if (address->family == AF_INET && memcmp(address->bytes, b, 4) == 0) own = 1;
            for (int i = 0; i < address->carried; i++) {
                if (memcmp(address->ipv4[i], b, 4) == 0) own = 1;
            }
        } else if (each->ifa_addr->sa_family == AF_INET6) {
            const unsigned char *b = ((const struct sockaddr_in6 *)each->ifa_addr)->sin6_addr.s6_addr;
            if (address->family == AF_INET6 && memcmp(address->bytes, b, 16) == 0) own = 1;
        }
    }
    freeifaddrs(interfaces);
    return own;
}

/// Reads `text` (`a.b.c.d[/n]`, `v6[/n]`) as a range: its family, its 16
/// bytes and its prefix. 0 when it isn't one.
static int agent_proxy_parse_range(const char *text, size_t length, int *family, unsigned char *bytes, int *prefix) {
    char buffer[64];
    while (length > 0 && (*text == ' ' || *text == '\t')) { text++; length--; }
    while (length > 0 && (text[length - 1] == ' ' || text[length - 1] == '\t' || text[length - 1] == '\r')) length--;
    if (length == 0 || length >= sizeof buffer) return 0;
    memcpy(buffer, text, length);
    buffer[length] = 0;
    char *slash = strchr(buffer, '/');
    long bits = -1;
    if (slash) {
        *slash = 0;
        char *end = 0;
        if (slash[1] == 0) return 0;
        bits = strtol(slash + 1, &end, 10);
        if (*end != 0 || bits < 0) return 0;
    }
    memset(bytes, 0, 16);
    if (inet_pton(AF_INET, buffer, bytes) == 1) {
        if (bits > 32) return 0;
        *family = AF_INET;
        *prefix = bits < 0 ? 32 : (int)bits;
        return 1;
    }
    if (inet_pton(AF_INET6, buffer, bytes) == 1) {
        if (bits > 128) return 0;
        *family = AF_INET6;
        *prefix = bits < 0 ? 128 : (int)bits;
        return 1;
    }
    return 0;
}

static int agent_proxy_in_range(const unsigned char *address, const unsigned char *range, int prefix) {
    int whole = prefix / 8, rest = prefix % 8;
    if (memcmp(address, range, (size_t)whole) != 0) return 0;
    if (rest == 0) return 1;
    unsigned char mask = (unsigned char)(0xff << (8 - rest));
    return (address[whole] & mask) == (range[whole] & mask);
}

/// Whether one of `ranges`' lines (CIDRs, or bare addresses) holds
/// `bytes` of `family`.
static int agent_proxy_in_ranges(int family, const unsigned char *bytes, const char *ranges) {
    if (!ranges) return 0;
    const char *line = ranges;
    while (*line) {
        const char *end = strchr(line, '\n');
        size_t length = end ? (size_t)(end - line) : strlen(line);
        int range_family = 0, prefix = 0;
        unsigned char range[16];
        if (agent_proxy_parse_range(line, length, &range_family, range, &prefix) && range_family == family
            && agent_proxy_in_range(bytes, range, prefix)) {
            return 1;
        }
        if (!end) break;
        line = end + 1;
    }
    return 0;
}

/// Whether `allowed` lets a private `address` be reached: its own address
/// listed whole, or else every private part of it (itself, if IPv6 in
/// fc00::/7; each IPv4 it carries in a private range) listed.
static int agent_proxy_listed(const struct agent_proxy_address *address, int own_kind, const char *allowed) {
    if (agent_proxy_in_ranges(address->family, address->bytes, allowed)) return 1;
    if (address->family == AF_INET || own_kind == PRIVATE) return 0;
    for (int i = 0; i < address->carried; i++) {
        if (agent_proxy_ipv4_class(address->ipv4[i]) == PRIVATE && !agent_proxy_in_ranges(AF_INET, address->ipv4[i], allowed)) return 0;
    }
    return 1;
}

static int agent_proxy_allowed(const struct sockaddr *from, const char *allowed, int private_allowed, const char *pin) {
    if (from->sa_family != AF_INET && from->sa_family != AF_INET6) return 0;
    struct agent_proxy_address address;
    agent_proxy_address_from(from, &address);
    int own_kind = address.family == AF_INET ? agent_proxy_ipv4_class(address.bytes) : agent_proxy_ipv6_class(address.bytes);
    int kind = own_kind;
    for (int i = 0; i < address.carried; i++) {
        int carried = agent_proxy_ipv4_class(address.ipv4[i]);
        if (carried < kind) kind = carried;
    }
    if (kind == REFUSED || agent_proxy_is_own(&address)) return 0;
    // A destination pinned (`host:port@CIDR`, NCH's review of #414): what it
    // resolves to must be in its pin, public or private.
    if (pin && *pin && !agent_proxy_in_ranges(address.family, address.bytes, pin)) return 0;
    if (kind == PRIVATE && !private_allowed && !agent_proxy_listed(&address, own_kind, allowed)) return 0;
    return 1;
}

int agent_proxy_address_allowed(const char *text, const char *allowed, int private_allowed) {
    return agent_proxy_address_allowed_pinned(text, allowed, private_allowed, 0);
}

int agent_proxy_address_allowed_pinned(const char *text, const char *allowed, int private_allowed, const char *pin) {
    struct sockaddr_storage storage;
    memset(&storage, 0, sizeof storage);
    struct sockaddr_in *v4 = (struct sockaddr_in *)&storage;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&storage;
    if (inet_pton(AF_INET, text, &v4->sin_addr) == 1) {
        v4->sin_family = AF_INET;
    } else if (inet_pton(AF_INET6, text, &v6->sin6_addr) == 1) {
        v6->sin6_family = AF_INET6;
    } else {
        return 0;
    }
    return agent_proxy_allowed((const struct sockaddr *)&storage, allowed, private_allowed, pin);
}

int agent_proxy_cidr_valid(const char *text) {
    int family = 0, prefix = 0;
    unsigned char bytes[16];
    return agent_proxy_parse_range(text, strlen(text), &family, bytes, &prefix);
}

int agent_proxy_interface_addresses(char *out, size_t size) {
    struct ifaddrs *interfaces = 0;
    if (getifaddrs(&interfaces) != 0) return -1;
    size_t used = 0;
    int count = 0;
    if (size > 0) out[0] = 0;
    for (struct ifaddrs *each = interfaces; each; each = each->ifa_next) {
        if (!each->ifa_addr) continue;
        char text[INET6_ADDRSTRLEN];
        if (each->ifa_addr->sa_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)each->ifa_addr)->sin_addr, text, sizeof text);
        } else if (each->ifa_addr->sa_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)each->ifa_addr)->sin6_addr, text, sizeof text);
        } else {
            continue;
        }
        size_t length = strlen(text);
        if (used + length + 2 > size) break;
        memcpy(out + used, text, length);
        out[used + length] = '\n';
        used += length + 1;
        out[used] = 0;
        count++;
    }
    freeifaddrs(interfaces);
    return count;
}

// Whether this thread's last connection failed reaching a private address
// with EHOSTUNREACH or EPERM: on macOS, what a process without the Local
// Network permission is told (agent_proxy_last_failure_private).
static __thread int agent_proxy_private_failure = 0;

int agent_proxy_last_failure_private(void) {
    return agent_proxy_private_failure;
}

static int agent_proxy_is_private(const struct sockaddr *to) {
    if (to->sa_family != AF_INET && to->sa_family != AF_INET6) return 0;
    struct agent_proxy_address address;
    agent_proxy_address_from(to, &address);
    int kind = address.family == AF_INET ? agent_proxy_ipv4_class(address.bytes) : agent_proxy_ipv6_class(address.bytes);
    for (int i = 0; i < address.carried; i++) {
        if (agent_proxy_ipv4_class(address.ipv4[i]) == PRIVATE) kind = PRIVATE;
    }
    return kind == PRIVATE;
}

static int agent_proxy_connect_tcp_checked(const char *host, unsigned short port, int checked, const char *allowed, int private_allowed,
                                           const char *pin) {
    agent_proxy_private_failure = 0;
    struct addrinfo hints, *found = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char service[8];
    snprintf(service, sizeof service, "%u", (unsigned)port);
    int status = getaddrinfo(host, service, &hints, &found);
    if (status != 0) { errno = EHOSTUNREACH; return -1; }
    int connection = -1, error = checked ? EACCES : ECONNREFUSED;
    for (struct addrinfo *each = found; each; each = each->ai_next) {
        if (checked && !agent_proxy_allowed(each->ai_addr, allowed, private_allowed, pin)) continue;
        connection = socket(each->ai_family, each->ai_socktype, each->ai_protocol);
        if (connection < 0) { error = errno; continue; }
        (void)fcntl(connection, F_SETFD, FD_CLOEXEC);
        if (connect(connection, each->ai_addr, each->ai_addrlen) == 0) break;
        error = errno;
        if ((error == EHOSTUNREACH || error == EPERM) && agent_proxy_is_private(each->ai_addr)) agent_proxy_private_failure = 1;
        close(connection);
        connection = -1;
    }
    freeaddrinfo(found);
    if (connection < 0) { errno = error; return -1; }
    struct timeval patience = {30, 0};
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &patience, sizeof patience);
    return connection;
}

int agent_proxy_connect_tcp(const char *host, unsigned short port) {
    return agent_proxy_connect_tcp_checked(host, port, 0, 0, 0, 0);
}

int agent_proxy_connect_tcp_egress(const char *host, unsigned short port, const char *allowed, int private_allowed) {
    return agent_proxy_connect_tcp_checked(host, port, 1, allowed, private_allowed, 0);
}

int agent_proxy_connect_tcp_egress_pinned(const char *host, unsigned short port, const char *allowed, int private_allowed,
                                          const char *pin) {
    return agent_proxy_connect_tcp_checked(host, port, 1, allowed, private_allowed, pin);
}

int agent_proxy_connect_tcp_public(const char *host, unsigned short port) {
    return agent_proxy_connect_tcp_checked(host, port, 1, 0, 0, 0);
}

void agent_proxy_set_receive_timeout(int socket, int seconds) {
    struct timeval patience = {seconds, 0};
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &patience, sizeof patience);
}

void agent_proxy_set_receive_timeout_ms(int socket, int milliseconds) {
    if (milliseconds < 1) milliseconds = 1;
    struct timeval patience = {milliseconds / 1000, (milliseconds % 1000) * 1000};
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &patience, sizeof patience);
}

int agent_proxy_open_log(const char *path) {
    int file = open(path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file >= 0 || errno != EEXIST) return file;
    file = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC);
    if (file < 0) return -1;
    if (fchmod(file, 0600) != 0) {
        int error = errno;
        close(file);
        errno = error;
        return -1;
    }
    return file;
}

// The next connection, or -1 once the listener is closed or shut down.
// Every other failure is a connection's or a passing shortage, not the
// listener's, and the next one is waited for: Linux hands a pending
// connection's error (one reset or aborted before it was taken) to
// accept itself, and a loop that ended there would leave its listener
// open and unanswered for good (a process killed with connections to it
// pending is enough). After anything but an interruption or an aborted
// connection (out of descriptors or memory, say), it waits a moment
// first, so a failure that keeps coming doesn't spin.
int agent_proxy_accept(int listener) {
    int connection;
    for (;;) {
        connection = accept(listener, 0, 0);
        if (connection >= 0) break;
        if (errno == EBADF || errno == EINVAL || errno == ENOTSOCK || errno == EFAULT) return -1;
        if (errno != EINTR && errno != ECONNABORTED && errno != EPROTO) usleep(100 * 1000);
    }
    (void)fcntl(connection, F_SETFD, FD_CLOEXEC);
    struct timeval patience = {30, 0};
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &patience, sizeof patience);
    return connection;
}

void agent_proxy_shutdown(int socket) {
    shutdown(socket, SHUT_RDWR);
}

void agent_proxy_shutdown_write(int socket) {
    shutdown(socket, SHUT_WR);
}

void agent_proxy_ignore_broken_pipes(void) {
    signal(SIGPIPE, SIG_IGN);
}

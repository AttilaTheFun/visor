// relay-client's network setup over netlink, so a container's image
// needs neither `ip` nor `nft`: loopback up and holding the container's own
// address, the default route through loopback from it, and one nftables
// table whose one chain redirects every outgoing TCP connection not to
// loopback to the client's listener. Linux only.

#include "relay_client_posix.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

#ifdef __linux__
#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

// The kernel's netlink ABI, as much as this needs: its own definitions, not
// <linux/…>'s, which the static Linux SDK (musl) doesn't carry. These are
// the kernel's values (linux/netlink.h, rtnetlink.h, netfilter/nfnetlink.h,
// netfilter/nf_tables.h), fixed by its ABI.
struct mp_nlmsghdr { uint32_t nlmsg_len; uint16_t nlmsg_type; uint16_t nlmsg_flags; uint32_t nlmsg_seq; uint32_t nlmsg_pid; };
struct mp_nlattr { uint16_t nla_len; uint16_t nla_type; };
struct mp_nlmsgerr { int32_t error; struct mp_nlmsghdr msg; };
struct mp_sockaddr_nl { unsigned short nl_family; unsigned short nl_pad; uint32_t nl_pid; uint32_t nl_groups; };
struct mp_ifinfomsg { unsigned char ifi_family; unsigned char ifi_pad; unsigned short ifi_type; int ifi_index; unsigned int ifi_flags; unsigned int ifi_change; };
struct mp_ifaddrmsg { uint8_t ifa_family; uint8_t ifa_prefixlen; uint8_t ifa_flags; uint8_t ifa_scope; uint32_t ifa_index; };
struct mp_rtmsg { unsigned char rtm_family, rtm_dst_len, rtm_src_len, rtm_tos, rtm_table, rtm_protocol, rtm_scope, rtm_type; unsigned int rtm_flags; };
struct mp_nfgenmsg { uint8_t nfgen_family; uint8_t version; uint16_t res_id; };
_Static_assert(sizeof(struct mp_nlmsghdr) == 16 && sizeof(struct mp_nlattr) == 4 && sizeof(struct mp_nlmsgerr) == 20, "netlink");
_Static_assert(sizeof(struct mp_sockaddr_nl) == 12 && sizeof(struct mp_ifinfomsg) == 16 && sizeof(struct mp_ifaddrmsg) == 8, "rtnetlink");
_Static_assert(sizeof(struct mp_rtmsg) == 12 && sizeof(struct mp_nfgenmsg) == 4, "rtnetlink, nfnetlink");

#define MP_ALIGN(length) (((length) + 3U) & ~3U)
#define MP_NLMSG_HDRLEN ((unsigned)MP_ALIGN(sizeof(struct mp_nlmsghdr)))
#define MP_NLA_HDRLEN ((unsigned)MP_ALIGN(sizeof(struct mp_nlattr)))

#define MP_AF_NETLINK 16
#define MP_NETLINK_ROUTE 0
#define MP_NETLINK_NETFILTER 12
#define MP_NLM_F_REQUEST 1
#define MP_NLM_F_ACK 4
#define MP_NLM_F_REPLACE 256
#define MP_NLM_F_CREATE 1024
#define MP_NLM_F_APPEND 2048
#define MP_NLMSG_ERROR 2
#define MP_NLA_F_NESTED 32768
#define MP_RTM_NEWLINK 16
#define MP_RTM_NEWADDR 20
#define MP_RTM_NEWROUTE 24
#define MP_IFA_ADDRESS 1
#define MP_IFA_LOCAL 2
#define MP_RTA_OIF 4
#define MP_RTA_PREFSRC 7
#define MP_RT_SCOPE_UNIVERSE 0
#define MP_RT_SCOPE_LINK 253
#define MP_RT_TABLE_MAIN 254
#define MP_RTPROT_BOOT 3
#define MP_RTN_UNICAST 1
#define MP_NFNL_SUBSYS_NFTABLES 10
#define MP_NFNL_MSG_BATCH_BEGIN 16
#define MP_NFNL_MSG_BATCH_END 17
#define MP_NFNETLINK_V0 0
#define MP_NFPROTO_IPV4 2
#define MP_NFT_MSG_NEWTABLE 0
#define MP_NFT_MSG_DELTABLE 2
#define MP_NFT_MSG_NEWCHAIN 3
#define MP_NFT_MSG_NEWRULE 6
#define MP_NFTA_TABLE_NAME 1
#define MP_NFTA_CHAIN_TABLE 1
#define MP_NFTA_CHAIN_NAME 3
#define MP_NFTA_CHAIN_HOOK 4
#define MP_NFTA_CHAIN_POLICY 5
#define MP_NFTA_CHAIN_TYPE 7
#define MP_NFTA_HOOK_HOOKNUM 1
#define MP_NFTA_HOOK_PRIORITY 2
#define MP_NF_INET_LOCAL_OUT 3
#define MP_NF_ACCEPT 1
#define MP_NFTA_RULE_TABLE 1
#define MP_NFTA_RULE_CHAIN 2
#define MP_NFTA_RULE_EXPRESSIONS 4
#define MP_NFTA_LIST_ELEM 1
#define MP_NFTA_EXPR_NAME 1
#define MP_NFTA_EXPR_DATA 2
#define MP_NFTA_PAYLOAD_DREG 1
#define MP_NFTA_PAYLOAD_BASE 2
#define MP_NFTA_PAYLOAD_OFFSET 3
#define MP_NFTA_PAYLOAD_LEN 4
#define MP_NFT_PAYLOAD_NETWORK_HEADER 1
#define MP_NFTA_BITWISE_SREG 1
#define MP_NFTA_BITWISE_DREG 2
#define MP_NFTA_BITWISE_LEN 3
#define MP_NFTA_BITWISE_MASK 4
#define MP_NFTA_BITWISE_XOR 5
#define MP_NFTA_CMP_SREG 1
#define MP_NFTA_CMP_OP 2
#define MP_NFTA_CMP_DATA 3
#define MP_NFT_CMP_EQ 0
#define MP_NFTA_DATA_VALUE 1
#define MP_NFTA_DATA_VERDICT 2
#define MP_NFTA_VERDICT_CODE 1
#define MP_NFTA_IMMEDIATE_DREG 1
#define MP_NFTA_IMMEDIATE_DATA 2
#define MP_NFT_REG_VERDICT 0
#define MP_NFT_REG_1 1
#define MP_NFT_RETURN (-5)
#define MP_NFTA_META_DREG 1
#define MP_NFTA_META_KEY 2
#define MP_NFT_META_L4PROTO 16
#define MP_NFTA_REDIR_REG_PROTO_MIN 1

/// A netlink message being written, attribute by attribute.
struct message {
    unsigned char bytes[2048];
    size_t length;
    // Where each open nest's header is, to fill its length in on closing.
    size_t nests[8];
    int depth;
};

static struct mp_nlmsghdr *header(struct message *m) { return (struct mp_nlmsghdr *)m->bytes; }

static void start(struct message *m, unsigned short type, unsigned short flags, unsigned int sequence,
                  const void *body, size_t size) {
    memset(m, 0, sizeof *m);
    struct mp_nlmsghdr *h = header(m);
    h->nlmsg_type = type;
    h->nlmsg_flags = flags;
    h->nlmsg_seq = sequence;
    m->length = MP_NLMSG_HDRLEN;
    memcpy(m->bytes + m->length, body, size);
    m->length += MP_ALIGN(size);
}

static void attribute(struct message *m, unsigned short type, const void *data, size_t size) {
    struct mp_nlattr *a = (struct mp_nlattr *)(m->bytes + m->length);
    a->nla_type = type;
    a->nla_len = (unsigned short)(MP_NLA_HDRLEN + size);
    memcpy(m->bytes + m->length + MP_NLA_HDRLEN, data, size);
    m->length += MP_ALIGN(MP_NLA_HDRLEN + size);
}

static void string(struct message *m, unsigned short type, const char *value) { attribute(m, type, value, strlen(value) + 1); }

/// A 32-bit value in network order, as nf_tables reads them.
static void be32(struct message *m, unsigned short type, unsigned int value) {
    unsigned int big = htonl(value);
    attribute(m, type, &big, sizeof big);
}

/// A 32-bit value in this computer's order, as rtnetlink reads them.
static void u32(struct message *m, unsigned short type, unsigned int value) { attribute(m, type, &value, sizeof value); }

static void open_nest(struct message *m, unsigned short type) {
    m->nests[m->depth++] = m->length;
    struct mp_nlattr *a = (struct mp_nlattr *)(m->bytes + m->length);
    a->nla_type = type | MP_NLA_F_NESTED;
    m->length += MP_NLA_HDRLEN;
}

static void close_nest(struct message *m) {
    size_t at = m->nests[--m->depth];
    ((struct mp_nlattr *)(m->bytes + at))->nla_len = (unsigned short)(m->length - at);
}

static void finish(struct message *m) { header(m)->nlmsg_len = (unsigned int)m->length; }

/// Waits for the acknowledgements of `count` requests numbered from
/// `first`: 0, or the first error (negative errno) with its request's number.
static int acknowledged(int socket, unsigned int first, int count, unsigned int *failed) {
    unsigned char buffer[8192];
    int heard = 0;
    while (heard < count) {
        ssize_t got = recv(socket, buffer, sizeof buffer, 0);
        if (got < 0) return -errno;
        size_t at = 0;
        while (at + sizeof(struct mp_nlmsghdr) <= (size_t)got) {
            struct mp_nlmsghdr *h = (struct mp_nlmsghdr *)(buffer + at);
            if (h->nlmsg_len < sizeof *h || at + h->nlmsg_len > (size_t)got) break;
            at += MP_ALIGN(h->nlmsg_len);
            if (h->nlmsg_type != MP_NLMSG_ERROR || h->nlmsg_len < MP_NLMSG_HDRLEN + sizeof(struct mp_nlmsgerr)) continue;
            struct mp_nlmsgerr *e = (struct mp_nlmsgerr *)((unsigned char *)h + MP_NLMSG_HDRLEN);
            if (h->nlmsg_seq < first || h->nlmsg_seq >= first + (unsigned int)count) continue;
            if (e->error != 0) {
                *failed = h->nlmsg_seq;
                return e->error;
            }
            heard++;
        }
    }
    return 0;
}

static int open_netlink(int protocol) {
    int s = socket(MP_AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, protocol);
    if (s < 0) return -1;
    struct timeval patience = {5, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &patience, sizeof patience);
    struct mp_sockaddr_nl here;
    memset(&here, 0, sizeof here);
    here.nl_family = MP_AF_NETLINK;
    if (bind(s, (struct sockaddr *)&here, sizeof here) != 0) {
        int error = errno;
        close(s);
        errno = error;
        return -1;
    }
    return s;
}

static int send_message(int s, struct message *m) {
    finish(m);
    struct mp_sockaddr_nl kernel;
    memset(&kernel, 0, sizeof kernel);
    kernel.nl_family = MP_AF_NETLINK;
    return sendto(s, m->bytes, m->length, 0, (struct sockaddr *)&kernel, sizeof kernel) == (ssize_t)m->length ? 0 : -1;
}

static int say(char *problem, size_t size, const char *what, int error) {
    snprintf(problem, size, "%s: %s", what, strerror(error < 0 ? -error : error));
    return -1;
}

/// Loopback up, holding `source`, and the default route through it.
static int set_up_routes(struct in_addr source, char *problem, size_t size) {
    int s = open_netlink(MP_NETLINK_ROUTE);
    if (s < 0) return say(problem, size, "rtnetlink", errno);
    unsigned int lo = if_nametoindex("lo");
    if (lo == 0) {
        close(s);
        return say(problem, size, "no loopback interface", ENODEV);
    }
    const char *steps[3] = {"loopback up", "loopback's address", "the default route"};
    struct message m;

    struct mp_ifinfomsg link;
    memset(&link, 0, sizeof link);
    link.ifi_family = AF_UNSPEC;
    link.ifi_index = (int)lo;
    link.ifi_flags = IFF_UP;
    link.ifi_change = IFF_UP;
    start(&m, MP_RTM_NEWLINK, MP_NLM_F_REQUEST | MP_NLM_F_ACK, 1, &link, sizeof link);
    if (send_message(s, &m) != 0) goto failed_send;

    struct mp_ifaddrmsg address;
    memset(&address, 0, sizeof address);
    address.ifa_family = AF_INET;
    address.ifa_prefixlen = 32;
    address.ifa_scope = MP_RT_SCOPE_UNIVERSE;
    address.ifa_index = lo;
    start(&m, MP_RTM_NEWADDR, MP_NLM_F_REQUEST | MP_NLM_F_ACK | MP_NLM_F_CREATE | MP_NLM_F_REPLACE, 2, &address, sizeof address);
    attribute(&m, MP_IFA_LOCAL, &source, sizeof source);
    attribute(&m, MP_IFA_ADDRESS, &source, sizeof source);
    if (send_message(s, &m) != 0) goto failed_send;

    struct mp_rtmsg route;
    memset(&route, 0, sizeof route);
    route.rtm_family = AF_INET;
    route.rtm_dst_len = 0;
    route.rtm_table = MP_RT_TABLE_MAIN;
    route.rtm_protocol = MP_RTPROT_BOOT;
    route.rtm_scope = MP_RT_SCOPE_LINK;
    route.rtm_type = MP_RTN_UNICAST;
    start(&m, MP_RTM_NEWROUTE, MP_NLM_F_REQUEST | MP_NLM_F_ACK | MP_NLM_F_CREATE | MP_NLM_F_REPLACE, 3, &route, sizeof route);
    u32(&m, MP_RTA_OIF, lo);
    attribute(&m, MP_RTA_PREFSRC, &source, sizeof source);
    if (send_message(s, &m) != 0) goto failed_send;

    unsigned int failed = 0;
    int error = acknowledged(s, 1, 3, &failed);
    close(s);
    if (error != 0) return say(problem, size, failed >= 1 && failed <= 3 ? steps[failed - 1] : "rtnetlink", error);
    return 0;

failed_send:;
    int sent = errno;
    close(s);
    return say(problem, size, "rtnetlink", sent);
}

/// One nf_tables message of the batch: its header and generic part.
static void nft_start(struct message *m, unsigned short type, unsigned short flags, unsigned int sequence) {
    struct mp_nfgenmsg generic;
    memset(&generic, 0, sizeof generic);
    generic.nfgen_family = MP_NFPROTO_IPV4;
    generic.version = MP_NFNETLINK_V0;
    start(m, (unsigned short)((MP_NFNL_SUBSYS_NFTABLES << 8) | type), (unsigned short)(MP_NLM_F_REQUEST | flags), sequence,
          &generic, sizeof generic);
}

static void expression(struct message *m, const char *name) {
    open_nest(m, MP_NFTA_LIST_ELEM);
    string(m, MP_NFTA_EXPR_NAME, name);
    open_nest(m, MP_NFTA_EXPR_DATA);
}

static void end_expression(struct message *m) {
    close_nest(m);
    close_nest(m);
}

/// A value for a register or comparison: MP_NFTA_DATA_VALUE inside `type`.
static void data(struct message *m, unsigned short type, const void *value, size_t size) {
    open_nest(m, type);
    attribute(m, MP_NFTA_DATA_VALUE, value, size);
    close_nest(m);
}

static const char *table = "relay_client";
static const char *chain = "output";

/// The table made anew: created if missing, deleted, created, with its
/// base chain (nat, output, priority -100) and its two rules: what is to
/// `excluded` under `mask` (relay-client's ContainerNetwork: 127.0.0.0/8,
/// where its forwards and DNS listen) returns, and every other TCP
/// connection is redirected to `port`.
static int set_up_redirect(unsigned short port, const unsigned char excluded[4], const unsigned char mask[4], char *problem,
                           size_t size) {
    int s = open_netlink(MP_NETLINK_NETFILTER);
    if (s < 0) return say(problem, size, "nf_tables netlink", errno);
    unsigned char batch[8192];
    size_t length = 0;
    struct message m;
    unsigned int sequence = 100;
    const char *steps[6] = {"the table", "the old table's removal", "the table again", "the chain", "the loopback rule",
                            "the redirect rule"};

    // The batch's start and end name nf_tables as their subsystem.
    struct mp_nfgenmsg batch_body;
    memset(&batch_body, 0, sizeof batch_body);
    batch_body.nfgen_family = AF_UNSPEC;
    batch_body.version = MP_NFNETLINK_V0;
    batch_body.res_id = htons(MP_NFNL_SUBSYS_NFTABLES);
    start(&m, MP_NFNL_MSG_BATCH_BEGIN, MP_NLM_F_REQUEST, sequence++, &batch_body, sizeof batch_body);
    finish(&m);
    memcpy(batch + length, m.bytes, m.length);
    length += m.length;
    unsigned int first = sequence;

#define APPEND() do { finish(&m); memcpy(batch + length, m.bytes, m.length); length += m.length; } while (0)

    nft_start(&m, MP_NFT_MSG_NEWTABLE, MP_NLM_F_CREATE | MP_NLM_F_ACK, sequence++);
    string(&m, MP_NFTA_TABLE_NAME, table);
    APPEND();
    nft_start(&m, MP_NFT_MSG_DELTABLE, MP_NLM_F_ACK, sequence++);
    string(&m, MP_NFTA_TABLE_NAME, table);
    APPEND();
    nft_start(&m, MP_NFT_MSG_NEWTABLE, MP_NLM_F_CREATE | MP_NLM_F_ACK, sequence++);
    string(&m, MP_NFTA_TABLE_NAME, table);
    APPEND();

    nft_start(&m, MP_NFT_MSG_NEWCHAIN, MP_NLM_F_CREATE | MP_NLM_F_ACK, sequence++);
    string(&m, MP_NFTA_CHAIN_TABLE, table);
    string(&m, MP_NFTA_CHAIN_NAME, chain);
    open_nest(&m, MP_NFTA_CHAIN_HOOK);
    be32(&m, MP_NFTA_HOOK_HOOKNUM, MP_NF_INET_LOCAL_OUT);
    be32(&m, MP_NFTA_HOOK_PRIORITY, (unsigned int)-100);
    close_nest(&m);
    be32(&m, MP_NFTA_CHAIN_POLICY, MP_NF_ACCEPT);
    string(&m, MP_NFTA_CHAIN_TYPE, "nat");
    APPEND();

    // ip daddr <excluded>/<mask> return (127.0.0.0/8)
    nft_start(&m, MP_NFT_MSG_NEWRULE, MP_NLM_F_CREATE | MP_NLM_F_APPEND | MP_NLM_F_ACK, sequence++);
    string(&m, MP_NFTA_RULE_TABLE, table);
    string(&m, MP_NFTA_RULE_CHAIN, chain);
    open_nest(&m, MP_NFTA_RULE_EXPRESSIONS);
    expression(&m, "payload");
    be32(&m, MP_NFTA_PAYLOAD_DREG, MP_NFT_REG_1);
    be32(&m, MP_NFTA_PAYLOAD_BASE, MP_NFT_PAYLOAD_NETWORK_HEADER);
    be32(&m, MP_NFTA_PAYLOAD_OFFSET, 16);
    be32(&m, MP_NFTA_PAYLOAD_LEN, 4);
    end_expression(&m);
    expression(&m, "bitwise");
    be32(&m, MP_NFTA_BITWISE_SREG, MP_NFT_REG_1);
    be32(&m, MP_NFTA_BITWISE_DREG, MP_NFT_REG_1);
    be32(&m, MP_NFTA_BITWISE_LEN, 4);
    unsigned char nothing[4] = {0, 0, 0, 0}, network[4];
    for (int i = 0; i < 4; i++) network[i] = excluded[i] & mask[i];
    data(&m, MP_NFTA_BITWISE_MASK, mask, 4);
    data(&m, MP_NFTA_BITWISE_XOR, nothing, 4);
    end_expression(&m);
    expression(&m, "cmp");
    be32(&m, MP_NFTA_CMP_SREG, MP_NFT_REG_1);
    be32(&m, MP_NFTA_CMP_OP, MP_NFT_CMP_EQ);
    data(&m, MP_NFTA_CMP_DATA, network, 4);
    end_expression(&m);
    expression(&m, "immediate");
    be32(&m, MP_NFTA_IMMEDIATE_DREG, MP_NFT_REG_VERDICT);
    open_nest(&m, MP_NFTA_IMMEDIATE_DATA);
    open_nest(&m, MP_NFTA_DATA_VERDICT);
    be32(&m, MP_NFTA_VERDICT_CODE, (unsigned int)MP_NFT_RETURN);
    close_nest(&m);
    close_nest(&m);
    end_expression(&m);
    close_nest(&m);
    APPEND();

    // meta l4proto tcp redirect to :port
    nft_start(&m, MP_NFT_MSG_NEWRULE, MP_NLM_F_CREATE | MP_NLM_F_APPEND | MP_NLM_F_ACK, sequence++);
    string(&m, MP_NFTA_RULE_TABLE, table);
    string(&m, MP_NFTA_RULE_CHAIN, chain);
    open_nest(&m, MP_NFTA_RULE_EXPRESSIONS);
    expression(&m, "meta");
    be32(&m, MP_NFTA_META_DREG, MP_NFT_REG_1);
    be32(&m, MP_NFTA_META_KEY, MP_NFT_META_L4PROTO);
    end_expression(&m);
    expression(&m, "cmp");
    be32(&m, MP_NFTA_CMP_SREG, MP_NFT_REG_1);
    be32(&m, MP_NFTA_CMP_OP, MP_NFT_CMP_EQ);
    unsigned char tcp = IPPROTO_TCP;
    data(&m, MP_NFTA_CMP_DATA, &tcp, 1);
    end_expression(&m);
    expression(&m, "immediate");
    be32(&m, MP_NFTA_IMMEDIATE_DREG, MP_NFT_REG_1);
    unsigned char big_port[2] = {(unsigned char)(port >> 8), (unsigned char)(port & 0xFF)};
    data(&m, MP_NFTA_IMMEDIATE_DATA, big_port, 2);
    end_expression(&m);
    expression(&m, "redir");
    be32(&m, MP_NFTA_REDIR_REG_PROTO_MIN, MP_NFT_REG_1);
    end_expression(&m);
    close_nest(&m);
    APPEND();
#undef APPEND

    start(&m, MP_NFNL_MSG_BATCH_END, MP_NLM_F_REQUEST, sequence++, &batch_body, sizeof batch_body);
    finish(&m);
    memcpy(batch + length, m.bytes, m.length);
    length += m.length;

    struct mp_sockaddr_nl kernel;
    memset(&kernel, 0, sizeof kernel);
    kernel.nl_family = MP_AF_NETLINK;
    if (sendto(s, batch, length, 0, (struct sockaddr *)&kernel, sizeof kernel) != (ssize_t)length) {
        int error = errno;
        close(s);
        return say(problem, size, "nf_tables batch", error);
    }
    unsigned int failed = 0;
    int error = acknowledged(s, first, 6, &failed);
    close(s);
    if (error != 0) {
        const char *what = failed >= first && failed < first + 6 ? steps[failed - first] : "nf_tables";
        char text[96];
        snprintf(text, sizeof text, "nftables, %s", what);
        return say(problem, size, text, error);
    }
    return 0;
}

int relay_client_container_network(unsigned short port, const char *source, const unsigned char excluded[4], const unsigned char mask[4],
                                   char *problem, size_t size) {
    struct in_addr address;
    if (inet_pton(AF_INET, source, &address) != 1) return say(problem, size, "the source address", EINVAL);
    if (set_up_routes(address, problem, size) != 0) return -1;
    return set_up_redirect(port, excluded, mask, problem, size);
}

#else

int relay_client_container_network(unsigned short port, const char *source, const unsigned char excluded[4], const unsigned char mask[4],
                                   char *problem, size_t size) {
    (void)port;
    (void)source;
    (void)excluded;
    (void)mask;
    snprintf(problem, size, "only on Linux");
    errno = ENOTSUP;
    return -1;
}

#endif

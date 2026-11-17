#include "RouteSocket.h"

#include <arpa/inet.h>
#include <errno.h>
#include <net/route.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <stdatomic.h>
#include <string.h>

struct tailscale_ipv4_route_message {
    struct rt_msghdr header;
    uint8_t addresses[3 * sizeof(struct sockaddr_in)];
};

static size_t route_sockaddr_size(size_t length) {
    const size_t alignment = sizeof(uint32_t);
    return (length + alignment - 1) & ~(alignment - 1);
}

static void append_route_sockaddr(
    struct tailscale_ipv4_route_message *message,
    size_t *offset,
    const void *address,
    size_t length
) {
    const size_t rounded_length = route_sockaddr_size(length);
    memcpy(message->addresses + *offset, address, rounded_length);
    *offset += rounded_length;
}

int tailscale_route_socket_open(void) {
    int descriptor = socket(PF_ROUTE, SOCK_RAW, 0);
    if (descriptor < 0) {
        return -1;
    }

    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    (void)setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    return descriptor;
}

static int read_route_reply(int descriptor, int sequence) {
    struct tailscale_ipv4_route_message reply;
    for (;;) {
        ssize_t count = read(descriptor, &reply, sizeof(reply));
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return errno;
        }
        if ((size_t)count < sizeof(struct rt_msghdr)) {
            return EPROTO;
        }
        if (reply.header.rtm_version != RTM_VERSION
            || reply.header.rtm_pid != getpid()
            || reply.header.rtm_seq != sequence) {
            continue;
        }
        return reply.header.rtm_errno;
    }
}

static int mutate_ipv4_route(
    int descriptor,
    uint32_t network,
    uint8_t prefix_length,
    uint32_t gateway,
    uint8_t message_type
) {
    if (descriptor < 0 || prefix_length > 32) {
        return EINVAL;
    }

    struct tailscale_ipv4_route_message message;
    memset(&message, 0, sizeof(message));

    const int is_host = prefix_length == 32;
    message.header.rtm_version = RTM_VERSION;
    message.header.rtm_type = message_type;
    message.header.rtm_flags = RTF_UP | RTF_STATIC | RTF_GATEWAY;
    if (is_host) {
        message.header.rtm_flags |= RTF_HOST;
    }
    struct sockaddr_in destination = {0};
    destination.sin_len = sizeof(struct sockaddr_in);
    destination.sin_family = AF_INET;
    uint32_t mask = prefix_length == 0
        ? 0
        : UINT32_MAX << (32 - prefix_length);
    destination.sin_addr.s_addr = htonl(network & mask);
    message.header.rtm_addrs = RTA_DST;

    size_t offset = 0;
    append_route_sockaddr(&message, &offset, &destination, destination.sin_len);
    struct sockaddr_in gateway_address = {0};
    gateway_address.sin_len = sizeof(struct sockaddr_in);
    gateway_address.sin_family = AF_INET;
    gateway_address.sin_addr.s_addr = htonl(gateway);
    append_route_sockaddr(&message, &offset, &gateway_address, gateway_address.sin_len);
    message.header.rtm_addrs |= RTA_GATEWAY;

    if (!is_host) {
        struct sockaddr_in netmask = {0};
        netmask.sin_len = sizeof(struct sockaddr_in);
        netmask.sin_family = AF_INET;
        netmask.sin_addr.s_addr = htonl(mask);
        // Match route(8)'s mask_addr(): shorten the netmask sockaddr to the
        // last significant byte before appending it to the routing message.
        const uint8_t *mask_bytes = (const uint8_t *)&netmask;
        while (netmask.sin_len > 2 && mask_bytes[netmask.sin_len - 1] == 0) {
            netmask.sin_len--;
        }
        append_route_sockaddr(&message, &offset, &netmask, netmask.sin_len);
        message.header.rtm_addrs |= RTA_NETMASK;
    }

    message.header.rtm_msglen = (u_short)(sizeof(message.header) + offset);
    static _Atomic int sequence = 0;
    const int request_sequence = atomic_fetch_add(&sequence, 1) + 1;
    message.header.rtm_seq = request_sequence;

    ssize_t written;
    do {
        written = write(descriptor, &message, message.header.rtm_msglen);
    } while (written < 0 && errno == EINTR);

    if (written < 0) {
        return errno;
    }
    if ((size_t)written != message.header.rtm_msglen) {
        return EIO;
    }
    return read_route_reply(descriptor, request_sequence);
}

int tailscale_route_socket_apply_ipv4(
    int descriptor,
    uint32_t network,
    uint8_t prefix_length,
    uint32_t gateway,
    int32_t add
) {
    return mutate_ipv4_route(
        descriptor,
        network,
        prefix_length,
        gateway,
        add ? RTM_ADD : RTM_DELETE
    );
}

int tailscale_route_socket_change_ipv4(
    int descriptor,
    uint32_t network,
    uint8_t prefix_length,
    uint32_t gateway
) {
    return mutate_ipv4_route(descriptor, network, prefix_length, gateway, RTM_CHANGE);
}

void tailscale_route_socket_close(int descriptor) {
    if (descriptor >= 0) {
        close(descriptor);
    }
}

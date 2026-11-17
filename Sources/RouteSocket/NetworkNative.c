// Native, read-only network inspection used on the hot status/apply path.
//
// These functions replace short-lived netstat(1)/ifconfig(8) subprocesses.
// Everything here only reads kernel state; no routes are modified.

#include "RouteSocket.h"

#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_media.h>
#include <net/route.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/sysctl.h>
#include <unistd.h>

// Flags that are not exported by every SDK version. Values are stable in
// xnu's net/route.h.
#ifndef RTF_DYNAMIC
#define RTF_DYNAMIC 0x10
#endif
#ifndef RTF_MODIFIED
#define RTF_MODIFIED 0x20
#endif
#ifndef RTF_DONE
#define RTF_DONE 0x40
#endif
#ifndef RTF_CLONING
#define RTF_CLONING 0x100
#endif
#ifndef RTF_XRESOLVE
#define RTF_XRESOLVE 0x200
#endif
#ifndef RTF_LLINFO
#define RTF_LLINFO 0x400
#endif
#ifndef RTF_PROTO2
#define RTF_PROTO2 0x4000
#endif
#ifndef RTF_PROTO1
#define RTF_PROTO1 0x8000
#endif
#ifndef RTF_PRCLONING
#define RTF_PRCLONING 0x10000
#endif
#ifndef RTF_WASCLONED
#define RTF_WASCLONED 0x20000
#endif
#ifndef RTF_PROTO3
#define RTF_PROTO3 0x40000
#endif
#ifndef RTF_BROADCAST
#define RTF_BROADCAST 0x400000
#endif
#ifndef RTF_MULTICAST
#define RTF_MULTICAST 0x800000
#endif
#ifndef RTF_IFSCOPE
#define RTF_IFSCOPE 0x1000000
#endif
#ifndef RTF_IFREF
#define RTF_IFREF 0x4000000
#endif
#ifndef RTF_PROXY
#define RTF_PROXY 0x8000000
#endif
#ifndef RTF_ROUTER
#define RTF_ROUTER 0x10000000
#endif
#ifndef RTF_GLOBAL
#define RTF_GLOBAL 0x40000000
#endif

// Routing-socket sockaddrs are padded to 32-bit boundaries; a zero sa_len
// still occupies one 32-bit slot (xnu's SA_SIZE / netstat's ROUNDUP).
static size_t tsr_sa_size(const struct sockaddr *sa) {
    const size_t length = sa->sa_len;
    if (length == 0) {
        return sizeof(uint32_t);
    }
    return 1 + ((length - 1) | (sizeof(uint32_t) - 1));
}

struct tsr_text {
    char *data;
    size_t length;
    size_t capacity;
    int failed;
};

static void tsr_append(struct tsr_text *text, const char *value) {
    if (text->failed) {
        return;
    }
    const size_t count = strlen(value);
    if (text->length + count + 1 > text->capacity) {
        size_t capacity = text->capacity == 0 ? 65536 : text->capacity;
        while (text->length + count + 1 > capacity) {
            capacity *= 2;
        }
        char *grown = realloc(text->data, capacity);
        if (grown == NULL) {
            text->failed = 1;
            return;
        }
        text->data = grown;
        text->capacity = capacity;
    }
    memcpy(text->data + text->length, value, count);
    text->length += count;
    text->data[text->length] = '\0';
}

// Same letters as netstat(1). Callers only rely on U/G/H/S/I/c, but the
// remaining letters keep diagnostic output familiar.
static void tsr_format_flags(uint32_t flags, char *output, size_t size) {
    static const struct {
        uint32_t bit;
        char letter;
    } table[] = {
        { RTF_UP, 'U' },
        { RTF_GATEWAY, 'G' },
        { RTF_HOST, 'H' },
        { RTF_REJECT, 'R' },
        { RTF_DYNAMIC, 'D' },
        { RTF_MODIFIED, 'M' },
        { RTF_DONE, 'd' },
        { RTF_CLONING, 'C' },
        { RTF_XRESOLVE, 'X' },
        { RTF_LLINFO, 'L' },
        { RTF_STATIC, 'S' },
        { RTF_PROTO1, '1' },
        { RTF_PROTO2, '2' },
        { RTF_WASCLONED, 'W' },
        { RTF_PRCLONING, 'c' },
        { RTF_PROTO3, '3' },
        { RTF_BLACKHOLE, 'B' },
        { RTF_BROADCAST, 'b' },
        { RTF_MULTICAST, 'm' },
        { RTF_IFSCOPE, 'I' },
        { RTF_IFREF, 'i' },
        { RTF_PROXY, 'Y' },
        { RTF_ROUTER, 'r' },
        { RTF_GLOBAL, 'g' },
    };
    size_t used = 0;
    for (size_t index = 0; index < sizeof(table) / sizeof(table[0]); index++) {
        if ((flags & table[index].bit) && used + 1 < size) {
            output[used++] = table[index].letter;
        }
    }
    output[used] = '\0';
}

static void tsr_format_gateway(const struct sockaddr *gateway, char *output, size_t size) {
    if (gateway == NULL) {
        snprintf(output, size, "-");
        return;
    }
    if (gateway->sa_family == AF_INET && gateway->sa_len >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *address = (const struct sockaddr_in *)gateway;
        if (inet_ntop(AF_INET, &address->sin_addr, output, (socklen_t)size) == NULL) {
            snprintf(output, size, "-");
        }
        return;
    }
    if (gateway->sa_family == AF_LINK) {
        const struct sockaddr_dl *link = (const struct sockaddr_dl *)gateway;
        // Mirrors netstat(1): an empty link sockaddr is "link#N", anything
        // else is link_ntoa() style "name:a:b:c" (hex bytes, no padding).
        if (link->sdl_nlen == 0 && link->sdl_alen == 0 && link->sdl_slen == 0) {
            snprintf(output, size, "link#%d", link->sdl_index);
            return;
        }
        size_t used = 0;
        output[0] = '\0';
        const size_t name_length = link->sdl_nlen < size - 1 ? link->sdl_nlen : size - 1;
        memcpy(output, link->sdl_data, name_length);
        used = name_length;
        output[used] = '\0';
        const unsigned char *bytes = (const unsigned char *)LLADDR(link);
        for (int index = 0; index < link->sdl_alen && used + 1 < size; index++) {
            const int separator = index > 0 || used > 0;
            int written = snprintf(output + used, size - used, separator ? ":%x" : "%x", bytes[index]);
            if (written < 0) {
                break;
            }
            used += (size_t)written;
        }
        if (output[0] == '\0') {
            snprintf(output, size, "link#%d", link->sdl_index);
        }
        return;
    }
    snprintf(output, size, "-");
}

char *tailscale_route_table_ipv4_text(void) {
    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP2, 0 };
    char *raw = NULL;
    size_t length = 0;
    int loaded = 0;
    // The table can grow between the size probe and the dump.
    for (int attempt = 0; attempt < 5 && !loaded; attempt++) {
        size_t needed = 0;
        if (sysctl(mib, 6, NULL, &needed, NULL, 0) < 0) {
            free(raw);
            return NULL;
        }
        needed += needed / 4 + 4096;
        char *grown = realloc(raw, needed);
        if (grown == NULL) {
            free(raw);
            return NULL;
        }
        raw = grown;
        length = needed;
        if (sysctl(mib, 6, raw, &length, NULL, 0) == 0) {
            loaded = 1;
        } else if (errno != ENOMEM) {
            free(raw);
            return NULL;
        }
    }
    if (!loaded) {
        free(raw);
        return NULL;
    }

    struct tsr_text text = { 0 };
    tsr_append(&text, "Routing tables\n\nInternet:\nDestination        Gateway            Flags        Netif Expire\n");

    char *cursor = raw;
    char *const limit = raw + length;
    while (cursor + sizeof(struct rt_msghdr2) <= limit) {
        struct rt_msghdr2 *message = (struct rt_msghdr2 *)cursor;
        if (message->rtm_msglen == 0) {
            break;
        }
        char *const message_end = cursor + message->rtm_msglen;
        cursor = message_end;
        if (message_end > limit || message->rtm_version != RTM_VERSION) {
            continue;
        }

        const struct sockaddr *addresses[RTAX_MAX] = { 0 };
        char *pointer = (char *)(message + 1);
        for (int index = 0; index < RTAX_MAX; index++) {
            if ((message->rtm_addrs & (1 << index)) == 0) {
                continue;
            }
            if (pointer + 2 > message_end) {
                break;
            }
            const struct sockaddr *address = (const struct sockaddr *)pointer;
            addresses[index] = address;
            pointer += tsr_sa_size(address);
        }

        const struct sockaddr *destination = addresses[RTAX_DST];
        if (destination == NULL
            || destination->sa_family != AF_INET
            || destination->sa_len < sizeof(struct sockaddr_in)) {
            continue;
        }
        const struct in_addr destination_address = ((const struct sockaddr_in *)destination)->sin_addr;
        char address_text[INET_ADDRSTRLEN] = { 0 };
        if (inet_ntop(AF_INET, &destination_address, address_text, sizeof(address_text)) == NULL) {
            continue;
        }

        const uint32_t flags = (uint32_t)message->rtm_flags;
        char destination_text[INET_ADDRSTRLEN + 4] = { 0 };
        const struct sockaddr *netmask = addresses[RTAX_NETMASK];
        if (flags & RTF_HOST) {
            snprintf(destination_text, sizeof(destination_text), "%s", address_text);
        } else if (netmask == NULL) {
            // netstat infers a classful prefix here; RouteOutputParser does
            // the same for a destination without "/" and without H.
            snprintf(destination_text, sizeof(destination_text), "%s", address_text);
        } else {
            // Netmask sockaddrs are commonly truncated after the last
            // non-zero byte (sa_len < 8), and sa_len 0 means /0.
            const unsigned char *mask_bytes = (const unsigned char *)netmask;
            uint32_t mask = 0;
            for (int index = 0; index < 4; index++) {
                const int offset = 4 + index; // offsetof(sockaddr_in, sin_addr)
                const unsigned char byte = offset < netmask->sa_len ? mask_bytes[offset] : 0;
                mask = (mask << 8) | byte;
            }
            int prefix = 0;
            while (prefix < 32 && (mask & (0x80000000u >> prefix))) {
                prefix++;
            }
            if (prefix == 0 && destination_address.s_addr == 0) {
                snprintf(destination_text, sizeof(destination_text), "default");
            } else {
                snprintf(destination_text, sizeof(destination_text), "%s/%d", address_text, prefix);
            }
        }

        char gateway_text[64];
        tsr_format_gateway(addresses[RTAX_GATEWAY], gateway_text, sizeof(gateway_text));

        char flags_text[32];
        tsr_format_flags(flags, flags_text, sizeof(flags_text));

        char interface_name[IF_NAMESIZE + 1] = { 0 };
        if (if_indextoname(message->rtm_index, interface_name) == NULL) {
            snprintf(interface_name, sizeof(interface_name), "-");
        }

        char line[256];
        snprintf(
            line,
            sizeof(line),
            "%-18s %-18s %-12s %s\n",
            destination_text,
            gateway_text,
            flags_text[0] == '\0' ? "-" : flags_text,
            interface_name
        );
        tsr_append(&text, line);
    }
    free(raw);

    if (text.failed) {
        free(text.data);
        return NULL;
    }
    return text.data;
}

int tailscale_interface_flags(const char *name) {
    if (name == NULL || strlen(name) >= IFNAMSIZ) {
        return -1;
    }
    const int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) {
        return -1;
    }
    struct ifreq request;
    memset(&request, 0, sizeof(request));
    strlcpy(request.ifr_name, name, sizeof(request.ifr_name));
    const int result = ioctl(descriptor, SIOCGIFFLAGS, &request);
    close(descriptor);
    if (result < 0) {
        return -1;
    }
    return (int)(request.ifr_flags & 0xffff);
}

int tailscale_interface_media_status(const char *name) {
    if (name == NULL || strlen(name) >= IFNAMSIZ) {
        return -1;
    }
    const int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) {
        return -1;
    }
    struct ifmediareq request;
    memset(&request, 0, sizeof(request));
    strlcpy(request.ifm_name, name, sizeof(request.ifm_name));
    const int result = ioctl(descriptor, SIOCGIFMEDIA, &request);
    close(descriptor);
    if (result < 0 || (request.ifm_status & IFM_AVALID) == 0) {
        return -1;
    }
    return (request.ifm_status & IFM_ACTIVE) ? 1 : 0;
}

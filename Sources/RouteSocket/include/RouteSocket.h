#ifndef TAILSCALE_ROUTE_SOCKET_H
#define TAILSCALE_ROUTE_SOCKET_H

#include <stdint.h>

int tailscale_route_socket_open(void);
int tailscale_route_socket_apply_ipv4(
    int descriptor,
    uint32_t network,
    uint8_t prefix_length,
    uint32_t gateway,
    int32_t add
);
int tailscale_route_socket_change_ipv4(
    int descriptor,
    uint32_t network,
    uint8_t prefix_length,
    uint32_t gateway
);
void tailscale_route_socket_close(int descriptor);

/// Read-only IPv4 routing table dump (sysctl NET_RT_DUMP2) formatted like
/// `netstat -rn -f inet`. Returns a malloc'd NUL-terminated string the caller
/// must free(), or NULL on failure.
char *tailscale_route_table_ipv4_text(void);

/// SIOCGIFFLAGS for an interface; -1 if the interface cannot be queried.
int tailscale_interface_flags(const char *name);

/// SIOCGIFMEDIA link status: 1 active, 0 inactive, -1 unknown/not reported.
int tailscale_interface_media_status(const char *name);

#endif

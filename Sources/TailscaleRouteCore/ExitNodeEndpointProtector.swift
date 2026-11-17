import Foundation

public struct ExitNodeEndpointProtectionResult: Sendable {
    public let managedRoutes: [RouteSpec]
    public let addedCount: Int
    public let removedCount: Int
    public let warnings: [String]

    public init(
        managedRoutes: [RouteSpec],
        addedCount: Int,
        removedCount: Int,
        warnings: [String]
    ) {
        self.managedRoutes = managedRoutes
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.warnings = warnings
    }
}

/// Result of pinning the domain resolver's DNS servers. Same shape as the
/// Exit Node endpoint result; kept as a distinct name for readability.
public typealias DNSServerRouteProtectionResult = ExitNodeEndpointProtectionResult

/// Pins the active Exit Node's public WireGuard endpoint to the current
/// physical gateway with an exact `/32` host route. A plain route lookup
/// would otherwise send the endpoint into the utun default route; Tailscale
/// normally avoids that loop by binding its socket to the physical interface,
/// and this host route keeps the endpoint reachable even if interface binding
/// fails or changes. Routes are owned with their exact destination, gateway
/// and interface triple so gateway switches replace them precisely.
public struct ExitNodeEndpointProtector: Sendable {
    private let reconciler: PinnedHostRouteReconciler

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.reconciler = PinnedHostRouteReconciler(
            runner: runner,
            cleanupFailurePrefix: "清理旧的 Exit Node 端点路由失败",
            pinFailurePrefix: "无法钉住 Exit Node 端点"
        )
    }

    /// - Parameter splitOwnedRoutes: routes the split-route ledger currently
    ///   owns. When the Exit Node moves away from an address that is also a
    ///   split target (for example a temporary domain resolving to the old
    ///   endpoint), the identical kernel route is handed over instead of
    ///   being deleted out from under the split route.
    public func reconcile(
        endpointAddress: String?,
        gateway: String?,
        interfaceName: String?,
        previouslyManaged: [RouteSpec],
        splitOwnedRoutes: [RouteSpec] = []
    ) -> ExitNodeEndpointProtectionResult {
        reconciler.reconcile(
            addresses: endpointAddress.map { [$0] } ?? [],
            gateway: gateway,
            interfaceName: interfaceName,
            previouslyManaged: previouslyManaged,
            handedOver: splitOwnedRoutes
        )
    }
}

/// Pins the public DNS servers used by `DirectDNSDomainResolver`
/// (114.114.114.114 / 222.85.85.85) to the current physical gateway with exact
/// `/32` host routes. `dig @server` only chooses *whom* to ask; the packets
/// still follow the route table, and with an Exit Node active the default
/// route is Tailscale's utun. Without these pins, domain resolution depends on
/// the China list already being installed (it is not on the first apply, and
/// is never touched by a domain-only refresh), and queries leak into the tunnel
/// and time out. Gateway and interface come from the current network snapshot,
/// so switching between Wi-Fi and an external adapter replaces the pins.
public struct DNSServerRouteProtector: Sendable {
    private let reconciler: PinnedHostRouteReconciler

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.reconciler = PinnedHostRouteReconciler(
            runner: runner,
            cleanupFailurePrefix: "清理旧的 DNS 服务器路由失败",
            pinFailurePrefix: "无法钉住 DNS 服务器"
        )
    }

    public func reconcile(
        servers: [String],
        gateway: String?,
        interfaceName: String?,
        previouslyManaged: [RouteSpec]
    ) -> DNSServerRouteProtectionResult {
        reconciler.reconcile(
            addresses: servers,
            gateway: gateway,
            interfaceName: interfaceName,
            previouslyManaged: previouslyManaged
        )
    }
}

/// Shared exact-ownership reconciler for `/32` host routes pinned to the
/// physical gateway. Desired routes are (address, gateway, interface) triples;
/// recorded routes that no longer match are deleted first, then missing ones
/// are added and verified with `route get` so the pin actually wins lookup.
struct PinnedHostRouteReconciler: Sendable {
    let runner: any CommandRunning
    let cleanupFailurePrefix: String
    let pinFailurePrefix: String

    func reconcile(
        addresses: [String],
        gateway: String?,
        interfaceName: String?,
        previouslyManaged: [RouteSpec],
        handedOver: [RouteSpec] = []
    ) -> ExitNodeEndpointProtectionResult {
        var warnings: [String] = []
        var desired: Set<RouteSpec> = []
        if let gateway, !gateway.isEmpty, IPv4CIDR.parseAddress(gateway) != nil,
           let interfaceName, !interfaceName.isEmpty, !Self.isVirtual(interfaceName)
        {
            for address in addresses {
                guard let cidr = IPv4CIDR.parse("\(address)/32"),
                      // Private/CGNAT addresses are on-link or Tailscale-owned
                      // and never need a pinned gateway route.
                      !IPv4CIDR.protectedRouteCIDRs.contains(where: { $0.overlaps(cidr) })
                else { continue }
                desired.insert(RouteSpec(cidr: cidr.description, gateway: gateway, interfaceName: interfaceName))
            }
        }

        let validPrevious = previouslyManaged.filter { route in
            IPv4CIDR.parse(route.cidr) != nil && IPv4CIDR.parseAddress(route.gateway) != nil
        }
        let desiredKeys = Set(desired.map(Self.routeKey))
        let handedOverKeys = Set(handedOver.map(Self.routeKey))
        // A stale pin whose exact route is now owned by another ledger is
        // released (not deleted, not retained): deleting it would remove the
        // other owner's route.
        let stale = validPrevious.filter {
            !desiredKeys.contains(Self.routeKey($0)) && !handedOverKeys.contains(Self.routeKey($0))
        }

        var currentRoutes = readRoutes()
        var removedCount = 0
        // A stale route whose deletion could not be confirmed stays owned so
        // the next reconcile (or Stop) retries it instead of orphaning it.
        var undeletedStale = Set<RouteSpec>()
        for route in stale {
            guard currentRoutes.contains(where: { Self.matches($0, spec: route) }) else {
                // Already gone; nothing remains to own or remove.
                continue
            }
            let result = mutate(route, action: "delete")
            currentRoutes = readRoutes()
            if result.succeeded, !currentRoutes.contains(where: { Self.matches($0, spec: route) }) {
                removedCount += 1
            } else {
                undeletedStale.insert(route)
                warnings.append(
                    "\(cleanupFailurePrefix)：\(route.cidr) via \(route.gateway) on \(route.interfaceName)：\(result.failureReason)"
                )
            }
        }

        var retained = Set<RouteSpec>()
        var addedCount = 0
        for route in desired.sorted(by: Self.specOrder) {
            let exists = currentRoutes.contains(where: { Self.matches($0, spec: route) })
            let winsLookup = selectedInterface(for: IPv4CIDR.addressString(from: route.cidr) ?? route.cidr)
                == route.interfaceName
            if exists, winsLookup {
                retained.insert(route)
                continue
            }

            let result = mutate(route, action: "add")
            currentRoutes = readRoutes()
            let added = currentRoutes.contains(where: { Self.matches($0, spec: route) })
            let nowWins = selectedInterface(for: IPv4CIDR.addressString(from: route.cidr) ?? route.cidr)
                == route.interfaceName
            if result.succeeded, added, nowWins {
                retained.insert(route)
                addedCount += 1
            } else {
                if result.succeeded, added {
                    _ = mutate(route, action: "delete")
                    currentRoutes = readRoutes()
                }
                warnings.append(
                    "\(pinFailurePrefix) \(route.cidr)：未确认经由 \(route.gateway) on \(route.interfaceName)；\(result.failureReason)"
                )
            }
        }

        return ExitNodeEndpointProtectionResult(
            managedRoutes: retained.union(undeletedStale).sorted(by: Self.specOrder),
            addedCount: addedCount,
            removedCount: removedCount,
            warnings: warnings
        )
    }

    private func mutate(_ route: RouteSpec, action: String) -> CommandResult {
        runner.run("/sbin/route", arguments: [
            "-n", action, "-host", IPv4CIDR.addressString(from: route.cidr) ?? route.cidr, route.gateway
        ])
    }

    private func selectedInterface(for address: String) -> String? {
        let result = runner.run("/sbin/route", arguments: ["-n", "get", address])
        guard result.succeeded else { return nil }
        return RouteOutputParser.parseRouteGetEntry(result.stdout)?.interfaceName
    }

    private func readRoutes() -> [RouteEntry] {
        let result = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        guard result.succeeded else { return [] }
        return RouteOutputParser.parseRouteTable(result.stdout)
    }

    private static func matches(_ entry: RouteEntry, spec: RouteSpec) -> Bool {
        // A kernel clone (flag W) is not the pinned static route.
        !entry.flags.contains("W")
            && IPv4CIDR.parse(entry.destination)?.description == IPv4CIDR.canonical(spec.cidr)
            && entry.gateway == spec.gateway
            && entry.interfaceName == spec.interfaceName
    }

    private static func routeKey(_ spec: RouteSpec) -> String {
        "\(IPv4CIDR.canonical(spec.cidr) ?? spec.cidr)|\(spec.gateway)|\(spec.interfaceName)"
    }

    private static func specOrder(_ left: RouteSpec, _ right: RouteSpec) -> Bool {
        routeKey(left) < routeKey(right)
    }

    private static func isVirtual(_ interfaceName: String) -> Bool {
        interfaceName == "lo"
            || interfaceName.hasPrefix("utun")
            || interfaceName.hasPrefix("bridge")
            || interfaceName.hasPrefix("awdl")
            || interfaceName.hasPrefix("llw")
            || interfaceName.hasPrefix("tap")
            || interfaceName.hasPrefix("tun")
    }
}

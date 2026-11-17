import Foundation

public struct ExternalGatewayRouteProtectionResult: Sendable {
    public let managedRoutes: [RouteSpec]
    public let pendingRestorations: [RouteSpec]
    public let addedCount: Int
    public let removedCount: Int
    public let warnings: [String]

    public init(
        managedRoutes: [RouteSpec],
        pendingRestorations: [RouteSpec] = [],
        addedCount: Int,
        removedCount: Int,
        warnings: [String]
    ) {
        self.managedRoutes = managedRoutes
        self.pendingRestorations = pendingRestorations
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.warnings = warnings
    }
}

private struct ExternalRouteTableRead {
    let routes: [RouteEntry]
    let succeeded: Bool
}

/// Keeps each detected external network on its physical adapter. A host-only
/// route for the gateway is not sufficient on macOS: Tailscale can still
/// create more-specific utun host routes for other addresses in the subnet,
/// and the host route itself can make `sendto()` fail with ENOMEM. The
/// protector therefore owns a complete network route using the local address
/// as a direct-interface gateway. On macOS, `route -interface <local-ip>` is
/// the form that creates a global static route on the physical adapter;
/// passing the router address can resolve through utun instead.
///
/// These routes are kept in a separate ownership ledger and are never
/// inferred from arbitrary routes. Legacy `/32` records are still understood
/// so an upgrade can remove the old gateway-only route safely.
public struct ExternalNetworkRouteProtector: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func reconcile(
        networks: [ExternalDirectNetwork],
        previouslyManaged: [RouteSpec],
        pendingRestorations pendingRoutes: [RouteSpec] = []
    ) -> ExternalGatewayRouteProtectionResult {
        var warnings: [String] = []
        var pendingRestorations = pendingRoutes
        let restoredPending = restoreConflictingRoutes(pendingRestorations)
        warnings.append(contentsOf: restoredPending.warnings)
        pendingRestorations = restoredPending.pendingRoutes
        let desired = networks.compactMap { network in
            Self.routeSpec(for: network).map { (network: network, route: $0) }
        }
        let validPrevious = previouslyManaged.filter { Self.isValid($0) }
        let previousKeys = Set(validPrevious.map(Self.routeKey))
        let desiredKeys = Set(desired.map { Self.routeKey($0.route) })

        var currentRead = readRoutes()
        guard currentRead.succeeded else {
            return ExternalGatewayRouteProtectionResult(
                managedRoutes: validPrevious.sorted(by: Self.specOrder),
                pendingRestorations: pendingRestorations,
                addedCount: 0,
                removedCount: 0,
                warnings: ["无法读取当前 IPv4 路由表，未执行外接网段保护变更"]
            )
        }
        var currentRoutes = currentRead.routes
        var removedCount = 0
        var retained = Set<RouteSpec>()
        for route in validPrevious where !desiredKeys.contains(Self.routeKey(route)) {
            guard currentRoutes.contains(where: { Self.matches($0, spec: route) }) else { continue }
            let result = mutate(route, action: "delete")
            currentRead = readRoutes()
            currentRoutes = currentRead.routes
            if result.succeeded,
               currentRead.succeeded,
               !currentRoutes.contains(where: { Self.matches($0, spec: route) })
            {
                removedCount += 1
            } else {
                retained.insert(route)
                warnings.append(
                    "清理旧外接网段路由失败：\(route.cidr) interface \(route.gateway) on \(route.interfaceName)：\(result.failureReason)"
                )
            }
        }

        var addedCount = 0
        for item in desired.sorted(by: { Self.specOrder($0.route, $1.route) }) {
            let route = item.route
            guard currentRead.succeeded else {
                if previousKeys.contains(Self.routeKey(route)) { retained.insert(route) }
                warnings.append("无法继续核对外接网段 \(route.cidr)：当前 IPv4 路由表不可读")
                break
            }
            // A previous implementation could leave the same network prefix
            // installed through another physical interface (for example
            // `192.168.32.0/20 -> 192.168.1.1` on Wi-Fi).  macOS returns
            // EEXIST when we try to add the correct direct route on the
            // external adapter, so remove that exact stale static gateway
            // route before installing the route we own.  Do not touch the
            // native connected UCSI route or a static direct UCSc route on
            // the target adapter.
            let conflictingNetworkCleanup = removeConflictingExactNetworkRoutes(
                route: route,
                from: currentRoutes
            )
            removedCount += conflictingNetworkCleanup.removedCount
            warnings.append(contentsOf: conflictingNetworkCleanup.warnings)
            currentRead = readRoutes()
            currentRoutes = currentRead.routes
            guard currentRead.succeeded else {
                if previousKeys.contains(Self.routeKey(route)) { retained.insert(route) }
                let restored = restoreConflictingRoutes(conflictingNetworkCleanup.removedRoutes)
                warnings.append(contentsOf: restored.warnings)
                pendingRestorations.append(contentsOf: restored.pendingRoutes)
                warnings.append("无法验证冲突路由清理结果：\(route.cidr)")
                break
            }

            let legacyCleanup = removeLegacyAndForeignHostRoutes(
                network: item.network,
                route: route,
                from: currentRoutes
            )
            removedCount += legacyCleanup.removedCount
            warnings.append(contentsOf: legacyCleanup.warnings)
            currentRead = readRoutes()
            currentRoutes = currentRead.routes
            guard currentRead.succeeded else {
                if previousKeys.contains(Self.routeKey(route)) { retained.insert(route) }
                let restored = restoreConflictingRoutes(conflictingNetworkCleanup.removedRoutes)
                warnings.append(contentsOf: restored.warnings)
                pendingRestorations.append(contentsOf: restored.pendingRoutes)
                warnings.append("无法验证外接网段旧路由清理结果：\(route.cidr)")
                break
            }

            let exactRouteExists = currentRoutes.contains(where: { Self.matches($0, spec: route) })
            let selected = selectedInterfaces(for: route)
            if exactRouteExists, selected.complete, selected.interfaces.allSatisfy({ $0 == route.interfaceName }) {
                // A static direct route is indistinguishable from one created
                // by an earlier App instance after the ledger is migrated. It
                // is the exact route this protector is responsible for, so
                // retain it and make ownership explicit in the new ledger.
                retained.insert(route)
                continue
            }

            let result = mutate(route, action: "add")
            currentRead = readRoutes()
            currentRoutes = currentRead.routes
            let nowMatches = currentRoutes.contains(where: { Self.matches($0, spec: route) })
            let nowSelected = selectedInterfaces(for: route)

            if result.succeeded, currentRead.succeeded, nowMatches, nowSelected.complete,
               nowSelected.interfaces.allSatisfy({ $0 == route.interfaceName }) {
                retained.insert(route)
                if !previousKeys.contains(Self.routeKey(route)) { addedCount += 1 }
            } else {
                if nowMatches {
                    let rollback = mutate(route, action: "delete")
                    if !rollback.succeeded {
                        warnings.append("外接网段新路由验证失败且回滚失败：\(route.cidr)：\(rollback.failureReason)")
                        retained.insert(route)
                    }
                }
                let restored = restoreConflictingRoutes(conflictingNetworkCleanup.removedRoutes)
                warnings.append(contentsOf: restored.warnings)
                pendingRestorations.append(contentsOf: restored.pendingRoutes)
                let selectedDescription = nowSelected.interfaces.isEmpty
                    ? "无法读取"
                    : Set(nowSelected.interfaces).sorted().joined(separator: ",")
                if previousKeys.contains(Self.routeKey(route)) { retained.insert(route) }
                warnings.append(
                    "无法固定外接网段 \(route.cidr) 到 \(route.interfaceName)：选路=\(selectedDescription)，\(result.failureReason)"
                )
            }
        }

        return ExternalGatewayRouteProtectionResult(
            managedRoutes: retained.sorted(by: Self.specOrder),
            pendingRestorations: Array(Set(pendingRestorations)).sorted(by: Self.specOrder),
            addedCount: addedCount,
            removedCount: removedCount,
            warnings: warnings
        )
    }

    private func mutate(_ route: RouteSpec, action: String) -> CommandResult {
        guard let cidr = IPv4CIDR.parse(route.cidr) else {
            return CommandResult(
                executable: "/sbin/route",
                arguments: [],
                stdout: "",
                stderr: "无效的外接网段 \(route.cidr)",
                exitCode: 1
            )
        }
        if cidr.prefixLength == 32 {
            // Upgrade cleanup for the previous gateway-only implementation.
            return runner.run("/sbin/route", arguments: [
                "-n", action, "-host", IPv4CIDR.string(from: cidr.network), "-interface", route.gateway
            ])
        }
        // `-interface` must receive an address owned by this host. Using the
        // detected router address here is unsafe on macOS: route(8) may resolve
        // that next hop through the Exit Node and create the static route on a
        // utun interface. The local address forces an UCSc direct route on the
        // physical adapter while leaving the configd-created connected route
        // intact. The command is also reversible with the same arguments.
        return runner.run("/sbin/route", arguments: [
            "-n", action, "-net", cidr.description, "-interface", route.gateway
        ])
    }

    private func selectedInterfaces(for route: RouteSpec) -> (interfaces: [String], complete: Bool) {
        guard let cidr = IPv4CIDR.parse(route.cidr) else { return ([], false) }
        var probes: Set<UInt32> = []
        if cidr.prefixLength == 32 {
            probes.insert(cidr.network)
        } else if cidr.prefixLength == 31 {
            probes.insert(cidr.network)
            probes.insert(cidr.lastAddress)
        } else {
            // Network and broadcast addresses are not valid host probes on
            // macOS. `route get` may send those two lookups to the default
            // route even when every usable address uses this network route.
            probes.insert(cidr.network + 1)
            probes.insert(cidr.lastAddress - 1)
            probes.insert(cidr.network + (cidr.lastAddress - cidr.network) / 2)
        }
        if let gateway = IPv4CIDR.parseAddress(route.gateway) { probes.insert(gateway) }
        var interfaces: [String] = []
        var complete = true
        for value in probes.sorted() {
            let address = IPv4CIDR.string(from: value)
            let result = runner.run("/sbin/route", arguments: ["-n", "get", address])
            guard result.succeeded,
                  let interfaceName = RouteOutputParser.parseRouteGetEntry(result.stdout)?.interfaceName
            else {
                complete = false
                continue
            }
            interfaces.append(interfaceName)
        }
        return (interfaces, complete && interfaces.count == probes.count)
    }

    private func readRoutes() -> ExternalRouteTableRead {
        let result = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        guard result.succeeded else {
            return ExternalRouteTableRead(routes: [], succeeded: false)
        }
        return ExternalRouteTableRead(
            routes: RouteOutputParser.parseRouteTable(result.stdout),
            succeeded: true
        )
    }

    private func removeLegacyAndForeignHostRoutes(
        network externalNetwork: ExternalDirectNetwork,
        route: RouteSpec,
        from routes: [RouteEntry]
    ) -> (removedCount: Int, warnings: [String]) {
        guard let network = IPv4CIDR.parse(route.cidr), network.prefixLength < 32 else {
            return (0, [])
        }
        let localAddress = externalNetwork.address
        let gatewayAddress = externalNetwork.gateway.flatMap(IPv4CIDR.parseAddress)
        let candidates = routes.filter { entry in
            guard let candidate = IPv4CIDR.parse(entry.destination), candidate.prefixLength == 32,
                  network.contains(candidate),
                  let address = IPv4CIDR.parseAddress(entry.destination)
            else { return false }
            let isLegacyGatewayRoute = address == gatewayAddress
                && entry.interfaceName == route.interfaceName
                && entry.gateway == localAddress
            // A virtual-interface host route may belong to Tailscale or a
            // third party. Without an ownership triple, leave it untouched.
            return isLegacyGatewayRoute
        }

        var removedCount = 0
        var warnings: [String] = []
        for entry in candidates {
            guard let address = IPv4CIDR.parse(entry.destination).map({ IPv4CIDR.string(from: $0.network) }) else { continue }
            let result = runner.run("/sbin/route", arguments: ["-n", "delete", "-host", address, entry.gateway])
            if result.succeeded {
                removedCount += 1
            } else {
                warnings.append("清理外接网段中的旧主机路由 \(address)→\(entry.interfaceName) 失败：\(result.failureReason)")
            }
        }
        return (removedCount, warnings)
    }

    private func removeConflictingExactNetworkRoutes(
        route: RouteSpec,
        from routes: [RouteEntry]
    ) -> (removedCount: Int, warnings: [String], removedRoutes: [RouteEntry]) {
        guard let cidr = IPv4CIDR.parse(route.cidr), cidr.prefixLength < 32 else {
            return (0, [], [])
        }

        let candidates = routes.filter { entry in
            guard IPv4CIDR.parse(entry.destination)?.description == cidr.description,
                  entry.interfaceName != route.interfaceName,
                  entry.flags.contains("S"),
                  entry.flags.contains("G"),
                  IPv4CIDR.parseAddress(entry.gateway) != nil
            else { return false }
            return true
        }

        var removedCount = 0
        var warnings: [String] = []
        var removedRoutes: [RouteEntry] = []
        for entry in candidates {
            let result = runner.run("/sbin/route", arguments: [
                "-n", "delete", "-net", cidr.description, entry.gateway
            ])
            if result.succeeded {
                removedCount += 1
                removedRoutes.append(entry)
            } else {
                warnings.append(
                    "清理冲突的外接网段路由 \(cidr.description)→\(entry.gateway) on \(entry.interfaceName) 失败：\(result.failureReason)"
                )
            }
        }
        return (removedCount, warnings, removedRoutes)
    }

    private func restoreConflictingRoutes(_ routes: [RouteEntry]) -> (restoredCount: Int, warnings: [String], pendingRoutes: [RouteSpec]) {
        var restoredCount = 0
        var warnings: [String] = []
        var pendingRoutes: [RouteSpec] = []
        for entry in routes {
            guard let cidr = IPv4CIDR.canonical(entry.destination),
                  IPv4CIDR.parse(cidr)?.prefixLength ?? 32 < 32,
                  IPv4CIDR.parseAddress(entry.gateway) != nil
            else { continue }
            let original = RouteSpec(cidr: cidr, gateway: entry.gateway, interfaceName: entry.interfaceName)
            let current = readRoutes()
            guard current.succeeded else {
                warnings.append("无法读取路由表确认待恢复冲突路由：\(cidr)→\(entry.gateway) on \(entry.interfaceName)")
                pendingRoutes.append(original)
                continue
            }
            if current.routes.contains(where: {
                IPv4CIDR.canonical($0.destination) == cidr
                    && $0.gateway == entry.gateway
                    && $0.interfaceName == entry.interfaceName
                    && $0.flags.contains("S")
                    && $0.flags.contains("G")
            }) {
                restoredCount += 1
                continue
            }
            let result = runner.run("/sbin/route", arguments: [
                "-n", "add", "-net", cidr, entry.gateway,
                "-ifscope", entry.interfaceName
            ])
            guard result.succeeded else {
                warnings.append("外接网段冲突路由回滚失败：\(cidr)→\(entry.gateway) on \(entry.interfaceName)：\(result.failureReason)")
                pendingRoutes.append(original)
                continue
            }
            let verification = readRoutes()
            guard verification.succeeded,
                  verification.routes.contains(where: {
                      IPv4CIDR.canonical($0.destination) == cidr
                          && $0.gateway == entry.gateway
                          && $0.interfaceName == entry.interfaceName
                          && $0.flags.contains("S")
                          && $0.flags.contains("G")
                  })
            else {
                warnings.append("外接网段冲突路由回滚后未确认原接口：\(cidr)→\(entry.gateway) on \(entry.interfaceName)")
                pendingRoutes.append(original)
                continue
            }
            restoredCount += 1
        }
        return (restoredCount, warnings, pendingRoutes)
    }

    private func restoreConflictingRoutes(_ routes: [RouteSpec]) -> (restoredCount: Int, warnings: [String], pendingRoutes: [RouteSpec]) {
        let entries = routes.map {
            RouteEntry(
                destination: $0.cidr,
                gateway: $0.gateway,
                flags: "UGSc",
                interfaceName: $0.interfaceName,
                rawLine: ""
            )
        }
        return restoreConflictingRoutes(entries)
    }

    private static func routeSpec(for network: ExternalDirectNetwork) -> RouteSpec? {
        guard IPv4CIDR.parseAddress(network.address) != nil,
              !network.interfaceName.isEmpty,
              !isVirtual(network.interfaceName),
              let cidr = IPv4CIDR.parse(network.cidr)
        else { return nil }
        return RouteSpec(cidr: cidr.description, gateway: network.address, interfaceName: network.interfaceName)
    }

    private static func isValid(_ route: RouteSpec) -> Bool {
        IPv4CIDR.parse(route.cidr) != nil
            && IPv4CIDR.parseAddress(route.gateway) != nil
            && !route.interfaceName.isEmpty
            && !isVirtual(route.interfaceName)
    }

    private static func matches(_ entry: RouteEntry, spec: RouteSpec) -> Bool {
        guard IPv4CIDR.parse(entry.destination)?.description == IPv4CIDR.canonical(spec.cidr),
              entry.interfaceName == spec.interfaceName,
              let cidr = IPv4CIDR.parse(spec.cidr)
        else { return false }

        if cidr.prefixLength == 32 {
            return entry.gateway == spec.gateway
        }

        // The route table represents `route ... -interface <local-ip>` with
        // a link-layer gateway (for example `link#10`), not with the local IP
        // supplied to route(8). Do not mistake the native interface-scoped
        // UCSI route for our static UCSc route.
        return entry.flags.contains("S")
            && !entry.flags.contains("G")
            && !entry.flags.contains("I")
    }

    private static func routeKey(_ route: RouteSpec) -> String {
        "\(IPv4CIDR.canonical(route.cidr) ?? route.cidr)|\(route.gateway)|\(route.interfaceName)"
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

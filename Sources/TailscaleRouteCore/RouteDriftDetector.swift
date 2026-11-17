import Foundation

/// Compares the Helper ownership ledger with a fresh kernel snapshot. It only
/// reports drift; it never changes routes or infers ownership from destinations.
public enum RouteDriftDetector {
    public static func missingOwnedRoutes(
        state: PersistedRouteState,
        actualRoutes: [RouteEntry],
        actualIPv6Routes: [RouteEntry]? = nil
    ) -> [String] {
        guard state.lifecycle == .enabled || state.lifecycle == .partial || state.lifecycle == .networkChanging else {
            return []
        }
        var missing: [String] = []
        let routesByIdentity = Set(actualRoutes.compactMap { entry -> String? in
            guard let cidr = IPv4CIDR.canonical(entry.destination) else { return nil }
            return identity(cidr: cidr, gateway: entry.gateway, interfaceName: entry.interfaceName)
        })
        let managedIPv4Routes = state.managedRoutes
            + state.managedDomainIPv4Routes.map(\.route)
        // External-network protection has its own reconciliation and may be
        // represented by a directly connected kernel route (for example
        // `link#10`) while its ownership ledger records the interface address
        // as the gateway. Do not let that separate representation trigger a
        // China-route reapply; protection reconciliation validates it itself.
        for route in managedIPv4Routes
            + state.managedExitNodeEndpointRoutes
            + state.managedDNSServerRoutes
        {
            guard let cidr = IPv4CIDR.canonical(route.cidr) else {
                missing.append("\(route.cidr) (账本目的地无法解析)")
                continue
            }
            let key = identity(cidr: cidr, gateway: route.gateway, interfaceName: route.interfaceName)
            if !routesByIdentity.contains(key) { missing.append("\(cidr) via \(route.gateway) dev \(route.interfaceName)") }
        }

        if let actualIPv6Routes {
            let ipv6Identity = Set(actualIPv6Routes.map { entry in
                "\(canonicalIPv6(entry.destination))|\(entry.gateway.lowercased())|\(entry.interfaceName)"
            })
            let managedIPv6Routes = state.managedIPv6Routes
                + state.managedDomainIPv6Routes.map(\.route)
            for route in managedIPv6Routes {
                let key = "\(canonicalIPv6(route.address))|\(route.gateway.lowercased())|\(route.interfaceName)"
                if !ipv6Identity.contains(key) {
                    missing.append("IPv6 \(route.address) via \(route.gateway) dev \(route.interfaceName)")
                }
            }
        }
        return Array(Set(missing)).sorted()
    }

    private static func identity(cidr: String, gateway: String, interfaceName: String) -> String {
        "\(cidr)|\(gateway)|\(interfaceName)"
    }

    private static func canonicalIPv6(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/128", with: "")
            .lowercased()
    }
}

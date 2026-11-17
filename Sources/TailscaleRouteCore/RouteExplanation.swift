import Foundation

/// Explains the current longest-prefix route choice for one IPv4 address.
/// This service is pure and never issues route mutations.
public enum RouteExplanationService {
    public static func explain(
        address rawAddress: String,
        actualRoutes: [RouteEntry],
        desiredTargets: [String],
        state: PersistedRouteState,
        kernelSelection: RouteEntry? = nil
    ) -> RouteExplanation {
        guard let address = IPv4CIDR.parse(rawAddress), address.prefixLength == 32 else {
            return RouteExplanation(
                address: rawAddress,
                matchingTargetCIDR: nil,
                selectedRoute: nil,
                selectedRouteIsAppManaged: false,
                candidates: [],
                summary: "请输入有效的 IPv4 地址"
            )
        }

        let matchingTargets = desiredTargets.compactMap { IPv4CIDR.parse($0) }.filter { $0.contains(address) }
        let matchingTarget = matchingTargets.max { $0.prefixLength < $1.prefixLength }?.description
        let candidates = actualRoutes.compactMap { route -> (RouteEntry, IPv4CIDR)? in
            let cidr = route.destination == "default"
                ? IPv4CIDR(network: 0, prefixLength: 0)
                : IPv4CIDR.parse(route.destination)
            guard let cidr, cidr.contains(address) else { return nil }
            return (route, cidr)
        }.sorted {
            if $0.1.prefixLength != $1.1.prefixLength { return $0.1.prefixLength > $1.1.prefixLength }
            if $0.0.interfaceName != $1.0.interfaceName { return $0.0.interfaceName < $1.0.interfaceName }
            return $0.0.gateway < $1.0.gateway
        }

        let selected = kernelSelection ?? candidates.first?.0
        let selectedManaged = selected.map { isManaged($0, by: state) } ?? false
        let explainedCandidates = candidates.map { route, cidr in
            let isSelected = selected.map { sameRoute(route, $0) } ?? false
            let managed = isManaged(route, by: state)
            let explanation: String
            if isSelected {
                explanation = "内核当前选中此路由"
            } else if let selected,
                      let selectedCIDR = selected.destination == "default"
                        ? IPv4CIDR(network: 0, prefixLength: 0)
                        : IPv4CIDR.parse(selected.destination),
                      selectedCIDR.prefixLength > cidr.prefixLength
            {
                explanation = "被更具体的 /\(selectedCIDR.prefixLength) 路由覆盖"
            } else {
                explanation = "匹配此地址，但当前未被内核选中"
            }
            return RouteExplanationCandidate(
                route: route,
                prefixLength: cidr.prefixLength,
                isAppManaged: managed,
                isSelected: isSelected,
                explanation: explanation
            )
        }

        let selectionDescription: String
        if let selected {
            selectionDescription = "\(selected.destination) via \(selected.gateway) dev \(selected.interfaceName)"
        } else {
            selectionDescription = "没有匹配路由"
        }
        let targetDescription = matchingTarget.map { "命中分流目标 \($0)" } ?? "未命中当前分流目标清单"
        let ownershipDescription = selected == nil
            ? ""
            : (selectedManaged ? "；选中路由由 App 账本管理" : "；选中路由不属于 App 账本")
        return RouteExplanation(
            address: IPv4CIDR.string(from: address.network),
            matchingTargetCIDR: matchingTarget,
            selectedRoute: selected,
            selectedRouteIsAppManaged: selectedManaged,
            candidates: explainedCandidates,
            summary: "\(targetDescription)；实际选路：\(selectionDescription)\(ownershipDescription)"
        )
    }

    private static func sameRoute(_ lhs: RouteEntry, _ rhs: RouteEntry) -> Bool {
        canonicalDestination(lhs.destination) == canonicalDestination(rhs.destination)
            && lhs.gateway == rhs.gateway
            && lhs.interfaceName == rhs.interfaceName
    }

    private static func canonicalDestination(_ destination: String) -> String? {
        destination == "default" ? "0.0.0.0/0" : IPv4CIDR.canonical(destination)
    }

    private static func isManaged(_ route: RouteEntry, by state: PersistedRouteState) -> Bool {
        guard let destination = canonicalDestination(route.destination) else { return false }
        let exactIPv4 = (state.managedRoutes + state.managedExitNodeEndpointRoutes + state.managedDNSServerRoutes).contains {
            IPv4CIDR.canonical($0.cidr) == destination
                && $0.gateway == route.gateway
                && $0.interfaceName == route.interfaceName
        }
        return exactIPv4
    }
}

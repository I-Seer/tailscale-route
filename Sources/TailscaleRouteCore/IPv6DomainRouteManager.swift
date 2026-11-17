import Darwin
import Foundation

public struct IPv6RouteUpdateResult: Sendable {
    public let managedRoutes: [IPv6HostRoute]
    public let addedCount: Int
    public let removedCount: Int
    public let warnings: [String]

    public init(
        managedRoutes: [IPv6HostRoute],
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

/// Manages only exact IPv6 host routes for explicitly configured domains.
/// It never changes Tailscale's default IPv6 route or adopts unrelated routes.
public struct IPv6DomainRouteManager: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func apply(
        addresses: [String],
        gateway: String?,
        interfaceName: String?,
        previouslyManaged: [IPv6HostRoute]
    ) -> IPv6RouteUpdateResult {
        let desiredAddresses = Set(addresses.compactMap(IPv6Address.canonical))
        let canonicalGateway = gateway.flatMap(IPv6Address.scopedGateway)
        let usableInterface = interfaceName.flatMap(Self.validInterfaceName)
        var warnings: [String] = []
        var retainedRoutes: [IPv6HostRoute] = []
        var removedCount = 0

        let previous = previouslyManaged.compactMap { route -> IPv6HostRoute? in
            guard let address = IPv6Address.canonical(route.address),
                  let normalizedGateway = IPv6Address.scopedGateway(route.gateway),
                  let interface = Self.validInterfaceName(route.interfaceName)
            else { return nil }
            return IPv6HostRoute(address: address, gateway: normalizedGateway, interfaceName: interface)
        }

        for oldRoute in previous {
            let remainsDesired = desiredAddresses.contains(oldRoute.address)
                && oldRoute.gateway == canonicalGateway
                && oldRoute.interfaceName == usableInterface
            if remainsDesired { continue }

            guard let current = lookup(oldRoute.address), matches(current, oldRoute) else { continue }
            let result = runner.run("/sbin/route", arguments: [
                "-n", "delete", "-inet6", "-host", oldRoute.address, oldRoute.gateway
            ])
            if result.succeeded {
                removedCount += 1
            } else {
                warnings.append("无法清理旧 IPv6 域名路由 \(oldRoute.address)：\(result.failureReason)")
                retainedRoutes.append(oldRoute)
            }
        }

        guard !desiredAddresses.isEmpty else {
            return IPv6RouteUpdateResult(
                managedRoutes: retainedRoutes,
                addedCount: 0,
                removedCount: removedCount,
                warnings: warnings
            )
        }

        guard let canonicalGateway,
              let usableInterface,
              Self.gateway(canonicalGateway, isScopedTo: usableInterface)
        else {
            warnings.append("没有可用的物理 IPv6 网关，域名的 IPv6 地址仍会使用系统默认路由")
            return IPv6RouteUpdateResult(
                managedRoutes: retainedRoutes,
                addedCount: 0,
                removedCount: removedCount,
                warnings: warnings
            )
        }

        var addedCount = 0
        for address in desiredAddresses.sorted() {
            let target = IPv6HostRoute(
                address: address,
                gateway: canonicalGateway,
                interfaceName: usableInterface
            )
            if let existingManaged = previous.first(where: {
                $0.address == address
                    && $0.gateway == canonicalGateway
                    && $0.interfaceName == usableInterface
            }), let current = lookup(address), matches(current, existingManaged) {
                retainedRoutes.append(existingManaged)
                continue
            }

            if let current = lookup(address), current.interfaceName == usableInterface {
                // It was already reaching the physical network independently
                // of this app, so do not claim ownership or later delete it.
                continue
            }

            let result = runner.run("/sbin/route", arguments: [
                "-n", "add", "-inet6", "-host", address, canonicalGateway
            ])
            guard result.succeeded else {
                if let installed = lookup(address), matches(installed, target) {
                    retainedRoutes.append(target)
                    warnings.append("IPv6 路由添加返回失败但路由仍存在，已记入待清理账本：\(address)")
                }
                warnings.append("无法添加 IPv6 本地网关路由 \(address)：\(result.failureReason)")
                continue
            }

            guard let installed = lookup(address), matches(installed, target) else {
                let rollback = runner.run("/sbin/route", arguments: [
                    "-n", "delete", "-inet6", "-host", address, canonicalGateway
                ])
                if rollback.succeeded,
                   let afterRollback = lookup(address),
                   !matches(afterRollback, target)
                {
                    warnings.append("IPv6 路由验证失败，已回滚：\(address) 没有经 \(usableInterface) 到达本地网关")
                } else {
                    retainedRoutes.append(target)
                    warnings.append("IPv6 路由验证失败且回滚未确认，已记入待清理账本：\(address)")
                }
                continue
            }
            retainedRoutes.append(target)
            addedCount += 1
        }

        return IPv6RouteUpdateResult(
            managedRoutes: Array(Set(retainedRoutes)).sorted {
                if $0.address == $1.address { return $0.interfaceName < $1.interfaceName }
                return $0.address < $1.address
            },
            addedCount: addedCount,
            removedCount: removedCount,
            warnings: warnings
        )
    }

    private func lookup(_ address: String) -> RouteEntry? {
        let result = runner.run("/sbin/route", arguments: ["-n", "get", "-inet6", address])
        guard result.succeeded else { return nil }
        return RouteOutputParser.parseRouteGetEntry(result.stdout)
    }

    private func matches(_ entry: RouteEntry, _ route: IPv6HostRoute) -> Bool {
        IPv6Address.canonical(entry.destination) == route.address
            && IPv6Address.scopedGateway(entry.gateway) == route.gateway
            && entry.interfaceName == route.interfaceName
    }

    private static func gateway(_ gateway: String, isScopedTo interfaceName: String) -> Bool {
        guard let separator = gateway.lastIndex(of: "%") else { return false }
        return String(gateway[gateway.index(after: separator)...]) == interfaceName
    }

    private static func validInterfaceName(_ value: String) -> String? {
        guard value.hasPrefix("en"),
              value.count <= 16,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return value
    }
}

private enum IPv6Address {
    static func canonical(_ value: String) -> String? {
        let addressText = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
        var address = in6_addr()
        let parsed = addressText.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let rendered = buffer.withUnsafeMutableBufferPointer { pointer in
            inet_ntop(AF_INET6, &address, pointer.baseAddress, socklen_t(pointer.count))
        }
        guard rendered != nil else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).lowercased()
    }

    static func scopedGateway(_ value: String) -> String? {
        let parts = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = parts.first,
              let canonicalAddress = canonical(String(address))
        else { return nil }
        guard parts.count == 2 else { return canonicalAddress }
        let scope = String(parts[1])
        guard !scope.isEmpty,
              scope.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return "\(canonicalAddress)%\(scope)"
    }
}

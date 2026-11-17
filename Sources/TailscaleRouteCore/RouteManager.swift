import Darwin
import Foundation
import RouteSocket

enum RouteSocketAction: Sendable, Equatable {
    case add
    case delete
    case change

    var messageType: String {
        switch self {
        case .add: "RTM_ADD"
        case .delete: "RTM_DELETE"
        case .change: "RTM_CHANGE"
        }
    }
}

struct RouteSocketOpenResult: Sendable {
    let descriptor: Int32
    let errorCode: Int32
}

protocol RouteSocketClient: Sendable {
    func open() -> RouteSocketOpenResult
    func applyIPv4(
        descriptor: Int32,
        network: UInt32,
        prefixLength: UInt8,
        gateway: UInt32,
        action: RouteSocketAction
    ) -> Int32
    func close(descriptor: Int32)
}

private struct DarwinRouteSocketClient: RouteSocketClient {
    func open() -> RouteSocketOpenResult {
        let descriptor = tailscale_route_socket_open()
        return RouteSocketOpenResult(descriptor: descriptor, errorCode: descriptor < 0 ? errno : 0)
    }

    func applyIPv4(
        descriptor: Int32,
        network: UInt32,
        prefixLength: UInt8,
        gateway: UInt32,
        action: RouteSocketAction
    ) -> Int32 {
        switch action {
        case .add:
            tailscale_route_socket_apply_ipv4(descriptor, network, prefixLength, gateway, 1)
        case .delete:
            tailscale_route_socket_apply_ipv4(descriptor, network, prefixLength, gateway, 0)
        case .change:
            tailscale_route_socket_change_ipv4(descriptor, network, prefixLength, gateway)
        }
    }

    func close(descriptor: Int32) {
        tailscale_route_socket_close(descriptor)
    }
}

public protocol RouteBackend: Sendable {
    func currentRoutes() -> [RouteEntry]
    func routeTableSnapshot() -> RouteTableSnapshot
    func add(_ route: RouteSpec) -> CommandResult
    func change(_ oldRoute: RouteSpec, to newRoute: RouteSpec) -> CommandResult
    func changeBatch(_ replacements: [RouteReplacementPlan], progress: (@Sendable (Int) -> Void)?) -> [CommandResult]
    func remove(_ route: RouteSpec) -> CommandResult
    func addBatch(_ routes: [RouteSpec], progress: (@Sendable (Int) -> Void)?) -> [CommandResult]
    func removeBatch(_ routes: [RouteSpec], progress: (@Sendable (Int) -> Void)?) -> [CommandResult]
    func lookup(address: String) -> RouteEntry?
}

public struct RouteTableSnapshot: Sendable {
    public let routes: [RouteEntry]
    public let succeeded: Bool
    public let failureReason: String?

    public init(routes: [RouteEntry], succeeded: Bool, failureReason: String? = nil) {
        self.routes = routes
        self.succeeded = succeeded
        self.failureReason = failureReason
    }
}

public struct SystemRouteBackend: RouteBackend, Sendable {
    private let runner: any CommandRunning
    private let routeSocket: any RouteSocketClient

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
        self.routeSocket = DarwinRouteSocketClient()
    }

    init(runner: any CommandRunning = ProcessCommandRunner(), routeSocket: any RouteSocketClient) {
        self.runner = runner
        self.routeSocket = routeSocket
    }

    public func currentRoutes() -> [RouteEntry] {
        routeTableSnapshot().routes
    }

    public func routeTableSnapshot() -> RouteTableSnapshot {
        let result = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        guard result.succeeded else {
            return RouteTableSnapshot(routes: [], succeeded: false, failureReason: result.failureReason)
        }
        return RouteTableSnapshot(routes: RouteOutputParser.parseRouteTable(result.stdout), succeeded: true)
    }

    public func add(_ route: RouteSpec) -> CommandResult {
        runner.run("/sbin/route", arguments: routeArguments(action: "add", route: route))
    }

    public func change(_ oldRoute: RouteSpec, to newRoute: RouteSpec) -> CommandResult {
        guard IPv4CIDR.canonical(oldRoute.cidr) == IPv4CIDR.canonical(newRoute.cidr) else {
            return CommandResult(executable: "PF_ROUTE socket", arguments: [], stdout: "", stderr: "route change 只接受同一目的前缀", exitCode: 1)
        }
        return changeBatch([RouteReplacementPlan(oldRoute: oldRoute, newRoute: newRoute)], progress: nil)[0]
    }

    public func changeBatch(
        _ replacements: [RouteReplacementPlan],
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [CommandResult] {
        guard !replacements.isEmpty else { return [] }

        let openedSocket = routeSocket.open()
        guard openedSocket.descriptor >= 0 else {
            let code = openedSocket.errorCode
            let reason = String(cString: strerror(code))
            return replacements.map { routeSocketResult(route: $0.newRoute, action: .change, errorCode: code, reason: reason) }
        }
        let descriptor = openedSocket.descriptor
        defer { routeSocket.close(descriptor: descriptor) }

        var results: [CommandResult] = []
        var previousFailure = false
        for (index, replacement) in replacements.enumerated() {
            let route = replacement.newRoute
            if previousFailure {
                results.append(routeSocketResult(
                    route: route,
                    action: .change,
                    errorCode: ECANCELED,
                    reason: "前一条路由失败，已停止批量操作"
                ))
                continue
            }

            let result: CommandResult
            guard IPv4CIDR.canonical(replacement.oldRoute.cidr) == IPv4CIDR.canonical(route.cidr),
                  let cidr = IPv4CIDR.parse(route.cidr),
                  let gateway = IPv4CIDR.parseAddress(route.gateway)
            else {
                result = routeSocketResult(route: route, action: .change, errorCode: EINVAL, reason: "无效的 IPv4 路由变更")
                results.append(result)
                previousFailure = true
                progress?(index + 1)
                continue
            }

            let errorCode = routeSocket.applyIPv4(
                descriptor: descriptor,
                network: cidr.network,
                prefixLength: UInt8(cidr.prefixLength),
                gateway: gateway,
                action: .change
            )
            let reason = errorCode == 0 ? "" : String(cString: strerror(errorCode))
            result = routeSocketResult(route: route, action: .change, errorCode: errorCode, reason: reason)
            progress?(index + 1)
            results.append(result)
            previousFailure = !result.succeeded
        }
        return results
    }

    public func remove(_ route: RouteSpec) -> CommandResult {
        runner.run("/sbin/route", arguments: routeArguments(action: "delete", route: route))
    }

    public func addBatch(
        _ routes: [RouteSpec],
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [CommandResult] {
        mutateBatch(routes, add: true, progress: progress)
    }

    public func removeBatch(
        _ routes: [RouteSpec],
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [CommandResult] {
        mutateBatch(routes, add: false, progress: progress)
    }

    public func lookup(address: String) -> RouteEntry? {
        let result = runner.run("/sbin/route", arguments: ["-n", "get", address])
        guard result.succeeded else { return nil }
        return RouteOutputParser.parseRouteGetEntry(result.stdout)
    }

    private func routeArguments(action: String, route: RouteSpec) -> [String] {
        var arguments = ["-n", action]
        if let parsed = IPv4CIDR.parse(route.cidr) {
            if parsed.prefixLength == 32 {
                arguments.append(contentsOf: ["-host", IPv4CIDR.string(from: parsed.network)])
            } else {
                arguments.append(contentsOf: ["-net", parsed.description])
            }
        } else {
            arguments.append(route.cidr)
        }

        // Include the gateway for deletion as well as addition so macOS
        // addresses the exact next-hop entry when destinations overlap.
        arguments.append(route.gateway)
        return arguments
    }

    private func mutateBatch(
        _ routes: [RouteSpec],
        add: Bool,
        progress: (@Sendable (Int) -> Void)?
    ) -> [CommandResult] {
        guard !routes.isEmpty else { return [] }

        let openedSocket = routeSocket.open()
        guard openedSocket.descriptor >= 0 else {
            let code = openedSocket.errorCode
            let reason = String(cString: strerror(code))
            return routes.map { routeSocketResult(route: $0, action: add ? .add : .delete, errorCode: code, reason: reason) }
        }
        let descriptor = openedSocket.descriptor
        defer { routeSocket.close(descriptor: descriptor) }

        var results: [CommandResult] = []
        var previousFailure = false
        for (index, route) in routes.enumerated() {
            if previousFailure {
                results.append(routeSocketResult(
                    route: route,
                    action: add ? .add : .delete,
                    errorCode: ECANCELED,
                    reason: "前一条路由失败，已停止批量操作"
                ))
                continue
            }

            let result: CommandResult
            if let cidr = IPv4CIDR.parse(route.cidr),
               let gateway = IPv4CIDR.parseAddress(route.gateway)
            {
                let errorCode = routeSocket.applyIPv4(
                    descriptor: descriptor,
                    network: cidr.network,
                    prefixLength: UInt8(cidr.prefixLength),
                    gateway: gateway,
                    action: add ? .add : .delete
                )
                // ESRCH on delete means the kernel has no matching static
                // route any more (already removed, or only a cloned/scoped
                // host entry is left). The goal "route absent" is met, so it
                // must not abort the batch or fail stop/quit.
                let effectiveCode = (!add && errorCode == ESRCH) ? 0 : errorCode
                let reason = effectiveCode == 0 ? "" : String(cString: strerror(effectiveCode))
                result = routeSocketResult(route: route, action: add ? .add : .delete, errorCode: effectiveCode, reason: reason)
            } else {
                result = routeSocketResult(
                    route: route,
                    action: add ? .add : .delete,
                    errorCode: EINVAL,
                    reason: "无效的 IPv4 路由或网关"
                )
            }
            progress?(index + 1)
            results.append(result)
            previousFailure = !result.succeeded
        }
        return results
    }

    private func routeSocketResult(
        route: RouteSpec,
        action: RouteSocketAction,
        errorCode: Int32,
        reason: String
    ) -> CommandResult {
        var arguments = [action.messageType]
        if let cidr = IPv4CIDR.parse(route.cidr) {
            arguments.append(cidr.description)
        } else {
            arguments.append(route.cidr)
        }
        arguments.append(route.gateway)
        return CommandResult(
            executable: "PF_ROUTE socket",
            arguments: arguments,
            stdout: "",
            stderr: reason,
            exitCode: errorCode == 0 ? 0 : 1
        )
    }
}

public extension RouteBackend {
    func routeTableSnapshot() -> RouteTableSnapshot {
        RouteTableSnapshot(routes: currentRoutes(), succeeded: true)
    }

    func change(_ oldRoute: RouteSpec, to newRoute: RouteSpec) -> CommandResult {
        CommandResult(
            executable: "route",
            arguments: [],
            stdout: "",
            stderr: "当前路由后端不支持原子 change 操作",
            exitCode: 1
        )
    }

    func changeBatch(
        _ replacements: [RouteReplacementPlan],
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [CommandResult] {
        var results: [CommandResult] = []
        var previousFailure = false
        for (index, replacement) in replacements.enumerated() {
            if previousFailure {
                results.append(CommandResult(
                    executable: "route",
                    arguments: [],
                    stdout: "",
                    stderr: "前一条路由失败，已停止批量操作",
                    exitCode: 1
                ))
                continue
            }
            let result = change(replacement.oldRoute, to: replacement.newRoute)
            progress?(index + 1)
            results.append(result)
            previousFailure = !result.succeeded
        }
        return results
    }

    func addBatch(
        _ routes: [RouteSpec],
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [CommandResult] {
        var results: [CommandResult] = []
        var previousFailure = false
        for (index, route) in routes.enumerated() {
            if previousFailure {
                results.append(CommandResult(
                    executable: "route",
                    arguments: [],
                    stdout: "",
                    stderr: "前一条路由失败，已停止批量操作",
                    exitCode: 1
                ))
                continue
            }
            let result = add(route)
            progress?(index + 1)
            results.append(result)
            previousFailure = !result.succeeded
        }
        return results
    }

    func removeBatch(
        _ routes: [RouteSpec],
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [CommandResult] {
        var results: [CommandResult] = []
        var previousFailure = false
        for (index, route) in routes.enumerated() {
            if previousFailure {
                results.append(CommandResult(
                    executable: "route",
                    arguments: [],
                    stdout: "",
                    stderr: "前一条路由失败，已停止批量操作",
                    exitCode: 1
                ))
                continue
            }
            let result = remove(route)
            progress?(index + 1)
            results.append(result)
            previousFailure = !result.succeeded
        }
        return results
    }
}

public final class RouteCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let backend: any RouteBackend
    private let logger: TailscaleRouteLogger?
    private let lockURL: URL?
    private var busy = false

    public init(
        backend: any RouteBackend = SystemRouteBackend(),
        logger: TailscaleRouteLogger? = nil,
        lockURL: URL? = nil
    ) {
        self.backend = backend
        self.logger = logger
        self.lockURL = lockURL
    }

    public func apply(
        targets: [String],
        snapshot: NetworkSnapshot,
        requireExitNode: Bool = true,
        previouslyManagedTargets: [String] = [],
        previouslyManagedRoutes: [RouteSpec] = [],
        allowEmptyTargets: Bool = false,
        purgeExternalRoutes: Bool = false,
        progress: (@Sendable (RouteProgress) -> Void)? = nil
    ) -> RouteOperationResult {
        withExclusiveAccess {
            RouteRebuilder(backend: backend, logger: logger).apply(
                targets: targets,
                snapshot: snapshot,
                requireExitNode: requireExitNode,
                previouslyManagedTargets: previouslyManagedTargets,
                previouslyManagedRoutes: previouslyManagedRoutes,
                allowEmptyTargets: allowEmptyTargets,
                purgeExternalRoutes: purgeExternalRoutes,
                progress: progress
            )
        }
    }

    public func preview(
        targets: [String],
        snapshot: NetworkSnapshot,
        requireExitNode: Bool = true,
        previouslyManagedRoutes: [RouteSpec] = [],
        allowEmptyTargets: Bool = false
    ) -> RoutePlanPreview {
        RouteRebuilder(backend: backend, logger: logger).preview(
            targets: targets,
            snapshot: snapshot,
            requireExitNode: requireExitNode,
            previouslyManagedRoutes: previouslyManagedRoutes,
            allowEmptyTargets: allowEmptyTargets
        )
    }

    public func pause(
        routes: [RouteSpec],
        progress: (@Sendable (RouteProgress) -> Void)? = nil
    ) -> RouteOperationResult {
        withExclusiveAccess {
            RouteRebuilder(backend: backend, logger: logger).pause(routes: routes, progress: progress)
        }
    }

    private func withExclusiveAccess(_ operation: () -> RouteOperationResult) -> RouteOperationResult {
        lock.lock()
        guard !busy else {
            lock.unlock()
            return RouteOperationResult(
                success: false,
                state: .applying,
                appliedCount: 0,
                removedCount: 0,
                failedCount: 0,
                lastError: "已有路由任务正在运行，请等待当前任务完成",
                warnings: [],
                verifiedTargets: []
            )
        }
        busy = true
        let fileDescriptor = acquireFileLock()
        guard lockURL == nil || fileDescriptor != nil else {
            busy = false
            lock.unlock()
            return RouteOperationResult(
                success: false,
                state: .applying,
                appliedCount: 0,
                removedCount: 0,
                failedCount: 0,
                lastError: "另一个 Helper 进程正在进行路由操作，请稍后重试",
                warnings: [],
                verifiedTargets: []
            )
        }
        lock.unlock()
        defer {
            releaseFileLock(fileDescriptor)
            lock.lock()
            busy = false
            lock.unlock()
        }
        return operation()
    }

    private func acquireFileLock() -> Int32? {
        guard let lockURL else { return nil }
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return nil
        }
        return descriptor
    }

    private func releaseFileLock(_ descriptor: Int32?) {
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

private struct RouteRebuilder: Sendable {
    let backend: any RouteBackend
    let logger: TailscaleRouteLogger?

    func preview(
        targets: [String],
        snapshot: NetworkSnapshot,
        requireExitNode: Bool,
        previouslyManagedRoutes: [RouteSpec],
        allowEmptyTargets: Bool
    ) -> RoutePlanPreview {
        var errors: [String] = []
        var warnings: [String] = []
        guard let gateway = snapshot.gateway, let interfaceName = snapshot.physicalInterface else {
            errors.append("没有可用的物理网关或接口")
            return RoutePlanPreview(
                networkFingerprint: snapshot.fingerprint, desiredRoutes: [], alreadyCorrect: [], additions: [],
                replacements: [], cleanup: [], unownedConflicts: [], errors: errors, warnings: warnings
            )
        }
        if isVirtual(interfaceName) { errors.append("拒绝使用虚拟接口 \(interfaceName) 作为本地网关") }
        if requireExitNode && snapshot.tailscaleExitNode == nil { errors.append("未确认 Tailscale Exit Node") }

        let endpointCIDRs = snapshot.tailscaleExitNodeEndpoint
            .flatMap { IPv4CIDR.parse("\($0)/32") }
            .map { [$0] } ?? []
        let normalizedTargets = normalizeTargets(targets, extraProtectedCIDRs: endpointCIDRs)
        if normalizedTargets.isEmpty && !allowEmptyTargets { errors.append("目标清单为空") }
        if normalizedTargets.count > 100_000 { errors.append("目标清单超过 100000 条") }

        let routeSnapshot = staticRouteTableSnapshot()
        guard routeSnapshot.succeeded else {
            errors.append("无法读取 IPv4 路由表：\(routeSnapshot.failureReason ?? "未知错误")")
            return RoutePlanPreview(
                networkFingerprint: snapshot.fingerprint, desiredRoutes: [], alreadyCorrect: [], additions: [],
                replacements: [], cleanup: [], unownedConflicts: [], errors: errors, warnings: warnings
            )
        }
        let routes = routeSnapshot.routes
        let actualRouteKeys = routeKeys(in: routes)
        let desiredRoutes = normalizedTargets.map { RouteSpec(cidr: $0, gateway: gateway, interfaceName: interfaceName) }
        let previous = previouslyManagedRoutes.filter {
            IPv4CIDR.canonical($0.cidr) != nil && IPv4CIDR.parseAddress($0.gateway) != nil && !$0.interfaceName.isEmpty
        }
        let previousKeys = Set(previous.map { routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName) })
        let desiredKeys = Set(desiredRoutes.map { routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName) })
        let actualPrevious = previous.filter {
            actualRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
        }
        var alreadyCorrect: [RouteSpec] = []
        var additions: [RouteSpec] = []
        var replacements: [RouteReplacementPlan] = []
        var conflicts: [RouteEntry] = []

        for desired in desiredRoutes {
            if actualRouteKeys.contains(routeKey(cidr: desired.cidr, gateway: desired.gateway, interfaceName: desired.interfaceName)) {
                alreadyCorrect.append(desired)
                continue
            }
            let ownedOldRoute = actualPrevious.first {
                IPv4CIDR.canonical($0.cidr) == desired.cidr
                    && routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName)
                        != routeKey(cidr: desired.cidr, gateway: desired.gateway, interfaceName: desired.interfaceName)
            }
            if let ownedOldRoute {
                replacements.append(RouteReplacementPlan(oldRoute: ownedOldRoute, newRoute: desired))
            } else {
                additions.append(desired)
            }
            conflicts.append(contentsOf: routes.filter { entry in
                IPv4CIDR.canonical(entry.destination) == desired.cidr
                    && !(entry.gateway == desired.gateway && entry.interfaceName == desired.interfaceName)
                    && !previousKeys.contains(routeKey(cidr: desired.cidr, gateway: entry.gateway, interfaceName: entry.interfaceName))
            })
        }
        let replacementOldKeys = Set(replacements.map {
            routeKey(cidr: $0.oldRoute.cidr, gateway: $0.oldRoute.gateway, interfaceName: $0.oldRoute.interfaceName)
        })
        let cleanup = actualPrevious.filter {
            !desiredKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
                && !replacementOldKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
        }.sorted {
            if $0.cidr != $1.cidr { return $0.cidr < $1.cidr }
            if $0.gateway != $1.gateway { return $0.gateway < $1.gateway }
            return $0.interfaceName < $1.interfaceName
        }
        let uniqueConflicts = conflicts.reduce(into: [RouteEntry]()) { unique, route in
            if !unique.contains(route) { unique.append(route) }
        }.sorted {
            if $0.destination != $1.destination { return $0.destination < $1.destination }
            if $0.gateway != $1.gateway { return $0.gateway < $1.gateway }
            return $0.interfaceName < $1.interfaceName
        }
        for conflict in uniqueConflicts {
            warnings.append("\(conflict.destination) 已有未纳入账本的冲突路由 via \(conflict.gateway) dev \(conflict.interfaceName)，预览不会建议删除它")
        }
        return RoutePlanPreview(
            networkFingerprint: snapshot.fingerprint,
            desiredRoutes: desiredRoutes,
            alreadyCorrect: alreadyCorrect,
            additions: additions,
            replacements: replacements,
            cleanup: cleanup,
            unownedConflicts: uniqueConflicts,
            errors: errors,
            warnings: warnings
        )
    }

    func apply(
        targets: [String],
        snapshot: NetworkSnapshot,
        requireExitNode: Bool,
        previouslyManagedTargets: [String],
        previouslyManagedRoutes: [RouteSpec],
        allowEmptyTargets: Bool,
        purgeExternalRoutes: Bool,
        progress: (@Sendable (RouteProgress) -> Void)?
    ) -> RouteOperationResult {
        guard let gateway = snapshot.gateway, let interfaceName = snapshot.physicalInterface else {
            return failure("没有可用的物理网关或接口", failedCount: 0)
        }
        guard !isVirtual(interfaceName) else {
            return failure("拒绝使用虚拟接口 \(interfaceName) 作为本地网关", failedCount: 0)
        }
        if requireExitNode && snapshot.tailscaleExitNode == nil {
            return failure("未确认 Tailscale Exit Node，已停止修改路由", failedCount: 0)
        }

        // The active Exit Node's public endpoint must never become a split
        // target; pinning (or at least leaving) it on the physical path is
        // what keeps the WireGuard tunnel itself from looping into utun.
        let endpointCIDRs = snapshot.tailscaleExitNodeEndpoint
            .flatMap { IPv4CIDR.parse("\($0)/32") }
            .map { [$0] } ?? []

        let normalizedTargets = normalizeTargets(targets, extraProtectedCIDRs: endpointCIDRs)
        guard !normalizedTargets.isEmpty || allowEmptyTargets else {
            return failure("目标清单为空，已停止修改路由", failedCount: 0)
        }
        guard normalizedTargets.count <= 100_000 else {
            return failure("目标清单超过 100000 条，已停止修改路由", failedCount: 0)
        }

        let currentSnapshot = staticRouteTableSnapshot()
        guard currentSnapshot.succeeded else {
            return failure("无法读取 IPv4 路由表，未开始应用：\(currentSnapshot.failureReason ?? "未知错误")", failedCount: 1)
        }
        let current = currentSnapshot.routes
        let currentRouteKeys = routeKeys(in: current)
        let desiredTargets = Set(normalizedTargets)
        let previousTargets = Set(normalizeTargets(previouslyManagedTargets))
        let previousRouteKeys = Set(previouslyManagedRoutes.compactMap { route -> String? in
            guard let destination = IPv4CIDR.canonical(route.cidr),
                  IPv4CIDR.parseAddress(route.gateway) != nil,
                  !route.interfaceName.isEmpty
            else { return nil }
            return routeKey(cidr: destination, gateway: route.gateway, interfaceName: route.interfaceName)
        })
        let endpointDestinations = Set(endpointCIDRs.map(\.description))
        let oldEntries = current.filter { entry in
            // Cloned host entries (flag W, e.g. created by Tailscale's
            // interface-bound WireGuard socket to the Exit Node endpoint) are
            // not static routes we own and cannot be deleted as such.
            guard !Self.isClonedRoute(entry) else { return false }
            guard let destination = IPv4CIDR.canonical(entry.destination) else { return false }
            // The Exit Node endpoint /32 is owned by ExitNodeEndpointProtector
            // (separate ledger). A stale split-route record for the same /32
            // must not make this transaction delete or fight over that pin.
            guard !endpointDestinations.contains(destination) else { return false }
            let isDesired = desiredTargets.contains(destination)
            let isCorrect = isDesired
                && entry.gateway == gateway
                && entry.interfaceName == interfaceName
            let wasPreviouslyManaged = previousRouteKeys.contains(
                routeKey(cidr: destination, gateway: entry.gateway, interfaceName: entry.interfaceName)
            ) || (
                previousTargets.contains(destination)
                    && entry.gateway == gateway
                    && entry.interfaceName == interfaceName
            )
            let overlapsProtectedRange = (IPv4CIDR.protectedRouteCIDRs + endpointCIDRs).contains { protected in
                guard let routeCIDR = IPv4CIDR.parse(destination) else { return false }
                return protected.overlaps(routeCIDR)
            }
            return (wasPreviouslyManaged && (!isDesired || !isCorrect))
                || (purgeExternalRoutes
                    && !isDesired
                    && !overlapsProtectedRange
                    && isExternalDirectRoute(entry, snapshot: snapshot))
        }
        let oldSpecs = Array(Set(oldEntries.compactMap(routeSpec(from:))))
        let ownedOldSpecs = oldSpecs.filter { spec in
            let key = routeKey(cidr: spec.cidr, gateway: spec.gateway, interfaceName: spec.interfaceName)
            return previousRouteKeys.contains(key)
                || (previousTargets.contains(spec.cidr) && spec.gateway == gateway && spec.interfaceName == interfaceName)
        }
        let currentCorrectTargets = Set(current.compactMap { entry -> String? in
            guard let destination = IPv4CIDR.canonical(entry.destination),
                  desiredTargets.contains(destination),
                  entry.gateway == gateway,
                  entry.interfaceName == interfaceName
            else { return nil }
            return destination
        })
        let newSpecs = normalizedTargets
            .filter { !currentCorrectTargets.contains($0) }
            .map { RouteSpec(cidr: $0, gateway: gateway, interfaceName: interfaceName) }

        // A gateway change can have the same destination as the previous
        // owned route. Darwin cannot safely add a second unscoped route for
        // that key, so change that exact owned route atomically after staging
        // all non-colliding additions. No unowned route is eligible here.
        let ownedOldByDestination = Dictionary(grouping: ownedOldSpecs) {
            IPv4CIDR.canonical($0.cidr) ?? $0.cidr
        }
        let replacements: [(old: RouteSpec, new: RouteSpec)] = newSpecs.compactMap { newRoute in
            guard let oldRoute = ownedOldByDestination[newRoute.cidr]?.first(where: {
                routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName)
                    != routeKey(cidr: newRoute.cidr, gateway: newRoute.gateway, interfaceName: newRoute.interfaceName)
            }) else { return nil }
            return (oldRoute, newRoute)
        }
        let replacementNewKeys = Set(replacements.map { routeKey(cidr: $0.new.cidr, gateway: $0.new.gateway, interfaceName: $0.new.interfaceName) })
        let addSpecs = newSpecs.filter {
            !replacementNewKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
        }
        let changedOldKeys = Set(replacements.map {
            routeKey(cidr: $0.old.cidr, gateway: $0.old.gateway, interfaceName: $0.old.interfaceName)
        })
        let cleanupSpecs = oldSpecs.filter {
            !changedOldKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
        }

        var removed = 0
        var applied = 0
        var completed = 0
        var confirmedAddRoutes: [RouteSpec] = []
        var changedRoutes: [RouteSpec] = []
        let total = addSpecs.count + replacements.count + cleanupSpecs.count + 3
        let updateProgress: @Sendable (Int, String) -> Void = { completed, message in
            guard completed == 0 || completed == total || completed % 250 == 0 else { return }
            progress?(RouteProgress(completed: completed, total: total, message: message))
        }
        updateProgress(0, "读取事务快照")
        logger?.info("开始分阶段更新：先新增 IPv4 \(addSpecs.count) 条、原子切换 \(replacements.count) 条，验证后清理旧路由 \(cleanupSpecs.count) 条")

        let addResults = backend.addBatch(addSpecs) { batchCompleted in
            updateProgress(batchCompleted, "新增路由 \(batchCompleted) / \(addSpecs.count)")
        }
        for (index, result) in addResults.enumerated() {
            if result.succeeded {
                confirmedAddRoutes.append(addSpecs[index])
                applied += 1
                continue
            }
            completed += index + 1
            let observedSnapshot = staticRouteTableSnapshot()
            let observed = observedSnapshot.succeeded ? observedSnapshot.routes : current
            let retained = managedRouteSnapshot(
                observed,
                desiredTargets: desiredTargets,
                gateway: gateway,
                interfaceName: interfaceName,
                previousRouteKeys: previousRouteKeys
            )
            let observedRouteKeys = routeKeys(in: observed)
            let pending = ownedOldSpecs.filter {
                observedRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
            }
            let message = "新增 \(addSpecs[index].cidr) 失败：\(result.failureReason)；已保留已验证路由和旧账本"
            logger?.error(message)
            let createdByThisTransaction = Array(addSpecs.prefix(applied))
            let ownedAfterFailure = Array(Set(retained + createdByThisTransaction))
            return transactionFailure(message, failedCount: addSpecs.count - index, applied: applied, removed: removed, managed: ownedAfterFailure, pending: pending)
        }
        completed += addResults.count

        if !replacements.isEmpty {
            let beforeChangeSnapshot = staticRouteTableSnapshot()
            guard beforeChangeSnapshot.succeeded else {
                let retained = managedRouteSnapshot(current, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
                let pending = ownedOldSpecs.filter {
                    currentRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
                }
                let possibleManaged = Array(Set(retained + confirmedAddRoutes))
                return transactionFailure("无法读取路由表，停止原子切换：\(beforeChangeSnapshot.failureReason ?? "未知错误")", failedCount: 1, applied: applied, removed: removed, managed: possibleManaged, pending: pending)
            }
            let beforeChange = beforeChangeSnapshot.routes
            let beforeChangeKeys = Set(beforeChange.compactMap { routeSpec(from: $0) }.map {
                routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName)
            })
            if let missing = replacements.first(where: { replacement in
                !beforeChangeKeys.contains(routeKey(
                    cidr: replacement.old.cidr,
                    gateway: replacement.old.gateway,
                    interfaceName: replacement.old.interfaceName
                ))
            }) {
                let retained = managedRouteSnapshot(beforeChange, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
                let pending = ownedOldSpecs.filter {
                    beforeChangeKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
                }
                return transactionFailure("受管旧路由 \(missing.old.cidr) 在切换前已变化；保留现状并停止本次事务", failedCount: 1, applied: applied, removed: removed, managed: retained, pending: pending)
            }

            // The preflight snapshot proves every replacement's exact ledger
            // triple immediately before the batch. Read back once after the
            // batch instead of launching a full netstat scan per route.
            let changeStart = completed
            let changeResults = backend.changeBatch(replacements.map {
                RouteReplacementPlan(oldRoute: $0.old, newRoute: $0.new)
            }) { batchCompleted in
                updateProgress(changeStart + batchCompleted, "原子切换网关 \(batchCompleted) / \(replacements.count)")
            }
            for (index, changeResult) in changeResults.enumerated() {
                let replacement = replacements[index]
                guard changeResult.succeeded else {
                    let observedSnapshot = staticRouteTableSnapshot()
                    let observed = observedSnapshot.succeeded ? observedSnapshot.routes : current
                    let retained = managedRouteSnapshot(observed, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
                    let observedRouteKeys = observedSnapshot.succeeded ? routeKeys(in: observed) : currentRouteKeys
                    let pending = observedSnapshot.succeeded
                        ? ownedOldSpecs.filter {
                            observedRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
                        }
                        : ownedOldSpecs
                    let message = "原子切换 \(replacement.old.cidr) 失败：\(changeResult.failureReason)"
                    let uncertainRoutes = observedSnapshot.succeeded ? [] : [replacement.old, replacement.new]
                    let possibleManaged = Array(Set(retained + confirmedAddRoutes + changedRoutes + uncertainRoutes))
                    return transactionFailure(message, failedCount: 1, applied: applied, removed: removed, managed: possibleManaged, pending: pending)
                }
                changedRoutes.append(replacement.new)
                applied += 1
                completed += 1
            }
        }

        let verifiedSnapshot = staticRouteTableSnapshot()
        guard verifiedSnapshot.succeeded else {
            let retained = managedRouteSnapshot(current, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
                let pending = ownedOldSpecs.filter {
                    currentRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
                }
            let possibleManaged = Array(Set(retained + confirmedAddRoutes + changedRoutes))
            return transactionFailure("新增/切换后无法读取验证快照：\(verifiedSnapshot.failureReason ?? "未知错误")", failedCount: 1, applied: applied, removed: removed, managed: possibleManaged, pending: pending)
        }
        let verifiedRoutes = verifiedSnapshot.routes
        let verifiedRouteKeys = routeKeys(in: verifiedRoutes)
        let verifiedTargets = exactDesiredTargets(verifiedRoutes, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName)
        if let missingTarget = normalizedTargets.first(where: { !verifiedTargets.contains($0) }) {
            let probe = IPv4CIDR.parse(missingTarget).map { cidr in
                IPv4CIDR.string(from: cidr.prefixLength == 32 ? cidr.network : cidr.network + 1)
            }
            let routeLookup = probe.flatMap { backend.lookup(address: $0) }
            let sameDestination = verifiedRoutes.filter { IPv4CIDR.canonical($0.destination) == missingTarget }.map(\.rawLine).joined(separator: " | ")
            logger?.error("验证诊断：读回 IPv4 路由 \(verifiedRoutes.count) 条；目标 \(missingTarget)，预期网关 \(gateway)/\(interfaceName)；route-get=\(routeLookup?.rawLine ?? "无")；同目标=\(sameDestination.isEmpty ? "无" : sameDestination)")
            let retained = managedRouteSnapshot(verifiedRoutes, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
            let pending = ownedOldSpecs.filter {
                verifiedRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
            }
            return transactionFailure("验证路由失败：\(missingTarget) 没有指向当前物理网关；未清理任何旧路由", failedCount: 1, applied: applied, removed: removed, managed: retained, pending: pending)
        }

        let samples = sampleTargets(normalizedTargets)
        var verified: [String] = []
        for target in samples {
            guard hasInstalledRoute(routes: verifiedRoutes, target: target, gateway: gateway, interfaceName: interfaceName) else {
                let retained = managedRouteSnapshot(verifiedRoutes, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
                let pending = ownedOldSpecs.filter {
                    verifiedRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
                }
                return transactionFailure("验证路由失败：\(target) 没有指向当前物理网关；未清理任何旧路由", failedCount: 1, applied: applied, removed: removed, managed: retained, pending: pending)
            }
            verified.append(target)
        }

        let foreignProbe = foreignProbeAddress(excluding: normalizedTargets)
        guard let tailscaleInterface = snapshot.tailscaleInterface,
              let foreignProbe,
              let foreignRoute = backend.lookup(address: foreignProbe),
              foreignRoute.interfaceName == tailscaleInterface || foreignRoute.interfaceName.hasPrefix("utun")
        else {
            let retained = managedRouteSnapshot(verifiedRoutes, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
            let pending = ownedOldSpecs.filter {
                verifiedRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
            }
            return transactionFailure("验证国外目标失败：没有目标经 Tailscale 接口转发；未清理任何旧路由", failedCount: 1, applied: applied, removed: removed, managed: retained, pending: pending)
        }
        verified.append("foreign:\(foreignProbe)")

        let cleanupProgressOffset = completed
        let cleanupResults = backend.removeBatch(cleanupSpecs) { batchCompleted in
            updateProgress(cleanupProgressOffset + batchCompleted, "清理旧路由 \(batchCompleted) / \(cleanupSpecs.count)")
        }
        for (index, result) in cleanupResults.enumerated() where result.succeeded {
            removed += 1
            completed += 1
            _ = index
        }
        let cleanupFailure = cleanupResults.enumerated().first { !$0.element.succeeded }
        let finalSnapshot = staticRouteTableSnapshot()
        if !finalSnapshot.succeeded {
            let retained = managedRouteSnapshot(verifiedRoutes, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
            let pending = ownedOldSpecs
            return transactionFailure("清理后无法验证路由表：\(finalSnapshot.failureReason ?? "未知错误")", failedCount: 1, applied: applied, removed: removed, managed: retained, pending: pending)
        }
        let finalRoutes = finalSnapshot.routes
        let finalRouteKeys = routeKeys(in: finalRoutes)
        let stillPending = ownedOldSpecs.filter {
            finalRouteKeys.contains(routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName))
        }
        if let cleanupFailure {
            let route = cleanupSpecs[cleanupFailure.offset]
            let retained = managedRouteSnapshot(finalRoutes, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
            let message = "清理旧路由 \(route.cidr) 失败：\(cleanupFailure.element.failureReason)；已保留新路由及仍存在的受管旧路由"
            return transactionFailure(message, failedCount: 1, applied: applied, removed: removed, managed: retained, pending: stillPending)
        }

        let finalTargets = exactDesiredTargets(finalRoutes, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName)
        if let missingTarget = normalizedTargets.first(where: { !finalTargets.contains($0) }) {
            let retained = managedRouteSnapshot(finalRoutes, desiredTargets: desiredTargets, gateway: gateway, interfaceName: interfaceName, previousRouteKeys: previousRouteKeys)
            return transactionFailure("清理后受管目标 \(missingTarget) 缺失；保留当前账本等待重试", failedCount: 1, applied: applied, removed: removed, managed: retained, pending: stillPending)
        }

        updateProgress(total, "路由事务完成")
        logger?.info("路由重建成功：应用/切换 IPv4 \(applied) 条、清理 \(removed) 条")
        return RouteOperationResult(
            success: true,
            state: .enabled,
            appliedCount: applied,
            removedCount: removed,
            failedCount: 0,
            lastError: nil,
            warnings: [],
            verifiedTargets: verified,
            managedRoutes: normalizedTargets.map { RouteSpec(cidr: $0, gateway: gateway, interfaceName: interfaceName) },
            pendingRemovals: []
        )
    }

    func pause(
        routes: [RouteSpec],
        progress: (@Sendable (RouteProgress) -> Void)?
    ) -> RouteOperationResult {
        // Old state files may contain IPv6 route JSON. Invalid IPv6 CIDRs are
        // ignored here, so stop can never touch the IPv6 route table.
        var requested = Set<String>()
        for route in routes {
            guard let cidr = IPv4CIDR.canonical(route.cidr),
                  IPv4CIDR.parseAddress(route.gateway) != nil,
                  !route.interfaceName.isEmpty
            else { continue }
            requested.insert(routeKey(cidr: cidr, gateway: route.gateway, interfaceName: route.interfaceName))
        }

        let current = backend.currentRoutes().compactMap { entry -> RouteSpec? in
            guard !Self.isClonedRoute(entry),
                  let cidr = IPv4CIDR.canonical(entry.destination),
                  IPv4CIDR.parseAddress(entry.gateway) != nil,
                  requested.contains(routeKey(cidr: cidr, gateway: entry.gateway, interfaceName: entry.interfaceName))
            else { return nil }
            return RouteSpec(cidr: cidr, gateway: entry.gateway, interfaceName: entry.interfaceName)
        }

        // The exact ownership check above remains per route, but the actual
        // deletes share one PF_ROUTE socket. This avoids spawning one
        // `/sbin/route` process for every CIDR while retaining gateway-scoped
        // deletion for each matched route.
        let removalResults = backend.removeBatch(current) { completed in
            progress?(RouteProgress(completed: completed, total: current.count, message: "暂停：删除 \(completed) / \(current.count)"))
        }
        for (index, result) in removalResults.enumerated() {
            guard result.succeeded else {
                return failure("暂停时删除 \(current[index].cidr) 失败：\(result.failureReason)", failedCount: 1)
            }
        }
        let removed = removalResults.count

        let remaining = backend.currentRoutes().filter { entry in
            guard !Self.isClonedRoute(entry),
                  let cidr = IPv4CIDR.canonical(entry.destination)
            else { return false }
            return requested.contains(routeKey(cidr: cidr, gateway: entry.gateway, interfaceName: entry.interfaceName))
        }
        guard remaining.isEmpty else {
            return failure("暂停后仍有 \(remaining.count) 条受管理路由存在：\(remaining.map(\.destination).joined(separator: ", "))", failedCount: remaining.count)
        }
        logger?.info("暂停分流成功：删除 \(removed) 条受管理 IPv4 路由")
        return RouteOperationResult(
            success: true,
            state: .paused,
            appliedCount: 0,
            removedCount: removed,
            failedCount: 0,
            lastError: nil,
            warnings: [],
            verifiedTargets: []
        )
    }

    private func transactionFailure(
        _ message: String,
        failedCount: Int,
        applied: Int,
        removed: Int,
        managed: [RouteSpec],
        pending: [RouteSpec]
    ) -> RouteOperationResult {
        logger?.error(message)
        return RouteOperationResult(
            success: false,
            state: managed.isEmpty ? .error : .partial,
            appliedCount: applied,
            removedCount: removed,
            failedCount: failedCount,
            lastError: message,
            warnings: pending.isEmpty ? [] : ["仍有 \(pending.count) 条账本路由待清理"],
            verifiedTargets: [],
            managedRoutes: managed,
            pendingRemovals: pending
        )
    }

    /// Kernel-cloned entries (netstat flag W) mirror a destination we may
    /// own, but are not the static route itself.
    static func isClonedRoute(_ entry: RouteEntry) -> Bool {
        entry.flags.contains("W")
    }

    /// Route table without kernel-cloned entries. A clone (for example the
    /// scoped host entry Tailscale's interface-bound WireGuard socket creates
    /// for the Exit Node endpoint) can share destination, gateway and
    /// interface with a static route we own, but it is neither deletable as
    /// that route nor proof that the static route is installed.
    private func staticRouteTableSnapshot() -> RouteTableSnapshot {
        let snapshot = backend.routeTableSnapshot()
        return RouteTableSnapshot(
            routes: snapshot.routes.filter { !Self.isClonedRoute($0) },
            succeeded: snapshot.succeeded,
            failureReason: snapshot.failureReason
        )
    }

    private func routeKeys(in routes: [RouteEntry]) -> Set<String> {
        Set(routes.compactMap { routeSpec(from: $0) }.map {
            routeKey(cidr: $0.cidr, gateway: $0.gateway, interfaceName: $0.interfaceName)
        })
    }

    private func exactDesiredTargets(
        _ routes: [RouteEntry],
        desiredTargets: Set<String>,
        gateway: String,
        interfaceName: String
    ) -> Set<String> {
        Set(routes.compactMap { entry -> String? in
            guard let destination = IPv4CIDR.canonical(entry.destination),
                  desiredTargets.contains(destination),
                  entry.gateway == gateway,
                  entry.interfaceName == interfaceName
            else { return nil }
            return destination
        })
    }

    private func managedRouteSnapshot(
        _ routes: [RouteEntry],
        desiredTargets: Set<String>,
        gateway: String,
        interfaceName: String,
        previousRouteKeys: Set<String>
    ) -> [RouteSpec] {
        let desiredKeys = Set(desiredTargets.map { routeKey(cidr: $0, gateway: gateway, interfaceName: interfaceName) })
        let ownedKeys = previousRouteKeys.union(desiredKeys)
        return Array(Set(routes.compactMap { entry -> RouteSpec? in
            guard let spec = routeSpec(from: entry) else { return nil }
            return ownedKeys.contains(routeKey(cidr: spec.cidr, gateway: spec.gateway, interfaceName: spec.interfaceName)) ? spec : nil
        })).sorted {
            if $0.cidr != $1.cidr { return $0.cidr < $1.cidr }
            if $0.gateway != $1.gateway { return $0.gateway < $1.gateway }
            return $0.interfaceName < $1.interfaceName
        }
    }

    private func normalizeTargets(_ targets: [String], extraProtectedCIDRs: [IPv4CIDR] = []) -> [String] {
        var normalized = Set<IPv4CIDR>()
        for target in targets {
            guard let cidr = IPv4CIDR.parse(target) else { continue }
            normalized.formUnion(cidr.subtracting(IPv4CIDR.protectedRouteCIDRs + extraProtectedCIDRs))
        }
        return normalized
            .sorted {
                if $0.network == $1.network { return $0.prefixLength < $1.prefixLength }
                return $0.network < $1.network
            }
            .map(\.description)
    }

    private func routeSpec(from entry: RouteEntry) -> RouteSpec? {
        guard let cidr = IPv4CIDR.canonical(entry.destination),
              IPv4CIDR.parseAddress(entry.gateway) != nil,
              !entry.interfaceName.isEmpty
        else { return nil }
        return RouteSpec(cidr: cidr, gateway: entry.gateway, interfaceName: entry.interfaceName)
    }

    private func routeKey(cidr: String, gateway: String, interfaceName: String) -> String {
        "\(cidr)|\(gateway)|\(interfaceName)"
    }

    private func hasInstalledRoute(
        routes: [RouteEntry],
        target: String,
        gateway: String,
        interfaceName: String
    ) -> Bool {
        routes.contains {
            IPv4CIDR.canonical($0.destination) == target
                && $0.gateway == gateway
                && $0.interfaceName == interfaceName
        }
    }

    private func sampleTargets(_ targets: [String]) -> [String] {
        guard targets.count > 2 else { return targets }
        return [targets[0], targets[targets.count / 2], targets[targets.count - 1]]
    }

    private func foreignProbeAddress(excluding targets: [String]) -> String? {
        let candidates = ["8.8.8.8", "9.9.9.9", "1.1.1.1"]
        let targetRanges = targets.compactMap { IPv4CIDR.parse($0) }
        return candidates.first { candidate in
            guard let address = IPv4CIDR.parseAddress(candidate) else { return false }
            let host = IPv4CIDR(network: address, prefixLength: 32)
            return !targetRanges.contains { $0.contains(host) }
        }
    }

    private func isExternalDirectRoute(_ entry: RouteEntry, snapshot: NetworkSnapshot) -> Bool {
        entry.destination != "default"
            && entry.flags.contains("G")
            && entry.interfaceName == snapshot.physicalInterface
            && entry.gateway == snapshot.gateway
    }

    private func isVirtual(_ interfaceName: String) -> Bool {
        interfaceName == "lo"
            || interfaceName.hasPrefix("utun")
            || interfaceName.hasPrefix("bridge")
            || interfaceName.hasPrefix("awdl")
            || interfaceName.hasPrefix("llw")
            || interfaceName.hasPrefix("tap")
            || interfaceName.hasPrefix("tun")
    }

    private func failure(_ message: String, failedCount: Int) -> RouteOperationResult {
        logger?.error(message)
        return RouteOperationResult(
            success: false,
            state: .error,
            appliedCount: 0,
            removedCount: 0,
            failedCount: failedCount,
            lastError: message,
            warnings: [],
            verifiedTargets: []
        )
    }
}

public final class InMemoryRouteBackend: RouteBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [RouteEntry]
    private var routeIndexByKey: [String: Int]
    public var failOnAddTarget: String?
    public var failOnChangeTarget: String?
    public var failOnRemoveTarget: String?
    public var routeTableReadFailureReason: String?

    public init(routes: [RouteEntry] = []) {
        self.routes = routes
        self.routeIndexByKey = Dictionary(routes.enumerated().compactMap { index, entry in
            guard let route = Self.routeSpec(from: entry) else { return nil }
            return (Self.routeKey(route), index)
        }, uniquingKeysWith: { _, latest in latest })
    }

    public func currentRoutes() -> [RouteEntry] {
        lock.lock()
        defer { lock.unlock() }
        return routes.filter { $0.destination == "default" || IPv4CIDR.parse($0.destination) != nil }
    }

    public func routeTableSnapshot() -> RouteTableSnapshot {
        if let routeTableReadFailureReason {
            return RouteTableSnapshot(routes: [], succeeded: false, failureReason: routeTableReadFailureReason)
        }
        return RouteTableSnapshot(routes: currentRoutes(), succeeded: true)
    }

    public func add(_ route: RouteSpec) -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        guard IPv4CIDR.parse(route.cidr) != nil,
              IPv4CIDR.parseAddress(route.gateway) != nil
        else {
            return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "invalid IPv4 route", exitCode: 1)
        }
        if failOnAddTarget == route.cidr {
            return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "simulated add failure", exitCode: 1)
        }
        let routeKey = Self.routeKey(route)
        if routeIndexByKey[routeKey] != nil {
            return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "route already exists", exitCode: 1)
        }
        routeIndexByKey[routeKey] = routes.count
        routes.append(RouteEntry(
            destination: IPv4CIDR.canonical(route.cidr) ?? route.cidr,
            gateway: route.gateway,
            flags: "UGSc",
            interfaceName: route.interfaceName,
            rawLine: "\(route.cidr) \(route.gateway) UGSc \(route.interfaceName)"
        ))
        return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "", exitCode: 0)
    }

    public func change(_ oldRoute: RouteSpec, to newRoute: RouteSpec) -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        if failOnChangeTarget == newRoute.cidr {
            return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "simulated change failure", exitCode: 1)
        }
        let oldKey = Self.routeKey(oldRoute)
        let newKey = Self.routeKey(newRoute)
        guard IPv4CIDR.canonical(oldRoute.cidr) == IPv4CIDR.canonical(newRoute.cidr),
              let index = routeIndexByKey[oldKey],
              index < routes.count,
              routeIndexByKey[newKey] == nil || newKey == oldKey
        else {
            return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "owned route changed before transaction", exitCode: 1)
        }
        routeIndexByKey.removeValue(forKey: oldKey)
        routeIndexByKey[newKey] = index
        routes[index] = RouteEntry(
            destination: IPv4CIDR.canonical(newRoute.cidr) ?? newRoute.cidr,
            gateway: newRoute.gateway,
            flags: "UGSc",
            interfaceName: newRoute.interfaceName,
            rawLine: "\(newRoute.cidr) \(newRoute.gateway) UGSc \(newRoute.interfaceName)"
        )
        return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "", exitCode: 0)
    }

    public func remove(_ route: RouteSpec) -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        if failOnRemoveTarget == route.cidr {
            return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "simulated remove failure", exitCode: 1)
        }
        let key = Self.routeKey(route)
        guard routeIndexByKey[key] != nil else {
            return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "", exitCode: 0)
        }
        routes.removeAll {
            IPv4CIDR.canonical($0.destination) == IPv4CIDR.canonical(route.cidr)
                && $0.gateway == route.gateway
                && $0.interfaceName == route.interfaceName
        }
        rebuildRouteIndex()
        return CommandResult(executable: "route", arguments: [], stdout: "", stderr: "", exitCode: 0)
    }

    public func lookup(address: String) -> RouteEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let ip = IPv4CIDR.parseAddress(address) else { return nil }
        return routes
            .compactMap { entry -> (RouteEntry, IPv4CIDR)? in
                guard let cidr = IPv4CIDR.parse(entry.destination), cidr.network <= ip, cidr.lastAddress >= ip else { return nil }
                return (entry, cidr)
            }
            .sorted { $0.1.prefixLength > $1.1.prefixLength }
            .first?.0
    }

    private func rebuildRouteIndex() {
        routeIndexByKey = Dictionary(routes.enumerated().compactMap { index, entry in
            guard let route = Self.routeSpec(from: entry) else { return nil }
            return (Self.routeKey(route), index)
        }, uniquingKeysWith: { _, latest in latest })
    }

    private static func routeSpec(from entry: RouteEntry) -> RouteSpec? {
        guard let cidr = IPv4CIDR.canonical(entry.destination),
              IPv4CIDR.parseAddress(entry.gateway) != nil,
              !entry.interfaceName.isEmpty
        else { return nil }
        return RouteSpec(cidr: cidr, gateway: entry.gateway, interfaceName: entry.interfaceName)
    }

    private static func routeKey(_ route: RouteSpec) -> String {
        "\(IPv4CIDR.canonical(route.cidr) ?? route.cidr)|\(route.gateway)|\(route.interfaceName)"
    }
}

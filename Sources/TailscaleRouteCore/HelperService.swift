import CryptoKit
import Foundation

public final class HelperService: @unchecked Sendable {
    private let paths: TailscaleRoutePaths
    private let hostsPath: String
    private let store: AtomicStore
    private let runner: any CommandRunning
    private let inspector: NetworkInspector
    private let logger: TailscaleRouteLogger
    private let coordinator: RouteCoordinator
    private let ipv6RouteManager: IPv6DomainRouteManager
    private let externalNetworkDetector: ExternalDirectNetworkDetector
    private let exitNodeEndpointProtector: ExitNodeEndpointProtector
    private let dnsServerRouteProtector: DNSServerRouteProtector
    private let externalNetworkRouteProtector: ExternalNetworkRouteProtector
    /// 断网保护. Only the real Helper process starts its periodic check.
    public let killSwitch: KillSwitchController
    private let stateOverrideLock = NSLock()
    private var unsavedStateOverride: PersistedRouteState?

    private var externalSnapshotKeyURL: URL {
        paths.root.appendingPathComponent("external-network-snapshot.json")
    }

    public convenience init(
        paths: TailscaleRoutePaths = .system,
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.init(
            paths: paths,
            runner: runner,
            routeBackend: SystemRouteBackend(runner: runner),
            hostsPath: "/etc/hosts"
        )
    }

    init(
        paths: TailscaleRoutePaths,
        runner: any CommandRunning,
        routeBackend: any RouteBackend,
        hostsPath: String = "/etc/hosts"
    ) {
        self.paths = paths
        self.hostsPath = hostsPath
        self.store = AtomicStore(paths: paths)
        self.runner = runner
        self.inspector = NetworkInspector(runner: runner)
        self.logger = TailscaleRouteLogger(paths: paths)
        self.coordinator = RouteCoordinator(
            backend: routeBackend,
            logger: TailscaleRouteLogger(paths: paths),
            lockURL: paths.lock
        )
        self.ipv6RouteManager = IPv6DomainRouteManager(runner: runner)
        self.externalNetworkDetector = ExternalDirectNetworkDetector(runner: runner)
        self.exitNodeEndpointProtector = ExitNodeEndpointProtector(runner: runner)
        self.dnsServerRouteProtector = DNSServerRouteProtector(runner: runner)
        self.externalNetworkRouteProtector = ExternalNetworkRouteProtector(runner: runner)
        self.killSwitch = KillSwitchController(
            paths: paths,
            runner: runner,
            inspector: NetworkInspector(runner: runner),
            logger: TailscaleRouteLogger(paths: paths),
            runtimeURL: paths.root.standardizedFileURL.path == TailscaleRoutePaths.system.root.standardizedFileURL.path
                ? URL(fileURLWithPath: "/var/run/tailscale-route-killswitch.json")
                : paths.root.appendingPathComponent("kill-switch-runtime.json")
        )
    }

    public func handle(
        _ request: HelperRequest,
        progress: (@Sendable (RouteProgress) -> Void)? = nil
    ) -> HelperResponse {
        do {
            // Status is deliberately a read-only diagnostic request. State
            // migration and generated-file cleanup can rewrite/delete files,
            // so they belong to mutating/reconcile requests only.
            if request.action == .status {
                return statusResponse(requestID: request.requestID)
            }
            // Kill-switch actions are independent of route state and must stay
            // fast and available even while the network is blocked.
            if let response = killSwitchResponse(request) {
                return response
            }
            try store.prepareDirectories()
            try store.migrateStateIfNeeded()
            try store.removeObsoleteGeneratedFiles()
            switch request.action {
            case .status:
                return statusResponse(requestID: request.requestID)
            case .reconcileExternalProtection:
                return reconcileExternalProtection(request, progress: progress)
            case .preview:
                return preview(request)
            case .updateList:
                return updateList(request, progress: progress)
            case .domainRefresh:
                return refreshDomains(request)
            case .enable, .reapply:
                return apply(request, progress: progress)
            case .pause:
                return pause(request, progress: progress)
            case .shutdown:
                // App quit / recovery script / uninstall: lift any network
                // block first so cleanup and the user regain connectivity.
                _ = killSwitch.release(reason: "退出或恢复网络时已解除断网保护")
                return pause(
                    request,
                    progress: progress,
                    restoreTailscalePreferences: true,
                    releaseExternalGatewayRoutes: true
                )
            case .restoreDefault:
                return restoreDefault(request)
            case .killSwitchStatus, .enableKillSwitch, .disableKillSwitch, .releaseKillSwitch:
                return killSwitchResponse(request) ?? statusResponse(requestID: request.requestID)
            }
        } catch {
            logger.error("请求 \(request.action.rawValue) 失败：\(error.localizedDescription)")
            return HelperResponse(
                requestID: request.requestID,
                success: false,
                message: error.localizedDescription,
                state: loadState(),
                layeredStatus: LayeredOperationStatus(
                    route: request.action == .reconcileExternalProtection || request.action == .updateList ? .notEvaluated : .failed,
                    externalProtection: request.action == .reconcileExternalProtection ? .failed : .notEvaluated,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }
    }

    private func statusResponse(requestID: UUID) -> HelperResponse {
        let report = diagnosticReport()
        let routeStatus: LayerStatus = report.errors.isEmpty ? .ok : .failed
        let externalStatus: LayerStatus
        if let active = report.externalSubnetProtectionActive {
            externalStatus = active ? .ok : .failed
        } else {
            externalStatus = .notEvaluated
        }
        return HelperResponse(
            requestID: requestID,
            success: report.errors.isEmpty,
            message: report.errors.first ?? "状态读取完成",
            report: report,
            state: loadState(),
            targetList: loadTargetList(),
            layeredStatus: LayeredOperationStatus(
                route: routeStatus,
                externalProtection: externalStatus,
                domainResolution: .notEvaluated,
                overall: routeStatus == .failed ? .failed : .ok
            )
        )
    }

    private func reconcileExternalProtection(
        _ request: HelperRequest,
        progress: (@Sendable (RouteProgress) -> Void)?
    ) -> HelperResponse {
        progress?(RouteProgress(completed: 0, total: 100, message: "检查外接网卡与当前保护状态"))
        let detection = externalNetworkDetector.scan()
        let initialReport = diagnosticReport()
        var state = loadState()
        let protection: ExternalProtectionStatus
        let shouldReconcile = shouldReconcileExternalProtection(for: detection)
        if shouldReconcile {
            state = reconcileDetectedRoutes(report: initialReport)
            progress?(RouteProgress(completed: 30, total: 100, message: "对账外接网段路由与 Tailscale 偏好"))
            protection = reconcileExternalSubnetProtection(state: &state, detection: detection)
            persistExternalSnapshotKeyIfSuccessful(detection: detection, protection: protection)
        } else {
            progress?(RouteProgress(completed: 100, total: 100, message: "外接网卡快照未变化，跳过写入"))
            protection = retainedExternalProtectionStatus(detection: detection, state: state)
        }
        let report = diagnosticReport(protection: protection)
        if !shouldReconcile {
            progress?(RouteProgress(completed: 100, total: 100, message: "外接网卡保护状态已读取"))
        } else {
            progress?(RouteProgress(completed: 100, total: 100, message: "外接网卡保护对账完成"))
        }
        let success = report.errors.isEmpty
            && protection.warnings.isEmpty
            && protection.active != false
        return HelperResponse(
            requestID: request.requestID,
            success: success,
            message: protection.warnings.first ?? report.errors.first ?? protection.message,
            report: report,
            state: state,
            targetList: loadTargetList(),
            layeredStatus: LayeredOperationStatus(
                route: .notEvaluated,
                externalProtection: protection.active == true ? .ok : protection.active == false ? .failed : (protection.warnings.isEmpty ? .ok : .degraded),
                domainResolution: .notEvaluated,
                overall: protection.warnings.isEmpty && protection.active != false ? .ok : .failed
            )
        )
    }

    private func updateList(
        _ request: HelperRequest,
        progress: (@Sendable (RouteProgress) -> Void)?
    ) -> HelperResponse {
        let configuration = request.configuration ?? store.loadConfiguration()
        // Updating the China list is a standalone manual transaction. Do not
        // make this button perform temporary-domain DNS work as a side effect.
        var listConfiguration = configuration
        listConfiguration.domainNames = []
        progress?(RouteProgress(completed: 0, total: 100, message: "保存清单配置"))
        do {
            try store.saveConfiguration(configuration)
        } catch {
            return failedResponse(
                requestID: request.requestID,
                message: "保存配置失败：\(error.localizedDescription)",
                layeredStatus: LayeredOperationStatus(
                    route: .notEvaluated,
                    externalProtection: .notEvaluated,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }
        do {
            progress?(RouteProgress(completed: 12, total: 100, message: "检查当前网络与 Exit Node 端点"))
            // Discover the active Exit Node endpoint (read-only) so the
            // rebuilt list excludes it exactly like the apply path does.
            let endpointCIDRs = inspector.inspect().snapshot.tailscaleExitNodeEndpoint
                .flatMap { IPv4CIDR.parse("\($0)/32") }
                .map { [$0] } ?? []
            progress?(RouteProgress(completed: 25, total: 100, message: "下载并校验中国 IP 清单"))
            let result = try domainListBuilder(for: listConfiguration).build(
                configuration: listConfiguration,
                refreshSource: true,
                protectedEndpointCIDRs: endpointCIDRs,
                externalDirectCIDRs: externalDirectCIDRs()
            )
            progress?(RouteProgress(completed: 88, total: 100, message: "写入清单缓存与目标摘要"))
            logger.info("目标清单更新成功：\(result.list.cidrs.count) 条")
            let report = diagnosticReport()
            progress?(RouteProgress(completed: 100, total: 100, message: "中国 IP 清单更新完成"))
            return HelperResponse(
                requestID: request.requestID,
                success: true,
                message: "目标清单已更新，共 \(result.list.cidrs.count) 条",
                report: report,
                state: loadState(),
                operation: RouteOperationResult(
                    success: true,
                    state: loadState().lifecycle,
                    appliedCount: 0,
                    removedCount: 0,
                    failedCount: 0,
                    lastError: nil,
                    warnings: result.warnings,
                    verifiedTargets: []
                ),
                targetList: result.list,
                layeredStatus: LayeredOperationStatus(
                    route: .notEvaluated,
                    externalProtection: .notEvaluated,
                    domainResolution: .notEvaluated,
                    overall: result.warnings.isEmpty ? .ok : .degraded
                )
            )
        } catch {
            logger.error("目标清单更新失败：\(error.localizedDescription)")
            return failedResponse(
                requestID: request.requestID,
                message: error.localizedDescription,
                report: diagnosticReport(),
                layeredStatus: LayeredOperationStatus(
                    route: .notEvaluated,
                    externalProtection: .notEvaluated,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }
    }

    /// Reconcile only the configured temporary domains. This path deliberately
    /// does not call `TargetListBuilder.build`, `apply`, external protection,
    /// Exit Node endpoint protection, or any China-list code. The RouteCoordinator
    /// is still used so the Helper's exact ownership checks, route lock, staged
    /// add/replace/cleanup transaction, and read-back verification remain the
    /// single authority for privileged IPv4 route changes.
    private func refreshDomains(_ request: HelperRequest) -> HelperResponse {
        let configuration = request.configuration ?? store.loadConfiguration()

        // Inspect first: the DNS servers must be pinned to the current
        // physical gateway before any lookup, otherwise `dig` follows the
        // Exit Node default route into the tunnel and times out.
        let inspection: (
            snapshot: NetworkSnapshot,
            tailscale: TailscaleStatusSummary,
            warnings: [String],
            errors: [String],
            actualRoutes: [RouteEntry]
        )
        do {
            inspection = try inspectStableNetwork()
        } catch {
            return failedDomainRefreshResponse(
                requestID: request.requestID,
                message: error.localizedDescription,
                state: loadState(),
                resolution: domainListBuilder(for: configuration).resolveConfiguredDomains(configuration.domainNames)
            )
        }
        guard inspection.errors.isEmpty else {
            return failedDomainRefreshResponse(
                requestID: request.requestID,
                message: inspection.errors.joined(separator: "；"),
                state: loadState(),
                resolution: domainListBuilder(for: configuration).resolveConfiguredDomains(configuration.domainNames)
            )
        }
        let dnsServerResult = pinDNSServers(snapshot: inspection.snapshot, servers: configuration.effectiveDNSServers)
        let resolution = domainListBuilder(for: configuration).resolveConfiguredDomains(configuration.domainNames)
        let previousState = loadState()

        let endpointCIDRs = inspection.snapshot.tailscaleExitNodeEndpoint
            .flatMap { IPv4CIDR.parse("\($0)/32") }
            .map { [$0] } ?? []
        let configuredExclusions = configuration.excludeCIDRs.compactMap { IPv4CIDR.parse($0) }
        let externalExclusions = previousState.managedExternalGatewayRoutes.compactMap {
            IPv4CIDR.parse($0.cidr)
        }
        let exclusions = IPv4CIDR.protectedRouteCIDRs
            + endpointCIDRs
            + configuredExclusions
            + externalExclusions

        var desiredIPv4ByDomain: [String: [String]] = [:]
        for entry in resolution.entries {
            let previous = previousState.managedDomainIPv4Routes
                .filter { $0.domain == entry.domain }
                .map(\.route)
            if entry.ipv4Status == .unavailable {
                // No current answer and no cache: preserve the exact old
                // domain routes, if any. This is the key last-known-good
                // ownership rule for an upgrade from an older cache/state.
                desiredIPv4ByDomain[entry.domain] = previous.map(\.cidr)
                continue
            }
            desiredIPv4ByDomain[entry.domain] = entry.ipv4Addresses.filter { address in
                guard let host = IPv4CIDR.parse("\(address)/32") else { return false }
                return !exclusions.contains { $0.overlaps(host) }
            }
        }
        let desiredIPv4 = Array(Set(desiredIPv4ByDomain.values.joined())).sorted()
        let previousDomainIPv4 = previousState.managedDomainIPv4Routes.map(\.route)
        let ipv4Result = coordinator.apply(
            targets: desiredIPv4,
            snapshot: inspection.snapshot,
            requireExitNode: true,
            previouslyManagedRoutes: previousDomainIPv4,
            allowEmptyTargets: true,
            purgeExternalRoutes: false,
            progress: nil
        )
        let domainIPv4Ledger = domainIPv4Ledger(
            routes: ipv4Result.managedRoutes ?? previousDomainIPv4,
            desiredByDomain: desiredIPv4ByDomain,
            previous: previousState.managedDomainIPv4Routes
        )

        // NetworkInspector can report an expected warning when macOS's
        // default route is Tailscale's utun. That is useful context for the
        // response, but it is not a DNS/domain-refresh failure. Keep the
        // domain-specific warning set separate for layered status reporting.
        var domainWarnings = dnsServerResult.warnings + resolution.warnings + ipv4Result.warnings
        var warnings = domainWarnings + inspection.warnings
        var domainIPv6LedgerResult = previousState.managedDomainIPv6Routes
        var ipv6Result = IPv6RouteUpdateResult(
            managedRoutes: previousState.managedIPv6Routes,
            addedCount: 0,
            removedCount: 0,
            warnings: []
        )

        if ipv4Result.success {
            var desiredIPv6ByDomain: [String: [String]] = [:]
            for entry in resolution.entries {
                let previous = previousState.managedDomainIPv6Routes
                    .filter { $0.domain == entry.domain }
                    .map(\.route.address)
                desiredIPv6ByDomain[entry.domain] = entry.ipv6Status == .unavailable
                    ? previous
                    : entry.ipv6Addresses
            }

            // Preserve pre-v56 IPv6 records whose domain association was not
            // persisted yet. They are never inferred or deleted by this path.
            let previousDomainIPv6 = Set(previousState.managedDomainIPv6Routes.map(\.route))
            let legacyIPv6 = previousState.managedIPv6Routes.filter { !previousDomainIPv6.contains($0) }
            let desiredIPv6 = Array(Set(desiredIPv6ByDomain.values.joined() + legacyIPv6.map(\.address))).sorted()

            if inspection.snapshot.ipv6Gateway != nil,
               inspection.snapshot.physicalInterface != nil
            {
                ipv6Result = ipv6RouteManager.apply(
                    addresses: desiredIPv6,
                    gateway: inspection.snapshot.ipv6Gateway,
                    interfaceName: inspection.snapshot.physicalInterface,
                    previouslyManaged: previousState.managedIPv6Routes
                )
                domainIPv6LedgerResult = domainIPv6Ledger(
                    routes: ipv6Result.managedRoutes,
                    desiredByDomain: desiredIPv6ByDomain,
                    previous: previousState.managedDomainIPv6Routes
                )
                domainWarnings.append(contentsOf: ipv6Result.warnings)
                warnings.append(contentsOf: ipv6Result.warnings)
            } else if !desiredIPv6.isEmpty || !previousState.managedIPv6Routes.isEmpty {
                let warning = "没有可用的物理 IPv6 网关，保留现有域名 IPv6 路由账本"
                domainWarnings.append(warning)
                warnings.append(warning)
            }

            // An uncertain lookup must not rewrite the managed block and
            // thereby erase a last-known-good entry that predates the cache.
            if resolution.entries.allSatisfy({
                $0.ipv4Status != .unavailable && $0.ipv6Status != .unavailable
            }) {
                do {
                    let pinCount = try HostsPinManager.apply(
                        domainAddresses: resolution.hosts,
                        hostsPath: hostsPath
                    )
                    if pinCount > 0 { logger.info("域名 hosts 增量更新：\(pinCount) 条") }
                } catch {
                    let warning = "更新 /etc/hosts 失败：\(error.localizedDescription)"
                    domainWarnings.append(warning)
                    warnings.append(warning)
                }
            } else {
                let warning = "存在未确认的 DNS 结果，保留现有 hosts 管理区"
                domainWarnings.append(warning)
                warnings.append(warning)
            }
        }

        var state = previousState
        let oldDomainIPv4 = Set(previousState.managedDomainIPv4Routes.map(\.route))
        let nonDomainIPv4 = state.managedRoutes.filter { !oldDomainIPv4.contains($0) }
        state.managedDomainIPv4Routes = domainIPv4Ledger
        state.managedRoutes = Array(Set(nonDomainIPv4 + domainIPv4Ledger.map(\.route))).sorted {
            if $0.cidr != $1.cidr { return $0.cidr < $1.cidr }
            if $0.gateway != $1.gateway { return $0.gateway < $1.gateway }
            return $0.interfaceName < $1.interfaceName
        }
        // Domain refreshes can add or remove IPv4 host routes without
        // rebuilding the China list. Keep the summary count aligned with the
        // exact ownership ledger so the App does not display the pre-refresh
        // count until the next full apply.
        state.appliedRouteCount = state.managedRoutes.count

        let oldDomainIPv6 = Set(previousState.managedDomainIPv6Routes.map(\.route))
        let legacyIPv6 = state.managedIPv6Routes.filter { !oldDomainIPv6.contains($0) }
        state.managedDomainIPv6Routes = domainIPv6LedgerResult
        state.managedIPv6Routes = Array(Set(legacyIPv6 + domainIPv6LedgerResult.map(\.route))).sorted {
            if $0.address != $1.address { return $0.address < $1.address }
            if $0.gateway != $1.gateway { return $0.gateway < $1.gateway }
            return $0.interfaceName < $1.interfaceName
        }
        state.updatedAt = Date()

        var stateSaveSucceeded = true
        do {
            state = try saveState(state)
        } catch {
            stateSaveSucceeded = false
            warnings.append("保存域名路由所有权账本失败：\(error.localizedDescription)")
            rememberUnsavedState(state)
        }

        let success = ipv4Result.success && stateSaveSucceeded
        let domainStatus: LayerStatus
        if !success {
            domainStatus = .failed
        } else if domainWarnings.isEmpty {
            domainStatus = .ok
        } else {
            domainStatus = .degraded
        }
        let message = success
            ? "临时域名增量刷新完成：IPv4 新增 \(ipv4Result.appliedCount) 条、清理 \(ipv4Result.removedCount) 条；IPv6 新增 \(ipv6Result.addedCount) 条、清理 \(ipv6Result.removedCount) 条"
            : (ipv4Result.lastError ?? "临时域名增量刷新失败")
        let completeMessage = warnings.isEmpty ? message : "\(message)；注意：\(warnings.first!)"
        let operation = RouteOperationResult(
            success: success,
            state: state.lifecycle,
            appliedCount: ipv4Result.appliedCount + ipv6Result.addedCount,
            removedCount: ipv4Result.removedCount + ipv6Result.removedCount,
            failedCount: ipv4Result.failedCount + ipv6Result.warnings.count,
            lastError: success ? nil : (ipv4Result.lastError ?? warnings.first),
            warnings: warnings,
            verifiedTargets: ipv4Result.verifiedTargets,
            managedRoutes: domainIPv4Ledger.map(\.route),
            pendingRemovals: ipv4Result.pendingRemovals
        )
        return HelperResponse(
            requestID: request.requestID,
            success: success,
            message: completeMessage,
            report: diagnosticReport(),
            state: state,
            operation: operation,
            domainIPv4Count: resolution.ipv4.count,
            domainIPv6Count: resolution.ipv6.count,
            layeredStatus: LayeredOperationStatus(
                route: ipv4Result.success ? .ok : .failed,
                externalProtection: .notEvaluated,
                domainResolution: domainStatus,
                overall: success && domainWarnings.isEmpty ? .ok : (success ? .degraded : .failed)
            )
        )
    }

    private func failedDomainRefreshResponse(
        requestID: UUID,
        message: String,
        state: PersistedRouteState,
        resolution: DomainResolutionResult
    ) -> HelperResponse {
        let warnings = resolution.warnings + [message]
        return HelperResponse(
            requestID: requestID,
            success: false,
            message: message,
            state: state,
            operation: RouteOperationResult(
                success: false,
                state: state.lifecycle,
                appliedCount: 0,
                removedCount: 0,
                failedCount: 1,
                lastError: message,
                warnings: warnings,
                verifiedTargets: [],
                managedRoutes: state.managedDomainIPv4Routes.map(\.route),
                pendingRemovals: []
            ),
            domainIPv4Count: resolution.ipv4.count,
            domainIPv6Count: resolution.ipv6.count,
            layeredStatus: LayeredOperationStatus(
                route: .notEvaluated,
                externalProtection: .notEvaluated,
                domainResolution: .failed,
                overall: .failed
            ),
        )
    }

    private func domainIPv4Ledger(
        routes: [RouteSpec],
        desiredByDomain: [String: [String]],
        previous: [ManagedDomainIPv4Route]
    ) -> [ManagedDomainIPv4Route] {
        var result: Set<ManagedDomainIPv4Route> = []
        for route in routes {
            guard let cidr = IPv4CIDR.canonical(route.cidr) else { continue }
            if let domain = desiredByDomain.keys.sorted().first(where: {
                desiredByDomain[$0, default: []].contains { IPv4CIDR.canonical($0) == cidr }
            }) {
                result.insert(ManagedDomainIPv4Route(domain: domain, route: route))
            } else if let old = previous.first(where: { $0.route == route }) {
                result.insert(old)
            }
        }
        return result.sorted {
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.route.cidr < $1.route.cidr
        }
    }

    private func domainIPv6Ledger(
        routes: [IPv6HostRoute],
        desiredByDomain: [String: [String]],
        previous: [ManagedDomainIPv6Route]
    ) -> [ManagedDomainIPv6Route] {
        var result: Set<ManagedDomainIPv6Route> = []
        for route in routes {
            let address = route.address.lowercased()
            if let domain = desiredByDomain.keys.sorted().first(where: {
                desiredByDomain[$0, default: []].contains { $0.lowercased() == address }
            }) {
                result.insert(ManagedDomainIPv6Route(domain: domain, route: route))
            } else if let old = previous.first(where: { $0.route == route }) {
                result.insert(old)
            }
        }
        return result.sorted {
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.route.address < $1.route.address
        }
    }

    private func preview(_ request: HelperRequest) -> HelperResponse {
        let configuration = request.configuration ?? store.loadConfiguration()
        do {
            // Preview is not a manual source update. It must never turn an
            // expired cache into an implicit network download.
            try requireUsableChinaListCache(for: configuration)
            let inspection = try inspectStableNetwork()
            guard inspection.errors.isEmpty else {
                return HelperResponse(
                    requestID: request.requestID,
                    success: false,
                    message: inspection.errors.joined(separator: "；"),
                    report: diagnosticReport(),
                    state: loadState(),
                    layeredStatus: LayeredOperationStatus(
                        route: .failed,
                        externalProtection: .notEvaluated,
                        domainResolution: .notEvaluated,
                        overall: .failed
                    )
                )
            }
            let list = try domainListBuilder(for: configuration).build(
                configuration: configuration,
                protectedEndpointCIDRs: inspection.snapshot.tailscaleExitNodeEndpoint
                    .flatMap { IPv4CIDR.parse("\($0)/32") }
                    .map { [$0] } ?? [],
                externalDirectCIDRs: externalDirectCIDRs()
            )
            let state = loadState()
            let plan = coordinator.preview(
                targets: list.list.cidrs,
                snapshot: inspection.snapshot,
                previouslyManagedRoutes: state.managedRoutes,
                allowEmptyTargets: list.list.cidrs.isEmpty
            )
            let routeCount = plan.desiredRoutes.count
            let summary = "只读预览：目标 \(routeCount) 条，新增 \(plan.additions.count) 条，切换 \(plan.replacements.count) 条，保留 \(plan.alreadyCorrect.count) 条，清理账本旧路由 \(plan.cleanup.count) 条"
            let message = plan.errors.first ?? plan.warnings.first.map { "\(summary)；注意：\($0)" } ?? summary
            return HelperResponse(
                requestID: request.requestID,
                success: plan.errors.isEmpty,
                message: message,
                report: diagnosticReport(),
                state: state,
                planPreview: RoutePlanPreview(
                    networkFingerprint: plan.networkFingerprint,
                    desiredRoutes: plan.desiredRoutes,
                    alreadyCorrect: plan.alreadyCorrect,
                    additions: plan.additions,
                    replacements: plan.replacements,
                    cleanup: plan.cleanup,
                    unownedConflicts: plan.unownedConflicts,
                    errors: plan.errors,
                    warnings: list.warnings + plan.warnings
                ),
                layeredStatus: LayeredOperationStatus(
                    route: plan.errors.isEmpty ? (plan.warnings.isEmpty ? .ok : .degraded) : .failed,
                    externalProtection: .notEvaluated,
                    domainResolution: list.warnings.isEmpty ? .ok : .degraded,
                    overall: plan.errors.isEmpty && list.warnings.isEmpty ? .ok : (plan.errors.isEmpty ? .degraded : .failed)
                )
            )
        } catch {
            return HelperResponse(
                requestID: request.requestID,
                success: false,
                message: error.localizedDescription,
                report: diagnosticReport(),
                state: loadState(),
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: .notEvaluated,
                    domainResolution: .failed,
                    overall: .failed
                )
            )
        }
    }

    private func apply(_ request: HelperRequest, progress: (@Sendable (RouteProgress) -> Void)?) -> HelperResponse {
        var configuration = request.configuration ?? store.loadConfiguration()
        configuration.enabled = true
        do {
            try store.saveConfiguration(configuration)
        } catch {
            return failedResponse(
                requestID: request.requestID,
                message: "保存配置失败：\(error.localizedDescription)",
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: .notEvaluated,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }

        // Keep the UI determinate from the first frame. Network inspection
        // runs first: the active Exit Node's endpoint address is discovered
        // here and must be excluded before the target list is built.
        progress?(RouteProgress(completed: 0, total: 100, message: "检查网络与 Tailscale 状态"))

        let inspection: (
            snapshot: NetworkSnapshot,
            tailscale: TailscaleStatusSummary,
            warnings: [String],
            errors: [String],
            actualRoutes: [RouteEntry]
        )
        do {
            inspection = try inspectStableNetwork()
        } catch {
            return failedResponse(
                requestID: request.requestID,
                message: error.localizedDescription,
                report: diagnosticReport(),
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: .notEvaluated,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }
        guard inspection.errors.isEmpty else {
            return failedResponse(
                requestID: request.requestID,
                message: inspection.errors.joined(separator: "；"),
                report: diagnosticReport(),
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: .notEvaluated,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }
        var protectionState = loadState()
        let externalDetection = externalNetworkDetector.scan()
        let externalProtection: ExternalProtectionStatus
        if shouldReconcileExternalProtection(for: externalDetection) {
            externalProtection = reconcileExternalSubnetProtection(
                state: &protectionState,
                detection: externalDetection
            )
            persistExternalSnapshotKeyIfSuccessful(
                detection: externalDetection,
                protection: externalProtection
            )
        } else {
            externalProtection = retainedExternalProtectionStatus(
                detection: externalDetection,
                state: protectionState
            )
        }
        let discoveryFailed = externalProtection.warnings.contains {
            $0.hasPrefix("外接网段检测失败：")
        }
        if discoveryFailed || (!externalProtection.networks.isEmpty && externalProtection.active != true) {
            let reason = externalProtection.warnings.first
                ?? "外接网段尚未验证通过，未应用会接管这些地址的分流路由"
            return HelperResponse(
                requestID: request.requestID,
                success: false,
                message: reason,
                report: diagnosticReport(protection: externalProtection),
                state: protectionState,
                layeredStatus: LayeredOperationStatus(
                    route: .notEvaluated,
                    externalProtection: .failed,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }
        // Pin the resolver DNS servers before the target list is built: the
        // builder resolves configured domains, and on a first apply the China
        // routes that would otherwise cover these servers do not exist yet.
        let dnsServerResult = pinDNSServers(snapshot: inspection.snapshot, servers: configuration.effectiveDNSServers)
        progress?(RouteProgress(completed: 8, total: 100, message: "准备中国 IP 清单"))

        let list: TargetListBuildResult
        do {
            try requireUsableChinaListCache(for: configuration)
            list = try domainListBuilder(for: configuration).build(
                configuration: configuration,
                protectedEndpointCIDRs: inspection.snapshot.tailscaleExitNodeEndpoint
                    .flatMap { IPv4CIDR.parse("\($0)/32") }
                    .map { [$0] } ?? [],
                externalDirectCIDRs: externalProtection.networks.compactMap { IPv4CIDR.parse($0.cidr) }
            )
        } catch {
            return failedResponse(
                requestID: request.requestID,
                message: error.localizedDescription,
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: externalProtection.active == false ? .failed : .ok,
                    domainResolution: .failed,
                    overall: .failed
                )
            )
        }
        progress?(RouteProgress(completed: 20, total: 100, message: "开始增量更新路由"))

        let routeProgress: (@Sendable (RouteProgress) -> Void)?
        if let progress {
            routeProgress = { localProgress in
                let scaled = 20 + Int((localProgress.fraction * 75).rounded())
                progress(RouteProgress(
                    completed: scaled,
                    total: 100,
                    message: localProgress.message
                ))
            }
        } else {
            routeProgress = nil
        }
        // Keep a complete read-only snapshot before the first destructive
        // replacement. It is useful for auditing and manual recovery without
        // making the backup itself part of route ownership.
        let transactionStartedAt = Date()
        var journal = RouteTransactionJournal(
            requestID: request.requestID,
            startedAt: transactionStartedAt,
            networkFingerprint: inspection.snapshot.fingerprint,
            beforeRoutes: inspection.actualRoutes
        )
        do {
            try store.write(inspection.actualRoutes, to: paths.preApplyRoutes)
            try store.write(journal, to: paths.lastOperation)
        } catch {
            return failedResponse(
                requestID: request.requestID,
                message: "保存路由事务前快照失败：\(error.localizedDescription)",
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: .ok,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }
        let previousState = loadState()
        let previouslyManagedRoutes = Array(Set(
            previousState.managedRoutes
                + previousState.managedDomainIPv4Routes.map(\.route)
        ))
        let result = coordinator.apply(
            targets: list.list.cidrs,
            snapshot: inspection.snapshot,
            previouslyManagedRoutes: previouslyManagedRoutes,
            // A successfully built empty list means the configured targets
            // existed but all fell inside mandatory/user exclusions. Permit
            // that result so previously recorded App routes can be reconciled.
            allowEmptyTargets: list.list.cidrs.isEmpty,
            // Match the script's ownership boundary: reconcile its previous
            // target set and the desired China list, but leave unrelated
            // direct routes on the LAN untouched.
            purgeExternalRoutes: false,
            progress: routeProgress
        )
        let domainIPv4ByDomain = Dictionary(
            grouping: list.hostAddresses.flatMap { host in
                host.ipv4Addresses
                    .filter { list.domainIPv4.contains($0) }
                    .map { (host.domain, $0) }
            },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }
        let previousDomainIPv4 = previousState.managedDomainIPv4Routes.map(\.route)
        let domainIPv4Result = result.success
            ? coordinator.apply(
                targets: list.domainIPv4,
                snapshot: inspection.snapshot,
                requireExitNode: true,
                previouslyManagedRoutes: previousDomainIPv4,
                allowEmptyTargets: true,
                purgeExternalRoutes: false,
                progress: nil
            )
            : RouteOperationResult(
                success: false,
                state: result.state,
                appliedCount: 0,
                removedCount: 0,
                failedCount: 0,
                lastError: result.lastError,
                warnings: [],
                verifiedTargets: [],
                managedRoutes: previousDomainIPv4,
                pendingRemovals: []
            )
        // Pin the active Exit Node's public endpoint to the physical gateway
        // so the WireGuard tunnel can never loop into its own utun default
        // route. Owned separately from split-tunnel targets.
        let endpointResult = result.success
            ? exitNodeEndpointProtector.reconcile(
                endpointAddress: inspection.snapshot.tailscaleExitNodeEndpoint,
                gateway: inspection.snapshot.gateway,
                interfaceName: inspection.snapshot.physicalInterface,
                previouslyManaged: previousState.managedExitNodeEndpointRoutes,
                splitOwnedRoutes: (result.managedRoutes ?? []) + (domainIPv4Result.managedRoutes ?? [])
            )
            : ExitNodeEndpointProtectionResult(
                managedRoutes: previousState.managedExitNodeEndpointRoutes,
                addedCount: 0,
                removedCount: 0,
                warnings: []
            )
        let ipv6Result = result.success && domainIPv4Result.success
            ? ipv6RouteManager.apply(
                addresses: list.domainIPv6,
                gateway: inspection.snapshot.ipv6Gateway,
                interfaceName: inspection.snapshot.physicalInterface,
                previouslyManaged: previousState.managedIPv6Routes
            )
            : IPv6RouteUpdateResult(
                managedRoutes: previousState.managedIPv6Routes,
                addedCount: 0,
                removedCount: 0,
                warnings: []
            )
        let domainIPv4Ledger = domainIPv4Ledger(
            routes: domainIPv4Result.managedRoutes ?? previousDomainIPv4,
            desiredByDomain: domainIPv4ByDomain,
            previous: previousState.managedDomainIPv4Routes
        )
        let domainIPv6ByDomain = Dictionary(
            grouping: list.hostAddresses.flatMap { host in
                host.ipv6Addresses
                    .filter { list.domainIPv6.contains($0) }
                    .map { (host.domain, $0) }
            },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }
        let domainIPv6LedgerResult = domainIPv6Ledger(
            routes: ipv6Result.managedRoutes,
            desiredByDomain: domainIPv6ByDomain,
            previous: previousState.managedDomainIPv6Routes
        )
        var domainLayerWarningCount = list.warnings.count + domainIPv4Result.warnings.count + ipv6Result.warnings.count
            + dnsServerResult.warnings.count
        var warnings = result.warnings
            + domainIPv4Result.warnings
            + externalProtection.warnings
            + endpointResult.warnings
            + dnsServerResult.warnings
            + ipv6Result.warnings
        // Pin resolved domain answers into /etc/hosts: while an Exit Node is
        // active macOS scopes system DNS through the tunnel, which would
        // otherwise hand browsers overseas edges even though the split-route
        // table points at domestic ones. Managed via an isolated section so
        // unrelated user entries stay untouched.
        if result.success && domainIPv4Result.success {
            do {
                let pinCount = try HostsPinManager.apply(domainAddresses: list.hostAddresses, hostsPath: hostsPath)
                if pinCount > 0 {
                    logger.info("域名 hosts 钉住已更新：\(pinCount) 条")
                }
            } catch {
                warnings.append("更新 /etc/hosts 失败：\(error.localizedDescription)")
                domainLayerWarningCount += 1
            }
        }
        progress?(RouteProgress(completed: 96, total: 100, message: "路由验证完成，刷新状态"))
        var state = loadState()
        state.updatedAt = Date()
        let overallRouteSuccess = result.success && domainIPv4Result.success
        state.lifecycle = overallRouteSuccess
            ? (warnings.isEmpty ? .enabled : .partial)
            : (result.success ? .partial : result.state)
        // `appliedCount` is the number of route commands issued in this
        // transaction. An incremental no-op legitimately issues zero add
        // commands, while the managed list is still fully active.
        state.appliedRouteCount = result.success ? list.list.cidrs.count : (result.managedRoutes?.count ?? state.managedRoutes.count)
        if result.success {
            let ipv4Routes = list.list.cidrs.map {
                RouteSpec(cidr: $0, gateway: inspection.snapshot.gateway ?? "", interfaceName: inspection.snapshot.physicalInterface ?? "")
            }
            state.managedRoutes = Array(Set(ipv4Routes + domainIPv4Ledger.map(\.route)))
            state.externalAdoptionEnabled = true
            state.managedIPv6Routes = ipv6Result.managedRoutes
            state.managedDomainIPv4Routes = domainIPv4Ledger
            state.managedDomainIPv6Routes = domainIPv6LedgerResult
        } else if let transactionalRoutes = result.managedRoutes {
            state.managedRoutes = Array(Set(transactionalRoutes + domainIPv4Ledger.map(\.route)))
            state.externalAdoptionEnabled = true
        }
        state.managedExitNodeEndpointRoutes = endpointResult.managedRoutes
        state.managedDNSServerRoutes = dnsServerResult.managedRoutes
        state.desiredHash = list.list.sha256
        state.lastError = result.lastError
        if result.success {
            state.lastSuccessAt = Date()
            state.lastSuccessFingerprint = inspection.snapshot.fingerprint
        }

        let aggregateAppliedCount = result.appliedCount + ipv6Result.addedCount + endpointResult.addedCount
            + dnsServerResult.addedCount
        let aggregateRemovedCount = result.removedCount + ipv6Result.removedCount + endpointResult.removedCount
            + dnsServerResult.removedCount
        let aggregateFailedCount = result.failedCount + ipv6Result.warnings.count + endpointResult.warnings.count
            + dnsServerResult.warnings.count + externalProtection.warnings.count
        let operation = RouteOperationResult(
            success: overallRouteSuccess,
            state: state.lifecycle,
            appliedCount: aggregateAppliedCount,
            removedCount: aggregateRemovedCount,
            failedCount: aggregateFailedCount,
            lastError: overallRouteSuccess ? result.lastError : (domainIPv4Result.lastError ?? result.lastError),
            warnings: warnings,
            verifiedTargets: result.verifiedTargets,
            managedRoutes: result.managedRoutes,
            pendingRemovals: result.pendingRemovals
        )
        let afterRoutes = inspector.inspect().actualRoutes
        journal.finishedAt = Date()
        journal.afterRoutes = afterRoutes
        journal.operation = operation
        do {
            try store.write(afterRoutes, to: paths.postApplyRoutes)
            try store.write(journal, to: paths.lastOperation)
        } catch {
            let journalWarning = "保存路由事务后快照失败：\(error.localizedDescription)"
            warnings.append(journalWarning)
            logger.warning(journalWarning)
        }
        do {
            state = try saveState(state)
        } catch {
            let message = "路由状态保存失败：\(error.localizedDescription)"
            state.lifecycle = .error
            state.lastError = message
            rememberUnsavedState(state)
            warnings.append(message)
            logger.error(message)
            return HelperResponse(
                requestID: request.requestID,
                success: false,
                message: message,
                report: diagnosticReport(protection: externalProtection),
                state: state,
                operation: RouteOperationResult(
                    success: false,
                    state: .error,
                    appliedCount: result.appliedCount + ipv6Result.addedCount + endpointResult.addedCount,
                    removedCount: result.removedCount + ipv6Result.removedCount + endpointResult.removedCount,
                    failedCount: 1,
                    lastError: message,
                    warnings: warnings,
                    verifiedTargets: result.verifiedTargets,
                    managedRoutes: result.managedRoutes,
                    pendingRemovals: result.pendingRemovals
                ),
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: externalProtection.active == false ? .failed : .ok,
                    domainResolution: domainLayerWarningCount == 0 ? .ok : .degraded,
                    overall: .failed
                )
            )
        }
        if endpointResult.addedCount > 0 || endpointResult.removedCount > 0 || !endpointResult.warnings.isEmpty {
            logger.info("Exit Node 端点保护：新增 \(endpointResult.addedCount) 条、清理 \(endpointResult.removedCount) 条")
        }
        if ipv6Result.addedCount > 0 || ipv6Result.removedCount > 0 || !ipv6Result.warnings.isEmpty {
            logger.info("临时域名 IPv6 路由：新增 \(ipv6Result.addedCount) 条、清理 \(ipv6Result.removedCount) 条")
        }
        logger.info("\(request.action.rawValue) 完成：\(overallRouteSuccess ? "成功" : "失败")")
        progress?(RouteProgress(completed: 100, total: 100, message: "分流应用完成"))
        let successMessage: String
        let localProtectionMessage = externalProtection.networks.isEmpty
            ? "未检测到外接直连网段"
            : "外接网段保护：\(externalProtection.message)"
        let endpointMessage = endpointResult.managedRoutes.isEmpty
            ? "端点保护未启用"
            : "Exit Node 端点保护 \(endpointResult.managedRoutes.count) 条"
        if result.appliedCount == 0, result.removedCount == 0,
           ipv6Result.addedCount == 0, ipv6Result.removedCount == 0,
           endpointResult.addedCount == 0, endpointResult.removedCount == 0
        {
            successMessage = "分流已验证，共 \(list.list.cidrs.count) 条 IPv4 路由；\(localProtectionMessage)；\(endpointMessage)；域名 IPv6 直连 \(ipv6Result.managedRoutes.count) 条"
        } else {
            successMessage = "分流已更新，共 \(list.list.cidrs.count) 条 IPv4 路由；\(localProtectionMessage)；\(endpointMessage)；新增域名 IPv6 直连 \(ipv6Result.addedCount) 条"
        }
        let responseMessage = warnings.first.map { "\(successMessage)；注意：\($0)" } ?? successMessage
        let routeLayerStatus: LayerStatus = overallRouteSuccess
            ? (result.warnings.isEmpty ? .ok : .degraded)
            : .failed
        let externalLayerStatus: LayerStatus = externalProtection.networks.isEmpty
            ? (externalProtection.warnings.isEmpty ? .ok : .degraded)
            : (externalProtection.active == true ? .ok : .failed)
        let domainLayerStatus: LayerStatus = configuration.domainNames.isEmpty
            ? .notEvaluated
            : (domainLayerWarningCount == 0 ? .ok : .degraded)
        let overallLayerStatus: LayerStatus = overallRouteSuccess
            ? (warnings.isEmpty ? .ok : .degraded)
            : .failed
        return HelperResponse(
            requestID: request.requestID,
            success: overallRouteSuccess,
            message: overallRouteSuccess
                ? responseMessage
                : (result.lastError ?? "路由应用失败"),
            report: diagnosticReport(protection: externalProtection),
            state: state,
            operation: RouteOperationResult(
                success: overallRouteSuccess,
                state: state.lifecycle,
                appliedCount: aggregateAppliedCount,
                removedCount: aggregateRemovedCount,
                failedCount: aggregateFailedCount,
                lastError: overallRouteSuccess ? result.lastError : (domainIPv4Result.lastError ?? result.lastError),
                warnings: warnings,
                verifiedTargets: result.verifiedTargets,
                managedRoutes: result.managedRoutes,
                pendingRemovals: result.pendingRemovals
            ),
            targetList: list.list,
            domainIPv4Count: list.domainIPv4.count,
            domainIPv6Count: list.domainIPv6.count,
            layeredStatus: LayeredOperationStatus(
                route: routeLayerStatus,
                externalProtection: externalLayerStatus,
                domainResolution: domainLayerStatus,
                overall: overallLayerStatus
            )
        )
    }

    private func pause(
        _ request: HelperRequest,
        progress: (@Sendable (RouteProgress) -> Void)?,
        restoreTailscalePreferences: Bool = false,
        releaseExternalGatewayRoutes: Bool = false
    ) -> HelperResponse {
        progress?(RouteProgress(completed: 0, total: 1, message: "移除项目管理的分流路由"))
        let previousState = loadState()
        var warnings: [String] = []
        var removedCount = 0

        // Route backends treat a failed route-table read as an empty table.
        // Refuse to start cleanup unless the table is readable, so a transient
        // netstat failure cannot be mistaken for successful removal.
        let routeTableCheck = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        guard routeTableCheck.succeeded else {
            return failedResponse(
                requestID: request.requestID,
                message: "无法读取当前路由表，未执行停止清理：\(routeTableCheck.failureReason)",
                report: diagnosticReport(),
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: .notEvaluated,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }

        let inspectedReport = diagnosticReport()
        let ownershipReport = DiagnosticReport(
            snapshot: inspectedReport.snapshot,
            managedTargets: inspectedReport.managedTargets,
            actualRoutes: RouteOutputParser.parseRouteTable(routeTableCheck.stdout),
            tailscale: inspectedReport.tailscale,
            warnings: inspectedReport.warnings,
            errors: inspectedReport.errors
        )

        // Drop the managed /etc/hosts pins along with the routes they serve.
        do {
            try HostsPinManager.apply(domainAddresses: [], hostsPath: hostsPath)
        } catch {
            warnings.append("清理 /etc/hosts 失败：\(error.localizedDescription)")
        }

        // Remove only routes owned by this app. Recover previously adopted
        // routes when the persisted list is empty, but never infer ownership
        // from a matching destination alone.
        let routesToRemove = managedRoutesForOperation(previousState, report: ownershipReport)
        let ipv4Result = coordinator.pause(routes: routesToRemove, progress: progress)
        if ipv4Result.success {
            removedCount += ipv4Result.removedCount
        } else {
            warnings.append(ipv4Result.lastError ?? "受管理 IPv4 路由删除失败")
        }

        // Pinned Exit Node endpoint host routes.
        let endpointResult = exitNodeEndpointProtector.reconcile(
            endpointAddress: nil,
            gateway: nil,
            interfaceName: nil,
            previouslyManaged: previousState.managedExitNodeEndpointRoutes
        )
        removedCount += endpointResult.removedCount
        warnings.append(contentsOf: endpointResult.warnings)

        let externalGatewayResult: ExternalGatewayRouteProtectionResult
        if releaseExternalGatewayRoutes {
            externalGatewayResult = externalNetworkRouteProtector.reconcile(
                networks: [],
                previouslyManaged: previousState.managedExternalGatewayRoutes,
                pendingRestorations: previousState.pendingExternalRouteRestorations
            )
            removedCount += externalGatewayResult.removedCount
            warnings.append(contentsOf: externalGatewayResult.warnings)
        } else {
            externalGatewayResult = ExternalGatewayRouteProtectionResult(
                managedRoutes: previousState.managedExternalGatewayRoutes,
                pendingRestorations: previousState.pendingExternalRouteRestorations,
                addedCount: 0,
                removedCount: 0,
                warnings: []
            )
        }

        // Exact IPv6 host routes for temporary domains.
        let ipv6Result = ipv6RouteManager.apply(
            addresses: [],
            gateway: nil,
            interfaceName: nil,
            previouslyManaged: previousState.managedIPv6Routes
        )
        removedCount += ipv6Result.removedCount
        warnings.append(contentsOf: ipv6Result.warnings)

        // Pinned resolver DNS server host routes.
        let dnsServerResult = dnsServerRouteProtector.reconcile(
            servers: [],
            gateway: nil,
            interfaceName: nil,
            previouslyManaged: previousState.managedDNSServerRoutes
        )
        removedCount += dnsServerResult.removedCount
        warnings.append(contentsOf: dnsServerResult.warnings)

        // Verify the IPv4 routes after all helpers have run. Individual route
        // managers intentionally return an empty list when netstat fails; a
        // readable post-check distinguishes "not found" from "could not read".
        let routeTableAfter = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        let routeTableReadable = routeTableAfter.succeeded
        let remainingRoutes = routeTableReadable
            ? RouteOutputParser.parseRouteTable(routeTableAfter.stdout)
            : []
        if !routeTableReadable {
            warnings.append("无法验证停止后的 IPv4 路由表：\(routeTableAfter.failureReason)")
        }

        let remainingIPv4Routes = routeTableReadable
            ? routesToRemove.filter { spec in
                remainingRoutes.contains { entry in
                    IPv4CIDR.canonical(entry.destination) == IPv4CIDR.canonical(spec.cidr)
                        && entry.gateway == spec.gateway
                        && entry.interfaceName == spec.interfaceName
                }
            }
            : routesToRemove
        if !remainingIPv4Routes.isEmpty, ipv4Result.success {
            warnings.append("停止后仍有 \(remainingIPv4Routes.count) 条受管 IPv4 路由")
        }

        let remainingEndpointRoutes = routeTableReadable
            ? previousState.managedExitNodeEndpointRoutes.filter { spec in
                remainingRoutes.contains { entry in
                    IPv4CIDR.canonical(entry.destination) == IPv4CIDR.canonical(spec.cidr)
                        && entry.gateway == spec.gateway
                        && entry.interfaceName == spec.interfaceName
                }
            }
            : previousState.managedExitNodeEndpointRoutes
        if !remainingEndpointRoutes.isEmpty, endpointResult.warnings.isEmpty {
            warnings.append("停止后仍有 \(remainingEndpointRoutes.count) 条受管 Exit Node 端点路由")
        }

        let remainingDNSServerRoutes = routeTableReadable
            ? previousState.managedDNSServerRoutes.filter { spec in
                remainingRoutes.contains { entry in
                    IPv4CIDR.canonical(entry.destination) == IPv4CIDR.canonical(spec.cidr)
                        && entry.gateway == spec.gateway
                        && entry.interfaceName == spec.interfaceName
                }
            }
            : previousState.managedDNSServerRoutes
        if !remainingDNSServerRoutes.isEmpty, dnsServerResult.warnings.isEmpty {
            warnings.append("停止后仍有 \(remainingDNSServerRoutes.count) 条受管 DNS 服务器路由")
        }

        let remainingExternalGatewayRoutes = routeTableReadable
            ? externalGatewayResult.managedRoutes.filter { spec in
                remainingRoutes.contains { entry in
                    remainingExternalNetworkRoute(entry, matches: spec)
                }
            }
            : externalGatewayResult.managedRoutes
        if releaseExternalGatewayRoutes,
           !remainingExternalGatewayRoutes.isEmpty,
           externalGatewayResult.warnings.isEmpty
        {
            warnings.append("停止后仍有 \(remainingExternalGatewayRoutes.count) 条受管外接网段路由")
        }

        let routeCleanupSucceeded = ipv4Result.success
            && routeTableReadable
            && remainingIPv4Routes.isEmpty
            && remainingEndpointRoutes.isEmpty
            && remainingDNSServerRoutes.isEmpty
            && (!releaseExternalGatewayRoutes || remainingExternalGatewayRoutes.isEmpty)
            && ipv6Result.warnings.isEmpty
        let externalGatewayCleanupSucceeded = !releaseExternalGatewayRoutes
            || (routeTableReadable
                && externalGatewayResult.warnings.isEmpty
                && remainingExternalGatewayRoutes.isEmpty
                && externalGatewayResult.pendingRestorations.isEmpty)
        var state = previousState
        let externalProtection: ExternalProtectionStatus
        if restoreTailscalePreferences {
            if externalGatewayCleanupSucceeded {
                externalProtection = restoreExternalSubnetPreferences(state: &state)
            } else {
                externalProtection = ExternalProtectionStatus(
                    networks: externalNetworkDetector.detect(),
                    active: false,
                    message: "外接网段路由尚未确认清理完成，暂不恢复 Tailscale 原设置",
                    warnings: ["外接网段路由清理未确认完成，保留 Tailscale 偏好恢复记录"]
                )
            }
        } else if releaseExternalGatewayRoutes {
            externalProtection = ExternalProtectionStatus(
                networks: externalNetworkDetector.detect(),
                active: nil,
                message: "外接网段保护路由已释放",
                warnings: []
            )
        } else {
            externalProtection = reconcileExternalSubnetProtection(state: &state)
        }
        if restoreTailscalePreferences {
            warnings.append(contentsOf: externalProtection.warnings)
        } else {
            warnings.append(contentsOf: externalProtection.warnings)
            if externalProtection.active == false, externalProtection.warnings.isEmpty {
                warnings.append("外接网段保护状态未确认，保留现有保护账本并等待重试")
            }
        }
        state.updatedAt = Date()
        state.lifecycle = warnings.isEmpty ? .paused : .error
        state.lastError = warnings.first
        // Keep failed ownership records so a later Stop/Quit can retry. The
        // delete routines tolerate routes that a previous attempt removed.
        state.appliedRouteCount = remainingIPv4Routes.count
        state.managedRoutes = remainingIPv4Routes
        state.managedDomainIPv4Routes = previousState.managedDomainIPv4Routes.filter { domainRoute in
            remainingIPv4Routes.contains(domainRoute.route)
        }
        state.managedIPv6Routes = ipv6Result.warnings.isEmpty
            ? []
            : (ipv6Result.managedRoutes.isEmpty ? previousState.managedIPv6Routes : ipv6Result.managedRoutes)
        state.managedDomainIPv6Routes = ipv6Result.warnings.isEmpty
            ? []
            : previousState.managedDomainIPv6Routes.filter { domainRoute in
                state.managedIPv6Routes.contains(domainRoute.route)
            }
        state.managedExitNodeEndpointRoutes = remainingEndpointRoutes
        state.managedDNSServerRoutes = remainingDNSServerRoutes
        if releaseExternalGatewayRoutes {
            state.managedExternalGatewayRoutes = remainingExternalGatewayRoutes
            state.pendingExternalRouteRestorations = externalGatewayResult.pendingRestorations
        }
        if routeCleanupSucceeded {
            state.externalAdoptionEnabled = false
        }
        do {
            state = try saveState(state)
        } catch {
            warnings.append("保存路由清理状态失败：\(error.localizedDescription)")
            state.lifecycle = .error
            state.lastError = warnings.first
            rememberUnsavedState(state)
        }
        // An explicit restore/quit releases external protection. The observed
        // network may still be present, so retaining its snapshot key would
        // make the next explicit enable look unchanged and skip rebuilding the
        // protection lease/routes. Clear the baseline only after cleanup was
        // authoritatively confirmed; failed cleanup keeps it for retry.
        if releaseExternalGatewayRoutes, externalGatewayCleanupSucceeded {
            clearExternalSnapshotKey()
        }
        let success = warnings.isEmpty
        progress?(RouteProgress(completed: 1, total: 1, message: "受管理路由清理完成"))
        let message = success
            ? "已停止分流：移除 \(removedCount) 条受管理路由，物理网关与 Tailscale 基础路由保持不变"
            : "部分受管理路由清理失败：\(warnings.first ?? "未知原因")"
        let notices = restoreTailscalePreferences ? [] : externalProtection.warnings
        let completeMessage = notices.isEmpty ? message : "\(message)；\(notices.joined(separator: "；"))"
        if success {
            logger.info("停止分流成功：精确移除 \(removedCount) 条受管理路由，保留物理与 Tailscale 基础路由")
        } else {
            logger.error(completeMessage)
        }
        return HelperResponse(
            requestID: request.requestID,
            success: success,
            message: completeMessage,
            report: diagnosticReport(protection: externalProtection),
            state: state,
            operation: RouteOperationResult(
                success: success,
                state: state.lifecycle,
                appliedCount: 0,
                removedCount: removedCount,
                failedCount: success ? 0 : warnings.count,
                lastError: success ? nil : warnings.first,
                warnings: warnings + notices,
                verifiedTargets: []
            ),
            layeredStatus: LayeredOperationStatus(
                route: routeCleanupSucceeded ? .ok : .failed,
                externalProtection: releaseExternalGatewayRoutes
                    ? (externalGatewayCleanupSucceeded ? .ok : .failed)
                    : (externalProtection.active == true ? .ok : externalProtection.active == false ? .failed : .notEvaluated),
                domainResolution: ipv6Result.warnings.isEmpty ? .notEvaluated : .degraded,
                overall: success ? .ok : .failed
            )
        )
    }

    private func killSwitchResponse(_ request: HelperRequest) -> HelperResponse? {
        let status: KillSwitchStatus
        switch request.action {
        case .killSwitchStatus:
            status = killSwitch.status()
        case .enableKillSwitch:
            status = killSwitch.setEnabled(true)
        case .disableKillSwitch:
            status = killSwitch.setEnabled(false)
        case .releaseKillSwitch:
            status = killSwitch.release(reason: "已手动解除断网保护")
        default:
            return nil
        }
        return HelperResponse(
            requestID: request.requestID,
            success: true,
            message: status.message,
            killSwitch: status
        )
    }

    private func restoreDefault(_ request: HelperRequest) -> HelperResponse {
        // Restoring system defaults also turns the kill switch off.
        _ = killSwitch.setEnabled(false)
        // Remove only project-managed routes; the physical default route and
        // Tailscale's base routes stay untouched.
        let pauseResponse = pause(
            request,
            progress: nil,
            restoreTailscalePreferences: true,
            releaseExternalGatewayRoutes: true
        )
        guard pauseResponse.success else {
            return HelperResponse(
                requestID: request.requestID,
                success: false,
                message: "恢复默认前清理受管理路由失败：\(pauseResponse.message)",
                report: diagnosticReport(),
                state: loadState(),
                operation: RouteOperationResult(
                    success: false,
                    state: .error,
                    appliedCount: 0,
                    removedCount: 0,
                    failedCount: 1,
                    lastError: pauseResponse.message,
                    warnings: [],
                    verifiedTargets: []
                ),
                layeredStatus: pauseResponse.layeredStatus ?? LayeredOperationStatus(
                    route: .failed,
                    externalProtection: .unknown,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }

        do {
            // Restoring the network defaults must not erase user intent. Keep
            // the configured domains and China source for the next enable;
            // only mark routing disabled and remove generated route output.
            var preservedConfiguration = request.configuration ?? store.loadConfiguration()
            preservedConfiguration.enabled = false
            try store.clearGeneratedFiles()
            var state = PersistedRouteState(
                lifecycle: .disabled,
                tailscalePreferenceLease: pauseResponse.state?.tailscalePreferenceLease,
                externalAdoptionEnabled: false
            )
            state = try saveState(state)
            try store.saveConfiguration(preservedConfiguration)

            let operation = RouteOperationResult(
                success: true,
                state: .disabled,
                appliedCount: 0,
                removedCount: pauseResponse.operation?.removedCount ?? 0,
                failedCount: 0,
                lastError: nil,
                warnings: [],
                verifiedTargets: []
            )
            logger.info("已恢复系统默认：精确移除受管理路由并清理配置缓存，物理与 Tailscale 基础路由保留")
            return HelperResponse(
                requestID: request.requestID,
                success: true,
                message: "已恢复系统默认：受管理分流路由已移除，配置缓存已清理；物理网关与 Tailscale 基础路由保持不变",
                report: diagnosticReport(),
                state: state,
                operation: operation
            )
        } catch {
            let message = "路由已删除，但清理 tailscale-route 状态失败：\(error.localizedDescription)"
            logger.error(message)
            return HelperResponse(
                requestID: request.requestID,
                success: false,
                message: message,
                report: diagnosticReport(),
                state: loadState(),
                operation: RouteOperationResult(
                    success: false,
                    state: .error,
                    appliedCount: 0,
                    removedCount: 0,
                    failedCount: 1,
                    lastError: message,
                    warnings: [],
                    verifiedTargets: []
                ),
                layeredStatus: LayeredOperationStatus(
                    route: .failed,
                    externalProtection: .unknown,
                    domainResolution: .notEvaluated,
                    overall: .failed
                )
            )
        }
    }

    private struct ExternalProtectionStatus {
        let networks: [ExternalDirectNetwork]
        let active: Bool?
        let message: String
        let warnings: [String]
    }

    private func diagnosticReport(protection: ExternalProtectionStatus? = nil) -> DiagnosticReport {
        let base = DiagnosticService(
            runner: runner,
            desiredTargetsURL: paths.desiredCIDRs,
            desiredMetadataURL: paths.desiredMetadata
        ).run()
        guard let protection else { return base }
        return DiagnosticReport(
            generatedAt: base.generatedAt,
            snapshot: base.snapshot,
            managedTargets: base.managedTargets,
            actualRoutes: base.actualRoutes,
            actualIPv6Routes: base.actualIPv6Routes,
            tailscale: base.tailscale,
            externalDirectNetworks: protection.networks,
            externalSubnetProtectionActive: protection.active,
            externalSubnetProtectionMessage: protection.message,
            warnings: base.warnings + protection.warnings,
            errors: base.errors
        )
    }

    private func reconcileExternalSubnetProtection(
        state: inout PersistedRouteState,
        detection suppliedDetection: ExternalDirectNetworkDetection? = nil
    ) -> ExternalProtectionStatus {
        let detection = suppliedDetection ?? externalNetworkDetector.scan()
        var warnings: [String] = []
        if let warning = detection.warning { warnings.append("外接网段检测失败：\(warning)") }

        guard detection.isAuthoritative else {
            return ExternalProtectionStatus(
                networks: detection.networks,
                active: nil,
                message: "无法确认外接网卡状态，暂不更改 Tailscale 设置",
                warnings: warnings
            )
        }

        let externalGatewayProtection = reconcileExternalNetworkRoutes(
            networks: detection.networks,
            state: &state,
            warnings: &warnings
        )

        if detection.networks.isEmpty {
            guard externalGatewayProtection.warnings.isEmpty else {
                return ExternalProtectionStatus(
                    networks: [],
                    active: false,
                    message: "外接网段路由尚未确认清理完成，暂不恢复 Tailscale 原设置",
                    warnings: warnings
                )
            }
            guard state.tailscalePreferenceLease != nil else {
                return ExternalProtectionStatus(networks: [], active: nil, message: "未连接外接网卡", warnings: warnings)
            }
            return restoreExternalSubnetPreferences(state: &state)
        }

        guard externalGatewayProtection.warnings.isEmpty else {
            return ExternalProtectionStatus(
                networks: detection.networks,
                active: false,
                message: "外接网段路由未验证通过",
                warnings: warnings
            )
        }

        let lookup = verifyExternalNetworkEgress(detection.networks)
        if let lease = state.tailscalePreferenceLease {
            let current = inspector.readTailscalePreferences()
            guard let preferences = current.preferences else {
                warnings.append(current.failure ?? "无法读取 Tailscale 偏好")
                return ExternalProtectionStatus(networks: detection.networks, active: false, message: "无法确认 Tailscale 自动保护状态", warnings: warnings)
            }
            guard Self.leaseIdentityMatches(lease, preferences) else {
                warnings.append("Tailscale 登录身份已变化，保留原设置恢复记录；请切回原尾网后再恢复")
                return ExternalProtectionStatus(
                    networks: detection.networks,
                    active: false,
                    message: "Tailscale 身份已变化，暂不覆盖新身份的设置",
                    warnings: warnings
                )
            }
            guard preferences.routeAll == false else {
                state.tailscalePreferenceLease = nil
                state.updatedAt = Date()
                if let saved = try? saveState(state) { state = saved }
                return ExternalProtectionStatus(networks: detection.networks, active: lookup.allCorrect, message: "Tailscale 设置已变化，停止自动接管", warnings: [])
            }
            if !lookup.mismatches.isEmpty,
               lease.managedLANAccess != true,
               preferences.exitNodeID?.isEmpty == false,
               preferences.allowLANAccess != true
            {
                let updatedLease = TailscalePreferenceLease(
                    originalAcceptRoutes: lease.originalAcceptRoutes,
                    originalAllowLANAccess: lease.originalAllowLANAccess,
                    managedLANAccess: true,
                    exitNodeID: preferences.exitNodeID,
                    tailnetControlURL: lease.tailnetControlURL,
                    nodeID: lease.nodeID ?? preferences.nodeID,
                    startedAt: lease.startedAt
                )
                state.tailscalePreferenceLease = updatedLease
                state.updatedAt = Date()
                do {
                    state = try saveState(state)
                } catch {
                    return ExternalProtectionStatus(
                        networks: detection.networks,
                        active: false,
                        message: "保存 Tailscale 设置恢复记录失败",
                        warnings: [error.localizedDescription]
                    )
                }
                let changed = inspector.setTailscalePreferences(acceptRoutes: nil, allowLANAccess: true)
                guard changed.succeeded else {
                    var rollbackState = state
                    rollbackState.tailscalePreferenceLease = lease
                    if let saved = try? saveState(rollbackState) { state = saved }
                    return ExternalProtectionStatus(
                        networks: detection.networks,
                        active: false,
                        message: "无法暂时启用 Exit Node LAN access",
                        warnings: [changed.failureReason]
                    )
                }

                var updatedPreferences: TailscalePrefsSnapshot?
                var verified = (allCorrect: false, mismatches: [String](), unknown: [String]())
                var gatewayProtection = externalGatewayProtection
                for _ in 0..<8 {
                    Thread.sleep(forTimeInterval: 0.5)
                    updatedPreferences = inspector.readTailscalePreferences().preferences
                    gatewayProtection = reconcileExternalNetworkRoutes(
                        networks: detection.networks,
                        state: &state,
                        warnings: &warnings
                    )
                    verified = verifyExternalNetworkEgress(detection.networks)
                    if updatedPreferences?.allowLANAccess == true,
                       gatewayProtection.warnings.isEmpty,
                       verified.allCorrect
                    { break }
                }
                let active = updatedPreferences?.routeAll == false
                    && updatedPreferences?.allowLANAccess == true
                    && gatewayProtection.warnings.isEmpty
                    && verified.allCorrect
                let message = active
                    ? "已生效：外接网段走物理网卡；Exit Node 默认路由保持连接，子网路由接收暂停，LAN access 已启用"
                    : "Exit Node LAN access 已暂时启用，但仍有地址未走外接网卡：\((verified.mismatches + verified.unknown).joined(separator: ", "))"
                return ExternalProtectionStatus(networks: detection.networks, active: active, message: message, warnings: warnings)
            }
            if let managedLANAccess = lease.managedLANAccess,
               preferences.allowLANAccess != managedLANAccess
            {
                warnings.append("Tailscale LAN access 已在 App 之外更改，保留原设置恢复记录")
            }
            let active = lookup.allCorrect && preferences.routeAll == false
                && (lease.managedLANAccess == nil || preferences.allowLANAccess == lease.managedLANAccess)
            let message = active
                ? "已生效：外接网段走物理网卡；Exit Node 默认路由保持连接，子网路由接收暂时关闭"
                : "Tailscale 子网路由已暂停，但仍有地址未走外接网卡：\(lookup.mismatches.joined(separator: ", "))"
            return ExternalProtectionStatus(networks: detection.networks, active: active, message: message, warnings: warnings)
        }

        guard !lookup.mismatches.isEmpty else {
            let active = lookup.allCorrect
            return ExternalProtectionStatus(
                networks: detection.networks,
                active: active,
                message: active ? "已生效：外接网段走物理网卡" : "正在验证外接网段实际出口",
                warnings: lookup.unknown.isEmpty ? warnings : warnings + ["无法验证部分地址：\(lookup.unknown.joined(separator: ", "))"]
            )
        }

        let current = inspector.readTailscalePreferences()
        guard let preferences = current.preferences, preferences.routeAll == true else {
            warnings.append(current.failure ?? "Tailscale 未接收子网路由，当前冲突无法通过自动协调修复")
            return ExternalProtectionStatus(
                networks: detection.networks,
                active: false,
                message: "外接网段路由冲突：\(lookup.mismatches.joined(separator: ", "))",
                warnings: warnings
            )
        }

        let managedLANAccess = preferences.exitNodeID?.isEmpty == false
            ? true
            : nil
        let lease = TailscalePreferenceLease(
            originalAcceptRoutes: preferences.routeAll ?? true,
            originalAllowLANAccess: preferences.allowLANAccess ?? false,
            managedLANAccess: managedLANAccess,
            exitNodeID: preferences.exitNodeID,
            tailnetControlURL: preferences.controlURL,
            nodeID: preferences.nodeID
        )
        state.tailscalePreferenceLease = lease
        state.updatedAt = Date()
        do {
            state = try saveState(state)
        } catch {
            warnings.append("保存 Tailscale 偏好恢复记录失败：\(error.localizedDescription)")
            return ExternalProtectionStatus(networks: detection.networks, active: false, message: "自动保护尚未应用", warnings: warnings)
        }

        let changed = inspector.setTailscalePreferences(acceptRoutes: false, allowLANAccess: managedLANAccess)
        guard changed.succeeded else {
            warnings.append("关闭 Tailscale 子网路由接收失败：\(changed.failureReason)")
            let rollback = restoreExternalSubnetPreferences(state: &state)
            warnings.append(contentsOf: rollback.warnings)
            return ExternalProtectionStatus(networks: detection.networks, active: false, message: "自动保护失败，已尝试恢复 Tailscale 原设置", warnings: warnings)
        }

        var updatedPreferences: TailscalePrefsSnapshot?
        var verified = (allCorrect: false, mismatches: [String](), unknown: [String]())
        var gatewayProtection = externalGatewayProtection
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.5)
            updatedPreferences = inspector.readTailscalePreferences().preferences
            gatewayProtection = reconcileExternalNetworkRoutes(
                networks: detection.networks,
                state: &state,
                warnings: &warnings
            )
            verified = verifyExternalNetworkEgress(detection.networks)
            if updatedPreferences?.routeAll == false,
               updatedPreferences?.allowLANAccess == (managedLANAccess ?? preferences.allowLANAccess),
               gatewayProtection.warnings.isEmpty,
               verified.allCorrect { break }
        }
        guard updatedPreferences?.routeAll == false,
              updatedPreferences?.allowLANAccess == (managedLANAccess ?? preferences.allowLANAccess),
              gatewayProtection.warnings.isEmpty,
              verified.allCorrect else {
            warnings.append("Tailscale 设置变更后出口验证失败：\((verified.mismatches + verified.unknown).joined(separator: ", "))")
            let rollback = restoreExternalSubnetPreferences(state: &state)
            warnings.append(contentsOf: rollback.warnings)
            return ExternalProtectionStatus(networks: detection.networks, active: false, message: "自动保护未通过路由验证，已尝试恢复 Tailscale 原设置", warnings: warnings)
        }

        return ExternalProtectionStatus(
            networks: detection.networks,
            active: true,
            message: managedLANAccess == true
                ? "已生效：外接网段走物理网卡；Exit Node 默认路由保持连接，子网路由接收暂停，LAN access 已启用"
                : "已生效：外接网段走物理网卡；Exit Node 默认路由保持连接，子网路由接收暂时关闭",
            warnings: []
        )
    }

    private func shouldReconcileExternalProtection(
        for detection: ExternalDirectNetworkDetection
    ) -> Bool {
        let decision = NetworkReconciliationPolicy.externalProtectionDecision(
            previousKey: loadExternalSnapshotKey(),
            detection: detection
        )
        switch decision {
        case .establishBaseline, .writeCandidate:
            return true
        case .deferUntilAuthoritativeScan, .unchanged:
            return false
        }
    }

    private func retainedExternalProtectionStatus(
        detection: ExternalDirectNetworkDetection,
        state: PersistedRouteState
    ) -> ExternalProtectionStatus {
        guard detection.isAuthoritative else {
            return ExternalProtectionStatus(
                networks: detection.networks,
                active: nil,
                message: "无法确认外接网卡状态，保留现有保护且不写入",
                warnings: detection.warning.map { ["外接网段检测失败：\($0)"] } ?? []
            )
        }
        let hasRetainedProtection = !state.managedExternalGatewayRoutes.isEmpty
            || state.tailscalePreferenceLease != nil
        let active = detection.networks.isEmpty ? nil : (hasRetainedProtection ? true : false)
        return ExternalProtectionStatus(
            networks: detection.networks,
            active: active,
            message: "外接网卡快照未变化，保留现有保护，不写入外接路由",
            warnings: []
        )
    }

    private func loadExternalSnapshotKey() -> ExternalNetworkSnapshotKey? {
        try? store.read(ExternalNetworkSnapshotKey.self, from: externalSnapshotKeyURL)
    }

    private func clearExternalSnapshotKey() {
        do {
            try store.remove(externalSnapshotKeyURL)
        } catch {
            logger.warning("清理外接网卡快照基线失败；下次显式操作将重新验证：\(error.localizedDescription)")
        }
    }

    private func persistExternalSnapshotKeyIfSuccessful(
        detection: ExternalDirectNetworkDetection,
        protection: ExternalProtectionStatus
    ) {
        guard detection.isAuthoritative,
              protection.warnings.isEmpty,
              protection.active != false
        else { return }
        do {
            try store.write(
                ExternalNetworkSnapshotKey(networks: detection.networks),
                to: externalSnapshotKeyURL
            )
        } catch {
            logger.warning("保存外接网卡快照键失败；下次对账将再次验证：\(error.localizedDescription)")
        }
    }

    /// The current TargetListBuilder API falls back to its loader when the
    /// cache is stale. Until that API grows an explicit cache-only mode, the
    /// Helper performs the read-only cache-integrity/source-identity gate here and only
    /// then calls the existing builder.
    private func requireUsableChinaListCache(
        for configuration: TailscaleRouteConfiguration
    ) throws {
        guard let sourceURL = configuration.chinaListURL else { return }
        guard let cache = try? store.read(ChinaCIDRCache.self, from: paths.chinaCache),
              cache.metadata.formatVersion == CIDRSourceMetadata.currentFormatVersion,
              cache.metadata.sourceURL == sourceURL.absoluteString,
              cache.metadata.entryCount == cache.cidrs.count,
              cache.metadata.rejectedLineCount >= 0,
              cache.cidrs.count > 0,
              cache.cidrs.count <= 100_000,
              cache.cidrs.allSatisfy({ IPv4CIDR.canonical($0) == $0 }),
              cache.metadata.sourceSHA256.count == 64,
              cache.metadata.cidrSHA256 == hashCIDRs(cache.cidrs)
        else {
            throw HelperServiceError.manualChinaListUpdateRequired
        }
    }

    private func hashCIDRs(_ cidrs: [String]) -> String {
        let canonical = cidrs.compactMap { IPv4CIDR.canonical($0) }
            .sorted()
            .joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func reconcileExternalNetworkRoutes(
        networks: [ExternalDirectNetwork],
        state: inout PersistedRouteState,
        warnings: inout [String]
    ) -> ExternalGatewayRouteProtectionResult {
        let result = externalNetworkRouteProtector.reconcile(
            networks: networks,
            previouslyManaged: state.managedExternalGatewayRoutes,
            pendingRestorations: state.pendingExternalRouteRestorations
        )
        warnings.append(contentsOf: result.warnings)
        if state.managedExternalGatewayRoutes != result.managedRoutes
            || state.pendingExternalRouteRestorations != result.pendingRestorations
        {
            state.managedExternalGatewayRoutes = result.managedRoutes
            state.pendingExternalRouteRestorations = result.pendingRestorations
            state.updatedAt = Date()
            do {
                state = try saveState(state)
            } catch {
                warnings.append("保存外接网段路由恢复记录失败：\(error.localizedDescription)")
            }
        }
        return result
    }

    private func remainingExternalNetworkRoute(_ entry: RouteEntry, matches spec: RouteSpec) -> Bool {
        guard IPv4CIDR.canonical(entry.destination) == IPv4CIDR.canonical(spec.cidr),
              entry.interfaceName == spec.interfaceName,
              let cidr = IPv4CIDR.parse(spec.cidr)
        else { return false }
        if cidr.prefixLength == 32 {
            return entry.gateway == spec.gateway
        }
        // macOS renders a direct `route -interface <local-ip>` network route
        // with a link# gateway. The local IP is retained in RouteSpec for the
        // reversible delete command, so it cannot be compared to netstat's
        // gateway field here.
        return entry.flags.contains("S")
            && !entry.flags.contains("G")
            && !entry.flags.contains("I")
    }

    /// Whether the current Tailscale login is the one the lease was taken on.
    /// NodeID identifies the login and stays stable when the user switches or
    /// turns off the Exit Node, so a changed Exit Node no longer blocks the
    /// restore forever. Leases from older versions (no NodeID) and Tailscale
    /// builds whose `debug prefs` lacks NodeID keep the previous ExitNodeID
    /// comparison.
    static func leaseIdentityMatches(
        _ lease: TailscalePreferenceLease,
        _ preferences: TailscalePrefsSnapshot
    ) -> Bool {
        guard preferences.controlURL == lease.tailnetControlURL else { return false }
        if let leaseNodeID = lease.nodeID, !leaseNodeID.isEmpty,
           let currentNodeID = preferences.nodeID, !currentNodeID.isEmpty
        {
            return leaseNodeID == currentNodeID
        }
        return preferences.exitNodeID == lease.exitNodeID
    }

    private func restoreExternalSubnetPreferences(state: inout PersistedRouteState) -> ExternalProtectionStatus {
        let networks = externalNetworkDetector.detect()
        guard let lease = state.tailscalePreferenceLease else {
            return ExternalProtectionStatus(networks: networks, active: nil, message: "没有待恢复的 Tailscale 设置", warnings: [])
        }
        let current = inspector.readTailscalePreferences()
        guard let preferences = current.preferences else {
            return ExternalProtectionStatus(networks: networks, active: nil, message: "等待恢复 Tailscale 原设置", warnings: [current.failure ?? "无法读取 Tailscale 偏好"])
        }
        guard Self.leaseIdentityMatches(lease, preferences) else {
            return ExternalProtectionStatus(
                networks: networks,
                active: false,
                message: "Tailscale 登录身份已变化，保留原设置恢复记录；请切回原尾网后再恢复",
                warnings: ["未覆盖新身份的 Tailscale 设置"]
            )
        }
        let acceptRoutes = preferences.routeAll == false ? lease.originalAcceptRoutes : nil
        let allowLANAccess = lease.managedLANAccess != nil
            && preferences.allowLANAccess == lease.managedLANAccess
            ? lease.originalAllowLANAccess
            : nil
        if acceptRoutes != nil || allowLANAccess != nil {
            let result = inspector.setTailscalePreferences(acceptRoutes: acceptRoutes, allowLANAccess: allowLANAccess)
            guard result.succeeded else {
                return ExternalProtectionStatus(networks: networks, active: false, message: "恢复 Tailscale 原设置失败，等待重试", warnings: [result.failureReason])
            }
            let verification = inspector.readTailscalePreferences()
            guard let updated = verification.preferences else {
                return ExternalProtectionStatus(networks: networks, active: false, message: "恢复 Tailscale 原设置后无法读回确认，等待重试", warnings: [verification.failure ?? "无法读取 Tailscale 偏好"])
            }
            guard updated.routeAll == (acceptRoutes ?? preferences.routeAll),
                  updated.allowLANAccess == (allowLANAccess ?? preferences.allowLANAccess)
            else {
                return ExternalProtectionStatus(networks: networks, active: false, message: "恢复 Tailscale 原设置后读回不一致，等待重试", warnings: ["Tailscale 偏好未按预期恢复"])
            }
        }
        state.tailscalePreferenceLease = nil
        state.updatedAt = Date()
        do {
            state = try saveState(state)
        } catch {
            return ExternalProtectionStatus(networks: networks, active: false, message: "偏好已恢复，但恢复记录保存失败", warnings: [error.localizedDescription])
        }
        return ExternalProtectionStatus(networks: networks, active: nil, message: "已恢复 Tailscale 原设置", warnings: [])
    }

    private func verifyExternalNetworkEgress(_ networks: [ExternalDirectNetwork]) -> (allCorrect: Bool, mismatches: [String], unknown: [String]) {
        var mismatches: [String] = []
        var unknown: [String] = []
        let routeSnapshot = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        let routes = routeSnapshot.succeeded ? RouteOutputParser.parseRouteTable(routeSnapshot.stdout) : []
        guard routeSnapshot.succeeded else {
            return (false, [], ["无法读取 IPv4 路由表：\(routeSnapshot.failureReason)"])
        }
        for network in networks {
            guard let cidr = IPv4CIDR.parse(network.cidr) else { continue }
            var probes: Set<UInt32> = []
            if cidr.prefixLength == 32 {
                probes.insert(cidr.network)
            } else if cidr.prefixLength == 31 {
                probes.insert(cidr.network)
                probes.insert(cidr.lastAddress)
            } else {
                // Do not use the network/broadcast addresses as route probes:
                // macOS may resolve those special addresses via the default
                // route even though all usable hosts use the external CIDR.
                probes.insert(cidr.network + 1)
                probes.insert(cidr.lastAddress - 1)
                probes.insert(cidr.network + (cidr.lastAddress - cidr.network) / 2)
            }
            if let ownAddress = IPv4CIDR.parseAddress(network.address) { probes.insert(ownAddress) }
            var conflictingRoutes = Set<String>()
            for route in routes {
                guard let overlapping = IPv4CIDR.parse(route.destination),
                      overlapping.prefixLength >= cidr.prefixLength,
                      overlapping.overlaps(cidr)
                else { continue }
                if route.interfaceName != network.interfaceName {
                    // A Tailscale/utun cloned host route may remain in the
                    // table after the explicit physical gateway route wins.
                    // It is harmless when the kernel's actual lookup already
                    // selects the external interface; only report routes that
                    // still win selection for their own destination.
                    if route.flags.contains("H") {
                        let address = IPv4CIDR.string(from: overlapping.network)
                        let selectedResult = runner.run("/sbin/route", arguments: ["-n", "get", address])
                        if selectedResult.succeeded,
                           RouteOutputParser.parseRouteGetEntry(selectedResult.stdout)?.interfaceName == network.interfaceName
                        {
                            continue
                        }
                    }
                    conflictingRoutes.insert("\(overlapping.description)→\(route.interfaceName)")
                }
            }
            if !conflictingRoutes.isEmpty {
                let samples = conflictingRoutes.sorted().prefix(8).joined(separator: ", ")
                let remaining = conflictingRoutes.count - min(conflictingRoutes.count, 8)
                let suffix = remaining == 0 ? "" : "，另有 \(remaining) 条"
                mismatches.append("检测到其它接口上的重叠路由：\(samples)\(suffix)")
            }
            for value in probes {
                let address = IPv4CIDR.string(from: value)
                let lookup = runner.run("/sbin/route", arguments: ["-n", "get", address])
                guard lookup.succeeded,
                      let selected = RouteOutputParser.parseRouteGetEntry(lookup.stdout)?.interfaceName
                else {
                    unknown.append("\(address) (\(network.interfaceName))")
                    continue
                }
                if selected != network.interfaceName {
                    mismatches.append("\(address)→\(selected)，应为\(network.interfaceName)")
                }
            }
        }
        return (mismatches.isEmpty && unknown.isEmpty, mismatches, unknown)
    }

    private func externalDirectCIDRs() -> [IPv4CIDR] {
        let detection = externalNetworkDetector.scan()
        guard detection.isAuthoritative else { return [] }
        return detection.networks.compactMap { IPv4CIDR.parse($0.cidr) }
    }

    private func inspectStableNetwork() throws -> (
        snapshot: NetworkSnapshot,
        tailscale: TailscaleStatusSummary,
        warnings: [String],
        errors: [String],
        actualRoutes: [RouteEntry]
    ) {
        let first = inspector.inspect()
        guard first.errors.isEmpty else { return first }
        Thread.sleep(forTimeInterval: 0.35)
        let second = inspector.inspect()
        guard first.snapshot.fingerprint == second.snapshot.fingerprint else {
            throw HelperServiceError.networkUnstable
        }
        return second
    }

    private func managedRoutesForOperation(
        _ state: PersistedRouteState,
        report: DiagnosticReport
    ) -> [RouteSpec] {
        let persisted = (state.managedRoutes + state.managedDomainIPv4Routes.map(\.route)).filter {
            IPv4CIDR.parse($0.cidr) != nil
                && IPv4CIDR.parseAddress($0.gateway) != nil
                && !$0.interfaceName.isEmpty
        }

        guard state.externalAdoptionEnabled else { return persisted }

        // Adopt only routes that match the current target list and physical
        // gateway, then merge with the exact persisted ownership triples.
        // This also recovers a partially recorded legacy route set safely.
        return Array(Set(persisted + detectedTargetRoutes(report)))
            .sorted {
                if $0.cidr != $1.cidr { return $0.cidr < $1.cidr }
                if $0.gateway != $1.gateway { return $0.gateway < $1.gateway }
                return $0.interfaceName < $1.interfaceName
            }
    }

    private func reconcileDetectedRoutes(report: DiagnosticReport) -> PersistedRouteState {
        var state = loadState()
        guard state.externalAdoptionEnabled else { return state }

        let detected = detectedTargetRoutes(report)
        guard !detected.isEmpty else {
            if state.managedRoutes.isEmpty,
               state.lifecycle == .enabled || state.lifecycle == .partial
            {
                state.lifecycle = .disabled
                state.appliedRouteCount = 0
                state.updatedAt = Date()
                if let savedState = try? saveState(state) { state = savedState }
            }
            return state
        }

        guard state.managedRoutes.isEmpty else { return state }
        let targetCount = Set(report.managedTargets.compactMap { IPv4CIDR.canonical($0) }).count
        let matchedCount = detected.count
        state.managedRoutes = detected
        state.appliedRouteCount = matchedCount
        state.lifecycle = targetCount > 0 && matchedCount == targetCount ? .enabled : .partial
        state.lastError = nil
        if state.lifecycle == .enabled {
            state.lastSuccessAt = Date()
            state.lastSuccessFingerprint = report.snapshot.fingerprint
        }
        state.updatedAt = Date()
        if let savedState = try? saveState(state) { state = savedState }
        logger.info("检测到并接管现有目标路由：\(detected.count) 条")
        return state
    }

    private func detectedTargetRoutes(_ report: DiagnosticReport) -> [RouteSpec] {
        let ipv4Routes: [RouteSpec]
        if let gateway = report.snapshot.gateway,
           let interfaceName = report.snapshot.physicalInterface
        {
            let targets = Set(report.managedTargets.compactMap { IPv4CIDR.canonical($0) })
            var seen = Set<String>()
            ipv4Routes = report.actualRoutes.compactMap { route in
                guard route.destination != "default",
                      route.interfaceName == interfaceName,
                      route.gateway == gateway,
                      let cidr = IPv4CIDR.canonical(route.destination),
                      targets.contains(cidr),
                      seen.insert(cidr).inserted
                else { return nil }
                return RouteSpec(cidr: cidr, gateway: gateway, interfaceName: interfaceName)
            }
        } else {
            ipv4Routes = []
        }

        return ipv4Routes
    }

    private func failedResponse(
        requestID: UUID,
        message: String,
        report: DiagnosticReport? = nil,
        layeredStatus: LayeredOperationStatus? = nil
    ) -> HelperResponse {
        var state = loadState()
        state.lifecycle = .error
        state.lastError = message
        state.updatedAt = Date()
        do {
            state = try saveState(state)
        } catch {
            rememberUnsavedState(state)
        }
        logger.error(message)
        return HelperResponse(
            requestID: requestID,
            success: false,
            message: message,
            report: report ?? diagnosticReport(),
            state: state,
            layeredStatus: layeredStatus
        )
    }

    private func loadTargetList() -> DesiredRouteList? {
        try? store.read(DesiredRouteList.self, from: paths.desiredMetadata)
    }

    /// Pin the resolver DNS servers to the snapshot's physical gateway and
    /// interface, and record ownership immediately so an early return later in
    /// the request cannot orphan the routes. The snapshot follows the active
    /// physical adapter, so switching Wi-Fi ↔ external NIC replaces the pins.
    /// Builds the target list with the DNS servers configured for this
    /// request, so a changed resolver setting applies without a restart.
    private func domainListBuilder(for configuration: TailscaleRouteConfiguration) -> TargetListBuilder {
        TargetListBuilder(
            paths: paths,
            resolver: DirectDNSDomainResolver(runner: runner, servers: configuration.effectiveDNSServers)
        )
    }

    private func pinDNSServers(snapshot: NetworkSnapshot, servers: [String]) -> DNSServerRouteProtectionResult {
        var state = loadState()
        let result = dnsServerRouteProtector.reconcile(
            servers: servers,
            gateway: snapshot.gateway,
            interfaceName: snapshot.physicalInterface,
            previouslyManaged: state.managedDNSServerRoutes
        )
        if state.managedDNSServerRoutes != result.managedRoutes {
            state.managedDNSServerRoutes = result.managedRoutes
            do {
                _ = try saveState(state)
            } catch {
                logger.warning("保存 DNS 服务器路由账本失败：\(error.localizedDescription)")
            }
        }
        if !result.warnings.isEmpty {
            logger.warning(result.warnings.joined(separator: "；"))
        }
        return result
    }

    private func loadState() -> PersistedRouteState {
        stateOverrideLock.lock()
        let override = unsavedStateOverride
        stateOverrideLock.unlock()
        return override ?? store.loadState()
    }

    private func saveState(_ state: PersistedRouteState) throws -> PersistedRouteState {
        do {
            let savedState = try store.saveState(state)
            stateOverrideLock.lock()
            unsavedStateOverride = nil
            stateOverrideLock.unlock()
            return savedState
        } catch {
            rememberUnsavedState(state)
            throw error
        }
    }

    private func rememberUnsavedState(_ state: PersistedRouteState) {
        stateOverrideLock.lock()
        unsavedStateOverride = state
        stateOverrideLock.unlock()
    }
}

private enum HelperServiceError: LocalizedError {
    case networkUnstable
    case manualChinaListUpdateRequired

    var errorDescription: String? {
        switch self {
        case .networkUnstable:
            return "网络仍在变化，已停止重建；请等待连接稳定后重新应用"
        case .manualChinaListUpdateRequired:
            return "中国 IP 清单缓存缺失、来源不匹配或校验失败；请手动点击“更新中国 IP 清单”"
        }
    }
}

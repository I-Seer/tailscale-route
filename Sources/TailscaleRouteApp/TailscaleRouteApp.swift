import AppKit
import TailscaleRouteCore
import Network
import SwiftUI

private enum HelperProtocolError: LocalizedError {
    case mismatch(Int?)

    var errorDescription: String? {
        switch self {
        case .mismatch(let version):
            return "Helper 协议版本不匹配：收到 \(version.map(String.init) ?? "未知")，需要 \(HelperResponse.currentProtocolVersion)"
        }
    }
}

private struct QuitTimeoutError: Error {}

/// Resumes a checked continuation exactly once (first result wins).
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

enum HelperConnectionState: Equatable {
    case unknown
    case ready
    case reloading
    case unavailable

    var title: String {
        switch self {
        case .unknown: return "等待权限助手"
        case .ready: return "权限助手已连接"
        case .reloading: return "正在更新权限助手"
        case .unavailable: return "权限助手未连接"
        }
    }
}

/// Owns the model so every termination path (menu, ⌘Q, Dock, logout,
/// restart) goes through the same cleanup instead of bypassing it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var powerOffObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.systemWillPowerOff() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.terminationReply()
    }
}

@main
struct TailscaleRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            StatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // Keep a real control window as well as the compact menu-bar popover.
        // A double-click on the .app must have visible, discoverable feedback;
        // a menu-bar-only scene otherwise looks like it did nothing.
        WindowGroup("tailscale-route", id: "main") {
            MenuBarView(model: model, presentation: .dashboard)
        }
        .defaultSize(width: 680, height: 860)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出并移除分流路由") {
                    model.quitApp()
                }
                .keyboardShortcut("q")
            }
        }
    }
}

enum AppOperation: Equatable {
    case route(HelperAction)
    case externalProtectionReconcile
    case listUpdate
    case preview
    case domainRefresh

    var isRouteMutation: Bool {
        switch self {
        case .route(let action):
            return [.enable, .reapply, .pause, .shutdown, .restoreDefault].contains(action)
        case .domainRefresh:
            return OperationStatePolicy.domainRefresh.isRouteMutation
        case .externalProtectionReconcile:
            return true
        case .listUpdate, .preview:
            return false
        }
    }
}

struct DomainRefreshState: Equatable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var nextRefreshAt: Date?
    var failureCount = 0
    var resolvedIPv4Count = 0
    var resolvedIPv6Count = 0
    var lastError: String?
    var pending = false
}

struct ChinaListRefreshState: Equatable {
    var isRefreshing = false
    var lastSuccessAt: Date?
    var lastError: String?
    var warning: String?
    var manualUpdateRequired = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var report: DiagnosticReport? {
        didSet { detectedDirectRouteCount = Self.directRouteCount(in: report) }
    }
    /// Recomputed only when a new report arrives instead of on every
    /// SwiftUI body evaluation (the route table can hold thousands of rows).
    private(set) var detectedDirectRouteCount = 0
    @Published private(set) var routeState = PersistedRouteState()
    @Published private(set) var configuration: TailscaleRouteConfiguration
    @Published private(set) var isRefreshing = false
    @Published private(set) var isOperating = false
    @Published private(set) var activeOperation: AppOperation?
    @Published private(set) var helperAvailable = false
    @Published private(set) var helperConnectionState: HelperConnectionState = .unknown
    @Published private(set) var lastMessage: String?
    @Published private(set) var routeProgress: RouteProgress?
    @Published private(set) var listProgress: RouteProgress?
    @Published private(set) var targetList: DesiredRouteList?
    @Published private(set) var layeredStatus: LayeredOperationStatus?
    @Published private(set) var domainRefreshState = DomainRefreshState()
    @Published private(set) var chinaListRefreshState = ChinaListRefreshState()
    @Published private(set) var routePlanPreview: RoutePlanPreview?
    @Published private(set) var connectivityReport: ConnectivityDiagnosticReport?
    @Published private(set) var routeExplanation: RouteExplanation?
    @Published private(set) var isCheckingConnectivity = false
    /// True from the moment the user asks to quit until the App terminates or
    /// the user cancels. Blocks new background operations.
    @Published private(set) var isQuitting = false
    /// Set when quit cleanup did not complete; drives the "quit anyway?" dialog.
    @Published var quitFailureMessage: String?
    /// Once true, applicationShouldTerminate lets the App exit immediately.
    private var terminationApproved = false
    private var systemPoweringOff = false
    /// 断网保护 status from the Helper; nil until the first successful read.
    @Published private(set) var killSwitchStatus: KillSwitchStatus?
    @Published private(set) var killSwitchRequestInFlight = false

    private let paths = TailscaleRoutePaths.user
    private let store: AtomicStore
    private let directDiagnostic: DiagnosticService
    private let helperClients: [UnixHelperClient]
    private let installer = HelperInstaller()
    private let networkMonitor: NetworkChangeMonitor
    private var networkChangeGeneration = 0
    private var networkReconcileTask: Task<Void, Never>?
    private var periodicReconcileTask: Task<Void, Never>?
    private var killSwitchPollTask: Task<Void, Never>?
    private var killSwitchPollInFlight = false
    private var networkRetryAttempt = 0
    private var networkRetryPaused = false
    private var automaticNetworkReconcileInFlight = false
    private var externalProtectionReapplyInFlight = false
    private var externalProtectionRetryAttempt = 0
    private var domainRefreshTask: Task<Void, Never>?
    private var externalProtectionReconcileTask: Task<Void, Never>?
    private var pendingDomainRefresh = false
    private var pendingStatusRefresh = false
    private var pendingExternalProtectionReconcile = false
    private var pendingExternalProtectionRequiresAutoFollow = false
    private var networkReapplyPending = false
    private var pendingNetworkChangeReason: NetworkChangeReason?
    private var suppressRouteEventsUntil: Date?
    private var didRequestHelperRegistration = false
    private var didRequestHelperReload = false
    private var helperRecoveryTask: Task<Void, Never>?
    private var helperProtocolReady = false
    private var lastTrustedRouteState = PersistedRouteState()
    private var lastTrustedReport: DiagnosticReport?
    private var lastTrustedTargetList: DesiredRouteList?
    private var lastExternalSnapshotKey: ExternalNetworkSnapshotKey?

    var isBusy: Bool {
        isRefreshing || activeOperation != nil
    }

    init() {
        let store = AtomicStore(paths: .user)
        self.store = store
        try? store.migrateStateIfNeeded()
        try? store.removeObsoleteGeneratedFiles()
        let savedConfiguration = store.loadConfiguration()
        var normalizedConfiguration = savedConfiguration
        normalizedConfiguration.domainNames = Array(Set(savedConfiguration.domainNames.map(Self.canonicalRoutingDomain)))
            .sorted()
        self.configuration = normalizedConfiguration
        self.lastTrustedRouteState = store.loadState()
        // Re-encode on every launch so unknown fields from retired config
        // versions (for example the old manual local-subnet list) do not
        // survive as misleading configuration state. Known domains, China
        // source and user exclusions are preserved by the Codable model.
        try? store.saveConfiguration(normalizedConfiguration)
        self.directDiagnostic = DiagnosticService(
            desiredTargetsURL: TailscaleRoutePaths.user.desiredCIDRs,
            desiredMetadataURL: TailscaleRoutePaths.user.desiredMetadata
        )
        self.helperClients = [
            UnixHelperClient(socketPath: "/var/run/tailscale-route-helper.sock"),
            UnixHelperClient()
        ]
        self.networkMonitor = NetworkChangeMonitor()
        self.lastTrustedTargetList = try? store.read(DesiredRouteList.self, from: store.paths.desiredMetadata)
        self.targetList = self.lastTrustedTargetList
        networkMonitor.onChange = { [weak self] reason in
            self?.networkDidStabilize(reason: reason)
        }
        // Startup recovery is an explicit protection task. The status request
        // itself remains read-only; only this follow-up may reconcile routes
        // or temporary Tailscale preferences.
        refresh(reconcileExternalProtection: true)
        networkMonitor.start()
        startDomainRefreshLoop()
        startPeriodicReconciliationLoop()
        startKillSwitchPollLoop()
    }

    var state: AppState {
        if isOperating { return .applying }
        if routeState.lifecycle == .networkChanging { return .networkChanging }
        if routeState.lifecycle == .error || !(report?.errors.isEmpty ?? true) { return .error }
        if !helperAvailable { return .unavailable }
        switch routeState.lifecycle {
        case .enabled: return .enabled
        case .partial: return .partial
        case .paused: return .paused
        case .applying: return .applying
        case .networkChanging: return .networkChanging
        case .error: return .error
        case .unavailable: return .unavailable
        case .disabled: return .disabled
        }
    }

    var logURL: URL {
        TailscaleRouteLogger(paths: paths).logURL
    }

    private static func directRouteCount(in report: DiagnosticReport?) -> Int {
        guard let report,
              let gateway = report.snapshot.gateway,
              let physicalInterface = report.snapshot.physicalInterface
        else { return 0 }
        return Set(report.actualRoutes.compactMap { route -> String? in
            guard route.destination != "default",
                  route.interfaceName == physicalInterface,
                  route.gateway == gateway,
                  let canonical = IPv4CIDR.canonical(route.destination)
            else { return nil }
            return canonical
        }).count
    }

    /// Read the current Helper snapshot. Automatic route writes are opt-in and
    /// are reserved for an explicit network-change reconciliation path; timer
    /// and route-monitor refreshes must remain read-only.
    func refresh(
        reconcileExternalProtection: Bool = false,
        allowAutomaticReconcile: Bool = false
    ) {
        guard !isQuitting else { return }
        guard !isRefreshing else {
            pendingStatusRefresh = true
            return
        }
        guard activeOperation == nil else {
            pendingStatusRefresh = true
            return
        }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            let request = HelperRequest(action: .status, configuration: configuration)
            do {
                let response = try await sendToHelper(request)
                apply(response: response, for: .status)
                helperAvailable = true
                helperProtocolReady = true
                helperConnectionState = .ready
                didRequestHelperReload = false
                didRequestHelperRegistration = false
                rememberTrustedSnapshot()
                lastMessage = response.message
                let externalDetectionIsReliable = !(response.report?.warnings.contains {
                    $0.hasPrefix("外接网段检测失败：")
                } ?? true)
                let currentExternalSnapshotKey: ExternalNetworkSnapshotKey?
                if externalDetectionIsReliable,
                   let externalNetworks = response.report?.externalDirectNetworks
                {
                    currentExternalSnapshotKey = ExternalNetworkSnapshotKey(networks: externalNetworks)
                } else {
                    currentExternalSnapshotKey = nil
                }
                let externalNetworksChanged = currentExternalSnapshotKey != nil
                    && lastExternalSnapshotKey != nil
                    && currentExternalSnapshotKey != lastExternalSnapshotKey
                if let currentExternalSnapshotKey {
                    lastExternalSnapshotKey = currentExternalSnapshotKey
                }
                let routesAreActive = routeState.lifecycle == .enabled
                    || routeState.lifecycle == .partial
                    || routeState.lifecycle == .networkChanging
                    || (!routeState.managedRoutes.isEmpty && routeState.lifecycle != .paused && routeState.lifecycle != .disabled)
                let automaticExternalReconcile = allowAutomaticReconcile
                    && configuration.autoFollowNetwork
                    && externalNetworksChanged
                    && routesAreActive
                if (reconcileExternalProtection || automaticExternalReconcile),
                   currentExternalSnapshotKey != nil
                {
                    if automaticExternalReconcile { externalProtectionRetryAttempt = 0 }
                    scheduleExternalProtectionReapply(
                        requireAutoFollow: automaticExternalReconcile
                    )
                }
                let scheduledNetworkReconcile = allowAutomaticReconcile
                    && scheduleReapplyIfNetworkChanged()
                if !scheduledNetworkReconcile {
                    let missingRoutes = RouteDriftDetector.missingOwnedRoutes(
                        state: routeState,
                        actualRoutes: report?.actualRoutes ?? [],
                        actualIPv6Routes: report?.actualIPv6Routes
                    )
                    if allowAutomaticReconcile,
                       !missingRoutes.isEmpty,
                       configuration.autoFollowNetwork,
                       !networkRetryPaused
                    {
                        routeState.lifecycle = .networkChanging
                        lastMessage = "检测到受管路由漂移，准备对账：\(missingRoutes.prefix(3).joined(separator: "、"))"
                        scheduleNetworkReconcile(
                            reason: "检测到受管路由缺失或网关/接口不匹配",
                            delay: .seconds(2),
                            resetRetryCount: true
                        )
                    } else {
                        if !missingRoutes.isEmpty, networkRetryPaused {
                            lastMessage = "自动路由写入已暂停；发现路由漂移，等待新的网络变化后再试"
                        } else if !missingRoutes.isEmpty, !allowAutomaticReconcile {
                            lastMessage = "检测到受管路由漂移；本次仅做只读核对，未写入路由"
                        } else if !missingRoutes.isEmpty {
                            lastMessage = "检测到受管路由漂移；自动跟随已关闭，未写入路由"
                        } else {
                            // No route drift and no external-key change: the
                            // network event remains a read-only observation.
                        }
                    }
                }
            } catch {
                helperAvailable = false
                helperProtocolReady = false
                helperConnectionState = error is HelperProtocolError ? .reloading : .unavailable
                let report = await Task.detached(priority: .userInitiated) {
                    self.directDiagnostic.run()
                }.value
                self.report = self.lastTrustedReport ?? report
                self.routeState = self.lastTrustedRouteState
                self.targetList = self.lastTrustedTargetList
                if error is HelperProtocolError, !didRequestHelperReload {
                    didRequestHelperReload = true
                    reloadOutdatedHelper()
                } else if !didRequestHelperRegistration {
                    didRequestHelperRegistration = true
                    helperConnectionState = .reloading
                    do {
                        try await installer.reloadInBackground()
                        lastMessage = "正在更新 tailscale-route 权限助手…"
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(1))
                            self?.refresh(reconcileExternalProtection: true)
                        }
                    } catch {
                        helperConnectionState = .unavailable
                        lastMessage = "Helper 未连接：\(error.localizedDescription)；当前仅显示只读诊断"
                    }
                } else {
                    lastMessage = "Helper 未连接：\(error.localizedDescription)；当前仅显示只读诊断"
                }
            }
            isRefreshing = false
            if pendingExternalProtectionReconcile, activeOperation == nil {
                let requireAutoFollow = pendingExternalProtectionRequiresAutoFollow
                pendingExternalProtectionReconcile = false
                pendingExternalProtectionRequiresAutoFollow = false
                scheduleExternalProtectionReapply(requireAutoFollow: requireAutoFollow)
            } else if pendingDomainRefresh, activeOperation == nil {
                pendingDomainRefresh = false
                requestDomainRefresh(force: true)
            } else if pendingStatusRefresh, activeOperation == nil {
                pendingStatusRefresh = false
                refresh()
            }
        }
    }

    func enable() { perform(.enable) }
    func reapply() { perform(.reapply) }
    func preview() { perform(.preview) }
    func pause() { perform(.pause) }

    // MARK: - 断网保护

    func setKillSwitchEnabled(_ enabled: Bool) {
        sendKillSwitchRequest(enabled ? .enableKillSwitch : .disableKillSwitch)
    }

    func releaseKillSwitch() {
        sendKillSwitchRequest(.releaseKillSwitch)
    }

    /// Kill-switch requests bypass the route-operation queue: they are fast,
    /// independent of route state, and must work while the network is blocked.
    private func sendKillSwitchRequest(_ action: HelperAction) {
        guard !isQuitting else { return }
        let isPoll = action == .killSwitchStatus
        if isPoll {
            guard !killSwitchPollInFlight, !killSwitchRequestInFlight else { return }
            killSwitchPollInFlight = true
        } else {
            guard !killSwitchRequestInFlight else { return }
            killSwitchRequestInFlight = true
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if isPoll { self.killSwitchPollInFlight = false } else { self.killSwitchRequestInFlight = false }
            }
            do {
                let response = try await self.sendToHelper(HelperRequest(action: action))
                if let status = response.killSwitch { self.killSwitchStatus = status }
                if action != .killSwitchStatus { self.lastMessage = response.message }
            } catch {
                if action != .killSwitchStatus {
                    self.lastMessage = "断网保护操作失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func startKillSwitchPollLoop() {
        guard killSwitchPollTask == nil else { return }
        killSwitchPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sendKillSwitchRequest(.killSwitchStatus)
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
            }
        }
    }
    func restoreDefault() { perform(.restoreDefault) }
    func updateList() { perform(.updateList) }

    /// One-click test: refresh the route status and run the layered
    /// connectivity check against the targets configured in settings.
    func runOneClickTest() {
        refresh()
        let settings = configuration.connectivityTest
        let urlText = settings.url.trimmingCharacters(in: .whitespacesAndNewlines)
        checkConnectivity(
            target: settings.address,
            tcpPort: (1...65535).contains(settings.port) ? settings.port : nil,
            httpURL: urlText.isEmpty ? nil : URL(string: urlText)
        )
    }

    /// Saves the resolver list for temporary domains. Returns an error
    /// message for invalid input; empty input restores the defaults.
    func saveDNSServers(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = TailscaleRouteConfiguration.normalizedDNSServers([trimmed])
        if !trimmed.isEmpty, parsed.isEmpty {
            return "请输入有效的 IPv4 地址，多个用逗号分隔（最多 4 个）"
        }
        configuration.dnsServers = parsed.isEmpty ? DirectDNSDomainResolver.defaultServers : parsed
        try? store.saveConfiguration(configuration)
        lastMessage = "域名解析 DNS 已设为 \(configuration.effectiveDNSServers.joined(separator: ", "))；正在重新解析临时域名"
        requestDomainRefresh(force: true)
        return nil
    }

    /// Saves the one-click test targets. Returns an error message for invalid input.
    func saveConnectivityTest(address: String, port: String, url: String) -> String? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // The layered check works on an IPv4 address (route get / ARP / TCP).
        guard address.split(separator: ".", omittingEmptySubsequences: false).count == 4,
              IPv4CIDR.parseAddress(address) != nil
        else { return "测试地址需为 IPv4 地址，例如 1.1.1.1" }
        guard let portValue = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(portValue) else {
            return "端口需为 1–65535"
        }
        if !url.isEmpty {
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", parsed.host != nil
            else { return "URL 需以 http:// 或 https:// 开头" }
        }
        configuration.connectivityTest = ConnectivityTestSettings(address: address, port: portValue, url: url)
        try? store.saveConfiguration(configuration)
        lastMessage = "测试目标已保存"
        return nil
    }

    func checkConnectivity(target: String, tcpPort: Int?, httpURL: URL?) {
        guard !isCheckingConnectivity else { return }
        isCheckingConnectivity = true
        let actualRoutes = report?.actualRoutes ?? []
        let desiredTargets = report?.managedTargets ?? []
        let savedState = routeState
        Task { @MainActor [weak self] in
            let service = ConnectivityDiagnosticService()
            let results = await Task.detached(priority: .utility) {
                let connectivity = service.run(target: target, tcpPort: tcpPort, httpURL: httpURL)
                let kernelSelection: RouteEntry?
                if IPv4CIDR.parseAddress(target) != nil {
                    let lookup = ProcessCommandRunner().run("/sbin/route", arguments: ["-n", "get", target])
                    kernelSelection = lookup.succeeded ? RouteOutputParser.parseRouteGetEntry(lookup.stdout) : nil
                } else {
                    kernelSelection = nil
                }
                let explanation = RouteExplanationService.explain(
                    address: target,
                    actualRoutes: actualRoutes,
                    desiredTargets: desiredTargets,
                    state: savedState,
                    kernelSelection: kernelSelection
                )
                return (connectivity, explanation)
            }.value
            guard let self else { return }
            self.connectivityReport = results.0
            self.routeExplanation = results.1
            self.isCheckingConnectivity = false
        }
    }

    // MARK: - 退出

    /// User-initiated quit (menu button, ⌘Q, Dock). Never refuses: it stops
    /// background work, waits briefly for the current operation, asks the
    /// Helper to clean up, and on failure offers retry / quit anyway / cancel.
    func quitApp() {
        guard !isQuitting else { return }
        beginQuitting()
        Task { @MainActor [weak self] in
            await self?.runQuitCleanup(interactive: true)
        }
    }

    func retryQuit() {
        guard isQuitting else { return quitApp() }
        quitFailureMessage = nil
        Task { @MainActor [weak self] in
            await self?.runQuitCleanup(interactive: true)
        }
    }

    /// Quit without completed cleanup. The Helper stays registered so any
    /// cleanup it is still running (or a later recovery script) can finish.
    func forceQuit() {
        quitFailureMessage = nil
        logger.warning("用户选择在清理未完成时退出 App")
        terminate(unregisterHelper: false)
    }

    func cancelQuit() {
        quitFailureMessage = nil
        isQuitting = false
        routeProgress = nil
        isOperating = false
        if activeOperation == .route(.shutdown) { activeOperation = nil }
        lastMessage = "已取消退出"
        startDomainRefreshLoop()
        startPeriodicReconciliationLoop()
        startKillSwitchPollLoop()
        refresh()
    }

    func systemWillPowerOff() {
        systemPoweringOff = true
    }

    /// Called from applicationShouldTerminate.
    func terminationReply() -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        if systemPoweringOff {
            // Logout / restart / shut down: clean up without dialogs within a
            // bounded time, then always let the system continue.
            if !isQuitting { beginQuitting() }
            Task { @MainActor [weak self] in
                await self?.runQuitCleanup(interactive: false)
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        // Dock or other external quit: same flow as the menu button.
        quitApp()
        return .terminateCancel
    }

    private var logger: TailscaleRouteLogger { TailscaleRouteLogger(paths: paths) }

    private func beginQuitting() {
        isQuitting = true
        quitFailureMessage = nil
        // Stop timers so no new Helper operation starts while quitting. The
        // network monitor keeps running (NWPathMonitor cannot restart after
        // cancel); its events are ignored while isQuitting.
        domainRefreshTask?.cancel()
        domainRefreshTask = nil
        externalProtectionReconcileTask?.cancel()
        externalProtectionReconcileTask = nil
        periodicReconcileTask?.cancel()
        periodicReconcileTask = nil
        killSwitchPollTask?.cancel()
        killSwitchPollTask = nil
        networkReconcileTask?.cancel()
        networkReconcileTask = nil
        networkReapplyPending = false
        pendingDomainRefresh = false
        pendingStatusRefresh = false
        pendingExternalProtectionReconcile = false
        lastMessage = "正在退出…"
    }

    private func runQuitCleanup(interactive: Bool) async {
        // Let an in-flight refresh or operation finish (the Helper serves
        // requests one at a time, so shutdown would queue behind it anyway).
        let idleDeadline = Date().addingTimeInterval(interactive ? 30 : 10)
        while (activeOperation != nil || isRefreshing), Date() < idleDeadline {
            routeProgress = RouteProgress(completed: 0, total: 1, message: "等待当前操作结束后退出")
            try? await Task.sleep(for: .milliseconds(200))
        }

        activeOperation = .route(.shutdown)
        isOperating = true
        routeProgress = RouteProgress(completed: 0, total: 1, message: "移除项目管理的分流路由后退出")
        lastMessage = "正在移除项目管理的分流路由…"

        let outcome = await requestShutdown(timeout: interactive ? 120 : 25)
        routeProgress = nil
        isOperating = false
        activeOperation = nil

        switch outcome {
        case .cleaned(let notice):
            if let notice { logger.warning("退出：\(notice)") }
            if interactive {
                terminate(unregisterHelper: true)
            } else {
                // System is shutting down / logging out: leave the daemon
                // registration alone; the caller replies to AppKit.
                prepareForTermination()
            }
        case .failed(let reason):
            logger.error("退出清理未完成：\(reason)")
            if interactive {
                lastMessage = "退出清理未完成：\(reason)"
                quitFailureMessage = reason
            } else {
                prepareForTermination()
            }
        }
    }

    private enum ShutdownOutcome {
        /// Managed routes and hosts pins were removed. `notice` carries a
        /// non-blocking issue (for example Tailscale preferences that will be
        /// restored on the next launch).
        case cleaned(notice: String?)
        case failed(String)
    }

    private func requestShutdown(timeout: Double) async -> ShutdownOutcome {
        var lastFailure = "未知原因"
        for attempt in 1...2 {
            do {
                let response = try await sendToHelper(
                    HelperRequest(action: .shutdown, configuration: configuration),
                    timeout: timeout
                )
                apply(response: response, for: .pause)
                helperAvailable = true
                helperProtocolReady = true
                helperConnectionState = .ready
                rememberTrustedSnapshot()
                if response.success { return .cleaned(notice: nil) }
                // Routes are gone; only Tailscale preference restore or external
                // adapter bookkeeping is pending. The lease is persisted and the
                // next launch's startup reconcile retries it, so this must not
                // trap the user in the App.
                if response.layeredStatus?.route == .ok {
                    return .cleaned(notice: response.message)
                }
                lastFailure = response.message
            } catch is QuitTimeoutError {
                // The Helper may still be cleaning up; do not send a second request.
                return .failed("权限助手 \(Int(timeout)) 秒内未完成清理（可能仍在进行）")
            } catch {
                lastFailure = "无法联系权限助手：\(error.localizedDescription)"
            }
            if attempt == 1 { try? await Task.sleep(for: .seconds(1)) }
        }
        return .failed(lastFailure)
    }

    private func prepareForTermination() {
        terminationApproved = true
        networkMonitor.stop()
    }

    private func terminate(unregisterHelper: Bool) {
        prepareForTermination()
        Task { @MainActor in
            if unregisterHelper {
                let installer = self.installer
                // SMAppService polling can take seconds; keep it off the main
                // actor, and never let an unregister failure block quitting.
                do {
                    try await Task.detached(priority: .userInitiated) { try installer.unregister() }.value
                } catch {
                    self.logger.warning("退出时注销 Helper 失败（不影响退出）：\(error.localizedDescription)")
                }
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private var shouldRefreshConfiguredDomains: Bool {
        let routesAreActive = routeState.lifecycle == .enabled
            || routeState.lifecycle == .partial
            || routeState.lifecycle == .networkChanging
        return routesAreActive && !configuration.domainNames.isEmpty && !networkRetryPaused
    }

    /// On-demand domain refresh. Resolved answers are pinned in /etc/hosts,
    /// so apps keep using the pinned addresses; re-resolving every 30 s only
    /// churned routes (and could cut connections to rotated-out CDN IPs).
    /// A refresh now runs when it is due: at startup, when the domain list
    /// changes (forced), after a real network change or wake (scheduled
    /// below), and as a slow safety net every 30 minutes. Failures retry with
    /// backoff from 30 s up to 10 minutes.
    private static let domainRefreshInterval: Double = 30 * 60

    private func startDomainRefreshLoop() {
        guard domainRefreshTask == nil else { return }
        domainRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let due = self.domainRefreshState.nextRefreshAt, Date() < due {
                    // Not due yet.
                } else {
                    self.requestDomainRefresh()
                }
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }
    }

    private var domainRefreshDelay: Double {
        guard domainRefreshState.failureCount > 0 else { return Self.domainRefreshInterval }
        return min(600, 30 * pow(2, Double(min(domainRefreshState.failureCount - 1, 5))))
    }

    /// Network changed or the Mac woke up: DNS answers may differ on the new
    /// network, so make the next domain refresh due shortly (it waits for any
    /// running operation and is merged with a reapply if one follows).
    private func scheduleDomainRefreshAfterNetworkChange() {
        let soon = Date().addingTimeInterval(10)
        if let due = domainRefreshState.nextRefreshAt, due <= soon { return }
        domainRefreshState.nextRefreshAt = soon
    }

    private func requestDomainRefresh(force: Bool = false) {
        let routesAreActive = routeState.lifecycle == .enabled
            || routeState.lifecycle == .partial
            || routeState.lifecycle == .networkChanging
        guard shouldRefreshConfiguredDomains || (force && routesAreActive) else {
            domainRefreshState.pending = false
            return
        }
        domainRefreshState.nextRefreshAt = Date().addingTimeInterval(domainRefreshDelay)
        guard activeOperation == nil, !isRefreshing else {
            pendingDomainRefresh = true
            domainRefreshState.pending = true
            return
        }
        pendingDomainRefresh = false
        domainRefreshState.pending = false
        domainRefreshState.lastAttemptAt = Date()
        perform(.domainRefresh, operation: .domainRefresh)
    }

    private func startPeriodicReconciliationLoop() {
        guard periodicReconcileTask == nil else { return }
        periodicReconcileTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard let self,
                      !self.isBusy
                else { continue }
                // This loop is a read-only health snapshot. It must not turn a
                // stale/partial diagnostic or a self-generated route event into
                // a complete China-list reapply.
                self.refresh()
            }
        }
    }

    private func scheduleExternalProtectionReapply(
        delay: Duration = .seconds(2),
        requireAutoFollow: Bool = false
    ) {
        if requireAutoFollow, !configuration.autoFollowNetwork { return }
        guard externalProtectionReconcileTask == nil else {
            pendingExternalProtectionReconcile = true
            pendingExternalProtectionRequiresAutoFollow = pendingExternalProtectionRequiresAutoFollow || requireAutoFollow
            return
        }
        guard !isRefreshing, activeOperation == nil else {
            pendingExternalProtectionReconcile = true
            pendingExternalProtectionRequiresAutoFollow = pendingExternalProtectionRequiresAutoFollow || requireAutoFollow
            return
        }
        externalProtectionReconcileTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.externalProtectionReconcileTask = nil
            guard !requireAutoFollow || self.configuration.autoFollowNetwork else { return }
            guard !self.isBusy else {
                self.pendingExternalProtectionReconcile = true
                self.pendingExternalProtectionRequiresAutoFollow = self.pendingExternalProtectionRequiresAutoFollow || requireAutoFollow
                return
            }
            self.externalProtectionReapplyInFlight = true
            self.perform(.reconcileExternalProtection, operation: .externalProtectionReconcile)
        }
    }

    func addDomain(_ rawDomain: String) -> String? {
        let domain = Self.canonicalRoutingDomain(rawDomain)
        guard Self.isValidDomainName(domain) else {
            return "请输入有效域名，例如 example.com"
        }
        guard !configuration.domainNames.contains(where: { $0.caseInsensitiveCompare(domain) == .orderedSame }) else {
            return "这个域名已经在列表中（包含对应的 www 子域名）"
        }

        configuration.domainNames.append(domain)
        do {
            try store.saveConfiguration(configuration)
        } catch {
            configuration.domainNames.removeAll { $0.caseInsensitiveCompare(domain) == .orderedSame }
            return "保存域名失败：\(error.localizedDescription)"
        }

        let hasManagedSplitRoutes = !routeState.managedRoutes.isEmpty
            || !routeState.managedIPv6Routes.isEmpty
            || !routeState.managedExitNodeEndpointRoutes.isEmpty
            || !routeState.managedDNSServerRoutes.isEmpty
        let routingNeedsApply = routeState.lifecycle == .enabled
            || routeState.lifecycle == .partial
            || routeState.lifecycle == .networkChanging
            || (hasManagedSplitRoutes && routeState.lifecycle != .paused && routeState.lifecycle != .disabled)
        if routingNeedsApply {
            lastMessage = "正在把 \(domain) 加入本地网关分流…"
            requestDomainRefresh(force: true)
        } else {
            lastMessage = "已缓存 \(domain)；恢复分流时会一并应用"
            refresh()
        }
        return nil
    }

    func removeDomain(_ domain: String) {
        let previousDomains = configuration.domainNames
        let canonicalDomain = Self.canonicalRoutingDomain(domain)
        configuration.domainNames.removeAll {
            Self.canonicalRoutingDomain($0).caseInsensitiveCompare(canonicalDomain) == .orderedSame
        }
        guard configuration.domainNames != previousDomains else { return }

        do {
            try store.saveConfiguration(configuration)
        } catch {
            configuration.domainNames = previousDomains
            lastMessage = "移除域名失败：\(error.localizedDescription)"
            return
        }

        lastMessage = "已移除 \(domain)，正在更新分流…"
        let hasManagedSplitRoutes = !routeState.managedRoutes.isEmpty
            || !routeState.managedIPv6Routes.isEmpty
            || !routeState.managedExitNodeEndpointRoutes.isEmpty
            || !routeState.managedDNSServerRoutes.isEmpty
        let cleanupNeedsApply = routeState.lifecycle == .enabled
            || routeState.lifecycle == .partial
            || routeState.lifecycle == .networkChanging
            || (hasManagedSplitRoutes && routeState.lifecycle != .paused && routeState.lifecycle != .disabled)
        if cleanupNeedsApply {
            requestDomainRefresh(force: true)
        } else {
            lastMessage = "已移除 \(domain)；当前未启用分流，旧路由清理将在恢复分流时执行"
            refresh()
        }
    }

    private static func isValidDomainName(_ domain: String) -> Bool {
        guard !domain.isEmpty,
              domain.utf8.count <= 253,
              !domain.contains("..")
        else { return false }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count),
                  isASCIIAlphaNumeric(bytes[0]),
                  isASCIIAlphaNumeric(bytes[bytes.count - 1])
            else { return false }
            return bytes.allSatisfy { isASCIIAlphaNumeric($0) || $0 == 45 }
        }
    }

    private static func canonicalRoutingDomain(_ rawDomain: String) -> String {
        var domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasSuffix(".") { domain.removeLast() }
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        return domain
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte) || (65...90).contains(byte)
    }

    func setAutoFollow(_ enabled: Bool) {
        configuration.autoFollowNetwork = enabled
        try? store.saveConfiguration(configuration)
        if !enabled {
            networkReconcileTask?.cancel()
            networkReconcileTask = nil
            networkReapplyPending = false
            pendingNetworkChangeReason = nil
            if pendingExternalProtectionRequiresAutoFollow {
                pendingExternalProtectionReconcile = false
                pendingExternalProtectionRequiresAutoFollow = false
            }
        }
        lastMessage = enabled ? "将自动跟随网络变化" : "已暂停自动跟随网络变化"
    }

    func installHelper() {
        helperAvailable = false
        helperProtocolReady = false
        helperConnectionState = .reloading
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.installer.reloadInBackground()
                self.lastMessage = "Helper 更新请求已提交"
                self.refresh(reconcileExternalProtection: true)
            } catch {
                self.helperConnectionState = .unavailable
                self.lastMessage = "Helper 注册失败：\(error.localizedDescription)"
            }
        }
    }

    private func reloadOutdatedHelper() {
        helperAvailable = false
        helperProtocolReady = false
        helperConnectionState = .reloading
        lastMessage = "正在更新 tailscale-route 权限助手…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.installer.reloadInBackground()
            } catch {
                self.helperConnectionState = .unavailable
                self.lastMessage = "权限助手版本过旧，无法自动更新：\(error.localizedDescription)"
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            self.lastMessage = "权限助手已更新，正在重新读取状态…"
            try? await Task.sleep(for: .seconds(1.5))
            self.refresh(reconcileExternalProtection: true)
        }
    }

    private func perform(_ action: HelperAction, operation requestedOperation: AppOperation? = nil) {
        guard !isQuitting else { return }
        guard helperAvailable, helperProtocolReady else {
            if requestedOperation == .externalProtectionReconcile || action == .reconcileExternalProtection {
                pendingExternalProtectionReconcile = true
                pendingExternalProtectionRequiresAutoFollow = pendingExternalProtectionRequiresAutoFollow || configuration.autoFollowNetwork
            } else if requestedOperation == .domainRefresh {
                pendingDomainRefresh = true
                domainRefreshState.pending = true
            }
            if action != .domainRefresh {
                lastMessage = "权限助手尚未确认，暂不执行写路由操作"
            }
            return
        }
        guard activeOperation == nil, !isRefreshing else {
            if requestedOperation == .domainRefresh {
                pendingDomainRefresh = true
                domainRefreshState.pending = true
            } else if requestedOperation == .externalProtectionReconcile {
                pendingExternalProtectionReconcile = true
                pendingExternalProtectionRequiresAutoFollow = pendingExternalProtectionRequiresAutoFollow || configuration.autoFollowNetwork
            }
            return
        }
        if action == .preview { routePlanPreview = nil }
        let operation = requestedOperation ?? {
            switch action {
            case .updateList: return AppOperation.listUpdate
            case .preview: return AppOperation.preview
            case .reconcileExternalProtection: return AppOperation.externalProtectionReconcile
            case .domainRefresh: return AppOperation.domainRefresh
            default: return AppOperation.route(action)
            }
        }()
        let isAutomaticNetworkAttempt = automaticNetworkReconcileInFlight && action == .reapply
        let isExternalProtectionAttempt = externalProtectionReapplyInFlight
            && action == .reconcileExternalProtection
        automaticNetworkReconcileInFlight = false
        externalProtectionReapplyInFlight = false
        activeOperation = operation
        isOperating = operation.isRouteMutation
        let initialProgress = RouteProgress(completed: 0, total: 100, message: actionMessage(action))
        if operation == .listUpdate {
            listProgress = initialProgress
        } else if operation.isRouteMutation {
            routeProgress = initialProgress
        }
        if operation == .listUpdate {
            chinaListRefreshState.isRefreshing = true
            chinaListRefreshState.lastError = nil
            chinaListRefreshState.warning = nil
        } else if operation != .domainRefresh {
            lastMessage = nil
        }
        Task { [weak self] in
            guard let self else { return }
            var shouldApplyUpdatedList = false
            var shouldRecoverHelper = false
            do {
                let response = try await sendToHelper(HelperRequest(action: action, configuration: configuration)) { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        if operation == .listUpdate {
                            self.listProgress = progress
                        } else if operation.isRouteMutation {
                            self.routeProgress = progress
                        }
                    }
                }
                apply(response: response, for: action)
                helperAvailable = true
                helperProtocolReady = true
                helperConnectionState = .ready
                rememberTrustedSnapshot()
                if operation == .listUpdate {
                    chinaListRefreshState.isRefreshing = false
                    chinaListRefreshState.lastSuccessAt = Date()
                    chinaListRefreshState.lastError = nil
                    chinaListRefreshState.warning = response.operation?.warnings.first
                    chinaListRefreshState.manualUpdateRequired = false
                } else if operation != .domainRefresh {
                    lastMessage = response.message
                }
                let routeIsActive = routeState.lifecycle == .enabled
                    || routeState.lifecycle == .partial
                    || routeState.lifecycle == .networkChanging
                shouldApplyUpdatedList = action == .updateList && response.success && routeIsActive
                if [.enable, .reapply, .pause, .shutdown, .restoreDefault, .reconcileExternalProtection].contains(action) {
                    suppressRouteEventsUntil = Date().addingTimeInterval(5)
                }
                if operation == .domainRefresh {
                    let domainResolutionSucceeded = response.layeredStatus?.domainResolution == .ok
                        || (response.layeredStatus == nil && response.success)
                    if domainResolutionSucceeded {
                        domainRefreshState.failureCount = 0
                        domainRefreshState.lastSuccessAt = Date()
                        domainRefreshState.lastError = nil
                    } else {
                        domainRefreshState.failureCount += 1
                        domainRefreshState.lastError = response.message
                    }
                    domainRefreshState.nextRefreshAt = Date().addingTimeInterval(domainRefreshDelay)
                    if let domainIPv6Count = response.domainIPv6Count {
                        domainRefreshState.resolvedIPv6Count = domainIPv6Count
                    }
                }
                if isAutomaticNetworkAttempt {
                    if !response.success && response.message.contains("网络仍在变化") {
                        scheduleNetworkRetry(reason: response.message)
                    } else {
                        networkRetryAttempt = 0
                    }
                }
                if isExternalProtectionAttempt {
                    let externalProtectionSucceeded = response.layeredStatus?.externalProtection == .ok
                        || (response.layeredStatus == nil && response.success)
                    if externalProtectionSucceeded {
                        externalProtectionRetryAttempt = 0
                    } else {
                        scheduleExternalProtectionRetry(reason: response.message)
                    }
                }
            } catch {
                helperAvailable = false
                helperProtocolReady = false
                helperConnectionState = error is HelperProtocolError ? .reloading : .unavailable
                let message = "操作失败：\(error.localizedDescription)"
                if operation != .domainRefresh, operation != .listUpdate {
                    lastMessage = message
                    routeState = lastTrustedRouteState
                    report = lastTrustedReport ?? report
                    targetList = lastTrustedTargetList
                }
                if error is HelperProtocolError, !didRequestHelperReload {
                    didRequestHelperReload = true
                    reloadOutdatedHelper()
                } else if !(error is HelperProtocolError) {
                    shouldRecoverHelper = true
                }
                if operation == .domainRefresh {
                    domainRefreshState.failureCount += 1
                    domainRefreshState.lastError = message
                    domainRefreshState.nextRefreshAt = Date().addingTimeInterval(domainRefreshDelay)
                } else if operation == .listUpdate {
                    chinaListRefreshState.isRefreshing = false
                    chinaListRefreshState.lastError = message
                    chinaListRefreshState.manualUpdateRequired = message.contains("手动点击")
                }
                if isAutomaticNetworkAttempt {
                    scheduleNetworkRetry(reason: "Helper 暂时不可用：\(error.localizedDescription)")
                }
                if isExternalProtectionAttempt {
                    scheduleExternalProtectionRetry(reason: "Helper 暂时不可用：\(error.localizedDescription)")
                }
            }
            routeProgress = nil
            listProgress = nil
            isOperating = false
            activeOperation = nil
            if networkReapplyPending {
                networkReapplyPending = false
                // A stop request is explicit. Its route changes must not be
                // mistaken for a network change that schedules an auto-reapply.
                if action != .pause {
                    let reason = pendingNetworkChangeReason ?? .systemConfigurationChanged
                    pendingNetworkChangeReason = nil
                    networkDidStabilize(reason: reason)
                }
            }
            if shouldRecoverHelper {
                scheduleHelperRecovery()
            }
            if shouldApplyUpdatedList {
                chinaListRefreshState.warning = "中国 IP 清单已更新，正在应用新分流…"
                perform(.reapply)
            } else if action == .updateList {
                chinaListRefreshState.warning = "中国 IP 清单已更新；分流当前未启用，启用时会应用新清单"
            } else if pendingExternalProtectionReconcile {
                pendingExternalProtectionReconcile = false
                let requireAutoFollow = pendingExternalProtectionRequiresAutoFollow
                pendingExternalProtectionRequiresAutoFollow = false
                scheduleExternalProtectionReapply(requireAutoFollow: requireAutoFollow)
            } else if pendingDomainRefresh {
                pendingDomainRefresh = false
                requestDomainRefresh(force: true)
            } else if pendingStatusRefresh {
                pendingStatusRefresh = false
                refresh()
            }
        }
    }

    private func apply(response: HelperResponse, for action: HelperAction) {
        // Domain refresh owns only its domain counters and retry state in the
        // App. Its Helper response also contains a compatibility-shaped route
        // state/report, but applying those fields would overwrite the main
        // route, external-protection, and top-level status modules.
        if action == .updateList {
            if let targetList = response.targetList { self.targetList = targetList }
        } else if action != .domainRefresh {
            if let report = response.report {
                self.report = report
            } else if action == .pause {
                report = nil
            }
            if let state = response.state { routeState = state }
            if let targetList = response.targetList { self.targetList = targetList }
            if let layeredStatus = response.layeredStatus { self.layeredStatus = layeredStatus }
        }
        if let domainIPv4Count = response.domainIPv4Count {
            domainRefreshState.resolvedIPv4Count = domainIPv4Count
        }
        if let domainIPv6Count = response.domainIPv6Count {
            domainRefreshState.resolvedIPv6Count = domainIPv6Count
        }
        if action == .preview {
            routePlanPreview = response.planPreview
        }
        if let progress = response.progress {
            if action == .updateList {
                listProgress = progress
            } else if [.enable, .reapply, .pause, .shutdown, .restoreDefault, .reconcileExternalProtection].contains(action) {
                routeProgress = progress
            }
        }
        if !response.success,
           let operation = response.operation,
           action != .domainRefresh,
           action != .updateList
        {
            routeState.lifecycle = operation.state
            routeState.lastError = operation.lastError
        }
    }

    @discardableResult
    private func scheduleReapplyIfNetworkChanged() -> Bool {
        guard configuration.autoFollowNetwork,
              routeState.lifecycle == .enabled
                || routeState.lifecycle == .partial
                || routeState.lifecycle == .networkChanging
                || networkRetryPaused,
              let currentFingerprint = report?.snapshot.fingerprint,
              let lastFingerprint = routeState.lastSuccessFingerprint,
              currentFingerprint != lastFingerprint
        else { return false }
        routeState.lifecycle = .networkChanging
        lastMessage = "检测到上次成功应用后网络已变化，准备重建路由…"
        scheduleNetworkReconcile(
            reason: "网络指纹变化",
            delay: .seconds(2),
            resetRetryCount: true
        )
        return true
    }

    /// Same as sendToHelper, but gives up waiting after `timeout` seconds.
    /// The blocking socket read cannot be cancelled, so the race resolves a
    /// continuation once and lets the late reply be dropped.
    private func sendToHelper(_ request: HelperRequest, timeout: Double) async throws -> HelperResponse {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HelperResponse, Error>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor [weak self] in
                guard let self else {
                    once.resume(.failure(UnixSocketError.connectFailed("App 已释放")))
                    return
                }
                do {
                    once.resume(.success(try await self.sendToHelper(request)))
                } catch {
                    once.resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                once.resume(.failure(QuitTimeoutError()))
            }
        }
    }

    private func sendToHelper(
        _ request: HelperRequest,
        onProgress: (@Sendable (RouteProgress) -> Void)? = nil
    ) async throws -> HelperResponse {
        var lastError: Error?
        for client in helperClients {
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try client.send(request, onProgress: onProgress)
                }.value
                guard HelperProtocolCompatibility.accepts(response.helperProtocolVersion) else {
                    throw HelperProtocolError.mismatch(response.helperProtocolVersion)
                }
                return response
            } catch {
                lastError = error
                if error is HelperProtocolError {
                    break
                }
            }
        }
        throw lastError ?? UnixSocketError.connectFailed("没有可用的 Helper")
    }

    private func rememberTrustedSnapshot() {
        lastTrustedRouteState = routeState
        if let report { lastTrustedReport = report }
        if let targetList { lastTrustedTargetList = targetList }
    }

    private func scheduleHelperRecovery() {
        guard helperRecoveryTask == nil else { return }
        helperAvailable = false
        helperProtocolReady = false
        helperConnectionState = .reloading
        lastMessage = "Helper 连接中断，正在重新加载权限助手…"
        helperRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.installer.reloadInBackground()
            } catch {
                self.helperRecoveryTask = nil
                self.helperConnectionState = .unavailable
                self.lastMessage = "Helper 重载失败：\(error.localizedDescription)；当前仅显示只读诊断"
                return
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            self.helperRecoveryTask = nil
            self.refresh(reconcileExternalProtection: true)
        }
    }

    private func networkDidStabilize(reason: NetworkChangeReason) {
        guard !isQuitting else { return }
        let action = NetworkReconciliationPolicy.action(
            for: reason,
            isOperating: isBusy,
            autoFollowNetwork: configuration.autoFollowNetwork,
            lifecycle: routeState.lifecycle,
            retryPaused: networkRetryPaused,
            suppressRouteEventsUntil: suppressRouteEventsUntil
        )
        if action == .ignore { return }
        networkChangeGeneration += 1
        networkRetryAttempt = 0
        networkRetryPaused = false
        if action == .deferUntilOperationFinishes {
            networkReapplyPending = true
            pendingNetworkChangeReason = reason
            return
        }
        if action == .refreshOnly {
            // A route-table notification is not proof that the physical network
            // changed; it is commonly emitted by our own route transaction.
            // Keep it read-only and do not start an external-protection write.
            refresh(reconcileExternalProtection: false)
            return
        }
        scheduleDomainRefreshAfterNetworkChange()
        // A broad network event is only a candidate. First take a debounced
        // read-only status snapshot; refresh() compares the external key and
        // the main-route fingerprint before scheduling any write transaction.
        lastMessage = "网络变化（\(reason.rawValue)），等待只读快照稳定…"
        scheduleNetworkObservation(delay: .seconds(2))
    }

    private func scheduleNetworkObservation(delay: Duration) {
        networkChangeGeneration += 1
        let generation = networkChangeGeneration
        networkReconcileTask?.cancel()
        networkReconcileTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.networkChangeGeneration == generation,
                  self.configuration.autoFollowNetwork,
                  !self.isBusy
            else {
                return
            }
            self.refresh(
                reconcileExternalProtection: false,
                allowAutomaticReconcile: true
            )
        }
    }

    private func scheduleNetworkReconcile(
        reason: String,
        delay: Duration,
        resetRetryCount: Bool
    ) {
        if resetRetryCount {
            networkRetryAttempt = 0
            networkRetryPaused = false
        }
        networkChangeGeneration += 1
        let generation = networkChangeGeneration
        networkReconcileTask?.cancel()
        lastMessage = "\(reason)，等待网络稳定…"
        networkReconcileTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.networkChangeGeneration == generation,
                  self.configuration.autoFollowNetwork,
                  !self.isBusy
            else { return }
            self.routeState.lifecycle = .networkChanging
            self.automaticNetworkReconcileInFlight = true
            self.reapply()
        }
    }

    private func scheduleExternalProtectionRetry(reason: String) {
        guard configuration.autoFollowNetwork else {
            externalProtectionRetryAttempt = 0
            return
        }
        guard let delaySeconds = NetworkReconciliationPolicy.retryDelaySeconds(after: externalProtectionRetryAttempt) else {
            lastMessage = "外接网段动态排除连续更新失败；等待新的外接网卡或路由变化后重试：\(reason)"
            return
        }
        externalProtectionRetryAttempt += 1
        lastMessage = "外接网段保护更新失败；将在 \(delaySeconds) 秒后第 \(externalProtectionRetryAttempt)/\(NetworkReconciliationPolicy.maximumRetryAttempts) 次重试：\(reason)"
        scheduleExternalProtectionReapply(
            delay: .seconds(delaySeconds),
            requireAutoFollow: true
        )
    }

    private func scheduleNetworkRetry(reason: String) {
        guard configuration.autoFollowNetwork else { return }
        guard let delaySeconds = NetworkReconciliationPolicy.retryDelaySeconds(after: networkRetryAttempt) else {
            networkRetryPaused = true
            routeState.lifecycle = .error
            routeState.lastError = "网络持续抖动，已暂停自动写入；等待网络稳定后会再次检查"
            lastMessage = routeState.lastError
            if let savedState = try? store.saveState(routeState) { routeState = savedState }
            return
        }
        networkRetryAttempt += 1
        routeState.lifecycle = .networkChanging
        lastMessage = "\(reason)；将在 \(delaySeconds) 秒后重试"
        scheduleNetworkReconcile(
            reason: "网络稳定性重试（\(networkRetryAttempt)/\(NetworkReconciliationPolicy.maximumRetryAttempts)）",
            delay: .seconds(delaySeconds),
            resetRetryCount: false
        )
    }

    private func actionMessage(_ action: HelperAction) -> String {
        switch action {
        case .status: return "读取状态"
        case .reconcileExternalProtection: return "对账外接网卡保护"
        case .preview: return "生成只读路由计划"
        case .enable: return "准备开始分流"
        case .reapply: return "准备更新分流"
        case .pause: return "准备停止分流"
        case .shutdown: return "退出并恢复 Tailscale 原设置"
        case .restoreDefault: return "正在恢复系统默认"
        case .updateList: return "正在更新中国 IP 清单"
        case .domainRefresh: return "刷新临时域名"
        case .killSwitchStatus: return "读取断网保护状态"
        case .enableKillSwitch: return "启用断网保护"
        case .disableKillSwitch: return "关闭断网保护"
        case .releaseKillSwitch: return "解除断网保护"
        }
    }
}

enum AppState: Equatable {
    case disabled
    case partial
    case enabled
    case networkChanging
    case applying
    case error
    case paused
    case unavailable

    var title: String {
        switch self {
        case .disabled: return "未启用"
        case .partial: return "部分生效"
        case .enabled: return "已启用"
        case .networkChanging: return "网络变化"
        case .applying: return "应用中"
        case .error: return "异常"
        case .paused: return "已暂停"
        case .unavailable: return "助手未连接"
        }
    }

    var color: Color {
        switch self {
        case .disabled, .paused, .unavailable: return .secondary
        case .partial: return .orange
        case .enabled: return .green
        case .networkChanging: return .yellow
        case .applying: return .blue
        case .error: return .red
        }
    }

    var symbol: String {
        switch self {
        case .disabled: return "circle"
        case .partial: return "exclamationmark.circle.fill"
        case .enabled: return "checkmark.circle.fill"
        case .networkChanging: return "wifi.exclamationmark"
        case .applying: return "arrow.triangle.2.circlepath"
        case .error: return "xmark.octagon.fill"
        case .paused: return "pause.circle.fill"
        case .unavailable: return "lock.slash"
        }
    }
}

struct StatusLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var didOpenDashboard = false

    var body: some View {
        Image(systemName: model.state.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(model.state.color)
            .onAppear {
                guard !didOpenDashboard else { return }
                didOpenDashboard = true
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
            }
    }
}

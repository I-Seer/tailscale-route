import Darwin
import Foundation

/// Kill-switch status reported to the App.
public struct KillSwitchStatus: Codable, Equatable, Sendable {
    /// Turned on by the user; persisted across Helper restarts and reboots.
    public let enabled: Bool
    /// The tunnel was confirmed working through the Exit Node at least once
    /// since startup or the last release, so a later failure will block.
    public let armed: Bool
    /// pf block rules are currently in effect.
    public let blocking: Bool
    public let message: String
    public let lastCheckedAt: Date?

    public init(enabled: Bool, armed: Bool, blocking: Bool, message: String, lastCheckedAt: Date?) {
        self.enabled = enabled
        self.armed = armed
        self.blocking = blocking
        self.message = message
        self.lastCheckedAt = lastCheckedAt
    }
}

/// Result of one Tailscale/Exit Node health check.
public enum KillSwitchHealth: Equatable, Sendable {
    /// Tailscale is connected and an outside-network probe through the Exit Node succeeded.
    case healthy
    /// The Tailscale App/daemon process is not running: the user quit Tailscale.
    case tailscaleNotRunning
    /// Tailscale is connected but no Exit Node is selected: the user chose not to use the tunnel.
    case noExitNode
    /// Tailscale is disconnected, the Exit Node is offline, or the probe failed.
    case unhealthy(String)
}

/// Pure state machine for the kill switch so its decisions can be tested
/// without pf or Tailscale.
public struct KillSwitchStateMachine: Equatable, Sendable {
    public static let failuresBeforeBlock = 3
    public static let successesBeforeRelease = 2

    public enum Decision: Equatable, Sendable {
        case none
        case activate(String)
        case release(String)
    }

    public var armed = false
    public var blocking = false
    public var consecutiveFailures = 0
    public var consecutiveSuccesses = 0

    public init(armed: Bool = false, blocking: Bool = false) {
        self.armed = armed
        self.blocking = blocking
    }

    public mutating func observe(_ health: KillSwitchHealth) -> Decision {
        switch health {
        case .healthy:
            armed = true
            consecutiveFailures = 0
            consecutiveSuccesses += 1
            if blocking, consecutiveSuccesses >= Self.successesBeforeRelease {
                return .release("Tailscale 已恢复，经 Exit Node 访问外网正常")
            }
            return .none
        case .tailscaleNotRunning:
            armed = false
            consecutiveFailures = 0
            consecutiveSuccesses = 0
            return blocking ? .release("Tailscale 已退出") : .none
        case .noExitNode:
            armed = false
            consecutiveFailures = 0
            consecutiveSuccesses = 0
            return blocking ? .release("Tailscale 未选择 Exit Node") : .none
        case .unhealthy(let reason):
            consecutiveSuccesses = 0
            guard armed else { return .none }
            consecutiveFailures += 1
            if !blocking, consecutiveFailures >= Self.failuresBeforeBlock {
                return .activate(reason)
            }
            return .none
        }
    }

    /// Manual release, App shutdown, or disabling: stay unarmed until the
    /// tunnel is confirmed working again, so a still-broken tunnel does not
    /// re-block the user right after they asked for network access.
    public mutating func reset() {
        armed = false
        blocking = false
        consecutiveFailures = 0
        consecutiveSuccesses = 0
    }
}

/// Inputs used to build the pf ruleset.
public struct KillSwitchRuleInputs: Equatable, Sendable {
    public var tunnelInterfaces: [String]
    /// Addresses Tailscale needs to reconnect: peer endpoints (including the
    /// Exit Node), DERP relays and the control server.
    public var allowedAddresses: [String]

    public init(tunnelInterfaces: [String], allowedAddresses: [String]) {
        self.tunnelInterfaces = tunnelInterfaces
        self.allowedAddresses = allowedAddresses
    }
}

public enum KillSwitchRules {
    /// The default macOS /etc/pf.conf evaluates `anchor "com.apple/*"`, so a
    /// sub-anchor there takes effect without editing the system pf.conf.
    public static let anchor = "com.apple/250.TailscaleRouteKillSwitch"
    public static let tableName = "tsroute_allow"

    public static func render(_ inputs: KillSwitchRuleInputs) -> String {
        let interfaces = Array(Set(inputs.tunnelInterfaces.filter(isSafeInterfaceName))).sorted()
        let addresses = Array(Set(inputs.allowedAddresses.filter(isAddressLiteral))).sorted()
        var lines: [String] = [
            "# tailscale-route 断网保护（自动生成，解除时整组清空）",
            "table <\(tableName)> persist" + (addresses.isEmpty ? "" : " { \(addresses.joined(separator: ", ")) }"),
            "pass quick on lo0 all",
        ]
        if !interfaces.isEmpty {
            lines.append("pass quick on { \(interfaces.joined(separator: " ")) } all")
        }
        lines.append(contentsOf: [
            // Keep the physical interface's DHCP lease and IPv6 neighbor/router discovery.
            "pass out quick inet proto udp from any port 68 to any port 67",
            "pass in quick inet proto udp from any port 67 to any port 68",
            "pass out quick inet6 proto udp from any port 546 to any port 547",
            "pass in quick inet6 proto udp from any port 547 to any port 546",
            "pass quick inet6 proto icmp6 all icmp6-type { 133, 134, 135, 136 }",
            // Tailscale's own reconnect traffic.
            "pass out quick to <\(tableName)> keep state",
            "pass in quick from <\(tableName)> keep state",
            // Everything else, including split-route, LAN and DNS traffic.
            "block drop quick all",
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    static func isSafeInterfaceName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 15 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func isAddressLiteral(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let isIPv4 = value.withCString { inet_pton(AF_INET, $0, &v4) } == 1
        if isIPv4 { return true }
        let isIPv6 = value.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
        return isIPv6
    }

    /// Parses "1.2.3.4:41641" / "[2001:db8::1]:41641" into the bare address.
    public static func address(fromEndpoint endpoint: String) -> String? {
        var host = endpoint.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        return isAddressLiteral(host) ? host : nil
    }
}

/// Parsed fields of `tailscale status --json` needed by the kill switch.
public struct KillSwitchTailscaleStatus: Equatable, Sendable {
    public let backendState: String?
    public let exitNodeSelected: Bool
    public let exitNodeOnline: Bool?
    public let selfAddresses: [String]
    public let peerEndpoints: [String]

    public static func parse(_ data: Data) -> KillSwitchTailscaleStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let selfObject = root["Self"] as? [String: Any]
        let selfAddresses = (selfObject?["TailscaleIPs"] as? [Any])?.compactMap { $0 as? String } ?? []
        let exitStatus = root["ExitNodeStatus"] as? [String: Any]
        var exitOnline = exitStatus?["Online"] as? Bool
        var exitSelected = exitStatus != nil
        var endpoints: [String] = []
        if let peers = root["Peer"] as? [String: Any] {
            for value in peers.values {
                guard let peer = value as? [String: Any] else { continue }
                if (peer["ExitNode"] as? Bool) == true {
                    exitSelected = true
                    if exitOnline == nil { exitOnline = peer["Online"] as? Bool }
                }
                for item in (peer["Addrs"] as? [Any]) ?? [] {
                    if let text = item as? String, let address = KillSwitchRules.address(fromEndpoint: text) {
                        endpoints.append(address)
                    }
                }
                if let current = peer["CurAddr"] as? String, let address = KillSwitchRules.address(fromEndpoint: current) {
                    endpoints.append(address)
                }
            }
        }
        return KillSwitchTailscaleStatus(
            backendState: root["BackendState"] as? String,
            exitNodeSelected: exitSelected,
            exitNodeOnline: exitOnline,
            selfAddresses: selfAddresses,
            peerEndpoints: endpoints
        )
    }
}

/// Network kill switch. While enabled and armed, a Tailscale disconnect, an
/// offline Exit Node, or a failed outside-network probe through the tunnel
/// blocks every packet that does not travel through Tailscale (split-route,
/// LAN and DNS traffic included), using a dedicated pf anchor. Only traffic
/// Tailscale needs to reconnect is allowed. The block is released when the
/// tunnel works again, when the user quits Tailscale, by the manual release
/// button, by App shutdown / recovery script, or by a reboot.
public final class KillSwitchController: @unchecked Sendable {
    public static let checkInterval: TimeInterval = 5

    private let runner: any CommandRunning
    private let inspector: NetworkInspector
    private let logger: TailscaleRouteLogger
    private let settingsURL: URL
    private let rulesURL: URL
    /// Under /var/run so a reboot clears it along with pf's in-memory rules.
    private let runtimeURL: URL
    private let queue = DispatchQueue(label: "com.tailscale-route.kill-switch")
    private var timer: DispatchSourceTimer?

    private var enabled: Bool
    private var machine = KillSwitchStateMachine()
    private var pfToken: String?
    private var appliedRules: String?
    private var message = "断网保护未启用"
    private var lastCheckedAt: Date?
    private var cachedReconnectAddresses: [String] = []
    private var reconnectAddressesRefreshedAt: Date?

    private struct Settings: Codable { var enabled: Bool }
    private struct Runtime: Codable { var blocking: Bool; var pfToken: String? }

    public init(
        paths: TailscaleRoutePaths,
        runner: any CommandRunning,
        inspector: NetworkInspector,
        logger: TailscaleRouteLogger,
        runtimeURL: URL = URL(fileURLWithPath: "/var/run/tailscale-route-killswitch.json")
    ) {
        let settingsURL = paths.root.appendingPathComponent("kill-switch.json")
        let settings = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        self.runner = runner
        self.inspector = inspector
        self.logger = logger
        self.settingsURL = settingsURL
        self.rulesURL = paths.root.appendingPathComponent("kill-switch.pf.conf")
        self.runtimeURL = runtimeURL
        self.enabled = settings?.enabled ?? false
        // A Helper crash/restart while blocking keeps the block (rules live
        // in pf, not in this process) and resumes monitoring it. After a
        // reboot the runtime file and pf rules are both gone.
        if let data = try? Data(contentsOf: runtimeURL),
           let runtime = try? JSONDecoder().decode(Runtime.self, from: data),
           runtime.blocking
        {
            machine = KillSwitchStateMachine(armed: true, blocking: true)
            pfToken = runtime.pfToken
            message = "断网保护拦截中（Helper 重启后继续）"
        } else if enabled {
            message = "等待确认 Tailscale 经 Exit Node 正常上网后开始保护"
        }
    }

    /// Starts the periodic check. Called only by the real Helper process.
    public func start() {
        queue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 2, repeating: Self.checkInterval, leeway: .seconds(1))
            source.setEventHandler { [weak self] in self?.tickLocked() }
            source.resume()
            timer = source
        }
    }

    public func status() -> KillSwitchStatus {
        queue.sync { statusLocked() }
    }

    public func setEnabled(_ value: Bool) -> KillSwitchStatus {
        queue.sync { () -> KillSwitchStatus in
            // Already off and not blocking: nothing to change or persist.
            if !value, !enabled, !machine.blocking { return statusLocked() }
            enabled = value
            saveSettingsLocked()
            if value {
                if !machine.blocking { message = "等待确认 Tailscale 经 Exit Node 正常上网后开始保护" }
                logger.info("断网保护已启用")
            } else {
                releaseLocked(reason: "断网保护已关闭")
                message = "断网保护未启用"
                logger.info("断网保护已关闭")
            }
            return statusLocked()
        }
    }

    /// Manual release (menu button), App shutdown or recovery script.
    public func release(reason: String) -> KillSwitchStatus {
        queue.sync { () -> KillSwitchStatus in
            releaseLocked(reason: reason)
            if enabled { message = "\(reason)；Tailscale 经 Exit Node 恢复正常后重新开始保护" }
            return statusLocked()
        }
    }

    // MARK: - Locked (queue) helpers

    private func statusLocked() -> KillSwitchStatus {
        KillSwitchStatus(
            enabled: enabled,
            armed: machine.armed,
            blocking: machine.blocking,
            message: message,
            lastCheckedAt: lastCheckedAt
        )
    }

    private func tickLocked() {
        guard enabled else {
            if machine.blocking { releaseLocked(reason: "断网保护已关闭") }
            return
        }
        let evaluation = evaluateLocked()
        lastCheckedAt = Date()
        let wasArmed = machine.armed
        switch machine.observe(evaluation.health) {
        case .activate(let reason):
            activateLocked(reason: reason, status: evaluation.status)
        case .release(let reason):
            releaseLocked(reason: reason)
            message = reason
        case .none:
            if machine.blocking {
                // Keep the reconnect allow-list and tunnel interface current
                // so Tailscale can recover through a changed path.
                refreshRulesLocked(status: evaluation.status)
                if case .unhealthy(let reason) = evaluation.health {
                    message = "已拦截所有非 Tailscale 流量：\(reason)"
                }
            } else {
                switch evaluation.health {
                case .healthy:
                    message = "保护中：Tailscale 经 Exit Node 上网正常"
                    if !wasArmed { logger.info("断网保护已就绪") }
                case .tailscaleNotRunning:
                    message = "Tailscale 未运行，暂不保护"
                case .noExitNode:
                    message = "未使用 Exit Node，暂不保护"
                case .unhealthy(let reason):
                    message = machine.armed
                        ? "检测到异常（\(machine.consecutiveFailures)/\(KillSwitchStateMachine.failuresBeforeBlock)）：\(reason)"
                        : "等待确认 Tailscale 经 Exit Node 正常上网后开始保护（\(reason)）"
                }
            }
        }
        // Cache reconnect addresses while the network still works.
        if !machine.blocking, evaluation.health == .healthy {
            refreshReconnectAddressesIfStaleLocked(status: evaluation.status)
        }
    }

    private func evaluateLocked() -> (health: KillSwitchHealth, status: KillSwitchTailscaleStatus?) {
        guard tailscaleProcessRunning() else { return (.tailscaleNotRunning, nil) }
        guard let result = inspector.runTailscaleCommand(["status", "--json"]),
              result.succeeded,
              let status = KillSwitchTailscaleStatus.parse(Data(result.stdout.utf8))
        else {
            return (.unhealthy("无法读取 Tailscale 状态"), nil)
        }
        guard status.backendState == "Running" else {
            return (.unhealthy("Tailscale 未连接（\(status.backendState ?? "未知状态")）"), status)
        }
        let preferences = inspector.readTailscalePreferences().preferences
        let exitNodeSelected = status.exitNodeSelected || (preferences?.exitNodeID?.isEmpty == false)
        if !exitNodeSelected {
            // Only conclude "no Exit Node" when prefs were readable.
            return preferences == nil ? (.unhealthy("无法读取 Tailscale 偏好"), status) : (.noExitNode, status)
        }
        if status.exitNodeOnline == false {
            return (.unhealthy("Exit Node 离线"), status)
        }
        let interfaces = Self.tunnelInterfaces(selfAddresses: status.selfAddresses)
        guard let interface = interfaces.first else {
            return (.unhealthy("找不到 Tailscale 网卡"), status)
        }
        guard Self.probeOutsideNetwork(interfaceName: interface) else {
            return (.unhealthy("经 Exit Node 访问外网失败"), status)
        }
        return (.healthy, status)
    }

    private func activateLocked(reason: String, status: KillSwitchTailscaleStatus?) {
        let rules = KillSwitchRules.render(ruleInputsLocked(status: status))
        guard loadRulesLocked(rules) else {
            // Could not install the block; stay armed and retry next tick.
            machine.blocking = false
            machine.consecutiveFailures = KillSwitchStateMachine.failuresBeforeBlock - 1
            message = "断网保护启动失败，稍后重试：\(reason)"
            return
        }
        if pfToken == nil {
            let enable = runner.run("/sbin/pfctl", arguments: ["-E"])
            pfToken = Self.parseToken(enable.stdout + "\n" + enable.stderr)
            if pfToken == nil {
                logger.warning("pfctl -E 未返回引用令牌：\(enable.failureReason)")
            }
        }
        machine.blocking = true
        saveRuntimeLocked()
        message = "已拦截所有非 Tailscale 流量：\(reason)"
        logger.warning("断网保护已触发：\(reason)")
    }

    private func refreshRulesLocked(status: KillSwitchTailscaleStatus?) {
        let rules = KillSwitchRules.render(ruleInputsLocked(status: status))
        if rules != appliedRules { _ = loadRulesLocked(rules) }
    }

    private func releaseLocked(reason: String) {
        let wasBlocking = machine.blocking
        machine.reset()
        // Never enabled or never blocked in this boot: leave pf untouched.
        guard wasBlocking || pfToken != nil || appliedRules != nil else { return }
        let flush = runner.run("/sbin/pfctl", arguments: ["-a", KillSwitchRules.anchor, "-F", "all"])
        if !flush.succeeded, wasBlocking {
            logger.error("清除断网保护规则失败：\(flush.failureReason)")
        }
        if let token = pfToken {
            _ = runner.run("/sbin/pfctl", arguments: ["-X", token])
            pfToken = nil
        }
        appliedRules = nil
        try? FileManager.default.removeItem(at: runtimeURL)
        if wasBlocking {
            message = reason
            logger.info("断网保护已解除：\(reason)")
        }
    }

    private func loadRulesLocked(_ rules: String) -> Bool {
        ensureAppleAnchorLocked()
        do {
            try FileManager.default.createDirectory(at: rulesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rules.write(to: rulesURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("写入断网保护规则失败：\(error.localizedDescription)")
            return false
        }
        let result = runner.run("/sbin/pfctl", arguments: ["-a", KillSwitchRules.anchor, "-f", rulesURL.path])
        guard result.succeeded else {
            logger.error("加载断网保护规则失败：\(result.failureReason)")
            return false
        }
        appliedRules = rules
        return true
    }

    /// The anchor only takes effect if the main ruleset evaluates com.apple/*.
    /// That is the macOS default; reload the system pf.conf if it is missing.
    private func ensureAppleAnchorLocked() {
        let rules = runner.run("/sbin/pfctl", arguments: ["-s", "rules"])
        if rules.succeeded, rules.stdout.contains("com.apple/*") { return }
        logger.warning("pf 主规则缺少 com.apple 锚点，重新加载 /etc/pf.conf")
        _ = runner.run("/sbin/pfctl", arguments: ["-f", "/etc/pf.conf"])
    }

    private func ruleInputsLocked(status: KillSwitchTailscaleStatus?) -> KillSwitchRuleInputs {
        var addresses = cachedReconnectAddresses
        if let status { addresses.append(contentsOf: status.peerEndpoints) }
        let interfaces = Self.tunnelInterfaces(selfAddresses: status?.selfAddresses ?? [])
        return KillSwitchRuleInputs(tunnelInterfaces: interfaces, allowedAddresses: addresses)
    }

    /// DERP relays and control server addresses, refreshed at most every ten
    /// minutes while the network works (DNS is blocked once triggered).
    private func refreshReconnectAddressesIfStaleLocked(status: KillSwitchTailscaleStatus?) {
        if let refreshed = reconnectAddressesRefreshedAt, Date().timeIntervalSince(refreshed) < 600 { return }
        var addresses: [String] = status?.peerEndpoints ?? []
        if let derp = inspector.runTailscaleCommand(["debug", "derp-map"]), derp.succeeded {
            addresses.append(contentsOf: Self.derpAddresses(Data(derp.stdout.utf8)))
        }
        var hosts = ["controlplane.tailscale.com", "login.tailscale.com", "log.tailscale.io"]
        if let control = inspector.readTailscalePreferences().preferences?.controlURL,
           let host = URL(string: control)?.host
        {
            hosts.append(host)
        }
        for host in Set(hosts) { addresses.append(contentsOf: Self.resolve(host)) }
        let unique = Array(Set(addresses)).sorted()
        if !unique.isEmpty {
            cachedReconnectAddresses = unique
            reconnectAddressesRefreshedAt = Date()
        }
    }

    private func saveSettingsLocked() {
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Settings(enabled: enabled)).write(to: settingsURL, options: .atomic)
        } catch {
            logger.error("保存断网保护设置失败：\(error.localizedDescription)")
        }
    }

    private func saveRuntimeLocked() {
        let runtime = Runtime(blocking: machine.blocking, pfToken: pfToken)
        try? JSONEncoder().encode(runtime).write(to: runtimeURL, options: .atomic)
    }

    // MARK: - System probes

    /// True when the Tailscale GUI App or a tailscaled daemon is running.
    /// Our own short-lived CLI calls use the same executable with arguments
    /// and are not counted. If ps fails, assume running (keep protecting).
    private func tailscaleProcessRunning() -> Bool {
        let result = runner.run("/bin/ps", arguments: ["-axo", "args="])
        guard result.succeeded else { return true }
        return Self.tailscaleProcessRunning(psOutput: result.stdout)
    }

    public static func tailscaleProcessRunning(psOutput: String) -> Bool {
        // The GUI App may live in /Applications or ~/Applications. It runs
        // without arguments (or with a legacy -psn_ argument); our own CLI
        // calls run the same executable with subcommand arguments.
        let appSuffix = "/Tailscale.app/Contents/MacOS/Tailscale"
        for raw in psOutput.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(appSuffix) { return true }
            if let range = line.range(of: appSuffix + " -psn") , !line[..<range.lowerBound].contains(" ") { return true }
            let executable = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
            if executable == "tailscaled" || executable.hasSuffix("/tailscaled") { return true }
        }
        return false
    }

    /// utun interfaces carrying a Tailscale address (100.64.0.0/10 or
    /// fd7a:115c:a1e0::/48); the one holding this node's own IPv4 first.
    static func tunnelInterfaces(selfAddresses: [String]) -> [String] {
        var preferred: [String] = []
        var others: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun"), let address = entry.pointee.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(cString: host)
            if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
            if selfAddresses.contains(text) {
                if !preferred.contains(name) { preferred.append(name) }
            } else if Self.isTailscaleAddress(text), !others.contains(name) {
                others.append(name)
            }
        }
        return preferred + others.filter { !preferred.contains($0) }
    }

    static func isTailscaleAddress(_ text: String) -> Bool {
        if text.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = text.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// TCP connect to well-known public anycast addresses, bound to the
    /// Tailscale interface with IP_BOUND_IF so the result reflects the
    /// Exit Node path regardless of split routes. Any success is healthy.
    static func probeOutsideNetwork(interfaceName: String) -> Bool {
        for target in ["1.1.1.1", "8.8.8.8", "9.9.9.9"] {
            if tcpConnect(address: target, port: 443, interfaceName: interfaceName, timeoutMilliseconds: 2500) {
                return true
            }
        }
        return false
    }

    static func tcpConnect(address: String, port: UInt16, interfaceName: String, timeoutMilliseconds: Int32) -> Bool {
        var index = if_nametoindex(interfaceName)
        guard index != 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // IP_BOUND_IF (netinet/in.h) = 25.
        let ipBoundIF: Int32 = 25
        guard setsockopt(descriptor, IPPROTO_IP, ipBoundIF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            return false
        }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard address.withCString({ inet_pton(AF_INET, $0, &socketAddress.sin_addr) }) == 1 else { return false }
        let connectResult = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, timeoutMilliseconds) == 1 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
        }
        return addresses
    }

    /// IPv4/IPv6 of every DERP node in `tailscale debug derp-map`.
    public static func derpAddresses(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let regions = root["Regions"] as? [String: Any]
        else { return [] }
        var addresses: [String] = []
        for value in regions.values {
            guard let region = value as? [String: Any], let nodes = region["Nodes"] as? [Any] else { continue }
            for item in nodes {
                guard let node = item as? [String: Any] else { continue }
                for key in ["IPv4", "IPv6"] {
                    if let address = node[key] as? String, KillSwitchRules.isAddressLiteral(address) {
                        addresses.append(address)
                    }
                }
            }
        }
        return addresses
    }

    /// `pfctl -E` prints "Token : 1234567890".
    static func parseToken(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "token", !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) {
                return parts[1]
            }
        }
        return nil
    }
}

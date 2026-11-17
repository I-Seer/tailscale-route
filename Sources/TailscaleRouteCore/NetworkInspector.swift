import Foundation
import Darwin

public struct NetworkInspector: Sendable {
    private let runner: any CommandRunning
    private let tailscaleCandidates = [
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/bin/tailscale",
        "tailscale"
    ]

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func readTailscalePreferences() -> (preferences: TailscalePrefsSnapshot?, failure: String?) {
        for binary in usableTailscaleCandidates {
            let status = readTailscaleStatus(binary)
            if status.exitCode == 127 { continue }
            guard status.succeeded else { return (nil, status.failureReason) }
            let result = readTailscalePrefs(binary)
            guard result.succeeded else { return (nil, result.failureReason) }
            guard let preferences = TailscalePrefsParser.parseSnapshot(Data(result.stdout.utf8)) else {
                return (nil, "Tailscale 偏好输出无法解析")
            }
            return (preferences, nil)
        }
        return (nil, "未找到可用的 Tailscale CLI")
    }

    /// Runs a read-only Tailscale CLI command (for example `status --json`
    /// or `debug derp-map`) through the first installed CLI, in the console
    /// user's session like every other CLI call. Nil when no CLI is found.
    public func runTailscaleCommand(_ arguments: [String]) -> CommandResult? {
        for binary in usableTailscaleCandidates {
            let result = runTailscale(binary, arguments: arguments)
            if result.exitCode == 127 { continue }
            return result
        }
        return nil
    }

    @discardableResult
    public func setTailscalePreferences(acceptRoutes: Bool?, allowLANAccess: Bool?) -> CommandResult {
        for binary in usableTailscaleCandidates {
            let status = readTailscaleStatus(binary)
            if status.exitCode == 127 { continue }
            guard status.succeeded else { return status }
            var arguments = ["set"]
            if let acceptRoutes { arguments.append("--accept-routes=\(acceptRoutes)") }
            if let allowLANAccess { arguments.append("--exit-node-allow-lan-access=\(allowLANAccess)") }
            guard arguments.count > 1 else {
                return CommandResult(executable: binary, arguments: arguments, stdout: "", stderr: "没有指定要更新的偏好", exitCode: 2)
            }
            let result = runTailscale(binary, arguments: arguments)
            // Preferences changed: the next read must observe the new state.
            TailscaleCLICache.shared.invalidate()
            return result
        }
        return CommandResult(executable: "tailscale", arguments: ["set"], stdout: "", stderr: "未找到可用的 Tailscale CLI", exitCode: 127)
    }

    public func inspect() -> (
        snapshot: NetworkSnapshot,
        tailscale: TailscaleStatusSummary,
        warnings: [String],
        errors: [String],
        actualRoutes: [RouteEntry]
    ) {
        var warnings: [String] = []
        var errors: [String] = []

        let defaultRouteResult = runner.run("/sbin/route", arguments: ["-n", "get", "default"])
        let defaultRoute = defaultRouteResult.succeeded
            ? RouteOutputParser.parseRouteGetEntry(defaultRouteResult.stdout)
            : nil

        if !defaultRouteResult.succeeded {
            errors.append("读取默认路由失败：\(defaultRouteResult.failureReason)")
        } else if defaultRoute == nil {
            errors.append("读取默认路由失败：输出中没有找到有效的 interface")
        }

        let hardwarePorts: [HardwarePort]
        if useNativeReads, let nativePorts = NativeNetworkReader.hardwarePorts() {
            hardwarePorts = nativePorts
        } else {
            let portsResult = runner.run("/usr/sbin/networksetup", arguments: ["-listallhardwareports"])
            hardwarePorts = portsResult.succeeded
                ? NetworksetupParser.parseHardwarePorts(portsResult.stdout)
                : []
            if !portsResult.succeeded {
                warnings.append("读取硬件端口名称失败：\(portsResult.failureReason)")
            }
        }

        let physical = findPhysicalNetwork(
            defaultRoute: defaultRoute,
            hardwarePorts: hardwarePorts,
            warnings: &warnings
        )
        let physicalIPv6Gateway = findPhysicalIPv6Gateway(interfaceName: physical.interfaceName)

        let tailscale = inspectTailscale(defaultRoute: defaultRoute, warnings: &warnings)
        let actualRoutesResult = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        let actualRoutes = actualRoutesResult.succeeded
            ? RouteOutputParser.parseRouteTable(actualRoutesResult.stdout)
            : []
        if !actualRoutesResult.succeeded {
            errors.append("读取当前 IPv4 路由表失败：\(actualRoutesResult.failureReason)")
        }

        let snapshot = NetworkSnapshot(
            physicalInterface: physical.interfaceName,
            physicalPortName: physical.portName,
            gateway: physical.gateway,
            ipv6Gateway: physicalIPv6Gateway,
            defaultRouteSignature: physical.signature ?? defaultRoute.map {
                "system:\($0.destination)->\($0.gateway) via \($0.interfaceName) [\($0.flags)]"
            },
            tailscaleInterface: tailscale.interfaceName,
            tailscaleAddress: tailscale.summary.selfAddress,
            tailscaleExitNode: tailscale.summary.exitNode,
            tailscaleExitNodeEndpoint: tailscale.summary.exitNodeEndpoint
        )
        return (snapshot, tailscale.summary, warnings, errors, actualRoutes)
    }

    private func findPhysicalIPv6Gateway(interfaceName: String?) -> String? {
        guard let interfaceName else { return nil }
        let result = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet6"])
        guard result.succeeded else { return nil }

        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 4,
                  fields[0] == "default",
                  fields[3] == Substring(interfaceName)
            else { continue }

            let gateway = String(fields[1])
            let address = gateway.split(separator: "%", maxSplits: 1).first.map(String.init) ?? gateway
            guard address.contains(":"), !address.hasPrefix("::") else { continue }
            if gateway.contains("%") {
                guard gateway.hasSuffix("%\(interfaceName)") else { continue }
                return gateway
            }
            return "\(gateway)%\(interfaceName)"
        }
        return nil
    }

    private func findPhysicalNetwork(
        defaultRoute: RouteEntry?,
        hardwarePorts: [HardwarePort],
        warnings: inout [String]
    ) -> (interfaceName: String?, portName: String?, gateway: String?, signature: String?) {
        let candidates = hardwarePorts.filter { isPhysicalInterface($0.device) }
        let requiresConfirmedActivity = defaultRoute.map { !isPhysicalInterface($0.interfaceName) } ?? true
        var viable: [(port: HardwarePort, gateway: String, signature: String)] = []
        // One SystemConfiguration read replaces `networksetup -getinfo` and
        // `ipconfig getpacket` for every port.
        let nativeServices = useNativeReads ? NativeNetworkReader.ipv4ServicesByInterface() : nil
        for port in candidates.sorted(by: { $0.device < $1.device }) {
            let activity = interfaceActiveState(port.device)
            if activity == false || (requiresConfirmedActivity && activity != true) { continue }
            let resolvedGateway: String?
            if let service = nativeServices?[port.device] {
                resolvedGateway = service.router
            } else {
                let info = runner.run("/usr/sbin/networksetup", arguments: ["-getinfo", port.name])
                let gateway = info.succeeded ? NetworksetupParser.parseRouter(info.stdout) : nil
                let dhcp = runner.run("/usr/sbin/ipconfig", arguments: ["getpacket", port.device])
                resolvedGateway = gateway ?? (dhcp.succeeded ? DHCPParser.parseRouter(dhcp.stdout) : nil)
            }
            guard let resolvedGateway,
                  IPv4CIDR.parseAddress(resolvedGateway) != nil
            else { continue }

            if let systemInterface = defaultRoute?.interfaceName,
               isVirtualInterface(systemInterface) {
                warnings.append("系统默认路由当前经过 \(systemInterface)；已从 \(port.name) / \(port.device) 读取本地网关")
            }
            let signature = "physical->\(resolvedGateway) via \(port.device)"
            viable.append((port, resolvedGateway, signature))
        }

        if let defaultInterface = defaultRoute?.interfaceName,
           isPhysicalInterface(defaultInterface),
           let preferred = viable.first(where: { $0.port.device == defaultInterface })
        {
            return (preferred.port.device, preferred.port.name, preferred.gateway, preferred.signature)
        }
        if let defaultInterface = defaultRoute?.interfaceName,
           isPhysicalInterface(defaultInterface)
        {
            warnings.append("系统默认路由已指向物理接口 (defaultInterface)，但该接口没有有效 IPv4 网关；已拒绝回退到其它物理网卡")
            return (nil, nil, nil, nil)
        }
        if viable.count == 1, let only = viable.first {
            return (only.port.device, only.port.name, only.gateway, only.signature)
        }
        if viable.count > 1 {
            warnings.append("检测到多个可用物理网卡且无法由默认路由唯一确定出口：\(viable.map { $0.port.device }.joined(separator: ", "))；已拒绝写入路由")
            return (nil, nil, nil, nil)
        }

        warnings.append("没有从活跃物理接口读取到本地网关；已忽略虚拟接口和 utun")
        return (nil, nil, nil, nil)
    }

    private func interfaceActiveState(_ interfaceName: String) -> Bool? {
        if useNativeReads, let state = NativeNetworkReader.interfaceActiveState(interfaceName) {
            return state
        }
        let result = runner.run("/sbin/ifconfig", arguments: [interfaceName])
        guard result.succeeded, !result.stdout.isEmpty else { return nil }
        let output = result.stdout.lowercased()
        if output.contains("status: inactive") { return false }
        guard let flagsStart = output.firstIndex(of: "<"),
              let flagsEnd = output[flagsStart...].firstIndex(of: ">")
        else { return nil }
        let flags = output[output.index(after: flagsStart)..<flagsEnd]
        return flags.split(separator: ",").contains { $0 == "up" }
    }

    private func isPhysicalInterface(_ interfaceName: String) -> Bool {
        guard !interfaceName.isEmpty else { return false }
        if isVirtualInterface(interfaceName) { return false }
        return interfaceName.hasPrefix("en")
    }

    private func isVirtualInterface(_ interfaceName: String) -> Bool {
        interfaceName == "lo"
            || interfaceName.hasPrefix("utun")
            || interfaceName.hasPrefix("bridge")
            || interfaceName.hasPrefix("awdl")
            || interfaceName.hasPrefix("llw")
            || interfaceName.hasPrefix("tap")
            || interfaceName.hasPrefix("tun")
    }

    private func inspectTailscale(
        defaultRoute: RouteEntry?,
        warnings: inout [String]
    ) -> (summary: TailscaleStatusSummary, interfaceName: String?) {
        var selectedResult: CommandResult?
        var selectedBinary: String?
        for binary in usableTailscaleCandidates {
            let result = readTailscaleStatus(binary)
            if result.exitCode != 127 {
                selectedResult = result
                selectedBinary = binary
                break
            }
        }

        guard let result = selectedResult else {
            warnings.append("未找到 Tailscale CLI，无法确认 Exit Node")
            return (
                TailscaleStatusSummary(
                    isInstalled: false,
                    isRunning: false,
                    selfAddress: nil,
                    selfHostName: nil,
                    exitNode: nil
                ),
                nil
            )
        }
        guard result.succeeded else {
            warnings.append("Tailscale 状态读取失败：\(result.failureReason)")
            return (
                TailscaleStatusSummary(
                    isInstalled: true,
                    isRunning: false,
                    selfAddress: nil,
                    selfHostName: nil,
                    exitNode: nil
                ),
                nil
            )
        }
        guard var summary = TailscaleJSONParser.parse(Data(result.stdout.utf8)) else {
            warnings.append("Tailscale 返回内容不是可识别的 JSON")
            return inferTailscaleFromNetwork(defaultRoute: defaultRoute, warnings: &warnings)
        }

        let prefsResult = readTailscalePrefs(selectedBinary ?? "tailscale")
        if prefsResult.succeeded, let prefs = TailscalePrefsParser.parseSnapshot(Data(prefsResult.stdout.utf8)) {
            summary = TailscaleStatusSummary(
                isInstalled: summary.isInstalled,
                isRunning: summary.isRunning,
                selfAddress: summary.selfAddress,
                selfHostName: summary.selfHostName,
                exitNode: summary.exitNode,
                exitNodeEndpoint: summary.exitNodeEndpoint,
                exitNodeAllowLANAccess: prefs.allowLANAccess,
                routeAll: prefs.routeAll
            )
            if summary.exitNode != nil, prefs.allowLANAccess == false {
                warnings.append("Tailscale Exit Node 已启用，但 Allow LAN access 未开启")
            }
        }

        var interfaceName: String?
        if let address = summary.selfAddress {
            let result = runner.run("/sbin/route", arguments: ["-n", "get", address])
            if result.succeeded {
                interfaceName = RouteOutputParser.parseRouteGet(result.stdout)["interface"]
            }
        }
        if interfaceName == nil, let defaultInterface = defaultRoute?.interfaceName,
           defaultInterface.hasPrefix("utun") {
            interfaceName = defaultInterface
        }
        return (summary, interfaceName)
    }

    private func inferTailscaleFromNetwork(
        defaultRoute: RouteEntry?,
        warnings: inout [String]
    ) -> (summary: TailscaleStatusSummary, interfaceName: String?) {
        guard let interfaceName = defaultRoute?.interfaceName,
              interfaceName.hasPrefix("utun")
        else {
            return (
                TailscaleStatusSummary(
                    isInstalled: true,
                    isRunning: false,
                    selfAddress: nil,
                    selfHostName: nil,
                    exitNode: nil
                ),
                nil
            )
        }

        let interfaceResult = runner.run("/sbin/ifconfig", arguments: [interfaceName])
        let addresses = interfaceResult.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let range = text.range(of: "inet ") else { return nil }
                let value = text[range.upperBound...]
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first
                    .map(String.init)
                guard let value, IPv4CIDR.parseAddress(value) != nil else { return nil }
                return value
            }
        let selfAddress = addresses.first(where: { $0.hasPrefix("100.") }) ?? addresses.first
        guard let selfAddress else {
            return (
                TailscaleStatusSummary(
                    isInstalled: true,
                    isRunning: false,
                    selfAddress: nil,
                    selfHostName: nil,
                    exitNode: nil
                ),
                nil
            )
        }

        warnings.append("Tailscale CLI 无法读取用户态 JSON；已根据 \(interfaceName) 和 \(selfAddress) 隧道状态确认连接")
        return (
            TailscaleStatusSummary(
                isInstalled: true,
                isRunning: true,
                selfAddress: selfAddress,
                selfHostName: nil,
                exitNode: "\(interfaceName) 默认隧道",
                exitNodeAllowLANAccess: nil,
                routeAll: true
            ),
            interfaceName
        )
    }

    /// Native kernel/SystemConfiguration reads are used only with the real
    /// process runner; injected fakes keep the original command sequence.
    private var useNativeReads: Bool {
        NativeNetworkReader.isEnabled(for: runner)
    }

    /// Absolute candidates that are not installed are skipped up front, so a
    /// missing /usr/local/bin/tailscale no longer costs a `su -l` login shell
    /// on every inspection.
    private var usableTailscaleCandidates: [String] {
        guard useNativeReads else { return tailscaleCandidates }
        return tailscaleCandidates.filter { candidate in
            !candidate.hasPrefix("/") || FileManager.default.isExecutableFile(atPath: candidate)
        }
    }

    private func readTailscaleStatus(_ binary: String) -> CommandResult {
        guard useNativeReads else { return runTailscale(binary, arguments: ["status", "--json"]) }
        return tailscaleReadPair(binary).status
    }

    private func readTailscalePrefs(_ binary: String) -> CommandResult {
        guard useNativeReads else { return runTailscale(binary, arguments: ["debug", "prefs"]) }
        return tailscaleReadPair(binary).prefs
    }

    /// `status --json` and `debug prefs` are always needed together. Read
    /// them in a single console-user session and keep the pair for a short
    /// time so back-to-back inspections (stability check, apply, verify)
    /// do not each start new login shells.
    private func tailscaleReadPair(_ binary: String) -> TailscaleReadPair {
        if let cached = TailscaleCLICache.shared.pair(for: binary) { return cached }
        let pair = runTailscalePairInOneSession(binary) ?? TailscaleReadPair(
            status: runTailscale(binary, arguments: ["status", "--json"]),
            prefs: runTailscale(binary, arguments: ["debug", "prefs"])
        )
        TailscaleCLICache.shared.store(pair, for: binary)
        return pair
    }

    private func runTailscalePairInOneSession(_ binary: String) -> TailscaleReadPair? {
        guard getuid() == 0 else { return nil }
        let consoleUser = runner.run("/usr/bin/stat", arguments: ["-f", "%Su", "/dev/console"])
        let username = consoleUser.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard consoleUser.succeeded,
              !username.isEmpty,
              username != "root",
              username != "loginwindow"
        else { return nil }

        let statusArguments = ["TAILSCALE_BE_CLI=1", binary, "status", "--json"]
        let prefsArguments = ["TAILSCALE_BE_CLI=1", binary, "debug", "prefs"]
        let marker = TailscaleCLICache.exitMarker
        let script = [
            (["/usr/bin/env"] + statusArguments).map(shellQuote).joined(separator: " "),
            "printf '\\n\(marker)%s\\n' \"$?\"",
            (["/usr/bin/env"] + prefsArguments).map(shellQuote).joined(separator: " "),
            "printf '\\n\(marker)%s\\n' \"$?\""
        ].joined(separator: "; ")
        let command = ["/bin/sh", "-c", script].map(shellQuote).joined(separator: " ")
        let sessionResult = runner.run("/usr/bin/su", arguments: ["-l", username, "-c", "exec \(command)"])
        guard let segments = TailscaleCLICache.splitMarkedOutput(sessionResult.stdout, marker: marker),
              segments.count == 2
        else { return nil }

        func makeResult(_ arguments: [String], _ segment: (output: String, exitCode: Int32)) -> CommandResult {
            CommandResult(
                executable: "/usr/bin/env",
                arguments: arguments,
                stdout: segment.output,
                stderr: segment.exitCode == 0 ? "" : sessionResult.stderr,
                exitCode: segment.exitCode
            )
        }
        var status = makeResult(statusArguments, segments[0])
        var prefs = makeResult(prefsArguments, segments[1])
        // Same fallback as runTailscale(): a failed user-session call is
        // retried directly so the error reported is the CLI's own.
        if !status.succeeded { status = runner.run("/usr/bin/env", arguments: statusArguments) }
        if !prefs.succeeded { prefs = runner.run("/usr/bin/env", arguments: prefsArguments) }
        return TailscaleReadPair(status: status, prefs: prefs)
    }

    private func runTailscale(_ binary: String, arguments: [String]) -> CommandResult {
        // The macOS app executable decides whether to launch the GUI or act
        // as the CLI from its environment. Tailscale documents this escape
        // hatch for scripts; without it, invoking the bundled executable
        // directly can launch the app or abort instead of returning JSON.
        let cliArguments = ["TAILSCALE_BE_CLI=1", binary] + arguments
        // The macOS Tailscale client exposes its local API in the logged-in
        // user's launchd session. The privileged helper runs as root, so a
        // direct invocation can incorrectly report that Tailscale is stopped.
        // Re-enter the console user's session when the helper is privileged.
        guard getuid() == 0 else {
            return runner.run("/usr/bin/env", arguments: cliArguments)
        }

        let consoleUser = runner.run(
            "/usr/bin/stat",
            arguments: ["-f", "%Su", "/dev/console"]
        )
        let username = consoleUser.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard consoleUser.succeeded,
              !username.isEmpty,
              username != "root",
              username != "loginwindow"
        else {
            return runner.run("/usr/bin/env", arguments: cliArguments)
        }

        // `su -l` supplies the logged-in user's HOME/session context. That
        // context is required by the macOS Tailscale GUI client; launchctl
        // alone can still leave the privileged helper with a root-like
        // environment and produce a misleading CLI error.
        let command = (["/usr/bin/env"] + cliArguments).map(shellQuote).joined(separator: " ")
        let userResult = runner.run(
            "/usr/bin/su",
            arguments: ["-l", username, "-c", "exec \(command)"]
        )
        if userResult.succeeded {
            return userResult
        }

        let consoleUID = runner.run(
            "/usr/bin/stat",
            arguments: ["-f", "%u", "/dev/console"]
        )
        guard let uid = Int(consoleUID.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              uid > 0
        else {
            return userResult
        }
        return runner.run(
            "/usr/bin/env",
            arguments: cliArguments
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct TailscaleReadPair: Sendable {
    let status: CommandResult
    let prefs: CommandResult
}

/// Process-wide, short-lived cache of Tailscale CLI reads. Entries expire
/// after two seconds and are dropped whenever the app writes preferences.
final class TailscaleCLICache: @unchecked Sendable {
    static let shared = TailscaleCLICache()
    static let exitMarker = "__TAILSCALE_ROUTE_EXIT__"

    private let lock = NSLock()
    private let lifetime: TimeInterval = 2
    private var entries: [String: (pair: TailscaleReadPair, storedAt: Date)] = [:]

    func pair(for binary: String) -> TailscaleReadPair? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[binary],
              Date().timeIntervalSince(entry.storedAt) < lifetime
        else { return nil }
        return entry.pair
    }

    func store(_ pair: TailscaleReadPair, for binary: String) {
        lock.lock()
        entries[binary] = (pair, Date())
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Splits "<output>\n<marker><code>\n<output>\n<marker><code>\n" into
    /// (output, exit code) segments. Returns nil when no marker is found,
    /// for example when su itself failed before running the script.
    static func splitMarkedOutput(_ output: String, marker: String) -> [(output: String, exitCode: Int32)]? {
        var segments: [(output: String, exitCode: Int32)] = []
        var remainder = Substring(output)
        while let range = remainder.range(of: "\n" + marker) {
            let body = remainder[..<range.lowerBound]
            let afterMarker = remainder[range.upperBound...]
            let lineEnd = afterMarker.firstIndex(of: "\n") ?? afterMarker.endIndex
            guard let code = Int32(afterMarker[..<lineEnd].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            segments.append((String(body), code))
            remainder = lineEnd < afterMarker.endIndex
                ? afterMarker[afterMarker.index(after: lineEnd)...]
                : afterMarker[lineEnd...]
        }
        return segments.isEmpty ? nil : segments
    }
}

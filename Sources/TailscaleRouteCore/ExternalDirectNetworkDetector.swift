import Foundation

public struct ExternalDirectNetwork: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { "\(interfaceName):\(cidr)" }

    public let interfaceName: String
    public let hardwarePortName: String
    public let address: String
    public let cidr: String
    /// The gateway advertised by the physical interface. This is optional
    /// for backwards-compatible decoding, but authoritative protection now
    /// requires it so a cloned utun host route can be overridden precisely.
    public let gateway: String?

    public init(
        interfaceName: String,
        hardwarePortName: String,
        address: String,
        cidr: String,
        gateway: String? = nil
    ) {
        self.interfaceName = interfaceName
        self.hardwarePortName = hardwarePortName
        self.address = address
        self.cidr = cidr
        self.gateway = gateway
    }
}

public enum ExternalNetworkScanState: String, Codable, Equatable, Sendable {
    case notAuthoritative
    case authoritativeEmpty
    case authoritativeNonEmpty
}

public struct ExternalDirectNetworkDetection: Sendable {
    public let networks: [ExternalDirectNetwork]
    public let isAuthoritative: Bool
    public let warning: String?

    public init(networks: [ExternalDirectNetwork], isAuthoritative: Bool, warning: String? = nil) {
        self.networks = networks
        self.isAuthoritative = isAuthoritative
        self.warning = warning
    }

    /// A scan with no detected networks is safe to interpret as unplugged
    /// only when all required observations completed authoritatively.
    public var scanState: ExternalNetworkScanState {
        guard isAuthoritative else { return .notAuthoritative }
        return networks.isEmpty ? .authoritativeEmpty : .authoritativeNonEmpty
    }

    public var isConfirmedEmpty: Bool {
        scanState == .authoritativeEmpty
    }

    /// This is a representation of the observed data. Callers must first
    /// check `isAuthoritative` (or `scanState`) before using it for writes.
    public var snapshotKey: ExternalNetworkSnapshotKey {
        ExternalNetworkSnapshotKey(networks: networks)
    }
}

public struct ExternalDirectNetworkDetector: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func detect() -> [ExternalDirectNetwork] {
        scan().networks
    }

    public func scan() -> ExternalDirectNetworkDetection {
        // With the real process runner, read interfaces, ports and routers
        // natively instead of launching networksetup/ifconfig/ioreg/ipconfig.
        // Each native read falls back to the original command if it fails.
        let native = NativeNetworkReader.isEnabled(for: runner)
        let nativePorts = native ? NativeNetworkReader.hardwarePorts() : nil
        let nativeInterfaces = native ? NativeNetworkReader.interfaceStates() : nil
        let hardwareResult = nativePorts == nil
            ? runner.run("/usr/sbin/networksetup", arguments: ["-listallhardwareports"])
            : nil
        let configResult = nativeInterfaces == nil
            ? runner.run("/sbin/ifconfig", arguments: ["-a"])
            : nil
        let routeResult = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        let commandResults = [hardwareResult, configResult, routeResult].compactMap { $0 }
        guard commandResults.allSatisfy(\.succeeded) else {
            let failures = commandResults.filter { !$0.succeeded }
                .map { "\($0.executable): \($0.failureReason)" }
            return ExternalDirectNetworkDetection(networks: [], isAuthoritative: false, warning: failures.joined(separator: "; "))
        }

        let hardwarePorts = nativePorts
            ?? NetworksetupParser.parseHardwarePorts(hardwareResult?.stdout ?? "")
        let interfaces = nativeInterfaces.map(Self.interfaceAddresses(fromNative:))
            ?? Self.parseInterfaceAddresses(configResult?.stdout ?? "")
        let routes = RouteOutputParser.parseRouteTable(routeResult.stdout)
        let nativeServices = native ? NativeNetworkReader.ipv4ServicesByInterface() : nil
        var detected: [ExternalDirectNetwork] = []
        var warnings: [String] = []

        for port in hardwarePorts where port.device.hasPrefix("en") {
            guard let interface = interfaces[port.device], interface.isUp, interface.isActive,
                  interface.hasIPv4Address
            else { continue }
            let isExternal: Bool
            if native, let nativeAnswer = NativeNetworkReader.isExternalNetworkInterface(port.device) {
                isExternal = nativeAnswer
            } else {
                let registry = runner.run("/usr/sbin/ioreg", arguments: ["-p", "IOService", "-r", "-n", port.device, "-l", "-w0"])
                guard registry.succeeded else {
                    warnings.append("无法确认接口 \(port.device) 是否为外接网卡：\(registry.failureReason)")
                    continue
                }
                isExternal = Self.isExternalNetworkInterface(registry.stdout)
            }
            guard isExternal else { continue }
            if interface.hasUnresolvedIPv4 || interface.networks.isEmpty {
                warnings.append("无法解析外接接口 \(port.device) 的 IPv4 掩码")
                continue
            }

            for (address, cidr) in interface.networks {
                let hasConnectedRoute = routes.contains { route in
                    guard let routeCIDR = IPv4CIDR.parse(route.destination),
                          routeCIDR.description == cidr,
                          route.interfaceName == port.device,
                          !route.flags.contains("G"), !route.flags.contains("H")
                    else { return false }
                    return route.gateway.hasPrefix("link#") || route.gateway == "-"
                }
                if hasConnectedRoute {
                    let rawGateway: String?
                    if let service = nativeServices?[port.device] {
                        rawGateway = service.router
                    } else {
                        let info = runner.run("/usr/sbin/networksetup", arguments: ["-getinfo", port.name])
                        let dhcp = runner.run("/usr/sbin/ipconfig", arguments: ["getpacket", port.device])
                        rawGateway = (info.succeeded ? NetworksetupParser.parseRouter(info.stdout) : nil)
                            ?? (dhcp.succeeded ? DHCPParser.parseRouter(dhcp.stdout) : nil)
                    }
                    // A manually configured USB adapter may intentionally
                    // have no router. The protector installs a direct route
                    // through the adapter's own address, so a missing
                    // gateway is valid and must not make detection
                    // non-authoritative.
                    let gateway = rawGateway.flatMap { IPv4CIDR.parseAddress($0) == nil ? nil : $0 }
                    detected.append(ExternalDirectNetwork(
                        interfaceName: port.device,
                        hardwarePortName: port.name,
                        address: address,
                        cidr: cidr,
                        gateway: gateway
                    ))
                } else {
                    warnings.append("外接接口 \(port.device) 的 \(cidr) 没有匹配的内核直连路由")
                }
            }
        }
        return ExternalDirectNetworkDetection(networks: Array(Set(detected)).sorted {
            if $0.interfaceName != $1.interfaceName { return $0.interfaceName < $1.interfaceName }
            return $0.cidr < $1.cidr
        }, isAuthoritative: warnings.isEmpty, warning: warnings.isEmpty ? nil : warnings.joined(separator: "; "))
    }

    private static func isExternalNetworkInterface(_ output: String) -> Bool {
        let isNotBuiltIn = output.contains("\"IOBuiltin\" = No")
        let isEthernetOrWiFi = output.contains("IOEthernet")
            || output.contains("IOSkywalkLegacyEthernetInterface")
            || output.contains("IO80211")
            || output.contains("\"IOInterfaceType\" = 6")
            || output.contains("\"IOInterfaceType\" = 71")
        return isNotBuiltIn && isEthernetOrWiFi
    }

    private static func parseInterfaceAddresses(_ output: String) -> [String: (isUp: Bool, isActive: Bool, networks: [(String, String)], hasIPv4Address: Bool, hasUnresolvedIPv4: Bool)] {
        var result: [String: (isUp: Bool, isActive: Bool, networks: [(String, String)], hasIPv4Address: Bool, hasUnresolvedIPv4: Bool)] = [:]
        var currentName: String?
        var isUp = false
        var isActive = false
        var networks: [(String, String)] = []
        var hasIPv4Address = false
        var hasUnresolvedIPv4 = false

        func saveCurrent() {
            guard let currentName else { return }
            result[currentName] = (isUp, isActive, networks, hasIPv4Address, hasUnresolvedIPv4)
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if !line.hasPrefix("\t"), !line.hasPrefix(" "), let range = line.range(of: ": flags=") {
                saveCurrent()
                currentName = String(line[..<range.lowerBound])
                isUp = line.contains("<UP,") || line.contains("<UP>")
                isActive = false
                networks = []
                hasIPv4Address = false
                hasUnresolvedIPv4 = false
                continue
            }
            guard currentName != nil else { continue }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("status: active") { isActive = true }
            guard let inetRange = line.range(of: "inet ") else { continue }
            let addressFields = line[inetRange.upperBound...].split(whereSeparator: \.isWhitespace)
            guard let rawAddress = addressFields.first,
                  let address = IPv4CIDR.parseAddress(String(rawAddress))
            else { continue }
            hasIPv4Address = true
            guard addressFields.count >= 3,
                  let maskIndex = addressFields.firstIndex(of: "netmask"),
                  addressFields.indices.contains(maskIndex + 1),
                  let mask = UInt32(String(addressFields[maskIndex + 1]).replacingOccurrences(of: "0x", with: ""), radix: 16),
                  let prefix = prefixLength(for: mask), (1...32).contains(prefix)
            else {
                hasUnresolvedIPv4 = true
                continue
            }
            let cidr = IPv4CIDR(network: address, prefixLength: prefix).description
            guard let network = IPv4CIDR.parse(cidr) else { continue }
            networks.append((String(rawAddress), network.description))
        }
        saveCurrent()
        return result
    }

    /// Builds the same per-interface summary as `parseInterfaceAddresses`
    /// from getifaddrs/ioctl data.
    private static func interfaceAddresses(
        fromNative states: [String: NativeNetworkReader.InterfaceState]
    ) -> [String: (isUp: Bool, isActive: Bool, networks: [(String, String)], hasIPv4Address: Bool, hasUnresolvedIPv4: Bool)] {
        var result: [String: (isUp: Bool, isActive: Bool, networks: [(String, String)], hasIPv4Address: Bool, hasUnresolvedIPv4: Bool)] = [:]
        for (name, state) in states {
            var networks: [(String, String)] = []
            var hasIPv4Address = false
            var hasUnresolvedIPv4 = false
            for entry in state.ipv4 {
                guard let address = IPv4CIDR.parseAddress(entry.address) else { continue }
                hasIPv4Address = true
                guard let mask = entry.mask,
                      let prefix = prefixLength(for: mask), (1...32).contains(prefix)
                else {
                    hasUnresolvedIPv4 = true
                    continue
                }
                let cidr = IPv4CIDR(network: address, prefixLength: prefix).description
                guard let network = IPv4CIDR.parse(cidr) else { continue }
                networks.append((entry.address, network.description))
            }
            result[name] = (state.isUp, state.isActive, networks, hasIPv4Address, hasUnresolvedIPv4)
        }
        return result
    }

    private static func prefixLength(for mask: UInt32) -> Int? {
        let prefix = (~mask).leadingZeroBitCount
        let expected = prefix == 0 ? UInt32.zero : UInt32.max << UInt32(32 - prefix)
        return expected == mask ? prefix : nil
    }
}

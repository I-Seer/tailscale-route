import Foundation

public struct HardwarePort: Equatable, Sendable {
    public let name: String
    public let device: String

    public init(name: String, device: String) {
        self.name = name
        self.device = device
    }
}

public enum RouteOutputParser {
    public static func parseRouteGet(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key] = value
        }
        return values
    }

    public static func parseRouteGetEntry(_ output: String) -> RouteEntry? {
        let values = parseRouteGet(output)
        guard let interfaceName = values["interface"] else { return nil }
        return RouteEntry(
            destination: values["destination"] ?? "default",
            gateway: values["gateway"] ?? "-",
            flags: values["flags"] ?? "-",
            interfaceName: interfaceName,
            rawLine: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public static func parseRouteTable(_ output: String) -> [RouteEntry] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let rawLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 4 else { return nil }
                guard !rawLine.hasPrefix("Routing tables"),
                      rawLine != "Internet:",
                      rawLine != "Destination        Gateway            Flags        Netif Expire",
                      fields[0] != "Destination"
                else { return nil }

                let rawDestination = String(fields[0])
                let gateway = String(fields[1])
                let flags = String(fields[2])
                let interfaceName = String(fields[3])
                let destination: String
                if rawDestination != "default",
                   !rawDestination.contains("/"),
                   !flags.contains("H"),
                   let firstOctet = rawDestination.split(separator: ".").first.flatMap({ Int($0) })
                {
                    // netstat omits the prefix for classful IPv4 networks
                    // (for example, "128.108" means 128.108.0.0/16). Host
                    // routes carry H and must remain /32.
                    let prefixLength = firstOctet < 128 ? 8 : firstOctet < 192 ? 16 : firstOctet < 224 ? 24 : 32
                    destination = IPv4CIDR.canonical(rawDestination, defaultPrefixLength: prefixLength)
                        ?? rawDestination
                } else {
                    destination = rawDestination
                }
                return RouteEntry(
                    destination: destination,
                    gateway: gateway,
                    flags: flags,
                    interfaceName: interfaceName,
                    rawLine: rawLine
                )
            }
    }
}

public enum NetworksetupParser {
    public static func parseHardwarePorts(_ output: String) -> [HardwarePort] {
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var ports: [HardwarePort] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("Hardware Port:") else {
                index += 1
                continue
            }
            let name = line.dropFirst("Hardware Port:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nextIndex = index + 1
            guard nextIndex < lines.count, lines[nextIndex].hasPrefix("Device:") else {
                index += 1
                continue
            }
            let device = lines[nextIndex].dropFirst("Device:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ports.append(HardwarePort(name: String(name), device: String(device)))
            index += 2
        }
        return ports
    }

    public static func parseRouter(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("router:") else { continue }
            let value = trimmed.dropFirst("Router:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value != "0.0.0.0",
                  value.caseInsensitiveCompare("none") != .orderedSame,
                  value.caseInsensitiveCompare("null") != .orderedSame,
                  value.caseInsensitiveCompare("(null)") != .orderedSame
            else { return nil }
            return String(value)
        }
        return nil
    }
}

public enum DHCPParser {
    public static func parseRouter(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("router (") else { continue }
            guard let openBrace = trimmed.firstIndex(of: "{"),
                  let closeBrace = trimmed[openBrace...].firstIndex(of: "}")
            else { continue }
            let value = trimmed[trimmed.index(after: openBrace)..<closeBrace]
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .first
            if let value, !value.isEmpty { return String(value) }
        }
        return nil
    }
}

public enum TailscaleJSONParser {
    public static func parse(_ data: Data) -> TailscaleStatusSummary? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        let selfObject = dictionaryValue(in: root, matchingKey: "Self")
        let addresses = (selfObject?["TailscaleIPs"] as? [Any])?.compactMap { $0 as? String } ?? []
        let selfAddress = addresses.first(where: { $0.contains(".") }) ?? addresses.first
        let hostName = firstString(in: selfObject, keys: ["HostName", "DNSName", "Name"])
        let exitNodePeer = findExitNodePeer(in: root, selfObject: selfObject)
        let exitNode = exitNodeName(in: root, selfObject: selfObject, peer: exitNodePeer)
        let exitNodeEndpoint = exitNodeEndpointAddress(from: exitNodePeer)
        return TailscaleStatusSummary(
            isInstalled: true,
            isRunning: true,
            selfAddress: selfAddress,
            selfHostName: hostName,
            exitNode: exitNode,
            exitNodeEndpoint: exitNodeEndpoint
        )
    }

    /// Resolves the dictionary of the peer currently acting as the Exit Node,
    /// following the same priority chain as the display name.
    private static func findExitNodePeer(
        in root: [String: Any],
        selfObject: [String: Any]?
    ) -> [String: Any]? {
        if let status = dictionaryValue(in: root, matchingKey: "ExitNodeStatus") {
            let exitNodeID = firstString(in: status, keys: ["ID", "NodeID"])
            if let peer = peer(in: root, matchingID: exitNodeID) {
                return peer
            }
        }
        if let value = selfObject?["ExitNode"] as? String, !value.isEmpty {
            if let peer = peer(in: root, matchingID: value) {
                return peer
            }
        }
        if let peers = root["Peer"] as? [String: Any] {
            for value in peers.values {
                guard let candidate = value as? [String: Any],
                      (candidate["ExitNode"] as? Bool) == true
                else { continue }
                return candidate
            }
        }
        return nil
    }

    /// The live WireGuard endpoint (`CurAddr`, e.g. "198.18.45.40:41641").
    /// Only public IPv4 endpoints qualify; DERP-only peers report an empty
    /// address, IPv6 endpoints are out of scope, and on-link private
    /// addresses need no pinned route.
    private static func exitNodeEndpointAddress(from peer: [String: Any]?) -> String? {
        guard let raw = firstString(in: peer, keys: ["CurAddr"]), !raw.isEmpty else { return nil }
        let host = raw.hasPrefix("[")
            ? raw.dropFirst().prefix(while: { $0 != "]" })
            : raw.prefix(while: { $0 != ":" })
        guard let address = IPv4CIDR.parseAddress(String(host)) else { return nil }
        let cidr = IPv4CIDR(network: address, prefixLength: 32)
        guard !IPv4CIDR.protectedRouteCIDRs.contains(where: { $0.overlaps(cidr) }) else { return nil }
        return String(host)
    }

    private static func exitNodeName(
        in root: [String: Any],
        selfObject: [String: Any]?,
        peer resolvedPeer: [String: Any]?
    ) -> String? {
        if let status = dictionaryValue(in: root, matchingKey: "ExitNodeStatus") {
            let exitNodeID = firstString(in: status, keys: ["ID", "NodeID"])
            if let name = firstString(in: status, keys: ["HostName", "DNSName", "Name"]) {
                return name
            }
            if let name = firstString(in: resolvedPeer, keys: ["HostName", "DNSName", "Name"]) {
                return name
            }
            if let exitNodeID { return exitNodeID }
        }
        if let value = selfObject?["ExitNode"] as? String, !value.isEmpty {
            if let name = firstString(in: resolvedPeer, keys: ["HostName", "DNSName", "Name"]) {
                return name
            }
            return value
        }
        if let resolvedPeer,
           (resolvedPeer["ExitNode"] as? Bool) == true,
           let name = firstString(in: resolvedPeer, keys: ["HostName", "DNSName", "Name", "ID"])
        {
            return name
        }
        return nil
    }

    private static func peer(in root: [String: Any], matchingID identifier: String?) -> [String: Any]? {
        guard let identifier,
              let peers = root["Peer"] as? [String: Any]
        else { return nil }

        if let peer = peers[identifier] as? [String: Any] {
            return peer
        }
        for value in peers.values {
            guard let peer = value as? [String: Any] else { continue }
            let peerID = firstString(in: peer, keys: ["ID", "NodeID"])
            if peerID == identifier { return peer }
        }
        return nil
    }

    private static func dictionaryValue(in dictionary: [String: Any], matchingKey key: String) -> [String: Any]? {
        if let direct = dictionary[key] as? [String: Any] { return direct }
        for (candidate, value) in dictionary {
            if candidate.caseInsensitiveCompare(key) == .orderedSame,
               let result = value as? [String: Any]
            {
                return result
            }
        }
        return nil
    }

    private static func firstString(in dictionary: [String: Any]?, keys: [String]) -> String? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let (_, value) = dictionary.first(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            }), let string = value as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }
}

public enum TailscalePrefsParser {
    public static func parse(_ data: Data) -> (allowLANAccess: Bool?, routeAll: Bool?)? {
        guard let prefs = parseSnapshot(data) else { return nil }
        return (prefs.allowLANAccess, prefs.routeAll)
    }

    public static func parseSnapshot(_ data: Data) -> TailscalePrefsSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }
        // `debug prefs` prints the login state under "Config" (older builds:
        // "Persist"). Its NodeID identifies this device's login and, unlike
        // ExitNodeID, does not change when the user switches Exit Nodes.
        let persist = (root["Config"] as? [String: Any]) ?? (root["Persist"] as? [String: Any])
        let nodeID = (persist?["NodeID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TailscalePrefsSnapshot(
            root["ExitNodeAllowLANAccess"] as? Bool,
            root["RouteAll"] as? Bool,
            root["ExitNodeID"] as? String,
            root["ControlURL"] as? String,
            nodeID
        )
    }
}

public struct TailscalePrefsSnapshot: Equatable, Sendable {
    public let allowLANAccess: Bool?
    public let routeAll: Bool?
    public let exitNodeID: String?
    public let controlURL: String?
    /// Login identity of this device (from `debug prefs` Config.NodeID); nil when unavailable.
    public let nodeID: String?

    public init(_ allowLANAccess: Bool?, _ routeAll: Bool?, _ exitNodeID: String?, _ controlURL: String?, _ nodeID: String? = nil) {
        self.allowLANAccess = allowLANAccess
        self.routeAll = routeAll
        self.exitNodeID = exitNodeID
        self.controlURL = controlURL
        self.nodeID = nodeID
    }
}

public enum DesiredTargetParser {
    public static func parse(_ contents: String) -> [String] {
        var seen = Set<String>()
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .filter { seen.insert($0).inserted }
    }
}

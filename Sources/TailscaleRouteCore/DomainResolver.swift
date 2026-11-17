import Foundation

/// Resolves temporary-domain split-route targets. Implementations must only
/// return addresses usable as host-route destinations.
public protocol DomainResolving: Sendable {
    /// A-record answers for the domain, or nil when the domain is unknown.
    func resolveIPv4(_ domain: String) -> [String]?
    /// Real AAAA-record answers (IPv4-mapped and other non-global addresses
    /// must be filtered out), or nil when the domain is unknown.
    func resolveIPv6(_ domain: String) -> [String]?
}

/// Resolves through the system resolver (`getaddrinfo`).
public struct SystemDomainResolver: DomainResolving {
    public init() {}

    public func resolveIPv4(_ domain: String) -> [String]? {
        SystemDomainResolver.resolve(domain: domain, family: AF_INET) { address in
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var ipv4Address = pointer.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ipv4Address, &buffer, socklen_t(buffer.count)) != nil else {
                    return nil
                }
                let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    public func resolveIPv6(_ domain: String) -> [String]? {
        Self.resolve(domain: domain, family: AF_INET6) { address in
            address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                guard TargetListBuilder.usableDomainIPv6(pointer.pointee.sin6_addr) else { return nil }
                var ipv6Address = pointer.pointee.sin6_addr
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &ipv6Address, &buffer, socklen_t(buffer.count)) != nil else {
                    return nil
                }
                let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    private static func resolve(
        domain: String,
        family: Int32,
        addressString: (UnsafePointer<sockaddr>) -> String?
    ) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(domain, nil, &hints, &result)
        guard status == 0 else {
            return nil
        }
        guard let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            if let address = addressString(node.pointee.ai_addr), !addresses.contains(address) {
                addresses.append(address)
            }
            current = node.pointee.ai_next
        }
        return addresses
    }
}

/// Resolves temporary domains with direct UDP queries against public Chinese
/// resolvers (via `/usr/bin/dig`). It deliberately does not fall back to the
/// system resolver: with an Exit Node active, that resolver may be scoped to
/// the tunnel and return a different region's or a poisoned CDN answer.
///
/// While a Tailscale exit node is active, macOS scopes all system-resolver
/// traffic through the tunnel, so `getaddrinfo` observes the exit node's
/// country and CDN geodns hands out overseas edges (multi-second RTTs for
/// domestic sites). `dig` sends queries to the explicitly selected servers;
/// those packets still follow the system route table. The Helper therefore
/// pins exact `/32` host routes for these servers to the current physical
/// gateway (`DNSServerRouteProtector`) before every lookup, so queries leave
/// through the physical interface — independent of whether the China list is
/// installed yet — and yield the nearby CDN edges the user wants. This
/// resolver does not change the system DNS used by browsers.
public struct DirectDNSDomainResolver: DomainResolving {
    /// Default domestic resolvers, used until the user configures others
    /// (`TailscaleRouteConfiguration.dnsServers`). The Helper pins the
    /// configured addresses to the physical gateway (`DNSServerRouteProtector`)
    /// before resolving, so the queries never depend on the China list.
    public static let defaultServers = ["114.114.114.114", "222.85.85.85"]

    private let runner: CommandRunning
    private let servers: [String]

    public init(
        runner: CommandRunning = ProcessCommandRunner(),
        servers: [String] = DirectDNSDomainResolver.defaultServers
    ) {
        self.runner = runner
        self.servers = servers
    }

    public func resolveIPv4(_ domain: String) -> [String]? {
        var answers: Set<String> = []
        var hadSuccessfulQuery = false
        for server in servers {
            let result = runner.run(
                "/usr/bin/dig",
                arguments: ["+short", "+time=2", "+tries=1", "@\(server)", domain, "A"]
            )
            if result.succeeded {
                hadSuccessfulQuery = true
                answers.formUnion(Self.literalLines(result.stdout, family: AF_INET))
            }
        }
        guard hadSuccessfulQuery else { return nil }
        return answers.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    public func resolveIPv6(_ domain: String) -> [String]? {
        var answers: Set<String> = []
        var hadSuccessfulQuery = false
        for server in servers {
            let result = runner.run(
                "/usr/bin/dig",
                arguments: ["+short", "+time=2", "+tries=1", "@\(server)", domain, "AAAA"]
            )
            if result.succeeded {
                hadSuccessfulQuery = true
                answers.formUnion(Self.literalLines(result.stdout, family: AF_INET6))
            }
        }
        let usable = answers.filter { Self.isUsableIPv6Literal($0) }
        guard hadSuccessfulQuery else { return nil }
        return usable.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// `dig +short` emits one record per line, mixing CNAME chains with the
    /// final literals; keep only lines that parse as an address of the family
    /// we asked for.
    private static func literalLines(_ output: String, family: Int32) -> [String] {
        output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let literal = line.trimmingCharacters(in: .whitespaces)
                guard !literal.isEmpty else { return nil }
                var address = in6_addr()
                let parsed: Int32
                if family == AF_INET {
                    var v4 = in_addr()
                    parsed = literal.withCString { inet_pton(AF_INET, $0, &v4) }
                } else {
                    parsed = literal.withCString { inet_pton(AF_INET6, $0, &address) }
                }
                return parsed == 1 ? literal : nil
            }
    }

    /// Defensive filter for dig answers (dig does not synthesize mapped
    /// addresses, but a broken upstream could still hand them out).
    private static func isUsableIPv6Literal(_ literal: String) -> Bool {
        var address = in6_addr()
        return literal.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
            && TargetListBuilder.usableDomainIPv6(address)
    }
}

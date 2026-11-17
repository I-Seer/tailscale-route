import CryptoKit
import Darwin
import Foundation

public enum TargetListError: LocalizedError {
    case empty
    case invalidSource(String)
    case tooManyTargets(Int)
    case cannotReadSource(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "目标清单为空；请检查中国 IP 源或手动配置"
        case .invalidSource(let source):
            return "中国 IP 清单来源无效：\(source)"
        case .tooManyTargets(let count):
            return "目标清单过大：\(count) 条，已停止应用"
        case .cannotReadSource(let reason):
            return "无法读取中国 IP 清单：\(reason)"
        }
    }
}

public protocol TextResourceLoading: Sendable {
    func load(_ url: URL) -> Result<Data, Error>
}

public struct URLTextResourceLoader: TextResourceLoading, Sendable {
    public init() {}

    public func load(_ url: URL) -> Result<Data, Error> {
        do {
            return .success(try Data(contentsOf: url))
        } catch {
            return .failure(error)
        }
    }
}

public struct IPv4CIDR: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Ranges that the route app must never use as IPv4 split-route targets.
    /// Tailscale's CGNAT allocation is 100.64.0.0/10; the rest of 100/8 is
    /// deliberately left available to normal target lists.
    public static let protectedRouteCIDRs = [
        IPv4CIDR(network: 0x0A00_0000, prefixLength: 8),  // 10.0.0.0/8
        IPv4CIDR(network: 0xAC10_0000, prefixLength: 12), // 172.16.0.0/12
        IPv4CIDR(network: 0xC0A8_0000, prefixLength: 16), // 192.168.0.0/16
        IPv4CIDR(network: 0x6440_0000, prefixLength: 10)  // 100.64.0.0/10
    ]

    public let network: UInt32
    public let prefixLength: Int

    public init(network: UInt32, prefixLength: Int) {
        self.network = network
        self.prefixLength = prefixLength
    }

    public var description: String {
        "\(Self.string(from: network))/\(prefixLength)"
    }

    public var lastAddress: UInt32 {
        let hostBits = 32 - prefixLength
        guard hostBits > 0 else { return network }
        return network | (UInt32.max >> UInt32(prefixLength))
    }

    public func contains(_ other: IPv4CIDR) -> Bool {
        other.network >= network && other.lastAddress <= lastAddress
    }

    public func overlaps(_ other: IPv4CIDR) -> Bool {
        contains(other) || other.contains(self)
    }

    /// Returns the portions of this CIDR that remain after subtracting the
    /// supplied ranges. Results are aligned CIDRs and never cover excluded
    /// addresses, including when an exclusion covers only part of this CIDR.
    public func subtracting(_ exclusions: [IPv4CIDR]) -> [IPv4CIDR] {
        exclusions.reduce([self]) { remaining, exclusion in
            remaining.flatMap { $0.subtracting(exclusion) }
        }
    }

    private func subtracting(_ exclusion: IPv4CIDR) -> [IPv4CIDR] {
        guard overlaps(exclusion) else { return [self] }
        guard !exclusion.contains(self) else { return [] }
        guard prefixLength < 32 else { return [] }

        let childPrefix = prefixLength + 1
        let splitBit = UInt32(1) << UInt32(32 - childPrefix)
        let lower = IPv4CIDR(network: network, prefixLength: childPrefix)
        let upper = IPv4CIDR(network: network | splitBit, prefixLength: childPrefix)
        return lower.subtracting(exclusion) + upper.subtracting(exclusion)
    }

    /// Returns the smallest parent network when these two CIDRs are the exact
    /// aligned siblings of that parent. Merging siblings is lossless: the
    /// resulting route covers exactly the same addresses as both inputs.
    public func mergedWithSibling(_ other: IPv4CIDR) -> IPv4CIDR? {
        guard prefixLength == other.prefixLength, prefixLength > 0 else { return nil }
        let parentPrefix = prefixLength - 1
        let parentMask = parentPrefix == 0
            ? UInt32.zero
            : UInt32.max << UInt32(32 - parentPrefix)
        guard (network & parentMask) == (other.network & parentMask) else { return nil }
        return IPv4CIDR(network: network & parentMask, prefixLength: parentPrefix)
    }

    public static func parse(_ raw: String, defaultPrefixLength: Int = 32) -> IPv4CIDR? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2 else { return nil }
        let ip = parseAddress(String(components[0]))
        guard let ip else { return nil }
        let prefix: Int
        if components.count == 2 {
            guard let parsed = Int(components[1]), (0...32).contains(parsed) else { return nil }
            prefix = parsed
        } else {
            prefix = defaultPrefixLength
        }
        guard (0...32).contains(prefix) else { return nil }
        let mask = prefix == 0 ? UInt32.zero : UInt32.max << UInt32(32 - prefix)
        return IPv4CIDR(network: ip & mask, prefixLength: prefix)
    }

    public static func canonical(_ raw: String, defaultPrefixLength: Int = 32) -> String? {
        parse(raw, defaultPrefixLength: defaultPrefixLength)?.description
    }

    public static func addressString(from cidr: String) -> String? {
        guard let parsed = parse(cidr) else { return nil }
        return string(from: parsed.network)
    }

    public static func parseAddress(_ raw: String) -> UInt32? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        for _ in parts.count..<4 {
            value <<= 8
        }
        return value
    }

    public static func string(from value: UInt32) -> String {
        [
            (value >> 24) & 255,
            (value >> 16) & 255,
            (value >> 8) & 255,
            value & 255
        ].map(String.init).joined(separator: ".")
    }
}

public struct TargetListBuilder: Sendable {
    public let paths: TailscaleRoutePaths
    private let loader: any TextResourceLoading
    private let resolver: any DomainResolving

    public init(
        paths: TailscaleRoutePaths = .system,
        loader: any TextResourceLoading = URLTextResourceLoader(),
        resolver: (any DomainResolving)? = nil
    ) {
        self.paths = paths
        self.loader = loader
        self.resolver = resolver ?? SystemDomainResolver()
    }

    /// Build the desired list. Normal route application uses the validated
    /// JSON cache when it is fresh; the explicit list-update action passes
    /// `refreshSource: true` to force a network download. Endpoint CIDRs
    /// (e.g. the active Exit Node's public address) are excluded with the
    /// same force as the built-in protected ranges.
    public func build(
        configuration: TailscaleRouteConfiguration,
        refreshSource: Bool = false,
        protectedEndpointCIDRs: [IPv4CIDR] = [],
        externalDirectCIDRs: [IPv4CIDR] = []
    ) throws -> TargetListBuildResult {
        let store = AtomicStore(paths: paths)
        try store.prepareDirectories()

        var warnings: [String] = []
        var cidrs = Set<String>()
        var sourceMetadata: CIDRSourceMetadata?

        if let sourceURL = configuration.chinaListURL {
            let sourceCache = try? store.read(ChinaCIDRCache.self, from: paths.chinaCache)
            var usableSourceCache = sourceCache.flatMap {
                isValidCache($0) && $0.metadata.sourceURL == sourceURL.absoluteString ? $0 : nil
            }
            if usableSourceCache == nil,
               let migrated = migrateLegacyTextCache(for: sourceURL)
            {
                try? store.write(migrated, to: paths.chinaCache)
                try? store.remove(paths.chinaCIDRs)
                try? store.remove(paths.chinaSourceURL)
                usableSourceCache = migrated
            }
            let cachedCIDRs = usableSourceCache?.cidrs ?? []
            let isFresh = usableSourceCache.map { isFreshCache(for: sourceURL, metadata: $0.metadata) } ?? false
            if !refreshSource {
                guard let usableSourceCache else {
                    // Cache-only builds must never turn a missing, invalid, or
                    // source-mismatched cache into an implicit source fetch.
                    // Throw before writing desired files so an existing target
                    // summary remains intact for the caller to keep using.
                    throw TargetListError.cannotReadSource(
                        "中国 IP 清单缓存缺失、无效或来源不匹配，请手动更新中国 IP 清单"
                    )
                }
                cidrs.formUnion(usableSourceCache.cidrs)
                sourceMetadata = usableSourceCache.metadata
                if !isFresh {
                    warnings.append("中国 IP 清单缓存已过期，需要手动更新；本次继续使用 last-known-good 缓存")
                }
            } else {
                switch loader.load(sourceURL) {
                case .success(let data):
                    do {
                        let validated = try validateSource(data)
                        let metadata = CIDRSourceMetadata(
                            sourceURL: sourceURL.absoluteString,
                            sourceSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                            cidrSHA256: Self.hashCIDRs(validated.cidrs),
                            entryCount: validated.cidrs.count,
                            rejectedLineCount: validated.rejectedLineCount
                        )
                        let cache = ChinaCIDRCache(cidrs: validated.cidrs, metadata: metadata)
                        try store.write(cache, to: paths.chinaCache)
                        try? store.remove(paths.chinaCIDRs)
                        try? store.remove(paths.chinaSourceURL)
                        cidrs.formUnion(validated.cidrs)
                        sourceMetadata = metadata
                        if validated.rejectedLineCount > 0 {
                            warnings.append("中国 IP 清单有 \(validated.rejectedLineCount) 行格式无效，已排除后缓存")
                        }
                    } catch {
                        guard !cachedCIDRs.isEmpty else { throw error }
                        cidrs.formUnion(cachedCIDRs)
                        sourceMetadata = usableSourceCache?.metadata
                        warnings.append("新中国 IP 清单校验或保存失败，继续使用 last-known-good 缓存：\(error.localizedDescription)")
                    }
                case .failure(let error):
                    if !cachedCIDRs.isEmpty {
                        cidrs.formUnion(cachedCIDRs)
                        sourceMetadata = usableSourceCache?.metadata
                        warnings.append("中国 IP 清单下载失败，已使用缓存：\(error.localizedDescription)")
                    } else {
                        throw TargetListError.cannotReadSource(error.localizedDescription)
                    }
                }
            }
        } else {
            // A cache tied to a previous source must never become an implicit
            // source when the user has removed the China list URL.
        }

        for value in configuration.fixedDirectIPs + configuration.manualIPs {
            if let cidr = IPv4CIDR.canonical(value) {
                cidrs.insert(cidr)
            } else if value.contains(":") {
                warnings.append("忽略 IPv6 地址：IPv6 已交由系统与 Tailscale 处理")
            } else {
                warnings.append("忽略无效手动 IP：\(value)")
            }
        }
        let domainResolution = resolveConfiguredDomains(configuration.domainNames)
        warnings.append(contentsOf: domainResolution.warnings)
        for address in domainResolution.ipv4 {
            cidrs.insert("\(address)/32")
        }
        guard !cidrs.isEmpty else { throw TargetListError.empty }

        let exclusions = configuration.excludeCIDRs.compactMap { raw -> IPv4CIDR? in
            guard let value = IPv4CIDR.parse(raw) else {
                warnings.append("忽略无效排除 CIDR：\(raw)")
                return nil
            }
            return value
        }
        let allExclusions = IPv4CIDR.protectedRouteCIDRs + protectedEndpointCIDRs + exclusions + externalDirectCIDRs
        let filtered = cidrs.compactMap { IPv4CIDR.parse($0) }.flatMap { candidate in
            candidate.subtracting(allExclusions)
        }
        let routableDomainIPv4 = domainResolution.ipv4.filter { address in
            guard let address = IPv4CIDR.parse("\(address)/32") else { return false }
            return !allExclusions.contains(where: { $0.overlaps(address) })
        }
        let collapsed = collapseIPv4(filtered)
        let sortedCIDRs = collapsed
            .sorted { left, right in
                if left.network == right.network { return left.prefixLength < right.prefixLength }
                return left.network < right.network
            }
            .map { $0.description }

        guard sortedCIDRs.count <= 100_000 else { throw TargetListError.tooManyTargets(sortedCIDRs.count) }
        let contents = sortedCIDRs.joined(separator: "\n") + "\n"
        let hash = SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
        let list = DesiredRouteList(
            cidrs: sortedCIDRs,
            source: configuration.chinaListURL?.absoluteString,
            sha256: hash,
            sourceMetadata: sourceMetadata
        )
        try store.writeText(contents, to: paths.desiredCIDRs)
        try store.write(list, to: paths.desiredMetadata)

        return TargetListBuildResult(
            list: list,
            domainIPv4: routableDomainIPv4,
            domainIPv6: domainResolution.ipv6,
            hostAddresses: domainResolution.hosts,
            warnings: warnings
        )
    }

    /// Resolve only the configured temporary domains. This intentionally does
    /// not read or rebuild the China CIDR source and does not write desired
    /// route-list files. The only persistent write is the atomic per-domain
    /// DNS last-known-good cache.
    public func resolveConfiguredDomains(_ domains: [String]) -> DomainResolutionResult {
        var warnings: [String] = []
        let resolvedDomains = Set(domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            .flatMap { [$0, "www.\($0)"] })

        var cachedByDomain: [String: HostAddress] = [:]
        if let cached = try? AtomicStore(paths: paths).read(
            DomainResolutionCache.self,
            from: paths.domainAnswers
        ) {
            for host in cached.hosts {
                cachedByDomain[host.domain] = host
            }
        }

        var cacheEntries = cachedByDomain
        var entries: [DomainResolutionEntry] = []
        for domain in resolvedDomains.sorted() {
            let cached = cachedByDomain[domain]
            let ipv4Result = resolver.resolveIPv4(domain)
            let ipv6Result = resolver.resolveIPv6(domain)
            let selectedIPv4: [String]
            let selectedIPv4Status: DomainResolutionStatus
            if let ipv4Result {
                selectedIPv4 = ipv4Result
                selectedIPv4Status = ipv4Result.isEmpty ? .confirmedEmpty : .fresh
            } else if let cached, !cached.ipv4Addresses.isEmpty {
                selectedIPv4 = cached.ipv4Addresses
                selectedIPv4Status = .lastKnownGood
                warnings.append("域名 A 记录暂时解析失败，继续使用 last-known-good：\(domain)")
            } else {
                selectedIPv4 = []
                selectedIPv4Status = .unavailable
                warnings.append("域名 A 记录暂时无法解析，未改变已有域名路由：\(domain)")
            }

            let selectedIPv6: [String]
            let selectedIPv6Status: DomainResolutionStatus
            if let ipv6Result {
                selectedIPv6 = ipv6Result
                selectedIPv6Status = ipv6Result.isEmpty ? .confirmedEmpty : .fresh
            } else if let cached, !cached.ipv6Addresses.isEmpty {
                selectedIPv6 = cached.ipv6Addresses
                selectedIPv6Status = .lastKnownGood
                warnings.append("域名 AAAA 记录暂时解析失败，继续使用 last-known-good：\(domain)")
            } else {
                selectedIPv6 = []
                selectedIPv6Status = .unavailable
                warnings.append("域名 AAAA 记录暂时无法解析，未改变已有域名 IPv6 路由：\(domain)")
            }

            let entry = DomainResolutionEntry(
                domain: domain,
                ipv4Addresses: selectedIPv4,
                ipv6Addresses: selectedIPv6,
                ipv4Status: selectedIPv4Status,
                ipv6Status: selectedIPv6Status
            )
            entries.append(entry)

            // A successful empty answer is a real deletion. A nil answer is
            // uncertainty and must never erase the cached family.
            if selectedIPv4Status == .confirmedEmpty {
                cacheEntries[domain] = HostAddress(
                    domain: domain,
                    ipv4Addresses: [],
                    ipv6Addresses: selectedIPv6
                )
            }
            if selectedIPv6Status == .confirmedEmpty {
                cacheEntries[domain] = HostAddress(
                    domain: domain,
                    ipv4Addresses: selectedIPv4,
                    ipv6Addresses: []
                )
            }
            if !selectedIPv4.isEmpty || !selectedIPv6.isEmpty {
                cacheEntries[domain] = HostAddress(
                    domain: domain,
                    ipv4Addresses: selectedIPv4,
                    ipv6Addresses: selectedIPv6
                )
            } else if selectedIPv4Status == .confirmedEmpty,
                      selectedIPv6Status == .confirmedEmpty
            {
                cacheEntries.removeValue(forKey: domain)
            }
        }

        try? AtomicStore(paths: paths).write(
            DomainResolutionCache(hosts: cacheEntries.values.sorted { $0.domain < $1.domain }),
            to: paths.domainAnswers
        )
        return DomainResolutionResult(entries: entries, warnings: warnings)
    }

    private func isFreshCache(for sourceURL: URL, metadata: CIDRSourceMetadata) -> Bool {
        let age = Date().timeIntervalSince(metadata.fetchedAt)
        return metadata.sourceURL == sourceURL.absoluteString
            && metadata.formatVersion == CIDRSourceMetadata.currentFormatVersion
            && age >= 0
            && age < 24 * 60 * 60
    }

    private func isValidCache(_ cache: ChinaCIDRCache) -> Bool {
        cache.metadata.formatVersion == CIDRSourceMetadata.currentFormatVersion
            && !cache.cidrs.isEmpty
            && cache.cidrs.count <= 100_000
            && cache.metadata.entryCount == cache.cidrs.count
            && cache.metadata.rejectedLineCount >= 0
            && cache.metadata.sourceSHA256.count == 64
            && cache.metadata.cidrSHA256 == Self.hashCIDRs(cache.cidrs)
            && cache.cidrs.allSatisfy { IPv4CIDR.canonical($0) == $0 }
    }

    private func migrateLegacyTextCache(for sourceURL: URL) -> ChinaCIDRCache? {
        guard let recordedSource = try? String(contentsOf: paths.chinaSourceURL, encoding: .utf8),
              recordedSource.trimmingCharacters(in: .whitespacesAndNewlines) == sourceURL.absoluteString
        else { return nil }
        guard let data = try? Data(contentsOf: paths.chinaCIDRs),
              let validated = try? validateSource(data)
        else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: paths.chinaCIDRs.path)
        let fetchedAt = (attributes?[.modificationDate] as? Date) ?? Date.distantPast
        let metadata = CIDRSourceMetadata(
            sourceURL: sourceURL.absoluteString,
            fetchedAt: fetchedAt,
            sourceSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            cidrSHA256: Self.hashCIDRs(validated.cidrs),
            entryCount: validated.cidrs.count,
            rejectedLineCount: validated.rejectedLineCount
        )
        return ChinaCIDRCache(cidrs: validated.cidrs, metadata: metadata)
    }

    private static func hashCIDRs(_ cidrs: [String]) -> String {
        let canonical = cidrs.compactMap { IPv4CIDR.canonical($0) }.sorted().joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func validateSource(_ data: Data) throws -> (cidrs: [String], rejectedLineCount: Int) {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw TargetListError.invalidSource("文件不是有效 UTF-8")
        }
        var seen = Set<String>()
        var rejectedLineCount = 0
        var recordCount = 0
        for line in contents.split(whereSeparator: \.isNewline) {
            let raw = line.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { continue }
            recordCount += 1
            guard recordCount <= 200_000 else {
                throw TargetListError.invalidSource("有效记录行数超过 200000 条安全上限")
            }
            if let canonical = IPv4CIDR.canonical(String(raw)) {
                seen.insert(canonical)
            } else {
                rejectedLineCount += 1
            }
        }
        let cidrs = seen.sorted {
            (IPv4CIDR.parse($0)?.network ?? 0) < (IPv4CIDR.parse($1)?.network ?? 0)
        }
        guard !cidrs.isEmpty else { throw TargetListError.invalidSource("没有找到有效 IPv4 CIDR") }
        guard cidrs.count <= 100_000 else { throw TargetListError.tooManyTargets(cidrs.count) }
        if rejectedLineCount > 0,
           (recordCount < 100 || rejectedLineCount * 100 > recordCount)
        {
            throw TargetListError.invalidSource("格式异常行 \(rejectedLineCount)/\(recordCount)，超过 1% 校验上限")
        }
        return (cidrs, rejectedLineCount)
    }

    /// Collapse only exact sibling networks. This keeps the target address
    /// set identical while reducing the number of route(8) invocations. The
    /// pass repeats because four /24 siblings can become one /22, etc.
    private func collapseIPv4(_ cidrs: [IPv4CIDR]) -> [IPv4CIDR] {
        var current = Array(Set(cidrs))
        var changed = true
        while changed {
            changed = false
            let sorted = current.sorted {
                if $0.prefixLength == $1.prefixLength { return $0.network < $1.network }
                return $0.prefixLength < $1.prefixLength
            }
            var next: [IPv4CIDR] = []
            var index = 0
            while index < sorted.count {
                if index + 1 < sorted.count,
                   let merged = sorted[index].mergedWithSibling(sorted[index + 1]) {
                    next.append(merged)
                    index += 2
                    changed = true
                } else {
                    next.append(sorted[index])
                    index += 1
                }
            }
            current = Array(Set(next))
        }
        return current
    }

    /// Filters out addresses that must never become domain IPv6 host routes:
    /// unspecified/loopback, IPv4-mapped (`::ffff:a.b.c.d`, which getaddrinfo
    /// synthesizes for A answers), IPv4-compatible, NAT64/DNS64-synthesized,
    /// link-local, ULA and multicast. Only real global unicast AAAA answers
    /// are meaningful split-route targets.
    static func usableDomainIPv6(_ address: in6_addr) -> Bool {
        withUnsafeBytes(of: address) { raw in
            let b = { (index: Int) -> UInt8 in index < raw.count ? raw[index] : 0 }
            let zeroRange = { (range: Range<Int>) in
                range.allSatisfy { b($0) == 0 }
            }
            // :: (unspecified), ::1 (loopback) and ::x (IPv4-compatible)
            if zeroRange(0..<12) { return false }
            // ::ffff:0:0/96 IPv4-mapped
            if zeroRange(0..<10), b(10) == 0xff, b(11) == 0xff { return false }
            // 64:ff9b::/96 NAT64/DNS64 synthesized
            if b(0) == 0x00, b(1) == 0x64, b(2) == 0xff, b(3) == 0x9b { return false }
            // fe80::/10 link-local
            if b(0) == 0xfe, (b(1) & 0xc0) == 0x80 { return false }
            // fc00::/7 unique-local
            if (b(0) & 0xfe) == 0xfc { return false }
            // ff00::/8 multicast
            if b(0) == 0xff { return false }
            return true
        }
    }

}

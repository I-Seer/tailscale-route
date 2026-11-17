import CryptoKit
import Foundation

public struct TailscaleRoutePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var desiredCIDRs: URL { root.appendingPathComponent("desired.cidrs") }
    /// Downgrade-only plain-text China list. New versions migrate it into
    /// `chinaCache` and remove it.
    public var chinaCIDRs: URL { root.appendingPathComponent("china.cidrs") }
    public var chinaCache: URL { root.appendingPathComponent("china-cache.json") }
    public var chinaSourceURL: URL { root.appendingPathComponent("china.source") }
    public var desiredMetadata: URL { root.appendingPathComponent("desired.json") }
    public var manualIPs: URL { root.appendingPathComponent("manual.ips") }
    public var excludeCIDRs: URL { root.appendingPathComponent("exclude.cidrs") }
    public var domainIPs: URL { root.appendingPathComponent("domain.ips") }
    public var domainIPv6IPs: URL { root.appendingPathComponent("domain.ipv6") }
    public var domainAnswers: URL { root.appendingPathComponent("domain-answers.json") }
    public var preApplyRoutes: URL { root.appendingPathComponent("pre-apply-routes.json") }
    public var postApplyRoutes: URL { root.appendingPathComponent("post-apply-routes.json") }
    public var lastOperation: URL { root.appendingPathComponent("last-operation.json") }
    public var lastSuccess: URL { root.appendingPathComponent("last-success.json") }
    public var lock: URL { root.appendingPathComponent("route.lock") }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    public static var user: TailscaleRoutePaths {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tailscale-route", isDirectory: true)
            ?? URL(fileURLWithPath: "/tmp/tailscale-route", isDirectory: true)
        return TailscaleRoutePaths(root: root)
    }

    public static var system: TailscaleRoutePaths {
        TailscaleRoutePaths(root: URL(fileURLWithPath: "/Library/Application Support/tailscale-route", isDirectory: true))
    }
}

public struct AtomicStore: Sendable {
    public let paths: TailscaleRoutePaths

    public init(paths: TailscaleRoutePaths) {
        self.paths = paths
    }

    public func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    }

    public func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    public func writeText(_ text: String, to url: URL) throws {
        try prepareDirectories()
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    public func readText(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func clearGeneratedFiles() throws {
        // Keep the validated China list cache. It is user data needed for a
        // later re-enable, not disposable operation output.
        for url in [paths.desiredCIDRs, paths.desiredMetadata, paths.chinaCIDRs, paths.chinaSourceURL, paths.manualIPs, paths.excludeCIDRs, paths.domainIPs, paths.domainIPv6IPs, paths.lastSuccess] {
            try remove(url)
        }
    }

    /// Remove generated files that were only mirrors or downgrade artifacts.
    /// The JSON China cache, domain configuration, and route transaction
    /// journals are intentionally retained.
    public func removeObsoleteGeneratedFiles() throws {
        // Keep china.source until TargetListBuilder can verify that a legacy
        // plain-text cache belongs to the currently configured URL.
        let obsolete = [paths.manualIPs, paths.excludeCIDRs, paths.domainIPs, paths.domainIPv6IPs]
        for url in obsolete {
            try remove(url)
        }
        // A validated JSON cache supersedes the old plain-text duplicate. If
        // the JSON cache is absent, leave the duplicate for one-time migration
        // by TargetListBuilder so an existing China list is never discarded.
        if FileManager.default.fileExists(atPath: paths.chinaCache.path) {
            try remove(paths.chinaCIDRs)
        }
    }

    public func loadConfiguration() -> TailscaleRouteConfiguration {
        (try? read(TailscaleRouteConfiguration.self, from: paths.config)) ?? TailscaleRouteConfiguration()
    }

    public func saveConfiguration(_ configuration: TailscaleRouteConfiguration) throws {
        try write(configuration, to: paths.config)
    }

    public func loadState() -> PersistedRouteState {
        (try? read(PersistedRouteState.self, from: paths.lastSuccess)) ?? PersistedRouteState()
    }

    /// Rewrites pre-v8 state once so obsolete split-route records and
    /// persisted transient warnings disappear from disk while all current
    /// route ownership and Tailscale preference data remains intact. The new
    /// domain-scoped ledgers decode as empty and are populated by the next
    /// full apply without guessing ownership from destinations alone.
    public func migrateStateIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: paths.lastSuccess.path),
              let state = try? read(PersistedRouteState.self, from: paths.lastSuccess),
              state.schemaVersion < PersistedRouteState.currentSchemaVersion
        else { return }
        _ = try saveState(state)
    }

    @discardableResult
    public func saveState(_ state: PersistedRouteState) throws -> PersistedRouteState {
        var persisted = state
        let previousGeneration = loadState().generation
        persisted.schemaVersion = PersistedRouteState.currentSchemaVersion
        persisted.generation = max(state.generation, previousGeneration) + 1
        persisted.ledgerFingerprint = ledgerFingerprint(for: persisted)
        try write(persisted, to: paths.lastSuccess)
        return persisted
    }

    private func ledgerFingerprint(for state: PersistedRouteState) -> String {
        let ipv4 = state.managedRoutes.map { "v4|\($0.cidr)|\($0.gateway)|\($0.interfaceName)" }
        let domainIPv4 = state.managedDomainIPv4Routes.map {
            "domain-v4|\($0.domain)|\($0.route.cidr)|\($0.route.gateway)|\($0.route.interfaceName)"
        }
        let ipv6 = state.managedIPv6Routes.map { "v6|\($0.address)|\($0.gateway)|\($0.interfaceName)" }
        let domainIPv6 = state.managedDomainIPv6Routes.map {
            "domain-v6|\($0.domain)|\($0.route.address)|\($0.route.gateway)|\($0.route.interfaceName)"
        }
        let endpoint = state.managedExitNodeEndpointRoutes.map { "endpoint|\($0.cidr)|\($0.gateway)|\($0.interfaceName)" }
        let dnsServer = state.managedDNSServerRoutes.map { "dns-server|\($0.cidr)|\($0.gateway)|\($0.interfaceName)" }
        let externalNetwork = state.managedExternalGatewayRoutes.map { "external-network|\($0.cidr)|\($0.gateway)|\($0.interfaceName)" }
        let canonical = (ipv4 + domainIPv4 + ipv6 + domainIPv6 + endpoint + dnsServer + externalNetwork)
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public final class TailscaleRouteLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let store: AtomicStore
    private let formatter: ISO8601DateFormatter

    public init(paths: TailscaleRoutePaths) {
        self.store = AtomicStore(paths: paths)
        self.formatter = ISO8601DateFormatter()
    }

    public func info(_ message: String) { append(level: "INFO", message: message) }
    public func warning(_ message: String) { append(level: "WARN", message: message) }
    public func error(_ message: String) { append(level: "ERROR", message: message) }

    public var logURL: URL {
        store.paths.logs.appendingPathComponent("tailscale-route.log")
    }

    private func append(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try store.prepareDirectories()
            let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try store.writeText(line, to: logURL)
            }
        } catch {
            // Logging must never make a route operation fail.
        }
    }
}

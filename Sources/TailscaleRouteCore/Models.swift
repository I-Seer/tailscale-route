import Foundation

public struct NetworkFingerprint: Codable, Equatable, Sendable, CustomStringConvertible {
    public let gateway: String?
    public let ipv6Gateway: String?
    public let physicalInterface: String?
    public let tailscaleInterface: String?
    public let defaultRouteSignature: String?
    public let tailscaleExitNode: String?
    public let tailscaleExitNodeEndpoint: String?

    public init(
        gateway: String?,
        ipv6Gateway: String? = nil,
        physicalInterface: String?,
        tailscaleInterface: String?,
        defaultRouteSignature: String?,
        tailscaleExitNode: String? = nil,
        tailscaleExitNodeEndpoint: String? = nil
    ) {
        self.gateway = gateway
        self.ipv6Gateway = ipv6Gateway
        self.physicalInterface = physicalInterface
        self.tailscaleInterface = tailscaleInterface
        self.defaultRouteSignature = defaultRouteSignature
        self.tailscaleExitNode = tailscaleExitNode
        self.tailscaleExitNodeEndpoint = tailscaleExitNodeEndpoint
    }

    public var description: String {
        [gateway, ipv6Gateway, physicalInterface, tailscaleInterface, defaultRouteSignature, tailscaleExitNode, tailscaleExitNodeEndpoint]
            .map { value in
                guard let value, !value.isEmpty else { return "-" }
                return value
            }
            .joined(separator: "|")
    }
}

public struct NetworkSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let physicalInterface: String?
    public let physicalPortName: String?
    public let gateway: String?
    public let ipv6Gateway: String?
    public let defaultRouteSignature: String?
    public let tailscaleInterface: String?
    public let tailscaleAddress: String?
    public let tailscaleExitNode: String?
    /// Public IPv4 address of the active Exit Node's WireGuard endpoint
    /// (from the peer's `CurAddr`). Nil for DERP-only connections, IPv6
    /// endpoints, or on-link private addresses.
    public let tailscaleExitNodeEndpoint: String?

    public init(
        capturedAt: Date = Date(),
        physicalInterface: String?,
        physicalPortName: String?,
        gateway: String?,
        ipv6Gateway: String? = nil,
        defaultRouteSignature: String?,
        tailscaleInterface: String?,
        tailscaleAddress: String?,
        tailscaleExitNode: String?,
        tailscaleExitNodeEndpoint: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.physicalInterface = physicalInterface
        self.physicalPortName = physicalPortName
        self.gateway = gateway
        self.ipv6Gateway = ipv6Gateway
        self.defaultRouteSignature = defaultRouteSignature
        self.tailscaleInterface = tailscaleInterface
        self.tailscaleAddress = tailscaleAddress
        self.tailscaleExitNode = tailscaleExitNode
        self.tailscaleExitNodeEndpoint = tailscaleExitNodeEndpoint
    }

    public var fingerprint: NetworkFingerprint {
        NetworkFingerprint(
            gateway: gateway,
            ipv6Gateway: ipv6Gateway,
            physicalInterface: physicalInterface,
            tailscaleInterface: tailscaleInterface,
            defaultRouteSignature: defaultRouteSignature,
            tailscaleExitNode: tailscaleExitNode,
            tailscaleExitNodeEndpoint: tailscaleExitNodeEndpoint
        )
    }
}

/// The canonical identity of the currently visible external networks.
///
/// This key is deliberately narrower than `NetworkFingerprint`: it contains
/// only the hardware port, interface, address, and CIDR for each detected
/// external network. Gateway/default-route changes and Tailscale state belong
/// to other reconciliation domains and must not change this key.
public struct ExternalNetworkSnapshotKey: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public struct Entry: Codable, Equatable, Hashable, Sendable {
        public let hardwarePortName: String
        public let interfaceName: String
        public let address: String
        public let cidr: String

        public init(
            hardwarePortName: String,
            interfaceName: String,
            address: String,
            cidr: String
        ) {
            self.hardwarePortName = hardwarePortName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.interfaceName = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            self.cidr = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public init(network: ExternalDirectNetwork) {
            self.init(
                hardwarePortName: network.hardwarePortName,
                interfaceName: network.interfaceName,
                address: network.address,
                cidr: network.cidr
            )
        }
    }

    /// Entries are deduplicated and sorted lexicographically by the tuple
    /// `(hardwarePortName, interfaceName, address, cidr)`.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = Array(Set(entries)).sorted(by: Self.isOrderedBefore)
    }

    public init(networks: [ExternalDirectNetwork]) {
        self.init(entries: networks.map(Entry.init(network:)))
    }

    public static let empty = ExternalNetworkSnapshotKey(entries: [])

    public var isEmpty: Bool { entries.isEmpty }

    public var description: String {
        entries
            .map { entry in
                [entry.hardwarePortName, entry.interfaceName, entry.address, entry.cidr]
                    .joined(separator: "|")
            }
            .joined(separator: ";")
    }

    private static func isOrderedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.hardwarePortName != rhs.hardwarePortName {
            return lhs.hardwarePortName < rhs.hardwarePortName
        }
        if lhs.interfaceName != rhs.interfaceName {
            return lhs.interfaceName < rhs.interfaceName
        }
        if lhs.address != rhs.address {
            return lhs.address < rhs.address
        }
        return lhs.cidr < rhs.cidr
    }
}

public struct RouteEntry: Codable, Equatable, Sendable {
    public let destination: String
    public let gateway: String
    public let flags: String
    public let interfaceName: String
    public let rawLine: String

    public init(
        destination: String,
        gateway: String,
        flags: String,
        interfaceName: String,
        rawLine: String
    ) {
        self.destination = destination
        self.gateway = gateway
        self.flags = flags
        self.interfaceName = interfaceName
        self.rawLine = rawLine
    }
}

public struct TailscaleStatusSummary: Codable, Equatable, Sendable {
    public let isInstalled: Bool
    public let isRunning: Bool
    public let selfAddress: String?
    public let selfHostName: String?
    public let exitNode: String?
    public let exitNodeEndpoint: String?
    public let exitNodeAllowLANAccess: Bool?
    public let routeAll: Bool?

    public init(
        isInstalled: Bool,
        isRunning: Bool,
        selfAddress: String?,
        selfHostName: String?,
        exitNode: String?,
        exitNodeEndpoint: String? = nil,
        exitNodeAllowLANAccess: Bool? = nil,
        routeAll: Bool? = nil
    ) {
        self.isInstalled = isInstalled
        self.isRunning = isRunning
        self.selfAddress = selfAddress
        self.selfHostName = selfHostName
        self.exitNode = exitNode
        self.exitNodeEndpoint = exitNodeEndpoint
        self.exitNodeAllowLANAccess = exitNodeAllowLANAccess
        self.routeAll = routeAll
    }
}

public struct DiagnosticReport: Codable, Sendable {
    public let generatedAt: Date
    public let snapshot: NetworkSnapshot
    public let managedTargets: [String]
    public let actualRoutes: [RouteEntry]
    /// Nil when produced by an older Helper or when IPv6 route enumeration was unavailable.
    public let actualIPv6Routes: [RouteEntry]?
    public let tailscale: TailscaleStatusSummary
    public let externalDirectNetworks: [ExternalDirectNetwork]?
    public let externalSubnetProtectionActive: Bool?
    public let externalSubnetProtectionMessage: String?
    public let warnings: [String]
    public let errors: [String]

    public init(
        generatedAt: Date = Date(),
        snapshot: NetworkSnapshot,
        managedTargets: [String],
        actualRoutes: [RouteEntry],
        actualIPv6Routes: [RouteEntry]? = nil,
        tailscale: TailscaleStatusSummary,
        externalDirectNetworks: [ExternalDirectNetwork]? = nil,
        externalSubnetProtectionActive: Bool? = nil,
        externalSubnetProtectionMessage: String? = nil,
        warnings: [String],
        errors: [String]
    ) {
        self.generatedAt = generatedAt
        self.snapshot = snapshot
        self.managedTargets = managedTargets
        self.actualRoutes = actualRoutes
        self.actualIPv6Routes = actualIPv6Routes
        self.tailscale = tailscale
        self.externalDirectNetworks = externalDirectNetworks
        self.externalSubnetProtectionActive = externalSubnetProtectionActive
        self.externalSubnetProtectionMessage = externalSubnetProtectionMessage
        self.warnings = warnings
        self.errors = errors
    }

    public var isHealthy: Bool {
        errors.isEmpty && warnings.isEmpty
    }
}

public struct TailscalePreferenceLease: Codable, Equatable, Sendable {
    public let originalAcceptRoutes: Bool
    public let originalAllowLANAccess: Bool
    public let managedLANAccess: Bool?
    public let exitNodeID: String?
    public let tailnetControlURL: String?
    /// Tailscale login NodeID when the lease was taken; nil for leases written by older versions.
    public let nodeID: String?
    public let startedAt: Date

    private enum CodingKeys: String, CodingKey {
        case originalAcceptRoutes
        case originalAllowLANAccess
        // Keep the prior on-disk key so leases written by older versions migrate safely.
        case managedLANAccess = "enabledLANAccess"
        case exitNodeID
        case tailnetControlURL
        case nodeID
        case startedAt
    }

    public init(
        originalAcceptRoutes: Bool,
        originalAllowLANAccess: Bool,
        managedLANAccess: Bool? = nil,
        exitNodeID: String?,
        tailnetControlURL: String?,
        nodeID: String? = nil,
        startedAt: Date = Date()
    ) {
        self.originalAcceptRoutes = originalAcceptRoutes
        self.originalAllowLANAccess = originalAllowLANAccess
        self.managedLANAccess = managedLANAccess
        self.exitNodeID = exitNodeID
        self.tailnetControlURL = tailnetControlURL
        self.nodeID = nodeID
        self.startedAt = startedAt
    }
}

public enum RouteLifecycleState: String, Codable, Sendable {
    case disabled
    case partial
    case enabled
    case networkChanging
    case applying
    case error
    case paused
    case unavailable
}

public struct TailscaleRouteConfiguration: Codable, Equatable, Sendable {
    public var chinaListURL: URL?
    public var fixedDirectIPs: [String]
    public var manualIPs: [String]
    public var domainNames: [String]
    public var excludeCIDRs: [String]
    public var autoFollowNetwork: Bool
    public var enabled: Bool
    /// Resolvers queried (with `dig @server`) for temporary domains. Each is
    /// pinned to the physical gateway before lookups. Empty means defaults.
    public var dnsServers: [String]
    /// Targets for the one-click connectivity test.
    public var connectivityTest: ConnectivityTestSettings

    public init(
        chinaListURL: URL? = TailscaleRouteConfiguration.defaultChinaListURL,
        fixedDirectIPs: [String] = [],
        manualIPs: [String] = [],
        domainNames: [String] = [],
        excludeCIDRs: [String] = [],
        autoFollowNetwork: Bool = true,
        enabled: Bool = false,
        dnsServers: [String] = DirectDNSDomainResolver.defaultServers,
        connectivityTest: ConnectivityTestSettings = ConnectivityTestSettings()
    ) {
        self.dnsServers = dnsServers
        self.connectivityTest = connectivityTest
        self.chinaListURL = chinaListURL
        self.fixedDirectIPs = fixedDirectIPs
        self.manualIPs = manualIPs
        self.domainNames = domainNames
        self.excludeCIDRs = excludeCIDRs
        self.autoFollowNetwork = autoFollowNetwork
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case chinaListURL
        case fixedDirectIPs
        case manualIPs
        case domainNames
        case excludeCIDRs
        case autoFollowNetwork
        case enabled
        case dnsServers
        case connectivityTest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chinaListURL = try container.decodeIfPresent(URL.self, forKey: .chinaListURL) ?? Self.defaultChinaListURL
        fixedDirectIPs = try container.decodeIfPresent([String].self, forKey: .fixedDirectIPs) ?? []
        manualIPs = try container.decodeIfPresent([String].self, forKey: .manualIPs) ?? []
        domainNames = try container.decodeIfPresent([String].self, forKey: .domainNames) ?? []
        excludeCIDRs = try container.decodeIfPresent([String].self, forKey: .excludeCIDRs) ?? []
        autoFollowNetwork = try container.decodeIfPresent(Bool.self, forKey: .autoFollowNetwork) ?? true
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers)
            ?? DirectDNSDomainResolver.defaultServers
        connectivityTest = try container.decodeIfPresent(ConnectivityTestSettings.self, forKey: .connectivityTest)
            ?? ConnectivityTestSettings()
    }

    /// Valid, de-duplicated IPv4 resolver addresses (at most four), falling
    /// back to the defaults when none are usable. IPv4 only: the Helper pins
    /// each server with an IPv4 /32 route to the physical gateway.
    public var effectiveDNSServers: [String] {
        let usable = Self.normalizedDNSServers(dnsServers)
        return usable.isEmpty ? DirectDNSDomainResolver.defaultServers : usable
    }

    /// Parses user input ("1.2.3.4, 5.6.7.8" or one per line) into valid
    /// IPv4 literals, keeping order and dropping duplicates.
    public static func normalizedDNSServers(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            for token in value.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }) {
                let candidate = String(token)
                // Require all four octets: parseAddress also accepts
                // shorthand such as "1.2.3", which dig would not treat as intended.
                guard candidate.split(separator: ".", omittingEmptySubsequences: false).count == 4,
                      IPv4CIDR.parseAddress(candidate) != nil,
                      IPv4CIDR.parse("\(candidate)/32") != nil,
                      !result.contains(candidate)
                else { continue }
                result.append(candidate)
            }
        }
        return Array(result.prefix(4))
    }

    public static let defaultChinaListURL = URL(
        string: "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
    )
}

/// Targets of the one-click layered connectivity test. Stored with the
/// configuration so they can be changed in settings.
public struct ConnectivityTestSettings: Codable, Equatable, Sendable {
    /// IPv4 address probed by the route, ARP, ICMP and TCP layers.
    public var address: String
    public var port: Int
    /// Optional HTTP(S) URL for the application-layer check; empty skips it.
    public var url: String

    public init(address: String = "1.1.1.1", port: Int = 443, url: String = "") {
        self.address = address
        self.port = port
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case address, port, url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? "1.1.1.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 443
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

public struct RouteSpec: Codable, Equatable, Hashable, Sendable {
    public let cidr: String
    public let gateway: String
    public let interfaceName: String

    public init(
        cidr: String,
        gateway: String,
        interfaceName: String
    ) {
        self.cidr = cidr
        self.gateway = gateway
        self.interfaceName = interfaceName
    }
}

/// An IPv4 route owned for one configured temporary domain. Keeping the
/// domain beside the exact route is important: a DNS failure for one domain
/// must not make the incremental transaction delete another domain's route.
public struct ManagedDomainIPv4Route: Codable, Equatable, Hashable, Sendable {
    public let domain: String
    public let route: RouteSpec

    public init(domain: String, route: RouteSpec) {
        self.domain = domain
        self.route = route
    }
}

public struct RouteReplacementPlan: Codable, Equatable, Sendable {
    public let oldRoute: RouteSpec
    public let newRoute: RouteSpec

    public init(oldRoute: RouteSpec, newRoute: RouteSpec) {
        self.oldRoute = oldRoute
        self.newRoute = newRoute
    }
}

/// Read-only summary of the route mutations an apply operation would perform.
public struct RoutePlanPreview: Codable, Equatable, Sendable {
    public let networkFingerprint: NetworkFingerprint
    public let desiredRoutes: [RouteSpec]
    public let alreadyCorrect: [RouteSpec]
    public let additions: [RouteSpec]
    public let replacements: [RouteReplacementPlan]
    public let cleanup: [RouteSpec]
    public let unownedConflicts: [RouteEntry]
    public let errors: [String]
    public let warnings: [String]

    public init(
        networkFingerprint: NetworkFingerprint,
        desiredRoutes: [RouteSpec],
        alreadyCorrect: [RouteSpec],
        additions: [RouteSpec],
        replacements: [RouteReplacementPlan],
        cleanup: [RouteSpec],
        unownedConflicts: [RouteEntry],
        errors: [String],
        warnings: [String]
    ) {
        self.networkFingerprint = networkFingerprint
        self.desiredRoutes = desiredRoutes
        self.alreadyCorrect = alreadyCorrect
        self.additions = additions
        self.replacements = replacements
        self.cleanup = cleanup
        self.unownedConflicts = unownedConflicts
        self.errors = errors
        self.warnings = warnings
    }
}

public struct RouteExplanationCandidate: Codable, Equatable, Sendable {
    public let route: RouteEntry
    public let prefixLength: Int
    public let isAppManaged: Bool
    public let isSelected: Bool
    public let explanation: String

    public init(route: RouteEntry, prefixLength: Int, isAppManaged: Bool, isSelected: Bool, explanation: String) {
        self.route = route
        self.prefixLength = prefixLength
        self.isAppManaged = isAppManaged
        self.isSelected = isSelected
        self.explanation = explanation
    }
}

public struct RouteExplanation: Codable, Equatable, Sendable {
    public let address: String
    public let matchingTargetCIDR: String?
    public let selectedRoute: RouteEntry?
    public let selectedRouteIsAppManaged: Bool
    public let candidates: [RouteExplanationCandidate]
    public let summary: String

    public init(
        address: String,
        matchingTargetCIDR: String?,
        selectedRoute: RouteEntry?,
        selectedRouteIsAppManaged: Bool,
        candidates: [RouteExplanationCandidate],
        summary: String
    ) {
        self.address = address
        self.matchingTargetCIDR = matchingTargetCIDR
        self.selectedRoute = selectedRoute
        self.selectedRouteIsAppManaged = selectedRouteIsAppManaged
        self.candidates = candidates
        self.summary = summary
    }
}

public enum ConnectivityLayerStatus: String, Codable, Sendable {
    case passed
    case failed
    case unknown
    case skipped
    case serviceError
}

public struct ConnectivityLayerResult: Codable, Equatable, Sendable {
    public let layer: String
    public let status: ConnectivityLayerStatus
    public let detail: String

    public init(layer: String, status: ConnectivityLayerStatus, detail: String) {
        self.layer = layer
        self.status = status
        self.detail = detail
    }
}

public struct ConnectivityDiagnosticReport: Codable, Equatable, Sendable {
    public let target: String
    public let layers: [ConnectivityLayerResult]

    public init(target: String, layers: [ConnectivityLayerResult]) {
        self.target = target
        self.layers = layers
    }
}

/// An exact IPv6 host route used only for IPv6 addresses resolved from
/// explicitly configured temporary domains. Broad IPv6 routes remain owned
/// by Tailscale and are never recorded here.
public struct IPv6HostRoute: Codable, Equatable, Hashable, Sendable {
    public let address: String
    public let gateway: String
    public let interfaceName: String

    public init(address: String, gateway: String, interfaceName: String) {
        self.address = address
        self.gateway = gateway
        self.interfaceName = interfaceName
    }
}

/// Domain-scoped ownership for an exact IPv6 host route.
public struct ManagedDomainIPv6Route: Codable, Equatable, Hashable, Sendable {
    public let domain: String
    public let route: IPv6HostRoute

    public init(domain: String, route: IPv6HostRoute) {
        self.domain = domain
        self.route = route
    }
}

public struct DesiredRouteList: Codable, Equatable, Sendable {
    public let cidrs: [String]
    public let generatedAt: Date
    public let source: String?
    public let sha256: String
    public let sourceMetadata: CIDRSourceMetadata?

    public init(
        cidrs: [String],
        generatedAt: Date = Date(),
        source: String?,
        sha256: String,
        sourceMetadata: CIDRSourceMetadata? = nil
    ) {
        self.cidrs = cidrs
        self.generatedAt = generatedAt
        self.source = source
        self.sha256 = sha256
        self.sourceMetadata = sourceMetadata
    }
}

public struct CIDRSourceMetadata: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 2

    public let formatVersion: Int
    public let sourceURL: String
    public let fetchedAt: Date
    public let sourceSHA256: String
    /// SHA-256 of the canonical, sorted CIDR payload stored in the cache.
    /// This is independently recomputed when a cache is read; checking only
    /// the source hash length is not sufficient to detect a damaged cache.
    public let cidrSHA256: String
    public let entryCount: Int
    public let rejectedLineCount: Int

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        sourceURL: String,
        fetchedAt: Date = Date(),
        sourceSHA256: String,
        cidrSHA256: String,
        entryCount: Int,
        rejectedLineCount: Int
    ) {
        self.formatVersion = formatVersion
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.sourceSHA256 = sourceSHA256
        self.cidrSHA256 = cidrSHA256
        self.entryCount = entryCount
        self.rejectedLineCount = rejectedLineCount
    }
}

/// Last-known-good validated source list and its provenance, written as one
/// atomic file so a crash cannot pair new CIDRs with old metadata.
public struct ChinaCIDRCache: Codable, Equatable, Sendable {
    public let cidrs: [String]
    public let metadata: CIDRSourceMetadata

    public init(cidrs: [String], metadata: CIDRSourceMetadata) {
        self.cidrs = cidrs
        self.metadata = metadata
    }
}

public struct TargetListBuildResult: Codable, Equatable, Sendable {
    public let list: DesiredRouteList
    public let domainIPv4: [String]
    public let domainIPv6: [String]
    public let hostAddresses: [HostAddress]
    public let warnings: [String]

    public init(
        list: DesiredRouteList,
        domainIPv4: [String],
        domainIPv6: [String] = [],
        hostAddresses: [HostAddress] = [],
        warnings: [String]
    ) {
        self.list = list
        self.domainIPv4 = domainIPv4
        self.domainIPv6 = domainIPv6
        self.hostAddresses = hostAddresses
        self.warnings = warnings
    }
}

/// Per-domain DNS answers for the temporary-domain split-route feature.
public struct HostAddress: Codable, Equatable, Hashable, Sendable {
    public let domain: String
    public let ipv4Addresses: [String]
    public let ipv6Addresses: [String]

    public init(domain: String, ipv4Addresses: [String], ipv6Addresses: [String]) {
        self.domain = domain
        self.ipv4Addresses = ipv4Addresses
        self.ipv6Addresses = ipv6Addresses
    }
}

public enum DomainResolutionStatus: String, Codable, Equatable, Sendable {
    /// The resolver returned one or more current answers.
    case fresh
    /// The resolver completed successfully and returned no answer. This is a
    /// confirmed deletion and is different from a transport/resolver error.
    case confirmedEmpty
    /// The current lookup failed, so the cached answer remains effective.
    case lastKnownGood
    /// The current lookup failed and there is no cached answer to use.
    case unavailable
}

/// One domain's effective A/AAAA answers plus the provenance of each family.
/// The Helper uses the provenance to preserve ownership on an uncertain DNS
/// failure while still accepting a confirmed empty answer as a deletion.
public struct DomainResolutionEntry: Equatable, Sendable {
    public let domain: String
    public let ipv4Addresses: [String]
    public let ipv6Addresses: [String]
    public let ipv4Status: DomainResolutionStatus
    public let ipv6Status: DomainResolutionStatus

    public init(
        domain: String,
        ipv4Addresses: [String],
        ipv6Addresses: [String],
        ipv4Status: DomainResolutionStatus,
        ipv6Status: DomainResolutionStatus
    ) {
        self.domain = domain
        self.ipv4Addresses = ipv4Addresses
        self.ipv6Addresses = ipv6Addresses
        self.ipv4Status = ipv4Status
        self.ipv6Status = ipv6Status
    }

    public var hostAddress: HostAddress? {
        guard !ipv4Addresses.isEmpty || !ipv6Addresses.isEmpty else { return nil }
        return HostAddress(domain: domain, ipv4Addresses: ipv4Addresses, ipv6Addresses: ipv6Addresses)
    }
}

/// Resolver-only output. Unlike `TargetListBuildResult`, this type contains
/// no China CIDR list and does not write desired-route files.
public struct DomainResolutionResult: Equatable, Sendable {
    public let entries: [DomainResolutionEntry]
    public let warnings: [String]

    public init(entries: [DomainResolutionEntry], warnings: [String]) {
        self.entries = entries
        self.warnings = warnings
    }

    public var hosts: [HostAddress] {
        entries.compactMap(\.hostAddress)
    }

    public var ipv4: [String] {
        Set(entries.flatMap(\.ipv4Addresses)).sorted {
            (IPv4CIDR.parseAddress($0) ?? 0) < (IPv4CIDR.parseAddress($1) ?? 0)
        }
    }

    public var ipv6: [String] {
        Array(Set(entries.flatMap(\.ipv6Addresses))).sorted()
    }

    public var configuredDomains: Set<String> {
        Set(entries.map(\.domain))
    }
}

/// Last-known-good DNS answers used when a temporary domain has a transient
/// resolver failure. Keeping this separate from the route ledger lets a
/// failed lookup avoid deleting an otherwise healthy domain route.
public struct DomainResolutionCache: Codable, Equatable, Sendable {
    public let updatedAt: Date
    public let hosts: [HostAddress]

    public init(updatedAt: Date = Date(), hosts: [HostAddress]) {
        self.updatedAt = updatedAt
        self.hosts = hosts
    }
}

public struct RouteProgress: Codable, Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let message: String

    public init(completed: Int, total: Int, message: String) {
        self.completed = completed
        self.total = total
        self.message = message
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

public struct RouteOperationResult: Codable, Equatable, Sendable {
    public let success: Bool
    public let state: RouteLifecycleState
    public let appliedCount: Int
    public let removedCount: Int
    public let failedCount: Int
    public let lastError: String?
    public let warnings: [String]
    public let verifiedTargets: [String]
    /// Exact currently observed routes owned by this operation. Optional for
    /// protocol compatibility with Helpers that predate staged transactions.
    public let managedRoutes: [RouteSpec]?
    /// Exact owned routes whose cleanup remains incomplete.
    public let pendingRemovals: [RouteSpec]?

    public init(
        success: Bool,
        state: RouteLifecycleState,
        appliedCount: Int,
        removedCount: Int,
        failedCount: Int,
        lastError: String?,
        warnings: [String],
        verifiedTargets: [String],
        managedRoutes: [RouteSpec]? = nil,
        pendingRemovals: [RouteSpec]? = nil
    ) {
        self.success = success
        self.state = state
        self.appliedCount = appliedCount
        self.removedCount = removedCount
        self.failedCount = failedCount
        self.lastError = lastError
        self.warnings = warnings
        self.verifiedTargets = verifiedTargets
        self.managedRoutes = managedRoutes
        self.pendingRemovals = pendingRemovals
    }
}

public enum LayerStatus: String, Codable, Equatable, Sendable {
    case notEvaluated
    case ok
    case degraded
    case failed
    case unknown
}

/// Independent results for the route, external-protection, and temporary
/// domain layers. A degraded domain layer must not hide a healthy external
/// protection layer.
public struct LayeredOperationStatus: Codable, Equatable, Sendable {
    public let route: LayerStatus
    public let externalProtection: LayerStatus
    public let domainResolution: LayerStatus
    public let overall: LayerStatus

    public init(
        route: LayerStatus,
        externalProtection: LayerStatus,
        domainResolution: LayerStatus,
        overall: LayerStatus
    ) {
        self.route = route
        self.externalProtection = externalProtection
        self.domainResolution = domainResolution
        self.overall = overall
    }
}

public struct PersistedRouteState: Codable, Equatable, Sendable {
    /// Version of the on-disk ownership and reconciliation schema.
    public var schemaVersion: Int
    /// Monotonically increases for every successful state write.
    public var generation: Int
    /// Stable digest of the exact managed-route ownership ledger.
    public var ledgerFingerprint: String?
    public var lifecycle: RouteLifecycleState
    public var lastSuccessAt: Date?
    public var lastSuccessFingerprint: NetworkFingerprint?
    public var appliedRouteCount: Int
    /// Exact routes currently owned/adopted by tailscale-route. This is the
    /// source of truth for pause/restore; the desired CIDR list alone is not
    /// sufficient because it can change while old routes are still present.
    public var managedRoutes: [RouteSpec]
    /// Exact `/32` IPv4 routes owned for temporary domains. This ledger is
    /// deliberately separate from the China/manual IPv4 ledger so a domain
    /// refresh cannot clean or replace a non-domain route.
    public var managedDomainIPv4Routes: [ManagedDomainIPv4Route]
    /// Exact IPv6 /128 routes created for temporary domain AAAA records.
    /// Tailscale's IPv6 default routes and all unrelated IPv6 routes stay out
    /// of this ownership list.
    public var managedIPv6Routes: [IPv6HostRoute]
    /// Domain-scoped subset of the IPv6 ownership ledger used for incremental
    /// refreshes and per-domain last-known-good handling.
    public var managedDomainIPv6Routes: [ManagedDomainIPv6Route]
    /// Exact `/32` host routes pinning the active Exit Node's public WireGuard
    /// endpoint to the current physical gateway. Owned separately so route
    /// reconciliation never treats them as split-tunnel targets.
    public var managedExitNodeEndpointRoutes: [RouteSpec]
    /// Exact `/32` host routes pinning the domain resolver's DNS servers to
    /// the current physical gateway, so domain lookups never enter the Exit
    /// Node tunnel. Owned separately from split targets and endpoint routes.
    public var managedDNSServerRoutes: [RouteSpec]
    /// Exact external-network routes keeping detected external CIDRs on their
    /// physical adapters. These are separate from split targets and Exit Node
    /// endpoint routes so stop can remove only routes created here. The JSON
    /// key is retained for migration compatibility with the old gateway-only
    /// implementation.
    public var managedExternalGatewayRoutes: [RouteSpec]
    /// Exact third-party static routes temporarily removed to resolve an
    /// external-network conflict. They are restored before another reconcile
    /// mutates the same prefix, and remain pending until read-back confirms
    /// the original gateway/interface tuple.
    public var pendingExternalRouteRestorations: [RouteSpec]
    public var tailscalePreferenceLease: TailscalePreferenceLease?
    /// Once the user explicitly restores defaults, do not automatically adopt
    /// leftover external routes again until the next explicit enable/apply.
    public var externalAdoptionEnabled: Bool
    public var desiredHash: String?
    public var lastError: String?
    public var updatedAt: Date

    public static let currentSchemaVersion = 8

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generation: Int = 0,
        ledgerFingerprint: String? = nil,
        lifecycle: RouteLifecycleState = .disabled,
        lastSuccessAt: Date? = nil,
        lastSuccessFingerprint: NetworkFingerprint? = nil,
        appliedRouteCount: Int = 0,
        managedRoutes: [RouteSpec] = [],
        managedDomainIPv4Routes: [ManagedDomainIPv4Route] = [],
        managedIPv6Routes: [IPv6HostRoute] = [],
        managedDomainIPv6Routes: [ManagedDomainIPv6Route] = [],
        managedExitNodeEndpointRoutes: [RouteSpec] = [],
        managedDNSServerRoutes: [RouteSpec] = [],
        managedExternalGatewayRoutes: [RouteSpec] = [],
        pendingExternalRouteRestorations: [RouteSpec] = [],
        tailscalePreferenceLease: TailscalePreferenceLease? = nil,
        externalAdoptionEnabled: Bool = true,
        desiredHash: String? = nil,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.ledgerFingerprint = ledgerFingerprint
        self.lifecycle = lifecycle
        self.lastSuccessAt = lastSuccessAt
        self.lastSuccessFingerprint = lastSuccessFingerprint
        self.appliedRouteCount = appliedRouteCount
        self.managedRoutes = managedRoutes
        self.managedDomainIPv4Routes = managedDomainIPv4Routes
        self.managedIPv6Routes = managedIPv6Routes
        self.managedDomainIPv6Routes = managedDomainIPv6Routes
        self.managedExitNodeEndpointRoutes = managedExitNodeEndpointRoutes
        self.managedDNSServerRoutes = managedDNSServerRoutes
        self.managedExternalGatewayRoutes = managedExternalGatewayRoutes
        self.pendingExternalRouteRestorations = pendingExternalRouteRestorations
        self.tailscalePreferenceLease = tailscalePreferenceLease
        self.externalAdoptionEnabled = externalAdoptionEnabled
        self.desiredHash = desiredHash
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generation
        case ledgerFingerprint
        case lifecycle
        case lastSuccessAt
        case lastSuccessFingerprint
        case appliedRouteCount
        case managedRoutes
        case managedDomainIPv4Routes
        case managedIPv6Routes
        case managedDomainIPv6Routes
        case managedExitNodeEndpointRoutes
        case managedDNSServerRoutes
        case managedExternalGatewayRoutes
        case pendingExternalRouteRestorations
        case tailscalePreferenceLease
        case externalAdoptionEnabled
        case desiredHash
        case lastError
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing schema metadata identifies a legacy v1 state file. Its
        // ownership data remains readable and is upgraded on the next write.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        ledgerFingerprint = try container.decodeIfPresent(String.self, forKey: .ledgerFingerprint)
        lifecycle = try container.decodeIfPresent(RouteLifecycleState.self, forKey: .lifecycle) ?? .disabled
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastSuccessFingerprint = try container.decodeIfPresent(NetworkFingerprint.self, forKey: .lastSuccessFingerprint)
        appliedRouteCount = try container.decodeIfPresent(Int.self, forKey: .appliedRouteCount) ?? 0
        managedRoutes = try container.decodeIfPresent([RouteSpec].self, forKey: .managedRoutes) ?? []
        managedDomainIPv4Routes = try container.decodeIfPresent(
            [ManagedDomainIPv4Route].self,
            forKey: .managedDomainIPv4Routes
        ) ?? []
        managedIPv6Routes = try container.decodeIfPresent([IPv6HostRoute].self, forKey: .managedIPv6Routes) ?? []
        managedDomainIPv6Routes = try container.decodeIfPresent(
            [ManagedDomainIPv6Route].self,
            forKey: .managedDomainIPv6Routes
        ) ?? []
        managedExitNodeEndpointRoutes = try container.decodeIfPresent(
            [RouteSpec].self,
            forKey: .managedExitNodeEndpointRoutes
        ) ?? []
        managedDNSServerRoutes = try container.decodeIfPresent(
            [RouteSpec].self,
            forKey: .managedDNSServerRoutes
        ) ?? []
        managedExternalGatewayRoutes = try container.decodeIfPresent(
            [RouteSpec].self,
            forKey: .managedExternalGatewayRoutes
        ) ?? []
        pendingExternalRouteRestorations = try container.decodeIfPresent(
            [RouteSpec].self,
            forKey: .pendingExternalRouteRestorations
        ) ?? []
        tailscalePreferenceLease = try container.decodeIfPresent(TailscalePreferenceLease.self, forKey: .tailscalePreferenceLease)
        externalAdoptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .externalAdoptionEnabled) ?? true
        desiredHash = try container.decodeIfPresent(String.self, forKey: .desiredHash)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// Durable before/after evidence for the most recent route transaction.
public struct RouteTransactionJournal: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let startedAt: Date
    public var finishedAt: Date?
    public let networkFingerprint: NetworkFingerprint
    public let beforeRoutes: [RouteEntry]
    public var afterRoutes: [RouteEntry]
    public var operation: RouteOperationResult?

    public init(
        requestID: UUID,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        networkFingerprint: NetworkFingerprint,
        beforeRoutes: [RouteEntry],
        afterRoutes: [RouteEntry] = [],
        operation: RouteOperationResult? = nil
    ) {
        self.requestID = requestID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.networkFingerprint = networkFingerprint
        self.beforeRoutes = beforeRoutes
        self.afterRoutes = afterRoutes
        self.operation = operation
    }
}

public enum HelperAction: String, Codable, Sendable {
    case status
    case reconcileExternalProtection
    case preview
    case enable
    case reapply
    case pause
    case shutdown
    case restoreDefault
    case updateList
    /// Resolve configured domains and reconcile only their exact routes and
    /// managed hosts block. It never rebuilds the China target list.
    case domainRefresh
    /// Kill switch (断网保护): read status, turn on/off, manually release a block.
    case killSwitchStatus
    case enableKillSwitch
    case disableKillSwitch
    case releaseKillSwitch
}

/// Shared, testable operation classification used by the App state layer.
/// Domain refresh is intentionally not a route-mutation progress operation:
/// it may write exact domain routes through the Helper, but it must not make
/// the global "正在更新路由" state visible.
public enum OperationStatePolicy: String, Sendable {
    case routeMutation
    case listUpdate
    case preview
    case domainRefresh
    case externalProtectionReconcile

    public var isRouteMutation: Bool {
        self == .routeMutation || self == .externalProtectionReconcile
    }

    public var updatesRouteProgress: Bool {
        isRouteMutation
    }
}

/// The App must reject every response from a Helper that does not implement
/// the exact current action/ownership protocol. The caller's existing reload
/// path then unregisters and re-registers the daemon.
public enum HelperProtocolCompatibility {
    public static func accepts(_ version: Int?) -> Bool {
        version == HelperResponse.currentProtocolVersion
    }
}

public struct HelperRequest: Codable, Sendable {
    public let requestID: UUID
    public let action: HelperAction
    public let configuration: TailscaleRouteConfiguration?

    public init(
        requestID: UUID = UUID(),
        action: HelperAction,
        configuration: TailscaleRouteConfiguration? = nil
    ) {
        self.requestID = requestID
        self.action = action
        self.configuration = configuration
    }
}

public struct HelperResponse: Codable, Sendable {
    // Bump whenever Helper behavior changes. The App uses this value to
    // unregister and re-register an already-running SMAppService daemon.
    // v38: bound helper socket waits and prevent a disconnected client from terminating Helper.
    // v40: enable Exit Node LAN access during protection and restore the prior preference.
    // v37: keep live external-network route verification bounded on large route tables.
    // v36: recognize Skywalk USB Ethernet interfaces and parse IPv4 masks correctly.
    // v35: keep Tailscale preference recovery records when the tailnet identity changes.
    // v41: remove obsolete split-route ledger, persisted transient warnings,
    // and downgrade-only generated caches.
    // v42: reload the helper so the retired external-network route cleanup is
    // active even when launchd still has the previous bundle instance loaded.
    // v43: accept macOS interface-scoped native connected routes as the
    // authoritative direct path for external-network verification.
    // v44: own exact external-network gateway host routes and stream final
    // Helper responses without waiting for socket EOF.
    // v45: force Tailscale macOS App CLI mode for privileged preference reads.
    // v46: own complete external-network routes instead of gateway-only /32s.
    // v47: use only valid host addresses for external-network egress probes;
    //      macOS routes network/broadcast addresses via the default path.
    // v48: verify cleanup of direct external-network routes by flags/link#,
    //      because netstat does not echo the local address used by route(8).
    // v49: remove exact conflicting static gateway routes on other interfaces
    //      before installing the owned physical external-network route.
    // v50: require a strict unregister-then-register cycle when the App
    //      detects an outdated Helper instead of reusing the old process.
    // v51: stream list-update progress and return the rebuilt target list so
    //      the App can apply it immediately without showing stale counts.
    // v52: make status read-only and expose external-network protection as an
    //      explicit reconcile action.
    // v53: expose independent route, external-protection, and domain status
    //      layers so degraded DNS/IPv6 results do not mask protection.
    // v54: force stale v53 Helpers through the strict reload path after the
    //      physical-gateway parser fix.
    // v55: accept manual external adapters without a configured router.
    // v56: add an independent domain refresh action and domain-scoped route
    //      ownership ledgers; domain refresh no longer uses reapply.
    // v57: make route-monitor/periodic reconciliation read-only and keep
    //      external-network protection out of main route-drift detection.
    // v58: classify expected network-inspection notices separately from
    //      domain-resolution degradation in the domain refresh result.
    // v59: isolate network-triggered external protection and enforce the
    //      manual-only China-list source boundary.
    // v33: automatic external-network discovery and Tailscale subnet-route coordination.
    // v32: route transactions preserve confirmed partial success, use exact
    // ownership for cleanup, and return the retained ledger on failure.
    // v62: identify the Tailscale preference lease by login NodeID so a
    //      switched or disabled Exit Node no longer blocks restoring
    //      accept-routes / LAN access; never pin Tailscale-owned domains
    //      in /etc/hosts.
    // v63: add the pf-based kill switch (断网保护) and its actions.
    // v64: temporary-domain DNS servers come from the request configuration
    //      (user-configurable) instead of fixed defaults.
    public static let currentProtocolVersion = 64

    public let requestID: UUID
    /// Optional for backwards compatibility with a helper that was already
    /// running before the app bundle was updated.
    public let helperProtocolVersion: Int?
    public let success: Bool
    public let isFinal: Bool
    public let message: String
    public let report: DiagnosticReport?
    public let state: PersistedRouteState?
    public let progress: RouteProgress?
    public let operation: RouteOperationResult?
    public let planPreview: RoutePlanPreview?
    /// The exact target list produced by a list update or route apply.
    /// Optional so older Helpers remain decodable during upgrade.
    public let targetList: DesiredRouteList?
    public let domainIPv4Count: Int?
    public let domainIPv6Count: Int?
    public let layeredStatus: LayeredOperationStatus?
    /// Kill-switch status; set by kill-switch actions and shutdown.
    public let killSwitch: KillSwitchStatus?

    public init(
        requestID: UUID,
        success: Bool,
        message: String,
        helperProtocolVersion: Int? = HelperResponse.currentProtocolVersion,
        isFinal: Bool = true,
        report: DiagnosticReport? = nil,
        state: PersistedRouteState? = nil,
        progress: RouteProgress? = nil,
        operation: RouteOperationResult? = nil,
        planPreview: RoutePlanPreview? = nil,
        targetList: DesiredRouteList? = nil,
        domainIPv4Count: Int? = nil,
        domainIPv6Count: Int? = nil,
        layeredStatus: LayeredOperationStatus? = nil,
        killSwitch: KillSwitchStatus? = nil
    ) {
        self.requestID = requestID
        self.helperProtocolVersion = helperProtocolVersion
        self.success = success
        self.isFinal = isFinal
        self.message = message
        self.report = report
        self.state = state
        self.progress = progress
        self.operation = operation
        self.planPreview = planPreview
        self.targetList = targetList
        self.domainIPv4Count = domainIPv4Count
        self.domainIPv6Count = domainIPv6Count
        self.layeredStatus = layeredStatus
        self.killSwitch = killSwitch
    }
}

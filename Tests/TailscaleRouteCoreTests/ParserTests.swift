import Foundation
import Darwin
import Testing
@testable import TailscaleRouteCore

@Test
func parsesDefaultRouteOutput() {
    let output = """
    routing to 0.0.0.0
       destination: default
              mask: default
           gateway: 192.168.1.1
         interface: en0
             flags: <UP,GATEWAY,DONE,STATIC>
    """

    let route = RouteOutputParser.parseRouteGetEntry(output)
    #expect(route?.destination == "default")
    #expect(route?.gateway == "192.168.1.1")
    #expect(route?.interfaceName == "en0")
}

@Test
func parsesHardwarePorts() {
    let output = """
    Hardware Port: Wi-Fi
    Device: en0
    Hardware Port: Ethernet Adapter (en5)
    Device: en5
    """

    #expect(NetworksetupParser.parseHardwarePorts(output) == [
        HardwarePort(name: "Wi-Fi", device: "en0"),
        HardwarePort(name: "Ethernet Adapter (en5)", device: "en5")
    ])
}

@Test
func networksetupNullRouterIsNotAcceptedAsGateway() {
    #expect(NetworksetupParser.parseRouter("Router: (null)\n") == nil)
    #expect(NetworksetupParser.parseRouter("Router: none\n") == nil)
    #expect(NetworksetupParser.parseRouter("Router: 192.168.1.1\n") == "192.168.1.1")
}

@Test
func parsesRouterFromNetworksetupAndDHCPOutput() {
    #expect(NetworksetupParser.parseRouter("Router: 192.168.1.1\n") == "192.168.1.1")
    #expect(DHCPParser.parseRouter("router (ip_mult): {192.168.1.1}\n") == "192.168.1.1")
}

@Test
func parsesRouteTableAndSkipsHeaders() {
    let output = """
    Routing tables

    Internet:
    Destination        Gateway            Flags        Netif Expire
    default            192.168.1.1        UGScg        en0
    192.168.1/24       link#14            UCS         en0
    """

    let routes = RouteOutputParser.parseRouteTable(output)
    #expect(routes.count == 2)
    #expect(routes[0].destination == "default")
    #expect(routes[0].interfaceName == "en0")
}

@Test
func parsesTailscaleStatus() throws {
    let data = Data("""
    {
      "Self": {
        "HostName": "laptop",
        "TailscaleIPs": ["100.64.0.12", "fd7a:115c:a1e0::12"]
      },
      "ExitNodeStatus": {
        "ID": "node-id",
        "HostName": "exitnode-a"
      }
    }
    """.utf8)

    let summary = try #require(TailscaleJSONParser.parse(data))
    #expect(summary.selfAddress == "100.64.0.12")
    #expect(summary.selfHostName == "laptop")
    #expect(summary.exitNode == "exitnode-a")
}

@Test
func resolvesTailscaleExitNodeIDThroughPeerMap() throws {
    let data = Data("""
    {
      "Self": {
        "HostName": "laptop",
        "TailscaleIPs": ["100.64.0.12"]
      },
      "ExitNodeStatus": {
        "ID": "node-id",
        "Online": true
      },
      "Peer": {
        "node-id": {
          "ID": "node-id",
          "HostName": "exitnode-a",
          "DNSName": "exitnode-a.tail.example.ts.net."
        }
      }
    }
    """.utf8)

    let summary = try #require(TailscaleJSONParser.parse(data))
    #expect(summary.exitNode == "exitnode-a")
}

@Test
func parsesTailscaleExitNodePreferences() throws {
    let data = Data("{\"ExitNodeAllowLANAccess\":true,\"RouteAll\":true}".utf8)
    let prefs = try #require(TailscalePrefsParser.parse(data))
    #expect(prefs.allowLANAccess == true)
    #expect(prefs.routeAll == true)
}

@Test
func fingerprintChangesWhenGatewayChanges() {
    let first = NetworkFingerprint(
        gateway: "192.168.1.1",
        physicalInterface: "en0",
        tailscaleInterface: "utun4",
        defaultRouteSignature: "default->192.168.1.1 via en0"
    )
    let second = NetworkFingerprint(
        gateway: "172.20.10.1",
        physicalInterface: "en0",
        tailscaleInterface: "utun4",
        defaultRouteSignature: "default->172.20.10.1 via en0"
    )

    #expect(first != second)
    #expect(first.description.contains("192.168.1.1"))
}

@Test
func fingerprintChangesWhenTailscaleExitNodeChanges() {
    let first = NetworkFingerprint(
        gateway: "192.168.1.1", physicalInterface: "en0", tailscaleInterface: "utun4",
        defaultRouteSignature: "default->utun4", tailscaleExitNode: "node-a", tailscaleExitNodeEndpoint: "203.0.113.1"
    )
    let second = NetworkFingerprint(
        gateway: "192.168.1.1", physicalInterface: "en0", tailscaleInterface: "utun4",
        defaultRouteSignature: "default->utun4", tailscaleExitNode: "node-b", tailscaleExitNodeEndpoint: "203.0.113.2"
    )
    #expect(first != second)
}

@Test
func networkRetryPolicyUsesCappedExponentialBackoff() {
    #expect((0..<5).compactMap { NetworkReconciliationPolicy.retryDelaySeconds(after: $0) } == [2, 4, 8, 16, 30])
    #expect(NetworkReconciliationPolicy.retryDelaySeconds(after: 5) == nil)
    #expect(NetworkReconciliationPolicy.retryDelaySeconds(after: -1) == nil)
}

@Test
func networkEventPolicyReconcilesWakeAndDefersWhileAnOperationRuns() {
    #expect(NetworkReconciliationPolicy.action(
        for: .wokeFromSleep,
        isOperating: false,
        autoFollowNetwork: true,
        lifecycle: .enabled,
        retryPaused: false
    ) == .reconcile)
    #expect(NetworkReconciliationPolicy.action(
        for: .pathChanged,
        isOperating: true,
        autoFollowNetwork: true,
        lifecycle: .enabled,
        retryPaused: false
    ) == .deferUntilOperationFinishes)
    #expect(NetworkReconciliationPolicy.action(
        for: .systemConfigurationChanged,
        isOperating: false,
        autoFollowNetwork: false,
        lifecycle: .enabled,
        retryPaused: false
    ) == .refreshOnly)
}

@Test
func networkEventPolicyTreatsRouteMonitorEventsAsReadOnly() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(NetworkReconciliationPolicy.action(
        for: .routeTableChanged,
        isOperating: true,
        autoFollowNetwork: true,
        lifecycle: .enabled,
        retryPaused: false,
        now: now
    ) == .ignore)
    #expect(NetworkReconciliationPolicy.action(
        for: .routeTableChanged,
        isOperating: false,
        autoFollowNetwork: true,
        lifecycle: .enabled,
        retryPaused: false,
        suppressRouteEventsUntil: now.addingTimeInterval(5),
        now: now
    ) == .ignore)
    #expect(NetworkReconciliationPolicy.action(
        for: .routeTableChanged,
        isOperating: false,
        autoFollowNetwork: true,
        lifecycle: .enabled,
        retryPaused: false,
        now: now.addingTimeInterval(10)
    ) == .refreshOnly)
    #expect(NetworkReconciliationPolicy.isRouteMutationEvent("RTM_CHANGE: gateway updated"))
    #expect(NetworkReconciliationPolicy.isRouteMutationEvent("RTM_IFINFO: interface changed"))
    #expect(!NetworkReconciliationPolicy.isRouteMutationEvent("RTM_GET: lookup result"))
}

@Test
func routeDriftDetectorChecksOwnedIPv4AndIPv6() {
    let state = PersistedRouteState(
        lifecycle: .enabled,
        managedRoutes: [RouteSpec(cidr: "1.0.0.0/8", gateway: "192.168.1.1", interfaceName: "en0")],
        managedIPv6Routes: [IPv6HostRoute(address: "2001:db8::1", gateway: "fe80::1%en0", interfaceName: "en0")]
    )
    let actual = [
        RouteEntry(destination: "1.0.0.0/8", gateway: "192.168.1.1", flags: "UG", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "192.168.32.0/22", gateway: "link#10", flags: "U", interfaceName: "en7", rawLine: "")
    ]
    let actualIPv6 = [RouteEntry(destination: "2001:db8::1", gateway: "fe80::1%en0", flags: "UGH", interfaceName: "en0", rawLine: "")]
    #expect(RouteDriftDetector.missingOwnedRoutes(state: state, actualRoutes: actual, actualIPv6Routes: actualIPv6).isEmpty)
    let missingIPv4 = RouteDriftDetector.missingOwnedRoutes(state: state, actualRoutes: [], actualIPv6Routes: actualIPv6)
    #expect(missingIPv4.contains { $0.contains("1.0.0.0/8") })
    #expect(!missingIPv4.contains { $0.contains("192.168.32.0/22") })
    #expect(RouteDriftDetector.missingOwnedRoutes(state: state, actualRoutes: actual, actualIPv6Routes: []).contains { $0.contains("2001:db8::1") })
    let wrongGateway = RouteEntry(destination: "1.0.0.0/8", gateway: "192.168.1.2", flags: "UG", interfaceName: "en0", rawLine: "")
    #expect(RouteDriftDetector.missingOwnedRoutes(state: state, actualRoutes: [wrongGateway, actual[1]]).contains { $0.contains("1.0.0.0/8") })

    let externalProtectionState = PersistedRouteState(
        lifecycle: .enabled,
        managedExternalGatewayRoutes: [
            RouteSpec(cidr: "192.168.32.0/20", gateway: "192.168.32.99", interfaceName: "en7")
        ]
    )
    #expect(RouteDriftDetector.missingOwnedRoutes(
        state: externalProtectionState,
        actualRoutes: actual,
        actualIPv6Routes: actualIPv6
    ).isEmpty)
}

@Test
func persistedStateMigratesLegacyOwnershipAndJournalRoundTrips() throws {
    let legacyJSON = Data(#"{"schemaVersion":3,"lifecycle":"enabled","managedRoutes":[{"cidr":"1.0.0.0/8","gateway":"192.168.1.1","interfaceName":"en0"}],"managedLocalSubnetOverrides":[{"protectedCIDR":"192.168.32.0/20","cidr":"192.168.32.0/22","interfaceAddress":"192.168.32.99","interfaceName":"en7"}],"lastWarning":"expired warning"}"#.utf8)
    let migrated = try JSONDecoder().decode(PersistedRouteState.self, from: legacyJSON)
    #expect(migrated.schemaVersion == 3)
    #expect(migrated.generation == 0)
    #expect(migrated.managedRoutes.count == 1)

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-state-generation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AtomicStore(paths: TailscaleRoutePaths(root: root))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try legacyJSON.write(to: store.paths.lastSuccess)
    try store.migrateStateIfNeeded()
    let cleaned = store.loadState()
    #expect(cleaned.schemaVersion == PersistedRouteState.currentSchemaVersion)
    let cleanedJSON = try String(contentsOf: store.paths.lastSuccess, encoding: .utf8)
    #expect(!cleanedJSON.contains("managedLocalSubnetOverrides"))
    #expect(!cleanedJSON.contains("lastWarning"))
    let savedOnce = try store.saveState(cleaned)
    let savedTwice = try store.saveState(savedOnce)
    #expect(savedOnce.schemaVersion == PersistedRouteState.currentSchemaVersion)
    #expect(savedOnce.generation == 2)
    #expect(savedOnce.ledgerFingerprint?.isEmpty == false)
    #expect(savedTwice.generation == 3)

    let operation = RouteOperationResult(
        success: false,
        state: .partial,
        appliedCount: 1,
        removedCount: 0,
        failedCount: 1,
        lastError: "cleanup failed",
        warnings: ["pending cleanup"],
        verifiedTargets: ["1.0.0.0/8"],
        managedRoutes: migrated.managedRoutes,
        pendingRemovals: migrated.managedRoutes
    )
    let journal = RouteTransactionJournal(
        requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        networkFingerprint: NetworkFingerprint(
            gateway: "192.168.1.1", physicalInterface: "en0", tailscaleInterface: "utun4",
            defaultRouteSignature: "default->utun4"
        ),
        beforeRoutes: [],
        afterRoutes: [RouteEntry(destination: "1.0.0.0/8", gateway: "192.168.1.1", flags: "UG", interfaceName: "en0", rawLine: "")],
        operation: operation
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(RouteTransactionJournal.self, from: encoder.encode(journal))
    #expect(decoded.requestID == journal.requestID)
    #expect(decoded.afterRoutes == journal.afterRoutes)
    #expect(decoded.operation == operation)
}

@Test
func helperRestartReloadsOwnershipAndPreviewAndDriftRecoveryStayIsolated() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-helper-restart-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = TailscaleRoutePaths(root: root)
    let hostsURL = root.appendingPathComponent("hosts")
    let sourceURL = root.appendingPathComponent("test-cidrs.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("127.0.0.1 localhost\n".utf8).write(to: hostsURL)
    try Data("203.0.113.0/24\n".utf8).write(to: sourceURL)

    let desiredRoute = RouteSpec(cidr: "203.0.113.0/24", gateway: "192.168.1.1", interfaceName: "en0")
    let routeBackend = InMemoryRouteBackend(routes: [
        RouteEntry(destination: "0.0.0.0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    let runner = HelperServiceTestRunner()
    let configuration = TailscaleRouteConfiguration(
        chinaListURL: sourceURL,
        autoFollowNetwork: false
    )

    let firstHelper = HelperService(
        paths: paths,
        runner: runner,
        routeBackend: routeBackend,
        hostsPath: hostsURL.path
    )
    // China-list source access is explicit now. Seed the validated cache as if
    // the user had pressed “更新中国 IP 清单” before enabling routing.
    _ = try TargetListBuilder(
        paths: paths,
        loader: StubTextLoader(data: Data("203.0.113.0/24\n".utf8))
    ).build(configuration: configuration, refreshSource: true)

    let applyResponse = firstHelper.handle(HelperRequest(action: .enable, configuration: configuration))
    #expect(applyResponse.success)
    #expect(applyResponse.state?.managedRoutes == [desiredRoute])
    let dnsPinCommands = [
        ["-n", "add", "-host", "114.114.114.114", "192.168.1.1"],
        ["-n", "add", "-host", "222.85.85.85", "192.168.1.1"]
    ]
    #expect(runner.routeMutationCommands == dnsPinCommands)
    let mutationCountAfterApply = runner.routeMutationCommands.count

    let persistedState = AtomicStore(paths: paths).loadState()
    #expect(persistedState.schemaVersion == PersistedRouteState.currentSchemaVersion)
    #expect(persistedState.generation > 0)
    #expect(persistedState.ledgerFingerprint?.isEmpty == false)
    #expect(persistedState.managedRoutes == [desiredRoute])

    // A separate HelperService instance models a helper restart. The route
    // backend is shared only to represent routes that remain in the kernel.
    let restartedHelper = HelperService(
        paths: paths,
        runner: runner,
        routeBackend: routeBackend,
        hostsPath: hostsURL.path
    )
    let previewResponse = restartedHelper.handle(HelperRequest(action: .preview))

    #expect(previewResponse.planPreview?.alreadyCorrect == [desiredRoute])
    #expect(previewResponse.planPreview?.additions.isEmpty == true)
    #expect(previewResponse.planPreview?.replacements.isEmpty == true)
    #expect(previewResponse.state?.generation == persistedState.generation)
    #expect(routeBackend.currentRoutes().contains {
        $0.destination == desiredRoute.cidr && $0.gateway == desiredRoute.gateway && $0.interfaceName == desiredRoute.interfaceName
    })
    #expect(runner.routeMutationCommands.count == mutationCountAfterApply)
    #expect(try String(contentsOf: hostsURL, encoding: .utf8) == "127.0.0.1 localhost\n")

    // Remove the managed route from the in-memory kernel to model route drift,
    // then reapply through the restarted helper instance.
    #expect(routeBackend.remove(desiredRoute).succeeded)
    let recoveryResponse = restartedHelper.handle(HelperRequest(action: .reapply))
    #expect(recoveryResponse.success)
    #expect(recoveryResponse.state?.managedRoutes == [desiredRoute])
    #expect(routeBackend.currentRoutes().contains {
        $0.destination == desiredRoute.cidr && $0.gateway == desiredRoute.gateway && $0.interfaceName == desiredRoute.interfaceName
    })
    #expect(runner.routeMutationCommands == dnsPinCommands + dnsPinCommands)
    #expect(try String(contentsOf: hostsURL, encoding: .utf8) == "127.0.0.1 localhost\n")
}

@Test
func helperDomainRefreshUsesOnlyDomainLedgerWithoutRebuildingChinaList() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-helper-domain-refresh-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = TailscaleRoutePaths(root: root)
    let hostsURL = root.appendingPathComponent("hosts")
    let hosts = HostsPinManager.renderedHosts(
        currentHosts: "127.0.0.1 localhost\n",
        pinLines: ["203.0.113.50 example.test www.example.test"]
    )
    try Data(hosts.utf8).write(to: hostsURL)

    let china = RouteSpec(cidr: "1.0.0.0/8", gateway: "192.168.1.1", interfaceName: "en0")
    let domain = RouteSpec(cidr: "203.0.113.50/32", gateway: "192.168.1.1", interfaceName: "en0")
    let store = AtomicStore(paths: paths)
    try store.write(DomainResolutionCache(hosts: [
        HostAddress(domain: "example.test", ipv4Addresses: ["203.0.113.50"], ipv6Addresses: []),
        HostAddress(domain: "www.example.test", ipv4Addresses: ["203.0.113.50"], ipv6Addresses: [])
    ]), to: paths.domainAnswers)
    try store.write(PersistedRouteState(
        lifecycle: .enabled,
        managedRoutes: [china, domain],
        managedDomainIPv4Routes: [
            ManagedDomainIPv4Route(domain: "example.test", route: domain)
        ],
        externalAdoptionEnabled: true
    ), to: paths.lastSuccess)

    let backend = InMemoryRouteBackend(routes: [
        RouteEntry(destination: china.cidr, gateway: china.gateway, flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: domain.cidr, gateway: domain.gateway, flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    let helper = HelperService(
        paths: paths,
        runner: HelperServiceTestRunner(),
        routeBackend: backend,
        hostsPath: hostsURL.path
    )

    let response = helper.handle(HelperRequest(
        action: .domainRefresh,
        configuration: TailscaleRouteConfiguration(domainNames: ["example.test"])
    ))

    #expect(response.success)
    #expect(response.targetList == nil)
    #expect(response.operation?.appliedCount == 0)
    #expect(response.operation?.removedCount == 0)
    #expect(backend.currentRoutes().contains { $0.destination == china.cidr })
    #expect(backend.currentRoutes().contains { $0.destination == domain.cidr })
    #expect(response.state?.managedRoutes.contains(china) == true)
    #expect(response.state?.appliedRouteCount == response.state?.managedRoutes.count)
}

@Test
func routeExplanationShowsLongestPrefixAndExactAppOwnership() {
    let broadManaged = RouteEntry(destination: "1.0.0.0/8", gateway: "192.168.1.1", flags: "UG", interfaceName: "en0", rawLine: "")
    let specificExternal = RouteEntry(destination: "1.1.0.0/16", gateway: "10.0.0.1", flags: "UG", interfaceName: "en5", rawLine: "")
    let defaultRoute = RouteEntry(destination: "default", gateway: "-", flags: "UG", interfaceName: "utun4", rawLine: "")
    let state = PersistedRouteState(managedRoutes: [
        RouteSpec(cidr: "1.0.0.0/8", gateway: "192.168.1.1", interfaceName: "en0")
    ])

    let explanation = RouteExplanationService.explain(
        address: "1.1.2.3",
        actualRoutes: [broadManaged, specificExternal, defaultRoute],
        desiredTargets: ["1.0.0.0/8"],
        state: state,
        kernelSelection: specificExternal
    )

    #expect(explanation.matchingTargetCIDR == "1.0.0.0/8")
    #expect(explanation.selectedRoute == specificExternal)
    #expect(!explanation.selectedRouteIsAppManaged)
    #expect(explanation.candidates.first?.prefixLength == 16)
    #expect(explanation.candidates.first?.isSelected == true)
    #expect(explanation.candidates.first?.isAppManaged == false)
    #expect(explanation.candidates.last?.explanation.contains("更具体") == true)
}

@Test
func connectivityDiagnosticReportsHTTP502AsBackendFailureAfterNetworkReachability() {
    let address = "8.8.8.8"
    let url = URL(string: "https://service.example.test/health")!
    let runner = StubCommandRunner(responses: [
        key("/sbin/route", ["-n", "get", address]): result(
            "/sbin/route", ["-n", "get", address],
            stdout: "destination: 8.8.8.8\ngateway: 192.168.1.1\ninterface: en0\nflags: <UP,GATEWAY>\n"
        ),
        key("/usr/sbin/arp", ["-n", "192.168.1.1"]): result(
            "/usr/sbin/arp", ["-n", "192.168.1.1"], stdout: "? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0\n"
        ),
        key("/sbin/ping", ["-n", "-c", "1", "-W", "1000", address]): result("/sbin/ping", []),
        key("/usr/bin/nc", ["-z", "-G", "3", address, "443"]): result("/usr/bin/nc", []),
        key("/usr/bin/curl", ["--max-time", "5", "--silent", "--show-error", "--output", "/dev/null", "--write-out", "%{http_code}", url.absoluteString]): result(
            "/usr/bin/curl", [], stdout: "502"
        )
    ])

    let report = ConnectivityDiagnosticService(runner: runner).run(target: address, tcpPort: 443, httpURL: url)

    #expect(report.layers.first { $0.layer == "路由选择" }?.status == .passed)
    #expect(report.layers.first { $0.layer == "L2 邻居/ARP" }?.status == .passed)
    #expect(report.layers.first { $0.layer == "TCP 443" }?.status == .passed)
    #expect(report.layers.first { $0.layer == "HTTP" }?.status == .serviceError)
    #expect(report.layers.first { $0.layer == "HTTP" }?.detail.contains("已到达 Web 服务，后端返回错误") == true)
    #expect(report.layers.first { $0.layer == "路由选择" }?.status != .failed)
}

@Test
func parsesDesiredTargetsAndDeduplicates() {
    let targets = DesiredTargetParser.parse("""
    # China IPv4
    1.1.1.1/32
    10.0.0.0/8
    1.1.1.1/32

    """)
    #expect(targets == ["1.1.1.1/32", "10.0.0.0/8"])
}

@Test
func parsesAbbreviatedMacOSRouteDestination() {
    #expect(IPv4CIDR.canonical("1.1.8/24") == "1.1.8.0/24")
    #expect(IPv4CIDR.canonical("10/8") == "10.0.0.0/8")

    let routes = RouteOutputParser.parseRouteTable("""
    Internet:
    Destination        Gateway            Flags        Netif Expire
    128.108            192.168.1.1        UGSc         en0
    192.168.1.1        link#12            UHLWIir      en0
    """)
    #expect(routes[0].destination == "128.108.0.0/16")
    #expect(routes[1].destination == "192.168.1.1")
}

@Test
func targetListBuilderMergesAndExcludesTargets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-route-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("china.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("1.0.0.0/8\n2.2.2.0/24\n".utf8).write(to: sourceURL)

    let builder = TargetListBuilder(
        paths: TailscaleRoutePaths(root: root.appendingPathComponent("state")),
        loader: StubTextLoader(data: Data("1.0.0.0/8\n2.2.2.0/24\n".utf8))
    )
    let result = try builder.build(
        configuration: TailscaleRouteConfiguration(
            chinaListURL: sourceURL,
            manualIPs: ["8.8.8.8"],
            domainNames: [],
            excludeCIDRs: ["2.2.2.0/24"]
        ),
        refreshSource: true
    )

    #expect(result.list.cidrs.contains("1.0.0.0/8"))
    #expect(result.list.cidrs.contains("8.8.8.8/32"))
    #expect(!result.list.cidrs.contains("2.2.2.0/24"))
    #expect(result.list.sha256.count == 64)
}

@Test
func targetListBuilderKeepsLastKnownGoodWhenDownloadedSourceFailsValidation() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-last-known-good-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = URL(string: "https://example.test/china.txt")!
    let paths = TailscaleRoutePaths(root: root)
    let configuration = TailscaleRouteConfiguration(chinaListURL: sourceURL)
    let previous = try TargetListBuilder(
        paths: paths,
        loader: StubTextLoader(data: Data("1.0.0.0/8\n2.0.0.0/8\n".utf8))
    ).build(configuration: configuration, refreshSource: true)
    let previousCache = try AtomicStore(paths: paths).read(ChinaCIDRCache.self, from: paths.chinaCache)

    let fallback = try TargetListBuilder(
        paths: paths,
        loader: StubTextLoader(data: Data("not-a-cidr\n3.0.0.0/8\n".utf8))
    ).build(configuration: configuration, refreshSource: true)
    let currentCache = try AtomicStore(paths: paths).read(ChinaCIDRCache.self, from: paths.chinaCache)

    #expect(fallback.list.cidrs == previous.list.cidrs)
    #expect(fallback.list.sourceMetadata == previousCache.metadata)
    #expect(fallback.warnings.contains { $0.contains("last-known-good") })
    #expect(currentCache == previousCache)
    #expect(currentCache.metadata.sourceSHA256.count == 64)
    #expect(currentCache.metadata.entryCount == 2)
}

@Test
func targetListBuilderDoesNotFallbackToCacheFromAnotherSourceURL() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-source-switch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = TailscaleRoutePaths(root: root)
    let firstURL = URL(string: "https://example.test/china-a.txt")!
    let secondURL = URL(string: "https://example.test/china-b.txt")!
    _ = try TargetListBuilder(
        paths: paths,
        loader: StubTextLoader(data: Data("1.0.0.0/8\n".utf8))
    ).build(
        configuration: TailscaleRouteConfiguration(chinaListURL: firstURL),
        refreshSource: true
    )

    var threw = false
    do {
        _ = try TargetListBuilder(
            paths: paths,
            loader: FailingTextLoader()
        ).build(configuration: TailscaleRouteConfiguration(chinaListURL: secondURL), refreshSource: true)
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test
func targetListBuilderRejectsTamperedCIDRCacheContent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-cache-integrity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = TailscaleRoutePaths(root: root)
    let sourceURL = URL(string: "https://example.test/china.txt")!
    _ = try TargetListBuilder(
        paths: paths,
        loader: StubTextLoader(data: Data("1.0.0.0/8\n".utf8))
    ).build(
        configuration: TailscaleRouteConfiguration(chinaListURL: sourceURL),
        refreshSource: true
    )
    let store = AtomicStore(paths: paths)
    let cache = try store.read(ChinaCIDRCache.self, from: paths.chinaCache)
    try store.write(
        ChinaCIDRCache(cidrs: ["2.0.0.0/8"], metadata: cache.metadata),
        to: paths.chinaCache
    )

    var threw = false
    do {
        _ = try TargetListBuilder(
            paths: paths,
            loader: FailingTextLoader()
        ).build(configuration: TailscaleRouteConfiguration(chinaListURL: sourceURL))
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test
func diagnosticRejectsMismatchedDesiredCIDRMetadata() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-desired-integrity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = TailscaleRoutePaths(root: root)
    let store = AtomicStore(paths: paths)
    try store.writeText("1.0.0.0/8\n", to: paths.desiredCIDRs)
    try store.write(
        DesiredRouteList(
            cidrs: ["2.0.0.0/8"],
            source: nil,
            sha256: "invalid"
        ),
        to: paths.desiredMetadata
    )

    let report = DiagnosticService(
        runner: StubCommandRunner(responses: [:]),
        desiredTargetsURL: paths.desiredCIDRs,
        desiredMetadataURL: paths.desiredMetadata
    ).run()
    #expect(report.managedTargets.isEmpty)
    #expect(report.warnings.contains { $0.contains("元数据不一致") })
}

@Test
func targetListBuilderCollapsesExactIPv4Siblings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-route-collapse-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("china.txt")
    let source = "1.0.0.0/25\n1.0.0.128/25\n2.0.0.0/24\n"
    try Data(source.utf8).write(to: sourceURL)

    let result = try TargetListBuilder(
        paths: TailscaleRoutePaths(root: root.appendingPathComponent("state")),
        loader: StubTextLoader(data: Data(source.utf8))
    ).build(
        configuration: TailscaleRouteConfiguration(chinaListURL: sourceURL),
        refreshSource: true
    )

    #expect(result.list.cidrs == ["1.0.0.0/24", "2.0.0.0/24"])
}

private func ipv6Address(_ literal: String) -> in6_addr {
    var address = in6_addr()
    precondition(literal.withCString { inet_pton(AF_INET6, $0, &address) } == 1)
    return address
}

@Test
func targetListBuilderRejectsNonGlobalIPv6Answers() {
    // getaddrinfo synthesizes IPv4-mapped answers for A records when queried
    // with AF_INET6; they must never become IPv6 host routes.
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("::ffff:198.51.100.164")))
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("::ffff:198.51.100.58")))
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("::1")))
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("::")))
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("::198.51.100.164")))
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("64:ff9b::198.51.100.164")))
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("fe80::1234")))
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("fc00::1a")))
    #expect(!TargetListBuilder.usableDomainIPv6(ipv6Address("ff02::1")))

    // Documentation IPv6 examples exercise accepted unicast-prefix paths.
    #expect(TargetListBuilder.usableDomainIPv6(ipv6Address("2001:db8:1::1a")))
    #expect(TargetListBuilder.usableDomainIPv6(ipv6Address("2001:db8:2::1")))
    #expect(TargetListBuilder.usableDomainIPv6(ipv6Address("2001:db8:3::1")))
}

private struct StubDigCommandRunner: CommandRunning {
    let aOutput: String
    let aaaaOutput: String

    public func run(_ executable: String, arguments: [String]) -> CommandResult {
        CommandResult(
            executable: executable,
            arguments: arguments,
            stdout: arguments.contains("AAAA") ? aaaaOutput : aOutput,
            stderr: "",
            exitCode: 0
        )
    }
}

@Test
func directDNSResolverParsesDigOutputAndIgnoresCNAMEs() {
    let resolver = DirectDNSDomainResolver(
        runner: StubDigCommandRunner(
            aOutput: "alias.example.test.\nedge.example.test.\n203.0.113.50\n203.0.113.48\n",
            aaaaOutput: "2001:db8:1::1a\n2001:db8:1::1b\n::ffff:203.0.113.50\n"
        ),
        servers: ["223.5.5.5"]
    )
    let ipv4 = resolver.resolveIPv4("example.test")
    #expect(ipv4 == ["203.0.113.48", "203.0.113.50"])
    let ipv6 = resolver.resolveIPv6("example.test")
    #expect(ipv6 == ["2001:db8:1::1a", "2001:db8:1::1b"])
}

private struct StubDomainResolver: DomainResolving {
    let ipv4: [String]?
    let ipv6: [String]?

    func resolveIPv4(_ domain: String) -> [String]? { ipv4 }
    func resolveIPv6(_ domain: String) -> [String]? { ipv6 }
}

@Test
func targetListBuilderKeepsLastKnownGoodDomainAnswersAfterTransientDNSFailure() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-domain-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = TailscaleRoutePaths(root: root)
    let configuration = TailscaleRouteConfiguration(
        chinaListURL: nil,
        manualIPs: ["1.1.1.1"],
        domainNames: ["example.test"]
    )

    let first = try TargetListBuilder(
        paths: paths,
        resolver: StubDomainResolver(ipv4: ["203.0.113.50"], ipv6: ["2001:db8:1::1a"])
    ).build(configuration: configuration)
    let second = try TargetListBuilder(
        paths: paths,
        resolver: StubDomainResolver(ipv4: nil, ipv6: nil)
    ).build(configuration: configuration)

    #expect(first.domainIPv4 == ["203.0.113.50"])
    #expect(second.domainIPv4 == ["203.0.113.50"])
    #expect(second.domainIPv6 == ["2001:db8:1::1a"])
    #expect(second.warnings.contains { $0.contains("last-known-good") })
}

@Test
func domainResolutionTreatsConfirmedEmptyAsDeletionButFailureAsLastKnownGood() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-domain-deletion-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = TailscaleRoutePaths(root: root)
    let configuration = TailscaleRouteConfiguration(domainNames: ["example.test"])

    let first = TargetListBuilder(
        paths: paths,
        resolver: StubDomainResolver(ipv4: ["203.0.113.50"], ipv6: [])
    ).resolveConfiguredDomains(configuration.domainNames)
    #expect(first.ipv4 == ["203.0.113.50"])

    // An explicit empty answer is a confirmed deletion, so the old address
    // is not kept in the resolver cache or the effective route set.
    let deleted = TargetListBuilder(
        paths: paths,
        resolver: StubDomainResolver(ipv4: [], ipv6: [])
    ).resolveConfiguredDomains(configuration.domainNames)
    #expect(deleted.ipv4.isEmpty)
    #expect(deleted.entries.allSatisfy { $0.ipv4Status == .confirmedEmpty })
    #expect(!(deleted.warnings.contains { $0.contains("last-known-good") }))

    // A later resolver failure has no stale answer to use and therefore does
    // not invent a new route or turn the failure into a deletion warning.
    let failed = TargetListBuilder(
        paths: paths,
        resolver: StubDomainResolver(ipv4: nil, ipv6: nil)
    ).resolveConfiguredDomains(configuration.domainNames)
    #expect(failed.ipv4.isEmpty)
    #expect(failed.entries.contains { $0.ipv4Status == .unavailable })
}

@Test
func domainIncrementalRouteTransactionLeavesChinaRoutesUntouched() {
    let china = RouteEntry(
        destination: "1.0.0.0/8",
        gateway: "192.168.1.1",
        flags: "UGSc",
        interfaceName: "en0",
        rawLine: ""
    )
    let oldDomain = RouteEntry(
        destination: "203.0.113.50/32",
        gateway: "192.168.1.1",
        flags: "UGSc",
        interfaceName: "en0",
        rawLine: ""
    )
    let backend = InMemoryRouteBackend(routes: [
        china,
        oldDomain,
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0",
        physicalPortName: "Wi-Fi",
        gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0",
        tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1",
        tailscaleExitNode: "tokyo"
    )

    let result = RouteCoordinator(backend: backend).apply(
        targets: ["203.0.113.51/32"],
        snapshot: snapshot,
        previouslyManagedRoutes: [RouteSpec(cidr: "203.0.113.50/32", gateway: "192.168.1.1", interfaceName: "en0")],
        allowEmptyTargets: true,
        purgeExternalRoutes: false
    )

    #expect(result.success)
    #expect(backend.currentRoutes().contains { $0.destination == "1.0.0.0/8" })
    #expect(backend.currentRoutes().contains { $0.destination == "203.0.113.50/32" } == false)
    #expect(backend.currentRoutes().contains { $0.destination == "203.0.113.51/32" })
}

@Test
func domainRefreshIsNotClassifiedAsRouteMutationAndOldHelperIsRejected() {
    #expect(!OperationStatePolicy.domainRefresh.isRouteMutation)
    #expect(!OperationStatePolicy.domainRefresh.updatesRouteProgress)
    #expect(HelperProtocolCompatibility.accepts(HelperResponse.currentProtocolVersion))
    #expect(!HelperProtocolCompatibility.accepts(HelperResponse.currentProtocolVersion - 1))
    #expect(!HelperProtocolCompatibility.accepts(nil))
}

@Test
func hostsPinManagerRendersAndCleansManagedSection() {
    let current = """
    ##
    # Host Database
    ##
    127.0.0.1 localhost
    192.168.1.10 device.test
    """
    let hosts = HostsPinManager.renderedHosts(
        currentHosts: current,
        pinLines: ["203.0.113.50 example.test www.example.test"]
    )
    #expect(hosts.hasPrefix(current))
    #expect(hosts.contains("203.0.113.50 example.test www.example.test"))

    // Re-rendering with different pins replaces the section, keeping the
    // original user entries intact and never duplicating markers.
    let updated = HostsPinManager.renderedHosts(
        currentHosts: hosts,
        pinLines: ["203.0.113.197 example.test www.example.test"]
    )
    #expect(!updated.contains("203.0.113.50"))
    #expect(updated.contains("203.0.113.197 example.test www.example.test"))
    #expect(updated.components(separatedBy: HostsPinManager.beginMarker).count - 1 == 1)

    // Rendering with no pins removes the managed section entirely.
    let cleaned = HostsPinManager.renderedHosts(currentHosts: updated, pinLines: [])
    #expect(cleaned == current)
}

@Test
func hostsPinManagerPinLinesCoverDomainsAndWWW() {
    let lines = HostsPinManager.pinLines(for: [
        HostAddress(domain: "example.test", ipv4Addresses: ["203.0.113.50"], ipv6Addresses: ["2001:db8:1::1a"]),
        HostAddress(domain: "example.com", ipv4Addresses: ["198.51.100.164", "198.51.100.165"], ipv6Addresses: []),
    ])
    #expect(lines.contains("203.0.113.50 example.test www.example.test"))
    #expect(lines.contains("2001:db8:1::1a example.test www.example.test"))
    #expect(lines.contains("198.51.100.164 example.com www.example.com"))
    #expect(lines.count == 4)
}

@Test
func routeCoordinatorRebuildsAndVerifiesAgainstNewGateway() {
    let oldRoute = RouteEntry(
        destination: "1/8",
        gateway: "192.168.1.1",
        flags: "UGSc",
        interfaceName: "en0",
        rawLine: "1/8 192.168.1.1 UGSc en0"
    )
    let exitRoute = RouteEntry(
        destination: "0/0",
        gateway: "-",
        flags: "UGSc",
        interfaceName: "utun4",
        rawLine: "0/0 - UGSc utun4"
    )
    let backend = InMemoryRouteBackend(routes: [oldRoute, exitRoute])
    let coordinator = RouteCoordinator(backend: backend)
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0",
        physicalPortName: "Wi-Fi",
        gateway: "172.20.10.1",
        defaultRouteSignature: "physical->172.20.10.1 via en0",
        tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1",
        tailscaleExitNode: "tokyo"
    )

    let result = coordinator.apply(
        targets: ["1.0.0.0/8"],
        snapshot: snapshot,
        previouslyManagedRoutes: [RouteSpec(cidr: "1.0.0.0/8", gateway: "192.168.1.1", interfaceName: "en0")]
    )
    #expect(result.success)
    let managed = backend.currentRoutes().first { $0.destination == "1.0.0.0/8" }
    #expect(managed?.gateway == "172.20.10.1")
    #expect(managed?.interfaceName == "en0")
}

@Test
func routeCoordinatorVerifiesExactTargetWhenMoreSpecificRouteWinsLookup() {
    let backend = InMemoryRouteBackend(routes: [
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: ""),
        RouteEntry(destination: "223.255.252.0/23", gateway: "192.168.1.1", flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "223.255.252.0/24", gateway: "192.168.1.1", flags: "UGSc", interfaceName: "en0", rawLine: "")
    ])
    let coordinator = RouteCoordinator(backend: backend)
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0",
        physicalPortName: "Wi-Fi",
        gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0",
        tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1",
        tailscaleExitNode: "tokyo"
    )

    let result = coordinator.apply(
        targets: ["223.255.252.0/23"],
        snapshot: snapshot
    )

    #expect(result.success)
}

@Test
func routeCoordinatorKeepsCorrectRoutesAndOnlyRemovesExternalRoutes() {
    let backend = InMemoryRouteBackend(routes: [
        RouteEntry(destination: "1.0.0.0/8", gateway: "192.168.1.1", flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "2.0.0.0/8", gateway: "192.168.1.1", flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    let coordinator = RouteCoordinator(backend: backend)
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0",
        physicalPortName: "Wi-Fi",
        gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0",
        tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1",
        tailscaleExitNode: "tokyo"
    )

    let result = coordinator.apply(
        targets: ["1.0.0.0/8"],
        snapshot: snapshot,
        purgeExternalRoutes: true
    )

    #expect(result.success)
    #expect(result.appliedCount == 0)
    #expect(result.removedCount == 1)
    #expect(backend.currentRoutes().map(\.destination) == ["1.0.0.0/8", "0/0"])
}

@Test
func routeCoordinatorReconcilesPreviousManagedTargetsWithoutPurgingUnrelatedRoutes() {
    let backend = InMemoryRouteBackend(routes: [
        RouteEntry(destination: "1.0.0.0/8", gateway: "192.168.1.1", flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "2.0.0.0/8", gateway: "192.168.1.1", flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    let coordinator = RouteCoordinator(backend: backend)
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0",
        physicalPortName: "Wi-Fi",
        gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0",
        tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1",
        tailscaleExitNode: "tokyo"
    )

    let result = coordinator.apply(
        targets: ["1.0.0.0/8"],
        snapshot: snapshot,
        previouslyManagedTargets: ["1.0.0.0/8", "2.0.0.0/8"]
    )

    #expect(result.success)
    #expect(result.removedCount == 1)
    #expect(backend.currentRoutes().map(\.destination).contains("2.0.0.0/8") == false)
    #expect(backend.currentRoutes().contains { $0.destination == "1.0.0.0/8" })
    #expect(backend.currentRoutes().contains { $0.destination == "0/0" })
}

@Test
func routeCoordinatorPreservesConfirmedAddsAndReportsIncompleteTargetsWhenAnAddFails() {
    let backend = InMemoryRouteBackend(routes: [RouteEntry(
        destination: "0/0",
        gateway: "-",
        flags: "UGSc",
        interfaceName: "utun4",
        rawLine: "0/0 - UGSc utun4"
    )])
    backend.failOnAddTarget = "2.0.0.0/8"
    let coordinator = RouteCoordinator(backend: backend)
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0",
        physicalPortName: "Wi-Fi",
        gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0",
        tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1",
        tailscaleExitNode: "tokyo"
    )

    let result = coordinator.apply(targets: ["1.0.0.0/8", "2.0.0.0/8"], snapshot: snapshot)
    #expect(!result.success)
    #expect(result.state == .partial)
    #expect(result.appliedCount == 1)
    #expect(result.managedRoutes?.map(\.cidr) == ["1.0.0.0/8"])
    #expect(backend.currentRoutes().count == 2)
}

@Test
func routeCoordinatorPreservesSuccessfulGatewayChangesWhenABatchChangeFails() {
    let oldGateway = "192.168.1.1"
    let newGateway = "172.20.10.1"
    let oldRoutes = [
        RouteSpec(cidr: "1.0.0.0/8", gateway: oldGateway, interfaceName: "en0"),
        RouteSpec(cidr: "2.0.0.0/8", gateway: oldGateway, interfaceName: "en0")
    ]
    let backend = InMemoryRouteBackend(routes: [
        RouteEntry(destination: "1.0.0.0/8", gateway: oldGateway, flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "2.0.0.0/8", gateway: oldGateway, flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    backend.failOnChangeTarget = "2.0.0.0/8"
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0", physicalPortName: "Wi-Fi", gateway: newGateway,
        defaultRouteSignature: "physical->172.20.10.1 via en0", tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1", tailscaleExitNode: "tokyo"
    )

    let result = RouteCoordinator(backend: backend).apply(
        targets: oldRoutes.map(\.cidr),
        snapshot: snapshot,
        previouslyManagedRoutes: oldRoutes
    )

    #expect(!result.success)
    #expect(result.state == .partial)
    #expect(result.appliedCount == 1)
    #expect(result.managedRoutes?.contains(RouteSpec(cidr: "1.0.0.0/8", gateway: newGateway, interfaceName: "en0")) == true)
    #expect(result.managedRoutes?.contains(oldRoutes[1]) == true)
    #expect(result.pendingRemovals == [oldRoutes[1]])
    #expect(backend.currentRoutes().contains { $0.destination == "1.0.0.0/8" && $0.gateway == newGateway })
    #expect(backend.currentRoutes().contains { $0.destination == "2.0.0.0/8" && $0.gateway == oldGateway })
}

@Test
func systemRouteBackendUsesOneRouteSocketAndStopsAfterTheFirstChangeError() {
    let socket = StubRouteSocketClient(responses: [0, EPERM])
    let backend = SystemRouteBackend(runner: StubCommandRunner(responses: [:]), routeSocket: socket)
    let replacements = ["1.0.0.0/8", "2.0.0.0/8", "3.0.0.0/8"].map { cidr in
        RouteReplacementPlan(
            oldRoute: RouteSpec(cidr: cidr, gateway: "192.0.2.1", interfaceName: "en0"),
            newRoute: RouteSpec(cidr: cidr, gateway: "192.0.2.2", interfaceName: "en0")
        )
    }

    let results = backend.changeBatch(replacements, progress: nil)

    #expect(socket.openCount == 1)
    #expect(socket.closeDescriptors == [17])
    #expect(socket.requests.count == 2)
    #expect(socket.requests.allSatisfy { $0.descriptor == 17 && $0.action == .change })
    #expect(results.map(\.succeeded) == [true, false, false])
    #expect(results[0].executable == "PF_ROUTE socket")
    #expect(results[0].arguments.first == "RTM_CHANGE")
    #expect(results[1].failureReason == String(cString: strerror(EPERM)))
    #expect(results[2].failureReason == "前一条路由失败，已停止批量操作")
}

@Test
func systemRouteBackendReportsRouteSocketOpenFailureWithoutSendingRequests() {
    let socket = StubRouteSocketClient(openResult: RouteSocketOpenResult(descriptor: -1, errorCode: EMFILE))
    let backend = SystemRouteBackend(runner: StubCommandRunner(responses: [:]), routeSocket: socket)
    let replacements = ["1.0.0.0/8", "2.0.0.0/8"].map { cidr in
        RouteReplacementPlan(
            oldRoute: RouteSpec(cidr: cidr, gateway: "192.0.2.1", interfaceName: "en0"),
            newRoute: RouteSpec(cidr: cidr, gateway: "192.0.2.2", interfaceName: "en0")
        )
    }

    let results = backend.changeBatch(replacements, progress: nil)

    #expect(socket.openCount == 1)
    #expect(socket.requests.isEmpty)
    #expect(socket.closeDescriptors.isEmpty)
    #expect(results.count == 2)
    #expect(results.allSatisfy { !$0.succeeded && $0.failureReason == String(cString: strerror(EMFILE)) })
}

@Test
func routeCoordinatorKeepsNewAndOldOwnedRoutesWhenStaleCleanupFails() {
    let oldGateway = "192.168.1.1"
    let backend = InMemoryRouteBackend(routes: [
        RouteEntry(destination: "1.0.0.0/8", gateway: oldGateway, flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "2.0.0.0/8", gateway: oldGateway, flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    backend.failOnRemoveTarget = "2.0.0.0/8"
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0", physicalPortName: "Wi-Fi", gateway: oldGateway,
        defaultRouteSignature: "physical->192.168.1.1 via en0", tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1", tailscaleExitNode: "tokyo"
    )
    let previous = [
        RouteSpec(cidr: "1.0.0.0/8", gateway: oldGateway, interfaceName: "en0"),
        RouteSpec(cidr: "2.0.0.0/8", gateway: oldGateway, interfaceName: "en0")
    ]

    let result = RouteCoordinator(backend: backend).apply(
        targets: ["1.0.0.0/8"],
        snapshot: snapshot,
        previouslyManagedRoutes: previous
    )

    #expect(!result.success)
    #expect(result.state == .partial)
    #expect(result.managedRoutes?.count == 2)
    #expect(result.pendingRemovals == [previous[1]])
    #expect(backend.currentRoutes().contains { $0.destination == "1.0.0.0/8" })
    #expect(backend.currentRoutes().contains { $0.destination == "2.0.0.0/8" })
}

@Test
func routeCoordinatorStopsBeforeMutationWhenInitialRouteSnapshotFails() {
    let initialRoute = RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    let backend = InMemoryRouteBackend(routes: [initialRoute])
    backend.routeTableReadFailureReason = "permission denied"
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0", physicalPortName: "Wi-Fi", gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0", tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1", tailscaleExitNode: "tokyo"
    )

    let result = RouteCoordinator(backend: backend).apply(targets: ["1.0.0.0/8"], snapshot: snapshot)

    #expect(!result.success)
    #expect(result.state == .error)
    #expect(backend.currentRoutes() == [initialRoute])
}

@Test
func routeCoordinatorLeavesAnUnownedConflictingRouteUntouched() {
    let foreign = RouteEntry(destination: "1.0.0.0/8", gateway: "10.0.0.1", flags: "UG", interfaceName: "en5", rawLine: "")
    let backend = InMemoryRouteBackend(routes: [
        foreign,
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0", physicalPortName: "Wi-Fi", gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0", tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1", tailscaleExitNode: "tokyo"
    )
    let result = RouteCoordinator(backend: backend).apply(targets: ["1.0.0.0/8"], snapshot: snapshot)
    #expect(result.success)
    #expect(backend.currentRoutes().contains { $0.gateway == foreign.gateway && $0.interfaceName == foreign.interfaceName })
    #expect(backend.currentRoutes().contains { $0.gateway == "192.168.1.1" && $0.interfaceName == "en0" })
}

@Test
func routeCoordinatorPreviewShowsChangesWithoutMutatingRoutes() {
    let current = [
        RouteEntry(destination: "1.0.0.0/8", gateway: "192.168.1.1", flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "2.0.0.0/8", gateway: "192.168.1.1", flags: "UGSc", interfaceName: "en0", rawLine: ""),
        RouteEntry(destination: "3.0.0.0/8", gateway: "10.0.0.1", flags: "UG", interfaceName: "en5", rawLine: ""),
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ]
    let backend = InMemoryRouteBackend(routes: current)
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0", physicalPortName: "Wi-Fi", gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0", tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1", tailscaleExitNode: "tokyo"
    )
    let previouslyManaged = [
        RouteSpec(cidr: "1.0.0.0/8", gateway: "192.168.1.1", interfaceName: "en0"),
        RouteSpec(cidr: "2.0.0.0/8", gateway: "192.168.1.1", interfaceName: "en0")
    ]

    let plan = RouteCoordinator(backend: backend).preview(
        targets: ["1.0.0.0/8", "3.0.0.0/8", "4.0.0.0/8"],
        snapshot: snapshot,
        previouslyManagedRoutes: previouslyManaged
    )

    #expect(plan.errors.isEmpty)
    #expect(plan.alreadyCorrect.map(\.cidr) == ["1.0.0.0/8"])
    #expect(plan.additions.map(\.cidr) == ["3.0.0.0/8", "4.0.0.0/8"])
    #expect(plan.cleanup == [previouslyManaged[1]])
    #expect(plan.unownedConflicts.count == 1)
    #expect(backend.currentRoutes() == current)
}

@Test
func stoppingRemovesManagedRoutesAndPreservesBaseConnectivity() {
    let managedIPv4 = RouteEntry(
        destination: "1.0.0.0/8",
        gateway: "192.168.1.1",
        flags: "UGSc",
        interfaceName: "en0",
        rawLine: "1.0.0.0/8 192.168.1.1 UGSc en0"
    )
    let sameDestinationOnTailscale = RouteEntry(
        destination: "1.0.0.0/8",
        gateway: "100.64.0.1",
        flags: "UGSc",
        interfaceName: "utun2",
        rawLine: "1.0.0.0/8 100.64.0.1 UGSc utun2"
    )
    let externalDirect = RouteEntry(
        destination: "2.0.0.0/8",
        gateway: "192.168.1.1",
        flags: "UGSc",
        interfaceName: "en0",
        rawLine: "2.0.0.0/8 192.168.1.1 UGSc en0"
    )
    let physicalDefault = RouteEntry(
        destination: "default",
        gateway: "192.168.1.1",
        flags: "UGSc",
        interfaceName: "en0",
        rawLine: "default 192.168.1.1 UGSc en0"
    )
    let tailscaleDefault = RouteEntry(
        destination: "default",
        gateway: "link#17",
        flags: "UCSIg",
        interfaceName: "utun2",
        rawLine: "default link#17 UCSIg utun2"
    )
    let tailscaleRange = RouteEntry(
        destination: "100.64.0.0/10",
        gateway: "link#17",
        flags: "UCS",
        interfaceName: "utun2",
        rawLine: "100.64.0.0/10 link#17 UCS utun2"
    )
    let backend = InMemoryRouteBackend(routes: [
        managedIPv4,
        sameDestinationOnTailscale,
        externalDirect,
        physicalDefault,
        tailscaleDefault,
        tailscaleRange
    ])
    let coordinator = RouteCoordinator(backend: backend)

    let result = coordinator.pause(routes: [
        RouteSpec(cidr: "1.0.0.0/8", gateway: "192.168.1.1", interfaceName: "en0"),
        // A legacy IPv6 spec is intentionally ignored by pause.
        RouteSpec(cidr: "::/1", gateway: "fe80::1%en0", interfaceName: "en0")
    ])

    #expect(result.success)
    #expect(result.removedCount == 1)
    #expect(backend.currentRoutes().contains(physicalDefault))
    #expect(backend.currentRoutes().contains(tailscaleDefault))
    #expect(backend.currentRoutes().contains(tailscaleRange))
    #expect(backend.currentRoutes().contains(externalDirect))
    #expect(backend.currentRoutes().contains(sameDestinationOnTailscale))
    #expect(!backend.currentRoutes().contains(managedIPv4))
}

@Test
func normalListBuildUsesFreshCacheAndExplicitUpdateRefreshes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-cache-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let loader = CountingTextLoader(data: Data("1.0.0.0/8\n".utf8))
    let builder = TargetListBuilder(
        paths: TailscaleRoutePaths(root: root),
        loader: loader
    )
    let configuration = TailscaleRouteConfiguration(
        chinaListURL: URL(string: "https://example.test/china.txt")
    )

    _ = try builder.build(configuration: configuration, refreshSource: true)
    _ = try builder.build(configuration: configuration)
    _ = try builder.build(configuration: configuration, refreshSource: true)

    #expect(loader.calls == 2)
}

@Test
func inspectorUsesPhysicalGatewayWhenSystemDefaultIsTailscale() throws {
    let defaultRoute = """
       destination: default
          gateway: -
        interface: utun8
            flags: <UP,DONE>
    """
    let hardwarePorts = """
    Hardware Port: Wi-Fi
    Device: en0
    """
    let tailscaleStatus = """
    {
      "Self": { "HostName": "laptop", "TailscaleIPs": ["100.64.0.100"] },
      "ExitNodeStatus": { "HostName": "exitnode-a" }
    }
    """
    let routeTable = """
    Routing tables
    Internet:
    Destination        Gateway            Flags        Netif Expire
    default            link#23            UGScg        utun8
    default            192.168.1.1        UGScg        en0
    """

    let runner = StubCommandRunner(responses: [
        key("/sbin/route", ["-n", "get", "default"]): result("/sbin/route", ["-n", "get", "default"], stdout: defaultRoute),
        key("/usr/sbin/networksetup", ["-listallhardwareports"]): result("/usr/sbin/networksetup", ["-listallhardwareports"], stdout: hardwarePorts),
        key("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"]): result("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"], stdout: "Router: 192.168.1.1\n"),
        key("/sbin/ifconfig", ["en0"]): result("/sbin/ifconfig", ["en0"], stdout: "en0: flags=8863<UP,BROADCAST,RUNNING>\nstatus: active\n"),
        key("/usr/sbin/ipconfig", ["getpacket", "en0"]): result("/usr/sbin/ipconfig", ["getpacket", "en0"], stderr: "not needed", exitCode: 1),
        key("/usr/bin/env", ["TAILSCALE_BE_CLI=1", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "status", "--json"]): result("tailscale", ["status", "--json"], stdout: tailscaleStatus),
        key("/sbin/route", ["-n", "get", "100.64.0.100"]): result("/sbin/route", ["-n", "get", "100.64.0.100"], stdout: "interface: utun8\n"),
        key("/usr/sbin/netstat", ["-rn", "-f", "inet"]): result("/usr/sbin/netstat", ["-rn", "-f", "inet"], stdout: routeTable)
    ])

    let inspection = NetworkInspector(runner: runner).inspect()
    #expect(inspection.snapshot.physicalInterface == "en0")
    #expect(inspection.snapshot.gateway == "192.168.1.1")
    #expect(inspection.snapshot.tailscaleInterface == "utun8")
    #expect(inspection.snapshot.tailscaleExitNode == "exitnode-a")
    #expect(inspection.actualRoutes.count == 2)
    #expect(inspection.warnings.contains { $0.contains("utun8") })
}

@Test
func inspectorRejectsAmbiguousPhysicalEgressWhenTailscaleIsDefault() {
    let responses = [
        key("/sbin/route", ["-n", "get", "default"]): result("route", ["get"], stdout: "destination: default\ngateway: -\ninterface: utun8\nflags: <UP>\n"),
        key("/usr/sbin/networksetup", ["-listallhardwareports"]): result("networksetup", ["list"], stdout: "Hardware Port: Wi-Fi\nDevice: en0\nHardware Port: Ethernet\nDevice: en1\n"),
        key("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"]): result("networksetup", ["getinfo"], stdout: "Router: 192.168.1.1\n"),
        key("/usr/sbin/networksetup", ["-getinfo", "Ethernet"]): result("networksetup", ["getinfo"], stdout: "Router: 192.168.4.1\n"),
        key("/sbin/ifconfig", ["en0"]): result("ifconfig", ["en0"], stdout: "en0: flags=8863<UP,BROADCAST,RUNNING>\nstatus: active\n"),
        key("/sbin/ifconfig", ["en1"]): result("ifconfig", ["en1"], stdout: "en1: flags=8863<UP,BROADCAST,RUNNING>\nstatus: active\n"),
        key("/usr/sbin/netstat", ["-rn", "-f", "inet"]): result("netstat", ["inet"], stdout: "default link#23 UGScg utun8\n")
    ]
    let inspection = NetworkInspector(runner: StubCommandRunner(responses: responses)).inspect()
    #expect(inspection.snapshot.physicalInterface == nil)
    #expect(inspection.warnings.contains { $0.contains("多个可用物理网卡") })
}

@Test
func inspectorRejectsFallbackWhenPhysicalDefaultInterfaceHasNoGateway() {
    let responses = [
        key("/sbin/route", ["-n", "get", "default"]): result("route", ["get"], stdout: "destination: default\ngateway: -\ninterface: en0\nflags: <UP>\n"),
        key("/usr/sbin/networksetup", ["-listallhardwareports"]): result("networksetup", ["list"], stdout: "Hardware Port: Wi-Fi\nDevice: en0\nHardware Port: Ethernet\nDevice: en1\n"),
        key("/usr/sbin/networksetup", ["-getinfo", "Wi-Fi"]): result("networksetup", ["getinfo"], stdout: "Router: (null)\n"),
        key("/usr/sbin/networksetup", ["-getinfo", "Ethernet"]): result("networksetup", ["getinfo"], stdout: "Router: 192.168.4.1\n"),
        key("/sbin/ifconfig", ["en0"]): result("ifconfig", ["en0"], stdout: "en0: flags=8863<UP,BROADCAST,RUNNING>\nstatus: active\n"),
        key("/sbin/ifconfig", ["en1"]): result("ifconfig", ["en1"], stdout: "en1: flags=8863<UP,BROADCAST,RUNNING>\nstatus: active\n"),
        key("/usr/sbin/netstat", ["-rn", "-f", "inet"]): result("netstat", ["inet"], stdout: "default link#23 UGScg en0\n")
    ]

    let inspection = NetworkInspector(runner: StubCommandRunner(responses: responses)).inspect()
    #expect(inspection.snapshot.physicalInterface == nil)
    #expect(inspection.snapshot.gateway == nil)
    #expect(inspection.warnings.contains { $0.contains("拒绝回退到其它物理网卡") })
}

@Test
func externalNetworkDetectorRecognizesModernSkywalkEthernetAdapters() {
    let runner = StubCommandRunner(responses: [
        key("/usr/sbin/networksetup", ["-listallhardwareports"]): result(
            "/usr/sbin/networksetup", ["-listallhardwareports"],
            stdout: "Hardware Port: USB 10/100/1000 LAN\nDevice: en7\n"
        ),
        key("/sbin/ifconfig", ["-a"]): result(
            "/sbin/ifconfig", ["-a"],
            stdout: "en7: flags=8863<UP,BROADCAST,RUNNING,MULTICAST> mtu 1500\n    inet 192.168.32.99 netmask 0xfffff000 broadcast 192.168.47.255\n    status: active\n"
        ),
        key("/usr/sbin/netstat", ["-rn", "-f", "inet"]): result(
            "/usr/sbin/netstat", ["-rn", "-f", "inet"],
            stdout: "192.168.32/20 link#13 UCSc en7\n"
        ),
        key("/usr/sbin/networksetup", ["-getinfo", "USB 10/100/1000 LAN"]): result(
            "/usr/sbin/networksetup", ["-getinfo", "USB 10/100/1000 LAN"],
            stdout: "Router: 192.168.32.1\n"
        ),
        key("/usr/sbin/ioreg", ["-p", "IOService", "-r", "-n", "en7", "-l", "-w0"]): result(
            "/usr/sbin/ioreg", ["-p", "IOService", "-r", "-n", "en7", "-l", "-w0"],
            stdout: """
            +-o en7 <class IOSkywalkLegacyEthernetInterface>
              | {
              |   "IOBuiltin" = No
              |   "IOInterfaceType" = 6
              | }
            """
        )
    ])

    let detection = ExternalDirectNetworkDetector(runner: runner).scan()
    #expect(detection.isAuthoritative)
    #expect(detection.warning == nil)
    #expect(detection.networks == [ExternalDirectNetwork(
        interfaceName: "en7",
        hardwarePortName: "USB 10/100/1000 LAN",
        address: "192.168.32.99",
        cidr: "192.168.32.0/20",
        gateway: "192.168.32.1"
    )])
}

@Test
func externalNetworkDetectorAcceptsManualAdapterWithoutRouter() {
    let runner = StubCommandRunner(responses: [
        key("/usr/sbin/networksetup", ["-listallhardwareports"]): result(
            "/usr/sbin/networksetup", ["-listallhardwareports"],
            stdout: "Hardware Port: USB 10/100/1000 LAN\nDevice: en7\n"
        ),
        key("/sbin/ifconfig", ["-a"]): result(
            "/sbin/ifconfig", ["-a"],
            stdout: "en7: flags=8863<UP,BROADCAST,RUNNING,MULTICAST> mtu 1500\n    inet 192.168.32.99 netmask 0xfffff000 broadcast 192.168.47.255\n    status: active\n"
        ),
        key("/usr/sbin/netstat", ["-rn", "-f", "inet"]): result(
            "/usr/sbin/netstat", ["-rn", "-f", "inet"],
            stdout: "192.168.32/20 link#13 UCSc en7\n"
        ),
        key("/usr/sbin/networksetup", ["-getinfo", "USB 10/100/1000 LAN"]): result(
            "/usr/sbin/networksetup", ["-getinfo"],
            stdout: "Router: (null)\n"
        ),
        key("/usr/sbin/ioreg", ["-p", "IOService", "-r", "-n", "en7", "-l", "-w0"]): result(
            "/usr/sbin/ioreg", ["-p", "IOService"],
            stdout: "+-o en7 <class IOSkywalkLegacyEthernetInterface>\n  | {\n  |   \"IOBuiltin\" = No\n  |   | \"IOInterfaceType\" = 6\n  | }\n"
        )
    ])

    let detection = ExternalDirectNetworkDetector(runner: runner).scan()
    #expect(detection.isAuthoritative)
    #expect(detection.warning == nil)
    #expect(detection.networks == [ExternalDirectNetwork(
        interfaceName: "en7",
        hardwarePortName: "USB 10/100/1000 LAN",
        address: "192.168.32.99",
        cidr: "192.168.32.0/20",
        gateway: nil
    )])
}

@Test
func helperTemporarilyEnablesAndRestoresExitNodeLANAccessForExternalSubnet() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-external-protection-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runner = ExternalNetworkProtectionTestRunner()
    let helper = HelperService(paths: TailscaleRoutePaths(root: root), runner: runner)
    let status = helper.handle(HelperRequest(action: .status))

    #expect(status.success)
    #expect(status.report?.externalSubnetProtectionActive == nil)
    #expect(status.state?.managedExternalGatewayRoutes.isEmpty == true)
    #expect(status.layeredStatus?.route == .ok)
    #expect(status.layeredStatus?.externalProtection == .notEvaluated)
    #expect(runner.routeAll == true)

    let protected = helper.handle(HelperRequest(action: .reconcileExternalProtection))

    #expect(protected.success)
    #expect(protected.report?.externalDirectNetworks?.map(\.cidr) == ["192.168.32.0/20"])
    #expect(protected.report?.externalSubnetProtectionActive == true)
    #expect(protected.layeredStatus?.externalProtection == .ok)
    #expect(protected.state?.tailscalePreferenceLease?.originalAllowLANAccess == false)
    #expect(protected.state?.tailscalePreferenceLease?.managedLANAccess == true)
    #expect(protected.state?.managedExternalGatewayRoutes == [RouteSpec(
        cidr: "192.168.32.0/20",
        gateway: "192.168.32.99",
        interfaceName: "en7"
    )])
    #expect(runner.routeAll == false)
    #expect(runner.allowLANAccess == true)
    #expect(runner.externalNetworkPinned)

    runner.externalAdapterActive = false
    let restored = helper.handle(HelperRequest(action: .reconcileExternalProtection))
    #expect(restored.success)
    #expect(restored.state?.tailscalePreferenceLease == nil)
    #expect(restored.state?.managedExternalGatewayRoutes.isEmpty == true)
    #expect(runner.routeAll == true)
    #expect(runner.allowLANAccess == false)

}

@Test
func pauseKeepsExternalProtectionAndRestoreDefaultReleasesIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-pause-external-protection-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runner = ExternalNetworkProtectionTestRunner()
    let paths = TailscaleRoutePaths(root: root)
    let hostsURL = root.appendingPathComponent("hosts")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: hostsURL)
    let helper = HelperService(paths: paths, runner: runner, routeBackend: SystemRouteBackend(runner: runner), hostsPath: hostsURL.path)
    let protected = helper.handle(HelperRequest(action: .reconcileExternalProtection))
    #expect(protected.success)
    #expect(protected.state?.tailscalePreferenceLease != nil)

    let paused = helper.handle(HelperRequest(action: .pause))
    #expect(paused.success)
    #expect(paused.state?.lifecycle == .paused)
    #expect(paused.state?.tailscalePreferenceLease != nil)
    #expect(paused.state?.managedExternalGatewayRoutes.isEmpty == false)
    #expect(runner.routeAll == false)
    #expect(runner.allowLANAccess == true)

    let restored = helper.handle(HelperRequest(action: .restoreDefault))
    #expect(restored.success)
    #expect(restored.state?.lifecycle == .disabled)
    #expect(restored.state?.tailscalePreferenceLease == nil)
    #expect(restored.state?.managedExternalGatewayRoutes.isEmpty == true)
    #expect(runner.routeAll == true)
    #expect(runner.allowLANAccess == false)

    // Releasing protection must invalidate the prior snapshot baseline. The
    // same adapter is still present, so the next explicit reconcile must be
    // able to establish protection again.
    let reprotected = helper.handle(HelperRequest(action: .reconcileExternalProtection))
    #expect(reprotected.success)
    #expect(reprotected.state?.tailscalePreferenceLease != nil)
    #expect(reprotected.report?.externalSubnetProtectionActive == true)
}

@Test
func helperAcceptsInterfaceScopedNativeExternalRoute() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-external-scoped-route-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runner = ExternalNetworkProtectionTestRunner()
    let helper = HelperService(paths: TailscaleRoutePaths(root: root), runner: runner)
    let protected = helper.handle(HelperRequest(action: .reconcileExternalProtection))

    #expect(protected.success)
    #expect(protected.report?.externalSubnetProtectionActive == true)
}

@Test
func helperMigratesOldLANAccessLeaseAndRestoresOriginalValue() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-external-lease-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = TailscaleRoutePaths(root: root)
    let store = AtomicStore(paths: paths)
    let oldLease = TailscalePreferenceLease(
        originalAcceptRoutes: true,
        originalAllowLANAccess: true,
        managedLANAccess: false,
        exitNodeID: "exit-id",
        tailnetControlURL: "https://controlplane.tailscale.com"
    )
    try store.write(PersistedRouteState(tailscalePreferenceLease: oldLease), to: paths.lastSuccess)

    let runner = ExternalNetworkProtectionTestRunner(routeAll: false, allowLANAccess: false)
    let helper = HelperService(paths: paths, runner: runner)
    let protected = helper.handle(HelperRequest(action: .reconcileExternalProtection))

    #expect(protected.report?.externalSubnetProtectionActive == true)
    #expect(protected.state?.tailscalePreferenceLease?.originalAllowLANAccess == true)
    #expect(protected.state?.tailscalePreferenceLease?.managedLANAccess == true)
    #expect(runner.routeAll == false)
    #expect(runner.allowLANAccess == true)

    runner.externalAdapterActive = false
    let restored = helper.handle(HelperRequest(action: .reconcileExternalProtection))
    #expect(restored.state?.tailscalePreferenceLease == nil)
    #expect(runner.routeAll == true)
    #expect(runner.allowLANAccess == true)
}

@Test
func externalProtectionRetainsLedgerWhenStaleRouteCleanupFails() {
    let runner = ExternalNetworkProtectionTestRunner()
    runner.externalAdapterActive = false
    runner.staleExternalRoutePresent = true
    runner.failExternalNetworkRouteDeletion = true
    let managed = RouteSpec(
        cidr: "192.168.32.0/20",
        gateway: "192.168.32.99",
        interfaceName: "en7"
    )

    let result = ExternalNetworkRouteProtector(runner: runner).reconcile(
        networks: [],
        previouslyManaged: [managed]
    )

    #expect(result.managedRoutes == [managed])
    #expect(!result.warnings.isEmpty)
}

@Test
func externalProtectionRestoresConflictWhenNewRouteAddFails() {
    let runner = ExternalNetworkProtectionTestRunner()
    runner.failExternalNetworkRouteAdd = true
    let network = ExternalDirectNetwork(
        interfaceName: "en7",
        hardwarePortName: "USB Ethernet",
        address: "192.168.32.99",
        cidr: "192.168.32.0/20",
        gateway: "192.168.32.1"
    )
    let result = ExternalNetworkRouteProtector(runner: runner).reconcile(
        networks: [network],
        previouslyManaged: []
    )
    #expect(!result.warnings.isEmpty)
    #expect(runner.conflictingExternalNetworkRoute)
}

@Test
func ipv6RouteVerificationFailureRollsBackTheNewRoute() {
    let runner = IPv6RollbackTestRunner()
    let result = IPv6DomainRouteManager(runner: runner).apply(
        addresses: ["2001:db8::1"],
        gateway: "fe80::1%en0",
        interfaceName: "en0",
        previouslyManaged: []
    )
    #expect(result.managedRoutes.isEmpty)
    #expect(result.warnings.contains { $0.contains("已回滚") })
    #expect(runner.deleteCount == 1)
}

@Test
func shutdownDoesNotRestoreTailscaleLeaseBeforeExternalCleanupIsConfirmed() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-shutdown-external-cleanup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = TailscaleRoutePaths(root: root)
    let store = AtomicStore(paths: paths)
    let managed = RouteSpec(cidr: "192.168.32.0/20", gateway: "192.168.32.99", interfaceName: "en7")
    try store.write(PersistedRouteState(
        managedExternalGatewayRoutes: [managed],
        tailscalePreferenceLease: TailscalePreferenceLease(
            originalAcceptRoutes: true,
            originalAllowLANAccess: false,
            managedLANAccess: true,
            exitNodeID: "exit-id",
            tailnetControlURL: "https://controlplane.tailscale.com"
        )
    ), to: paths.lastSuccess)

    let runner = ExternalNetworkProtectionTestRunner()
    runner.externalAdapterActive = false
    runner.staleExternalRoutePresent = true
    runner.failExternalNetworkRouteDeletion = true
    let helper = HelperService(paths: paths, runner: runner)

    let response = helper.handle(HelperRequest(action: .shutdown))

    #expect(!response.success)
    #expect(response.state?.managedExternalGatewayRoutes == [managed])
    #expect(response.state?.tailscalePreferenceLease != nil)
    #expect(runner.routeAll == true)
    #expect(runner.allowLANAccess == false)
}

@Test
func tailscaleParserExtractsExitNodeEndpointAddress() throws {
    let data = Data("""
    {
      "Self": {
        "HostName": "laptop",
        "TailscaleIPs": ["100.64.0.100"]
      },
      "ExitNodeStatus": {
        "ID": "node-id",
        "Online": true
      },
      "Peer": {
        "node-id": {
          "ID": "node-id",
          "HostName": "exitnode-a",
          "CurAddr": "198.18.45.40:41641"
        }
      }
    }
    """.utf8)

    let summary = try #require(TailscaleJSONParser.parse(data))
    #expect(summary.exitNode == "exitnode-a")
    #expect(summary.exitNodeEndpoint == "198.18.45.40")
}

@Test
func tailscaleParserIgnoresUnroutableExitNodeEndpoints() throws {
    func statusJSON(curAddr: String) -> Data {
        Data("""
        {
          "Self": { "TailscaleIPs": ["100.64.0.100"] },
          "ExitNodeStatus": { "ID": "node-id" },
          "Peer": {
            "node-id": { "ID": "node-id", "HostName": "exitnode-a", "CurAddr": "\(curAddr)" }
          }
        }
        """.utf8)
    }

    // DERP relay: no live UDP endpoint.
    #expect(TailscaleJSONParser.parse(statusJSON(curAddr: ""))?.exitNodeEndpoint == nil)
    // IPv6 endpoints stay out of scope (this app manages IPv4 routes only).
    #expect(TailscaleJSONParser.parse(statusJSON(curAddr: "[240e:33d:955:1e8e::1]:41641"))?.exitNodeEndpoint == nil)
    // On-link private addresses need no pinned host route.
    #expect(TailscaleJSONParser.parse(statusJSON(curAddr: "192.168.1.44:41641"))?.exitNodeEndpoint == nil)
    #expect(TailscaleJSONParser.parse(statusJSON(curAddr: "100.100.1.1:41641"))?.exitNodeEndpoint == nil)
}

@Test
func targetListBuilderExcludesExitNodeEndpointRanges() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-endpoint-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("china.txt")
    let source = "198.18.32.0/19\n"
    try Data(source.utf8).write(to: sourceURL)

    let result = try TargetListBuilder(
        paths: TailscaleRoutePaths(root: root.appendingPathComponent("state")),
        loader: StubTextLoader(data: Data(source.utf8))
    ).build(
        configuration: TailscaleRouteConfiguration(
            chinaListURL: sourceURL,
            manualIPs: ["198.18.45.40"]
        ),
        refreshSource: true,
        protectedEndpointCIDRs: [IPv4CIDR(network: IPv4CIDR.parseAddress("198.18.45.40")!, prefixLength: 32)]
    )

    // The endpoint /32 is carved out of both the China range and manual IPs,
    // while the rest of the overlapping /19 survives as split pieces.
    #expect(!result.list.cidrs.contains("198.18.45.40/32"))
    #expect(result.list.cidrs.contains("198.18.48.0/20"))
    #expect(result.list.cidrs.count > 2)
}

@Test
func routeCoordinatorFiltersExitNodeEndpointFromTargets() {
    let backend = InMemoryRouteBackend(routes: [
        RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun4", rawLine: "")
    ])
    let coordinator = RouteCoordinator(backend: backend)
    let snapshot = NetworkSnapshot(
        physicalInterface: "en0",
        physicalPortName: "Wi-Fi",
        gateway: "192.168.1.1",
        defaultRouteSignature: "physical->192.168.1.1 via en0",
        tailscaleInterface: "utun4",
        tailscaleAddress: "100.64.0.1",
        tailscaleExitNode: "tokyo",
        tailscaleExitNodeEndpoint: "198.18.45.40"
    )

    let result = coordinator.apply(
        targets: ["1.0.0.0/8", "198.18.45.40/32"],
        snapshot: snapshot
    )

    #expect(result.success)
    #expect(backend.currentRoutes().contains { $0.destination == "1.0.0.0/8" })
    #expect(backend.currentRoutes().contains { $0.destination == "198.18.45.40" } == false)
}

@Test
func exitNodeEndpointProtectorAddsMissingRouteAndVerifiesLookup() {
    let runner = EndpointRouteStubRunner(initialLines: [
        "default            link#17            UCSIg       utun2",
        "default            192.168.1.1        UGScg       en0"
    ], winnerInterface: "utun2")

    let result = ExitNodeEndpointProtector(runner: runner).reconcile(
        endpointAddress: "198.18.45.40",
        gateway: "192.168.1.1",
        interfaceName: "en0",
        previouslyManaged: []
    )

    #expect(result.warnings.isEmpty)
    #expect(result.addedCount == 1)
    #expect(result.removedCount == 0)
    #expect(result.managedRoutes == [RouteSpec(cidr: "198.18.45.40/32", gateway: "192.168.1.1", interfaceName: "en0")])
    #expect(runner.addCommands.count == 1)
    #expect(runner.routeLines.contains { $0.contains("198.18.45.40") && $0.contains("en0") })
}

@Test
func exitNodeEndpointProtectorReplacesStaleGatewayRoute() {
    let runner = EndpointRouteStubRunner(initialLines: [
        "default            192.168.1.1        UGScg       en0"
    ], winnerInterface: "utun2")
    // The old hotspot route is already absent; only its record is stale.
    let result = ExitNodeEndpointProtector(runner: runner).reconcile(
        endpointAddress: "198.18.45.40",
        gateway: "192.168.1.1",
        interfaceName: "en0",
        previouslyManaged: [
            RouteSpec(cidr: "198.18.45.40/32", gateway: "172.20.10.1", interfaceName: "en0")
        ]
    )

    #expect(result.warnings.isEmpty)
    #expect(result.addedCount == 1)
    #expect(result.removedCount == 0)
    #expect(result.managedRoutes.map(\.gateway) == ["192.168.1.1"])
}

@Test
func exitNodeEndpointProtectorDropsOwnershipWhenStaleRouteIsAlreadyAbsent() {
    let runner = EndpointRouteStubRunner(initialLines: [
        "default            192.168.1.1        UGScg       en0"
    ], winnerInterface: "utun2")

    let result = ExitNodeEndpointProtector(runner: runner).reconcile(
        endpointAddress: nil,
        gateway: "192.168.1.1",
        interfaceName: "en0",
        previouslyManaged: [
            RouteSpec(cidr: "198.18.45.40/32", gateway: "192.168.1.1", interfaceName: "en0")
        ]
    )

    #expect(result.warnings.isEmpty)
    #expect(result.removedCount == 0)
    #expect(result.managedRoutes.isEmpty)
    #expect(runner.deleteCommands.isEmpty)
}

@Test
func exitNodeEndpointProtectorRemovesRoutesWhenEndpointDisappears() {
    let runner = EndpointRouteStubRunner(initialLines: [
        "198.18.45.40        192.168.1.1        UGHS        en0",
        "default            192.168.1.1        UGScg       en0"
    ], winnerInterface: "utun2")

    let result = ExitNodeEndpointProtector(runner: runner).reconcile(
        endpointAddress: nil,
        gateway: "192.168.1.1",
        interfaceName: "en0",
        previouslyManaged: [
            RouteSpec(cidr: "198.18.45.40/32", gateway: "192.168.1.1", interfaceName: "en0")
        ]
    )

    #expect(result.warnings.isEmpty)
    #expect(result.addedCount == 0)
    #expect(result.removedCount == 1)
    #expect(result.managedRoutes.isEmpty)
    #expect(runner.deleteCommands.count == 1)
    #expect(runner.routeLines.contains { $0.contains("198.18.45.40") } == false)
}

@Test
func exitNodeEndpointProtectorSkipsInvalidInputs() {
    let runner = EndpointRouteStubRunner(initialLines: [], winnerInterface: "utun2")
    let protector = ExitNodeEndpointProtector(runner: runner)

    let privateEndpoint = protector.reconcile(
        endpointAddress: "192.168.1.44",
        gateway: "192.168.1.1",
        interfaceName: "en0",
        previouslyManaged: []
    )
    let virtualInterface = protector.reconcile(
        endpointAddress: "198.18.45.40",
        gateway: "192.168.1.1",
        interfaceName: "utun4",
        previouslyManaged: []
    )
    let missingGateway = protector.reconcile(
        endpointAddress: "198.18.45.40",
        gateway: nil,
        interfaceName: "en0",
        previouslyManaged: []
    )

    #expect(privateEndpoint.managedRoutes.isEmpty && privateEndpoint.addedCount == 0)
    #expect(virtualInterface.managedRoutes.isEmpty && virtualInterface.addedCount == 0)
    #expect(missingGateway.managedRoutes.isEmpty && missingGateway.addedCount == 0)
    #expect(runner.addCommands.isEmpty)
}

private final class EndpointRouteStubRunner: CommandRunning, @unchecked Sendable {
    let gateway = "192.168.1.1"
    var routeLines: [String]
    var winnerInterface: String
    private(set) var addCommands: [[String]] = []
    private(set) var deleteCommands: [[String]] = []

    init(initialLines: [String], winnerInterface: String) {
        self.routeLines = initialLines
        self.winnerInterface = winnerInterface
    }

    func run(_ executable: String, arguments: [String]) -> CommandResult {
        switch executable {
        case "/usr/sbin/netstat":
            let table = """
            Routing tables

            Internet:
            Destination        Gateway            Flags        Netif Expire
            \(routeLines.joined(separator: "\n"))
            """
            return result(executable, arguments, stdout: table)
        case "/sbin/route":
            if arguments.count >= 3, arguments[0] == "-n", arguments[1] == "get" {
                return result(executable, arguments, stdout: "   interface: \(winnerInterface)\n")
            }
            if let actionIndex = arguments.firstIndex(where: { $0 == "add" || $0 == "delete" }) {
                let action = arguments[actionIndex]
                let address = arguments[actionIndex + 2]
                if action == "add" {
                    addCommands.append(arguments)
                    routeLines.append("\(address)            \(gateway)        UGHS        en0")
                    winnerInterface = "en0"
                } else {
                    deleteCommands.append(arguments)
                    routeLines.removeAll { $0.contains(address) }
                    winnerInterface = "utun2"
                }
                return result(executable, arguments)
            }
            return result(executable, arguments, stderr: "unexpected route command", exitCode: 127)
        default:
            return result(executable, arguments, stderr: "unexpected command", exitCode: 127)
        }
    }
}

private func key(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).joined(separator: " ")
}

private func result(
    _ executable: String,
    _ arguments: [String],
    stdout: String = "",
    stderr: String = "",
    exitCode: Int32 = 0
) -> CommandResult {
    CommandResult(
        executable: executable,
        arguments: arguments,
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode
    )
}

private final class StubCommandRunner: CommandRunning, @unchecked Sendable {
    let responses: [String: CommandResult]

    init(responses: [String: CommandResult]) {
        self.responses = responses
    }

    func run(_ executable: String, arguments: [String]) -> CommandResult {
        responses[key(executable, arguments)] ?? result(
            executable,
            arguments,
            stderr: "unexpected command",
            exitCode: 127
        )
    }
}

private struct FailingTextLoader: TextResourceLoading {
    func load(_ url: URL) -> Result<Data, Error> {
        .failure(NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated source failure"]))
    }
}

private final class IPv6RollbackTestRunner: CommandRunning, @unchecked Sendable {
    private(set) var deleteCount = 0

    func run(_ executable: String, arguments: [String]) -> CommandResult {
        if executable == "/sbin/route",
           arguments == ["-n", "get", "-inet6", "2001:db8::1"]
        {
            return result(
                executable,
                arguments,
                stdout: "destination: 2001:db8::1\ngateway: fe80::1%en0\ninterface: en9\n"
            )
        }
        if executable == "/sbin/route",
           arguments == ["-n", "add", "-inet6", "-host", "2001:db8::1", "fe80::1%en0"]
        {
            return result(executable, arguments)
        }
        if executable == "/sbin/route",
           arguments == ["-n", "delete", "-inet6", "-host", "2001:db8::1", "fe80::1%en0"]
        {
            deleteCount += 1
            return result(executable, arguments)
        }
        return result(executable, arguments, stderr: "unexpected command", exitCode: 127)
    }
}

private final class StubRouteSocketClient: RouteSocketClient, @unchecked Sendable {
    struct Request: Equatable {
        let descriptor: Int32
        let network: UInt32
        let prefixLength: UInt8
        let gateway: UInt32
        let action: RouteSocketAction
    }

    let openResult: RouteSocketOpenResult
    let responses: [Int32]
    private(set) var openCount = 0
    private(set) var requests: [Request] = []
    private(set) var closeDescriptors: [Int32] = []

    init(
        openResult: RouteSocketOpenResult = RouteSocketOpenResult(descriptor: 17, errorCode: 0),
        responses: [Int32] = []
    ) {
        self.openResult = openResult
        self.responses = responses
    }

    func open() -> RouteSocketOpenResult {
        openCount += 1
        return openResult
    }

    func applyIPv4(
        descriptor: Int32,
        network: UInt32,
        prefixLength: UInt8,
        gateway: UInt32,
        action: RouteSocketAction
    ) -> Int32 {
        requests.append(Request(
            descriptor: descriptor,
            network: network,
            prefixLength: prefixLength,
            gateway: gateway,
            action: action
        ))
        let responseIndex = requests.count - 1
        return responseIndex < responses.count ? responses[responseIndex] : 0
    }

    func close(descriptor: Int32) {
        closeDescriptors.append(descriptor)
    }
}

private final class HelperServiceTestRunner: CommandRunning, @unchecked Sendable {
    private(set) var routeMutationCommands: [[String]] = []

    private let tailscaleStatus = """
    {
      "Self": { "HostName": "test-client", "TailscaleIPs": ["100.64.0.10"] },
      "ExitNodeStatus": { "ID": "exit-id", "Online": true },
      "Peer": { "exit-id": { "ID": "exit-id", "HostName": "test-exit", "DNSName": "test-exit.tail.example.ts.net." } }
    }
    """

    func run(_ executable: String, arguments: [String]) -> CommandResult {
        if executable == "/sbin/route" {
            if arguments == ["-n", "get", "default"] {
                return result(executable, arguments, stdout: "destination: default\ngateway: 192.0.2.1\ninterface: utun4\nflags: <UP,GATEWAY,DONE>\n")
            }
            if arguments.count == 3, arguments[0...1].elementsEqual(["-n", "get"]) {
                return result(executable, arguments, stdout: "destination: \(arguments[2])\ngateway: 192.0.2.1\ninterface: utun4\nflags: <UP,GATEWAY,DONE>\n")
            }
            if arguments.contains(where: { ["add", "delete", "change"].contains($0) }) {
                routeMutationCommands.append(arguments)
                return result(executable, arguments, stderr: "test runner blocks route mutations", exitCode: 1)
            }
        }

        if executable == "/usr/sbin/networksetup" {
            if arguments == ["-listallhardwareports"] {
                return result(executable, arguments, stdout: "Hardware Port: Wi-Fi\nDevice: en0\n")
            }
            if arguments == ["-getinfo", "Wi-Fi"] {
                return result(executable, arguments, stdout: "Router: 192.168.1.1\n")
            }
        }

        if executable == "/sbin/ifconfig", arguments == ["-a"] {
            return result(executable, arguments, stdout: """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                inet 192.168.1.32 netmask 0xffffff00 broadcast 192.168.1.255
                status: active
            """)
        }

        if executable == "/usr/sbin/ioreg" {
            return result(executable, arguments, stdout: "| | \"IOBuiltin\" = Yes\n| | IO80211Interface\n")
        }

        if executable == "/usr/sbin/ipconfig" {
            return result(executable, arguments, stderr: "DHCP packet not needed", exitCode: 1)
        }

        if executable == "/usr/sbin/netstat" {
            if arguments.last == "inet" {
                return result(executable, arguments, stdout: """
                Routing tables

                Internet:
                Destination        Gateway            Flags        Netif Expire
                default            link#7             UGScg        utun4
                """)
            }
            if arguments.last == "inet6" {
                return result(executable, arguments, stdout: "Routing tables\nInternet6:\nDestination Gateway Flags Netif\n")
            }
        }

        if executable == "/usr/bin/stat" {
            let output = arguments.contains("%Su") ? "test-user\n" : "501\n"
            return result(executable, arguments, stdout: output)
        }

        if executable == "/sbin/ifconfig", arguments.count == 1 {
            return result(executable, arguments, stdout: "\(arguments[0]): flags=8863<UP,BROADCAST,RUNNING>\nstatus: active\n")
        }

        if executable == "/usr/bin/su" {
            let command = arguments.last ?? ""
            if command.contains("status") {
                return result(executable, arguments, stdout: tailscaleStatus)
            }
            if command.contains("debug") && command.contains("prefs") {
                return result(executable, arguments, stdout: "{\"ExitNodeAllowLANAccess\":true,\"RouteAll\":true}")
            }
        }

        if executable == "/usr/bin/env" {
            let command = Array(arguments.dropFirst(2))
            if command == ["status", "--json"] {
                return result(executable, arguments, stdout: tailscaleStatus)
            }
            if command == ["debug", "prefs"] {
                return result(executable, arguments, stdout: "{\"ExitNodeAllowLANAccess\":true,\"RouteAll\":true}")
            }
        }

        return result(executable, arguments, stderr: "unexpected command", exitCode: 127)
    }
}

private final class ExternalNetworkProtectionTestRunner: CommandRunning, @unchecked Sendable {
    var externalAdapterActive = true
    var externalNetworkPinned = false
    var conflictingExternalNetworkRoute = true
    var staleExternalRoutePresent = false
    var failExternalNetworkRouteDeletion = false
    var failExternalNetworkRouteAdd = false
    private(set) var routeAll: Bool
    private(set) var allowLANAccess: Bool

    init(routeAll: Bool = true, allowLANAccess: Bool = false) {
        self.routeAll = routeAll
        self.allowLANAccess = allowLANAccess
    }

    private let tailscaleStatus = """
    {
      "Self": { "HostName": "test-client", "TailscaleIPs": ["100.64.0.10"] },
      "ExitNodeStatus": { "ID": "exit-id", "Online": true },
      "Peer": { "exit-id": { "ID": "exit-id", "HostName": "test-exit" } }
    }
    """

    func run(_ executable: String, arguments: [String]) -> CommandResult {
        if executable == "/sbin/route" {
            if arguments == ["-n", "get", "default"] {
                return result(executable, arguments, stdout: "destination: default\ngateway: -\ninterface: utun4\nflags: <UP,DONE>\n")
            }
            if arguments.count == 3, arguments[0...1].elementsEqual(["-n", "get"]) {
                let target = arguments[2]
                let interface: String
                if target == "100.64.0.10" {
                    interface = "utun4"
                } else if isInExternalSubnet(target), externalNetworkPinned {
                    interface = "en7"
                } else if isInExternalSubnet(target), externalAdapterActive {
                    interface = "utun4"
                } else {
                    interface = "en0"
                }
                return result(executable, arguments, stdout: "destination: \(target)\ngateway: 192.168.1.1\ninterface: \(interface)\nflags: <UP,GATEWAY,DONE>\n")
            }
            if arguments.count == 6,
               arguments[0] == "-n",
               (arguments[1] == "add" || arguments[1] == "change"),
               arguments[2] == "-net",
               arguments[3] == "192.168.32.0/20",
               arguments[4] == "-interface",
               arguments[5] == "192.168.32.99"
            {
                if failExternalNetworkRouteAdd {
                    return result(executable, arguments, stderr: "simulated external route add failure", exitCode: 1)
                }
                externalNetworkPinned = true
                return result(executable, arguments)
            }
            if arguments.count == 6,
               arguments[0] == "-n",
               arguments[1] == "delete",
               arguments[2] == "-net",
               arguments[3] == "192.168.32.0/20",
               arguments[4] == "-interface",
               arguments[5] == "192.168.32.99"
            {
                if failExternalNetworkRouteDeletion {
                    return result(executable, arguments, stderr: "simulated external route delete failure", exitCode: 1)
                }
                externalNetworkPinned = false
                staleExternalRoutePresent = false
                return result(executable, arguments)
            }
            if arguments == ["-n", "delete", "-net", "192.168.32.0/20", "192.168.1.1"] {
                conflictingExternalNetworkRoute = false
                return result(executable, arguments)
            }
            if arguments == ["-n", "add", "-net", "192.168.32.0/20", "192.168.1.1"] {
                conflictingExternalNetworkRoute = true
                return result(executable, arguments)
            }
            if arguments.count == 7,
               arguments[0] == "-n",
               arguments[1] == "add",
               arguments[2] == "-net",
               arguments[3] == "192.168.32.0/20",
               arguments[4] == "192.168.1.1",
               arguments[5] == "-ifscope",
               arguments[6] == "en0"
            {
                conflictingExternalNetworkRoute = true
                return result(executable, arguments)
            }
            if arguments.count == 5,
               arguments[0] == "-n",
               arguments[1] == "delete",
               arguments[2] == "-host",
               arguments[3] == "192.168.32.1",
               arguments[4] == "link#20"
            {
                return result(executable, arguments)
            }
            return result(executable, arguments, stderr: "unexpected route command", exitCode: 127)
        }

        if executable == "/usr/sbin/networksetup" {
            if arguments == ["-listallhardwareports"] {
                let ports = externalAdapterActive
                    ? "Hardware Port: Wi-Fi\nDevice: en0\n\nHardware Port: USB 10/100/1000 LAN\nDevice: en7\n"
                    : "Hardware Port: Wi-Fi\nDevice: en0\n"
                return result(executable, arguments, stdout: ports)
            }
            if arguments == ["-getinfo", "Wi-Fi"] {
                return result(executable, arguments, stdout: "Router: 192.168.1.1\n")
            }
            if arguments == ["-getinfo", "USB 10/100/1000 LAN"] {
                return result(executable, arguments, stdout: "Router: 192.168.32.1\n")
            }
        }

        if executable == "/sbin/ifconfig", arguments == ["-a"] {
            var output = """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                inet 192.168.1.32 netmask 0xffffff00 broadcast 192.168.1.255
                status: active

            """
            if externalAdapterActive {
                output += """
                en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                    inet 192.168.32.99 netmask 0xfffff000 broadcast 192.168.47.255
                    status: active
                """
            }
            return result(executable, arguments, stdout: output)
        }

        if executable == "/usr/sbin/ioreg" {
            let output = arguments.contains("en7")
                ? """
                +-o en7 <class IOSkywalkLegacyEthernetInterface>
                  | "IOBuiltin" = No
                  | "IOInterfaceType" = 6
                """
                : """
                | | "IOBuiltin" = Yes
                | | IO80211Interface
                """
            return result(executable, arguments, stdout: output)
        }

        if executable == "/usr/sbin/netstat" {
            if arguments.last == "inet" {
                var routes = """
                Routing tables

                Internet:
                Destination        Gateway            Flags        Netif
                default            link#30            UGScg        utun4
                default            192.168.1.1        UGScg        en0
                192.168.1/24       link#7             UCS          en0
                """
                routes += "\n"
                if externalAdapterActive {
                    if conflictingExternalNetworkRoute {
                        routes += "192.168.32/20      192.168.1.1       UGSc         en0\n"
                    }
                    // The native connected route is interface-scoped (UCSI);
                    // an App-owned static route is UCSc and is emitted below
                    // only while the protection pin is active.
                    routes += "192.168.32/20      link#13            UCSI         en7\n"
                    if !allowLANAccess {
                        routes += "192.168.32/21      link#7             UCSc         en0\n"
                    }
                    if externalNetworkPinned {
                        routes += "192.168.32/20      link#13            UCSc         en7\n"
                    } else {
                        routes += "192.168.32.1       link#20            UHW3Ig       utun4\n"
                    }
                } else if staleExternalRoutePresent {
                    routes += "192.168.32/20      link#13            UCSc         en7\n"
                }
                return result(executable, arguments, stdout: routes)
            }
            if arguments.last == "inet6" {
                return result(executable, arguments, stdout: "Routing tables\nInternet6:\nDestination Gateway Flags Netif\n")
            }
        }

        if executable == "/usr/bin/env" {
            let command = Array(arguments.dropFirst(2))
            if command == ["status", "--json"] {
                return result(executable, arguments, stdout: tailscaleStatus)
            }
            if command == ["debug", "prefs"] {
                let prefs = """
                {"ExitNodeAllowLANAccess":\(allowLANAccess),"RouteAll":\(routeAll),"ExitNodeID":"exit-id","ControlURL":"https://controlplane.tailscale.com"}
                """
                return result(executable, arguments, stdout: prefs)
            }
            if command.first == "set" {
                if command.contains("--accept-routes=false") { routeAll = false }
                if command.contains("--accept-routes=true") { routeAll = true }
                if command.contains("--exit-node-allow-lan-access=false") { allowLANAccess = false }
                if command.contains("--exit-node-allow-lan-access=true") { allowLANAccess = true }
                return result(executable, arguments)
            }
        }

        if executable == "/usr/sbin/ipconfig" {
            return result(executable, arguments, stderr: "DHCP packet not needed", exitCode: 1)
        }
        return result(executable, arguments, stderr: "unexpected command", exitCode: 127)
    }

    private func isInExternalSubnet(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4
            && octets[0] == 192
            && octets[1] == 168
            && (32...47).contains(octets[2])
    }
}

private struct StubTextLoader: TextResourceLoading {
    let data: Data

    func load(_ url: URL) -> Result<Data, Error> {
        .success(data)
    }
}

private final class CountingTextLoader: TextResourceLoading, @unchecked Sendable {
    let data: Data
    private(set) var calls = 0

    init(data: Data) {
        self.data = data
    }

    func load(_ url: URL) -> Result<Data, Error> {
        calls += 1
        return .success(data)
    }
}

@Test func tailscalePrefsParserReadsLoginNodeID() {
    let json = #"{"ControlURL":"https://controlplane.tailscale.com","RouteAll":true,"ExitNodeID":"exit-a","ExitNodeAllowLANAccess":false,"Config":{"NodeID":"node-123"}}"#
    let prefs = TailscalePrefsParser.parseSnapshot(Data(json.utf8))
    #expect(prefs?.nodeID == "node-123")
    let withoutConfig = TailscalePrefsParser.parseSnapshot(Data(#"{"RouteAll":true}"#.utf8))
    #expect(withoutConfig?.nodeID == nil)
}

@Test func preferenceLeaseIdentityUsesNodeIDAcrossExitNodeChanges() {
    let control = "https://controlplane.tailscale.com"
    let lease = TailscalePreferenceLease(
        originalAcceptRoutes: true,
        originalAllowLANAccess: false,
        managedLANAccess: true,
        exitNodeID: "exit-a",
        tailnetControlURL: control,
        nodeID: "node-123"
    )
    // Same login, Exit Node switched or turned off: restore must still be allowed.
    #expect(HelperService.leaseIdentityMatches(lease, TailscalePrefsSnapshot(true, false, "exit-b", control, "node-123")))
    #expect(HelperService.leaseIdentityMatches(lease, TailscalePrefsSnapshot(true, false, "", control, "node-123")))
    // Different login or control server: never overwrite.
    #expect(!HelperService.leaseIdentityMatches(lease, TailscalePrefsSnapshot(true, false, "exit-a", control, "node-999")))
    #expect(!HelperService.leaseIdentityMatches(lease, TailscalePrefsSnapshot(true, false, "exit-a", "https://other.example", "node-123")))

    // Leases written by older versions have no NodeID and keep the ExitNodeID rule.
    let oldLease = TailscalePreferenceLease(
        originalAcceptRoutes: true,
        originalAllowLANAccess: false,
        exitNodeID: "exit-a",
        tailnetControlURL: control
    )
    #expect(HelperService.leaseIdentityMatches(oldLease, TailscalePrefsSnapshot(true, false, "exit-a", control, "node-123")))
    #expect(!HelperService.leaseIdentityMatches(oldLease, TailscalePrefsSnapshot(true, false, "exit-b", control, "node-123")))
}

@Test func hostsPinsSkipTailscaleOwnedDomains() {
    #expect(HostsPinManager.isTailscaleOwnedDomain("controlplane.tailscale.com"))
    #expect(HostsPinManager.isTailscaleOwnedDomain("Tailscale.com."))
    #expect(HostsPinManager.isTailscaleOwnedDomain("my-machine.tail1234.ts.net"))
    #expect(!HostsPinManager.isTailscaleOwnedDomain("nottailscale.com"))
    #expect(!HostsPinManager.isTailscaleOwnedDomain("example.test"))
    let lines = HostsPinManager.pinLines(for: [
        HostAddress(domain: "login.tailscale.com", ipv4Addresses: ["1.2.3.4"], ipv6Addresses: []),
        HostAddress(domain: "example.test", ipv4Addresses: ["203.0.113.50"], ipv6Addresses: [])
    ])
    #expect(lines == ["203.0.113.50 example.test www.example.test"])
}

// MARK: - 断网保护

@Test func killSwitchStateMachineRequiresArmingAndHysteresis() {
    var machine = KillSwitchStateMachine()
    var decision = KillSwitchStateMachine.Decision.none
    // Failures before the tunnel was ever confirmed working never block.
    for _ in 0..<5 {
        decision = machine.observe(.unhealthy("x"))
        #expect(decision == .none)
    }
    #expect(!machine.armed)

    decision = machine.observe(.healthy)
    #expect(decision == .none)
    #expect(machine.armed)
    decision = machine.observe(.unhealthy("断开"))
    #expect(decision == .none)
    decision = machine.observe(.unhealthy("断开"))
    #expect(decision == .none)
    decision = machine.observe(.unhealthy("断开"))
    #expect(decision == .activate("断开"))
    machine.blocking = true

    // One success is not enough to release; two in a row are.
    decision = machine.observe(.healthy)
    #expect(decision == .none)
    decision = machine.observe(.healthy)
    #expect(decision == .release("Tailscale 已恢复，经 Exit Node 访问外网正常"))
}

@Test func killSwitchReleasesWhenTailscaleQuitsAndDisarms() {
    var machine = KillSwitchStateMachine(armed: true, blocking: true)
    var decision = machine.observe(.tailscaleNotRunning)
    #expect(decision == .release("Tailscale 已退出"))
    #expect(!machine.armed)
    machine.blocking = false
    // Still broken afterwards: no re-block until healthy again.
    for _ in 0..<5 {
        decision = machine.observe(.unhealthy("x"))
        #expect(decision == .none)
    }

    var noExit = KillSwitchStateMachine(armed: true, blocking: true)
    decision = noExit.observe(.noExitNode)
    #expect(decision == .release("Tailscale 未选择 Exit Node"))
}

@Test func killSwitchRulesAllowOnlyTunnelAndReconnectTargets() {
    let rules = KillSwitchRules.render(KillSwitchRuleInputs(
        tunnelInterfaces: ["utun4", "bad name;"],
        allowedAddresses: ["203.0.113.7", "2001:db8::1", "not-an-ip", "203.0.113.7"]
    ))
    #expect(rules.contains("table <tsroute_allow> persist { 2001:db8::1, 203.0.113.7 }"))
    #expect(rules.contains("pass quick on { utun4 } all"))
    #expect(!rules.contains("bad name"))
    #expect(!rules.contains("not-an-ip"))
    #expect(rules.hasSuffix("block drop quick all\n"))
}

@Test func killSwitchParsesTailscaleStatusDerpAndProcesses() {
    let status = #"{"BackendState":"Running","Self":{"TailscaleIPs":["100.101.102.103"]},"ExitNodeStatus":{"ID":"n1","Online":false},"Peer":{"k":{"ExitNode":true,"Online":false,"Addrs":["203.0.113.7:41641","[2001:db8::1]:41641"],"CurAddr":"198.51.100.2:41641"}}}"#
    let parsed = KillSwitchTailscaleStatus.parse(Data(status.utf8))
    #expect(parsed?.backendState == "Running")
    #expect(parsed?.exitNodeSelected == true)
    #expect(parsed?.exitNodeOnline == false)
    #expect(Set(parsed?.peerEndpoints ?? []) == ["203.0.113.7", "2001:db8::1", "198.51.100.2"])

    let derp = #"{"Regions":{"1":{"Nodes":[{"HostName":"derp1","IPv4":"192.0.2.10","IPv6":"2001:db8::10"}]}}}"#
    #expect(Set(KillSwitchController.derpAddresses(Data(derp.utf8))) == ["192.0.2.10", "2001:db8::10"])

    #expect(KillSwitchController.tailscaleProcessRunning(psOutput: "/sbin/launchd\n/Applications/Tailscale.app/Contents/MacOS/Tailscale\n"))
    #expect(!KillSwitchController.tailscaleProcessRunning(psOutput: "/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json\n"))
    #expect(KillSwitchController.tailscaleProcessRunning(psOutput: "/opt/homebrew/bin/tailscaled --state=/x\n"))
    #expect(KillSwitchController.parseToken("No ALTQ support in kernel\npf enabled\nToken : 1234567890\n") == "1234567890")
}

// MARK: - 可配置 DNS 与一键测试目标

@Test func dnsServerSettingsAreNormalizedWithDefaults() {
    #expect(TailscaleRouteConfiguration.normalizedDNSServers(["223.5.5.5, 119.29.29.29，223.5.5.5"]) == ["223.5.5.5", "119.29.29.29"])
    #expect(TailscaleRouteConfiguration.normalizedDNSServers(["not-an-ip 1.2.3"]) == [])
    #expect(TailscaleRouteConfiguration.normalizedDNSServers(["1.1.1.1 2.2.2.2 3.3.3.3 4.4.4.4 5.5.5.5"]).count == 4)

    var configuration = TailscaleRouteConfiguration()
    #expect(configuration.effectiveDNSServers == DirectDNSDomainResolver.defaultServers)
    configuration.dnsServers = ["bogus"]
    #expect(configuration.effectiveDNSServers == DirectDNSDomainResolver.defaultServers)
    configuration.dnsServers = ["223.5.5.5"]
    #expect(configuration.effectiveDNSServers == ["223.5.5.5"])
}

@Test func olderConfigurationDecodesNewSettingsWithDefaults() throws {
    let legacy = #"{"domainNames":["example.test"],"autoFollowNetwork":true,"enabled":true}"#
    let configuration = try JSONDecoder().decode(TailscaleRouteConfiguration.self, from: Data(legacy.utf8))
    #expect(configuration.dnsServers == DirectDNSDomainResolver.defaultServers)
    #expect(configuration.connectivityTest == ConnectivityTestSettings())

    var updated = configuration
    updated.dnsServers = ["223.5.5.5"]
    updated.connectivityTest = ConnectivityTestSettings(address: "8.8.8.8", port: 53, url: "https://example.com")
    let roundTrip = try JSONDecoder().decode(
        TailscaleRouteConfiguration.self,
        from: JSONEncoder().encode(updated)
    )
    #expect(roundTrip == updated)
}

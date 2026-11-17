import Foundation
import Testing
@testable import TailscaleRouteCore

private let wifi = (gateway: "192.168.1.1", interface: "en0")
private let usbEthernet = (gateway: "192.168.32.1", interface: "en7")

@Test
func dnsServerProtectorPinsBothResolversToPhysicalGateway() {
    let runner = DNSPinStubRunner()

    let result = DNSServerRouteProtector(runner: runner).reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: wifi.gateway,
        interfaceName: wifi.interface,
        previouslyManaged: []
    )

    #expect(result.warnings.isEmpty)
    #expect(result.addedCount == 2)
    #expect(result.managedRoutes == [
        RouteSpec(cidr: "114.114.114.114/32", gateway: wifi.gateway, interfaceName: wifi.interface),
        RouteSpec(cidr: "222.85.85.85/32", gateway: wifi.gateway, interfaceName: wifi.interface)
    ])
    #expect(runner.lookup("114.114.114.114") == wifi.interface)
    #expect(runner.lookup("222.85.85.85") == wifi.interface)
}

@Test
func dnsServerProtectorIsIdempotentWhenPinsAlreadyWin() {
    let runner = DNSPinStubRunner()
    let protector = DNSServerRouteProtector(runner: runner)
    let first = protector.reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: wifi.gateway,
        interfaceName: wifi.interface,
        previouslyManaged: []
    )

    let second = protector.reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: wifi.gateway,
        interfaceName: wifi.interface,
        previouslyManaged: first.managedRoutes
    )

    #expect(second.warnings.isEmpty)
    #expect(second.addedCount == 0)
    #expect(second.removedCount == 0)
    #expect(second.managedRoutes == first.managedRoutes)
    #expect(runner.addCount == 2)
}

@Test
func dnsServerProtectorMovesPinsWhenSwitchingToExternalAdapter() {
    let runner = DNSPinStubRunner()
    let protector = DNSServerRouteProtector(runner: runner)
    let onWiFi = protector.reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: wifi.gateway,
        interfaceName: wifi.interface,
        previouslyManaged: []
    )

    // The user plugs in a USB Ethernet adapter; the snapshot now reports it
    // as the physical interface with its own gateway.
    let onEthernet = protector.reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: usbEthernet.gateway,
        interfaceName: usbEthernet.interface,
        previouslyManaged: onWiFi.managedRoutes
    )

    #expect(onEthernet.warnings.isEmpty)
    #expect(onEthernet.removedCount == 2)
    #expect(onEthernet.addedCount == 2)
    #expect(onEthernet.managedRoutes.allSatisfy {
        $0.gateway == usbEthernet.gateway && $0.interfaceName == usbEthernet.interface
    })
    #expect(runner.routes.allSatisfy { $0.interface == usbEthernet.interface })
    #expect(runner.lookup("114.114.114.114") == usbEthernet.interface)
}

@Test
func dnsServerProtectorRemovesAllPinsOnStop() {
    let runner = DNSPinStubRunner()
    let protector = DNSServerRouteProtector(runner: runner)
    let pinned = protector.reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: wifi.gateway,
        interfaceName: wifi.interface,
        previouslyManaged: []
    )

    let stopped = protector.reconcile(
        servers: [],
        gateway: nil,
        interfaceName: nil,
        previouslyManaged: pinned.managedRoutes
    )

    #expect(stopped.warnings.isEmpty)
    #expect(stopped.removedCount == 2)
    #expect(stopped.managedRoutes.isEmpty)
    #expect(runner.routes.isEmpty)
    #expect(runner.lookup("114.114.114.114") == "utun4")
}

@Test
func dnsServerProtectorKeepsOwnershipWhenStaleDeleteFails() {
    let runner = DNSPinStubRunner()
    let protector = DNSServerRouteProtector(runner: runner)
    let pinned = protector.reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: wifi.gateway,
        interfaceName: wifi.interface,
        previouslyManaged: []
    )
    runner.failingDeletes = ["222.85.85.85"]

    let stopped = protector.reconcile(
        servers: [],
        gateway: nil,
        interfaceName: nil,
        previouslyManaged: pinned.managedRoutes
    )

    #expect(stopped.removedCount == 1)
    #expect(stopped.warnings.count == 1)
    #expect(stopped.managedRoutes == [
        RouteSpec(cidr: "222.85.85.85/32", gateway: wifi.gateway, interfaceName: wifi.interface)
    ])
}

@Test
func dnsServerProtectorSkipsVirtualInterfaceAndMissingGateway() {
    let runner = DNSPinStubRunner()
    let protector = DNSServerRouteProtector(runner: runner)

    let virtual = protector.reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: wifi.gateway,
        interfaceName: "utun4",
        previouslyManaged: []
    )
    let noGateway = protector.reconcile(
        servers: DirectDNSDomainResolver.defaultServers,
        gateway: nil,
        interfaceName: wifi.interface,
        previouslyManaged: []
    )

    #expect(virtual.managedRoutes.isEmpty)
    #expect(noGateway.managedRoutes.isEmpty)
    #expect(runner.addCount == 0)
}

@Test
func persistedStateDecodesLegacyFileWithoutDNSServerRoutes() throws {
    let legacy = #"{"schemaVersion":8,"managedRoutes":[]}"#
    let state = try JSONDecoder().decode(PersistedRouteState.self, from: Data(legacy.utf8))
    #expect(state.managedDNSServerRoutes.isEmpty)

    var updated = state
    updated.managedDNSServerRoutes = [
        RouteSpec(cidr: "114.114.114.114/32", gateway: wifi.gateway, interfaceName: wifi.interface)
    ]
    let roundTrip = try JSONDecoder().decode(
        PersistedRouteState.self,
        from: JSONEncoder().encode(updated)
    )
    #expect(roundTrip.managedDNSServerRoutes == updated.managedDNSServerRoutes)
}

@Test
func driftDetectorReportsMissingDNSServerPin() {
    let state = PersistedRouteState(
        lifecycle: .enabled,
        managedDNSServerRoutes: [
            RouteSpec(cidr: "114.114.114.114/32", gateway: wifi.gateway, interfaceName: wifi.interface)
        ]
    )

    let missing = RouteDriftDetector.missingOwnedRoutes(state: state, actualRoutes: [])

    #expect(missing.contains { $0.contains("114.114.114.114") })
}

/// Minimal macOS route-table model: host routes keyed by address, gateway
/// mapped to the interface it is reachable on, and `route get` falling back
/// to the Tailscale default route when no pin exists.
private final class DNSPinStubRunner: CommandRunning, @unchecked Sendable {
    struct HostRoute: Equatable {
        let address: String
        let gateway: String
        let interface: String
    }

    private(set) var routes: [HostRoute] = []
    private(set) var addCount = 0
    var failingDeletes: Set<String> = []
    private let gatewayInterfaces = [
        wifi.gateway: wifi.interface,
        usbEthernet.gateway: usbEthernet.interface
    ]

    func lookup(_ address: String) -> String {
        routes.last(where: { $0.address == address })?.interface ?? "utun4"
    }

    func run(_ executable: String, arguments: [String]) -> CommandResult {
        switch executable {
        case "/usr/sbin/netstat":
            let lines = routes.map { "\($0.address)    \($0.gateway)    UGHS    \($0.interface)" }
            let table = """
            Routing tables

            Internet:
            Destination        Gateway            Flags        Netif Expire
            default            link#17            UCSIg        utun4
            \(lines.joined(separator: "\n"))
            """
            return output(executable, arguments, stdout: table)
        case "/sbin/route":
            if arguments.count >= 3, arguments[0] == "-n", arguments[1] == "get" {
                return output(executable, arguments, stdout: "   interface: \(lookup(arguments[2]))\n")
            }
            if arguments.count == 5, arguments[0] == "-n", arguments[2] == "-host" {
                let address = arguments[3]
                let gateway = arguments[4]
                if arguments[1] == "add" {
                    addCount += 1
                    routes.append(HostRoute(
                        address: address,
                        gateway: gateway,
                        interface: gatewayInterfaces[gateway] ?? "en0"
                    ))
                    return output(executable, arguments)
                }
                if arguments[1] == "delete" {
                    if failingDeletes.contains(address) {
                        return output(executable, arguments, stderr: "route: not in table", exitCode: 1)
                    }
                    routes.removeAll { $0.address == address && $0.gateway == gateway }
                    return output(executable, arguments)
                }
            }
            return output(executable, arguments, stderr: "unexpected route command", exitCode: 127)
        default:
            return output(executable, arguments, stderr: "unexpected command", exitCode: 127)
        }
    }

    private func output(
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
}

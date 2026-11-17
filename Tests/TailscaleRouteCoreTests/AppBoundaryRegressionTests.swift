import Testing
@testable import TailscaleRouteCore

@Test
func externalSnapshotKeyIgnoresGatewayAndSortsStableIdentityFields() {
    let first = ExternalDirectNetwork(
        interfaceName: "en5",
        hardwarePortName: "USB Ethernet",
        address: "192.168.34.10",
        cidr: "192.168.34.0/24",
        gateway: "192.168.34.1"
    )
    let sameAdapterWithDifferentGateway = ExternalDirectNetwork(
        interfaceName: "en5",
        hardwarePortName: "USB Ethernet",
        address: "192.168.34.10",
        cidr: "192.168.34.0/24",
        gateway: "192.168.34.254"
    )

    #expect(ExternalNetworkSnapshotKey(networks: [first]) ==
            ExternalNetworkSnapshotKey(networks: [sameAdapterWithDifferentGateway]))

    let second = ExternalDirectNetwork(
        interfaceName: "en6",
        hardwarePortName: "Another USB Ethernet",
        address: "10.20.0.10",
        cidr: "10.20.0.0/24"
    )
    let key = ExternalNetworkSnapshotKey(networks: [second, first])
    #expect(key.entries.count == 2)
    #expect(key.description.contains("Another USB Ethernet|en6|10.20.0.10|10.20.0.0/24"))
    #expect(ExternalNetworkSnapshotKey(networks: []).isEmpty)
}

@Test
func automaticNetworkEventsRemainReadOnlyWhenAutoFollowIsDisabled() {
    for reason in [
        NetworkChangeReason.pathChanged,
        .systemConfigurationChanged,
        .wokeFromSleep,
        .routeTableChanged
    ] {
        #expect(NetworkReconciliationPolicy.action(
            for: reason,
            isOperating: false,
            autoFollowNetwork: false,
            lifecycle: .enabled,
            retryPaused: false
        ) == .refreshOnly)
    }
}

@Test
func externalSnapshotKeyChangesForAdapterAddressOrHardwareChanges() {
    let base = ExternalDirectNetwork(
        interfaceName: "en5",
        hardwarePortName: "USB Ethernet",
        address: "192.168.34.10",
        cidr: "192.168.34.0/24"
    )
    let changedAddress = ExternalDirectNetwork(
        interfaceName: "en5",
        hardwarePortName: "USB Ethernet",
        address: "192.168.35.10",
        cidr: "192.168.35.0/24"
    )
    let changedHardware = ExternalDirectNetwork(
        interfaceName: "en5",
        hardwarePortName: "Different USB Ethernet",
        address: "192.168.34.10",
        cidr: "192.168.34.0/24"
    )

    #expect(ExternalNetworkSnapshotKey(networks: [base]) !=
            ExternalNetworkSnapshotKey(networks: [changedAddress]))
    #expect(ExternalNetworkSnapshotKey(networks: [base]) !=
            ExternalNetworkSnapshotKey(networks: [changedHardware]))
}

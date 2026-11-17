import Testing
@testable import TailscaleRouteCore

@Test
func externalSnapshotKeySortsAndDeduplicatesOnlyItsFourIdentityFields() {
    let first = ExternalDirectNetwork(
        interfaceName: "en7",
        hardwarePortName: "USB Ethernet",
        address: "192.168.32.99",
        cidr: "192.168.32.0/20",
        gateway: "192.168.32.1"
    )
    let sameIdentityWithDifferentGateway = ExternalDirectNetwork(
        interfaceName: "en7",
        hardwarePortName: "USB Ethernet",
        address: "192.168.32.99",
        cidr: "192.168.32.0/20",
        gateway: "192.168.32.254"
    )
    let second = ExternalDirectNetwork(
        interfaceName: "en5",
        hardwarePortName: "Thunderbolt Ethernet",
        address: "10.0.0.9",
        cidr: "10.0.0.0/24",
        gateway: "10.0.0.1"
    )

    let key = ExternalNetworkSnapshotKey(networks: [first, second, sameIdentityWithDifferentGateway])

    #expect(key.entries.count == 2)
    #expect(key.entries.map(\.interfaceName) == ["en5", "en7"])
    #expect(key.entries.map(\.cidr) == ["10.0.0.0/24", "192.168.32.0/20"])
    #expect(key == ExternalNetworkSnapshotKey(networks: [sameIdentityWithDifferentGateway, first, second]))
    #expect(key != ExternalNetworkSnapshotKey(networks: [
        ExternalDirectNetwork(
            interfaceName: "en7",
            hardwarePortName: "USB Ethernet",
            address: "192.168.32.100",
            cidr: "192.168.32.0/20",
            gateway: "192.168.32.1"
        ),
        second
    ]))
}

@Test
func externalProtectionIgnoresGatewayOnlyChanges() {
    let previous = ExternalDirectNetwork(
        interfaceName: "en7",
        hardwarePortName: "USB Ethernet",
        address: "192.168.32.99",
        cidr: "192.168.32.0/20",
        gateway: "192.168.32.1"
    )
    let current = ExternalDirectNetwork(
        interfaceName: "en7",
        hardwarePortName: "USB Ethernet",
        address: "192.168.32.99",
        cidr: "192.168.32.0/20",
        gateway: "192.168.32.254"
    )
    let previousKey = ExternalNetworkSnapshotKey(networks: [previous])
    let decision = NetworkReconciliationPolicy.externalProtectionDecision(
        previousKey: previousKey,
        detection: ExternalDirectNetworkDetection(networks: [current], isAuthoritative: true)
    )

    #expect(decision == .unchanged(previousKey))
    #expect(!decision.isWriteCandidate)
}

@Test
func externalProtectionTreatsEveryIdentityFieldAsAChange() {
    let base = ExternalDirectNetwork(
        interfaceName: "en7",
        hardwarePortName: "USB Ethernet",
        address: "192.168.32.99",
        cidr: "192.168.32.0/20"
    )
    let previousKey = ExternalNetworkSnapshotKey(networks: [base])
    let changedNetworks = [
        ExternalDirectNetwork(
            interfaceName: "en7",
            hardwarePortName: "Thunderbolt Ethernet",
            address: "192.168.32.99",
            cidr: "192.168.32.0/20"
        ),
        ExternalDirectNetwork(
            interfaceName: "en8",
            hardwarePortName: "USB Ethernet",
            address: "192.168.32.99",
            cidr: "192.168.32.0/20"
        ),
        ExternalDirectNetwork(
            interfaceName: "en7",
            hardwarePortName: "USB Ethernet",
            address: "192.168.32.100",
            cidr: "192.168.32.0/20"
        ),
        ExternalDirectNetwork(
            interfaceName: "en7",
            hardwarePortName: "USB Ethernet",
            address: "192.168.32.99",
            cidr: "192.168.0.0/16"
        )
    ]

    for changed in changedNetworks {
        let decision = NetworkReconciliationPolicy.externalProtectionDecision(
            previousKey: previousKey,
            detection: ExternalDirectNetworkDetection(networks: [changed], isAuthoritative: true)
        )
        #expect(decision.isWriteCandidate)
    }
}

@Test
func externalProtectionDefersNonAuthoritativeEmptyScan() {
    let previousKey = ExternalNetworkSnapshotKey(entries: [
        .init(
            hardwarePortName: "USB Ethernet",
            interfaceName: "en7",
            address: "192.168.32.99",
            cidr: "192.168.32.0/20"
        )
    ])
    let detection = ExternalDirectNetworkDetection(
        networks: [],
        isAuthoritative: false,
        warning: "ifconfig 读取失败"
    )

    #expect(detection.scanState == .notAuthoritative)
    #expect(!detection.isConfirmedEmpty)
    #expect(NetworkReconciliationPolicy.externalProtectionDecision(
        previousKey: previousKey,
        detection: detection
    ) == .deferUntilAuthoritativeScan)
}

@Test
func externalProtectionTreatsAuthoritativeEmptyAsConfirmedUnplug() {
    let previousKey = ExternalNetworkSnapshotKey(entries: [
        .init(
            hardwarePortName: "USB Ethernet",
            interfaceName: "en7",
            address: "192.168.32.99",
            cidr: "192.168.32.0/20"
        )
    ])
    let detection = ExternalDirectNetworkDetection(networks: [], isAuthoritative: true)

    #expect(detection.scanState == .authoritativeEmpty)
    #expect(detection.isConfirmedEmpty)
    #expect(NetworkReconciliationPolicy.externalProtectionDecision(
        previousKey: previousKey,
        detection: detection
    ) == .writeCandidate(previous: previousKey, current: .empty))
}

@Test
func externalProtectionEstablishesBaselineWithoutWriting() {
    let detection = ExternalDirectNetworkDetection(networks: [], isAuthoritative: true)
    let decision = NetworkReconciliationPolicy.externalProtectionDecision(
        previousKey: nil,
        detection: detection
    )

    #expect(detection.scanState == .authoritativeEmpty)
    #expect(decision == .establishBaseline(.empty))
    #expect(!decision.isWriteCandidate)
}

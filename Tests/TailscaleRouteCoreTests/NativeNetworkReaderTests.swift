import Foundation
import Testing
@testable import TailscaleRouteCore

/// The native sysctl dump replaces `netstat -rn -f inet` on the hot path.
/// Compare both on the real machine: every static route netstat reports must
/// appear natively with the same gateway, interface and G/H/S/I flags.
@Test
func nativeIPv4RouteTableMatchesNetstat() throws {
    guard let nativeText = NativeNetworkReader.ipv4RouteTableText() else {
        Issue.record("sysctl(NET_RT_DUMP2) 读取失败")
        return
    }
    let netstatText = try runNetstat()

    func staticRouteKeys(_ text: String) -> Set<String> {
        Set(RouteOutputParser.parseRouteTable(text).compactMap { route -> String? in
            // Cloned/ARP entries churn constantly; static routes do not.
            guard route.flags.contains("S"), !route.flags.contains("W") else { return nil }
            let destination = route.destination == "default"
                ? "default"
                : (IPv4CIDR.canonical(route.destination) ?? route.destination)
            let flags = String(route.flags.filter { "GHSI".contains($0) }.sorted())
            return "\(destination)|\(route.gateway)|\(route.interfaceName)|\(flags)"
        })
    }

    let fromNetstat = staticRouteKeys(netstatText)
    let fromNative = staticRouteKeys(nativeText)
    #expect(!fromNative.isEmpty)
    let missing = fromNetstat.subtracting(fromNative)
    #expect(missing.isEmpty, "netstat 有而原生读取缺失：\(missing.sorted().prefix(10))")
}

@Test
func markedTailscaleOutputSplitsIntoExitCodes() {
    let marker = TailscaleCLICache.exitMarker
    let output = "login noise\n{\"a\":1}\n\n\(marker)0\n{\"b\":2}\n\(marker)1\n"
    let segments = TailscaleCLICache.splitMarkedOutput(output, marker: marker)
    #expect(segments?.count == 2)
    #expect(segments?[0].exitCode == 0)
    #expect(segments?[0].output.contains("{\"a\":1}") == true)
    #expect(segments?[1].exitCode == 1)
    #expect(segments?[1].output == "{\"b\":2}")
    #expect(TailscaleCLICache.splitMarkedOutput("su: Sorry\n", marker: marker) == nil)
}

private func runNetstat() throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-rn", "-f", "inet"]
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

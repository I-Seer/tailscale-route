import Foundation
import Testing
@testable import TailscaleRouteCore

@Test
func commandRunnerDoesNotLeakFileDescriptors() throws {
    let runner = ProcessCommandRunner()
    let initialCount = try openFileDescriptorCount()

    // The command only reads the default route. It may fail inside a test
    // sandbox, but both the success and launch-failure paths must close pipes.
    for _ in 0..<40 {
        _ = runner.run("/sbin/route", arguments: ["-n", "get", "default"])
    }

    let afterRouteCount = try openFileDescriptorCount()
    #expect(afterRouteCount <= initialCount + 2)

    // A failed Process.run() used to bypass explicit closure of the
    // temporary-file handles used by non-route commands.
    let missingExecutable = "/private/tmp/tailscale-route-missing-\(UUID().uuidString)"
    for _ in 0..<40 {
        let result = runner.run(missingExecutable, arguments: [])
        #expect(result.exitCode == 127)
    }

    let finalCount = try openFileDescriptorCount()
    #expect(finalCount <= initialCount + 2)
}

private func openFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

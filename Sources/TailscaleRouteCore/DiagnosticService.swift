import CryptoKit
import Foundation

public struct DiagnosticService: Sendable {
    private let inspector: NetworkInspector
    private let externalNetworkDetector: ExternalDirectNetworkDetector
    private let runner: any CommandRunning
    private let desiredTargetsURL: URL?
    private let desiredMetadataURL: URL?

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        desiredTargetsURL: URL? = nil,
        desiredMetadataURL: URL? = nil
    ) {
        self.runner = runner
        self.inspector = NetworkInspector(runner: runner)
        self.externalNetworkDetector = ExternalDirectNetworkDetector(runner: runner)
        self.desiredTargetsURL = desiredTargetsURL
        self.desiredMetadataURL = desiredMetadataURL
    }

    public func run() -> DiagnosticReport {
        let result = inspector.inspect()
        let externalDetection = externalNetworkDetector.scan()
        let loadedTargets = loadManagedTargets()
        let managedTargets = loadedTargets.targets
        var warnings = result.warnings + loadedTargets.warnings
        if let warning = externalDetection.warning {
            warnings.append("外接网段检测失败：\(warning)")
        }
        let ipv6Result = runner.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet6"])
        let actualIPv6Routes = ipv6Result.succeeded
            ? RouteOutputParser.parseRouteTable(ipv6Result.stdout)
            : nil
        if !ipv6Result.succeeded {
            warnings.append("读取当前 IPv6 路由表失败：\(ipv6Result.failureReason)")
        }
        if managedTargets.isEmpty {
            warnings.append("尚未找到受管理目标清单；请先更新中国 IP 清单")
        }
        return DiagnosticReport(
            snapshot: result.snapshot,
            managedTargets: managedTargets,
            actualRoutes: result.actualRoutes,
            actualIPv6Routes: actualIPv6Routes,
            tailscale: result.tailscale,
            externalDirectNetworks: externalDetection.networks,
            warnings: warnings,
            errors: result.errors
        )
    }

    private func loadManagedTargets() -> (targets: [String], warnings: [String]) {
        let url = desiredTargetsURL ?? Self.defaultDesiredTargetsURL
        guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ([], [])
        }
        let targets = DesiredTargetParser.parse(contents)
        let metadataURL = desiredMetadataURL
            ?? url.deletingLastPathComponent().appendingPathComponent("desired.json")
        guard let metadataData = try? Data(contentsOf: metadataURL) else {
            return ([], ["受管理目标清单元数据缺失，已拒绝使用孤立清单"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(DesiredRouteList.self, from: metadataData) else {
            return ([], ["受管理目标清单元数据无法解析，已拒绝使用不一致清单"])
        }
        let expectedHash = SHA256.hash(data: Data(contents.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard metadata.sha256 == expectedHash, metadata.cidrs == targets else {
            return ([], ["受管理目标清单与元数据不一致，已拒绝使用并等待重新生成"])
        }
        return (targets, [])
    }

    public static var defaultDesiredTargetsURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tailscale-route", isDirectory: true)
            .appendingPathComponent("desired.cidrs")
    }
}

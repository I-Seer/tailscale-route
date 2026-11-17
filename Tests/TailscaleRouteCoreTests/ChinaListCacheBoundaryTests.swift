import Foundation
import Testing
@testable import TailscaleRouteCore

private final class RecordingChinaListLoader: TextResourceLoading, @unchecked Sendable {
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

private struct FixedDomainResolver: DomainResolving {
    let ipv4: [String]?
    let ipv6: [String]?

    func resolveIPv4(_ domain: String) -> [String]? { ipv4 }
    func resolveIPv6(_ domain: String) -> [String]? { ipv6 }
}

private func chinaCacheTestPaths() -> (root: URL, paths: TailscaleRoutePaths) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailscale-route-china-cache-boundary-\(UUID().uuidString)", isDirectory: true)
    return (root, TailscaleRoutePaths(root: root))
}

@Test
func manualChinaListRefreshIsTheOnlyLoaderPath() throws {
    let (root, paths) = chinaCacheTestPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = URL(string: "https://example.test/china.txt")!
    let loader = RecordingChinaListLoader(data: Data("1.0.0.0/8\n".utf8))
    let builder = TargetListBuilder(paths: paths, loader: loader)

    let result = try builder.build(
        configuration: TailscaleRouteConfiguration(chinaListURL: sourceURL),
        refreshSource: true
    )

    #expect(loader.calls == 1)
    #expect(result.list.cidrs.contains("1.0.0.0/8"))
    #expect(FileManager.default.fileExists(atPath: paths.chinaCache.path))
}

@Test
func cacheOnlyBuildUsesFreshCacheWithoutCallingLoader() throws {
    let (root, paths) = chinaCacheTestPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = URL(string: "https://example.test/china.txt")!
    let loader = RecordingChinaListLoader(data: Data("1.0.0.0/8\n".utf8))
    let builder = TargetListBuilder(paths: paths, loader: loader)
    let configuration = TailscaleRouteConfiguration(chinaListURL: sourceURL)

    _ = try builder.build(configuration: configuration, refreshSource: true)
    let result = try builder.build(configuration: configuration)

    #expect(loader.calls == 1)
    #expect(result.list.cidrs.contains("1.0.0.0/8"))
}

@Test
func expiredCacheDoesNotDownloadAndReportsManualUpdate() throws {
    let (root, paths) = chinaCacheTestPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = URL(string: "https://example.test/china.txt")!
    let loader = RecordingChinaListLoader(data: Data("1.0.0.0/8\n".utf8))
    let builder = TargetListBuilder(paths: paths, loader: loader)
    let configuration = TailscaleRouteConfiguration(chinaListURL: sourceURL)

    _ = try builder.build(configuration: configuration, refreshSource: true)
    let store = AtomicStore(paths: paths)
    let cache = try store.read(ChinaCIDRCache.self, from: paths.chinaCache)
    let expiredMetadata = CIDRSourceMetadata(
        sourceURL: cache.metadata.sourceURL,
        fetchedAt: Date(timeIntervalSinceNow: -(48 * 60 * 60)),
        sourceSHA256: cache.metadata.sourceSHA256,
        cidrSHA256: cache.metadata.cidrSHA256,
        entryCount: cache.metadata.entryCount,
        rejectedLineCount: cache.metadata.rejectedLineCount
    )
    try store.write(
        ChinaCIDRCache(cidrs: cache.cidrs, metadata: expiredMetadata),
        to: paths.chinaCache
    )

    let result = try builder.build(configuration: configuration)

    #expect(loader.calls == 1)
    #expect(result.list.cidrs.contains("1.0.0.0/8"))
    #expect(result.warnings.contains { $0.contains("需要手动更新") })
}

@Test
func missingOrMismatchedCacheDoesNotDownloadOrOverwriteOldSummary() throws {
    let (root, paths) = chinaCacheTestPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = URL(string: "https://example.test/china-a.txt")!
    let secondURL = URL(string: "https://example.test/china-b.txt")!
    let loader = RecordingChinaListLoader(data: Data("1.0.0.0/8\n".utf8))
    let builder = TargetListBuilder(paths: paths, loader: loader)

    _ = try builder.build(
        configuration: TailscaleRouteConfiguration(chinaListURL: firstURL),
        refreshSource: true
    )
    let oldSummary = try Data(contentsOf: paths.desiredMetadata)
    let resultBeforeRemovingCache = try Data(contentsOf: paths.desiredCIDRs)
    try FileManager.default.removeItem(at: paths.chinaCache)

    var missingError = ""
    do {
        _ = try builder.build(configuration: TailscaleRouteConfiguration(chinaListURL: firstURL))
    } catch {
        missingError = error.localizedDescription
    }
    let summaryAfterMissing = try Data(contentsOf: paths.desiredMetadata)
    let cidrsAfterMissing = try Data(contentsOf: paths.desiredCIDRs)
    #expect(missingError.contains("手动更新"))
    #expect(loader.calls == 1)
    #expect(summaryAfterMissing == oldSummary)
    #expect(cidrsAfterMissing == resultBeforeRemovingCache)

    _ = try builder.build(
        configuration: TailscaleRouteConfiguration(chinaListURL: firstURL),
        refreshSource: true
    )
    let oldSummaryAfterRepair = try Data(contentsOf: paths.desiredMetadata)
    var mismatchError = ""
    do {
        _ = try builder.build(configuration: TailscaleRouteConfiguration(chinaListURL: secondURL))
    } catch {
        mismatchError = error.localizedDescription
    }
    let summaryAfterMismatch = try Data(contentsOf: paths.desiredMetadata)
    #expect(mismatchError.contains("来源不匹配"))
    #expect(loader.calls == 2)
    #expect(summaryAfterMismatch == oldSummaryAfterRepair)
}

@Test
func domainResolutionNeverCallsChinaListLoader() throws {
    let (root, paths) = chinaCacheTestPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = RecordingChinaListLoader(data: Data("1.0.0.0/8\n".utf8))
    let builder = TargetListBuilder(
        paths: paths,
        loader: loader,
        resolver: FixedDomainResolver(ipv4: ["203.0.113.10"], ipv6: ["2001:db8::10"])
    )

    let result = builder.resolveConfiguredDomains(["example.test"])

    #expect(result.ipv4 == ["203.0.113.10"])
    #expect(result.ipv6 == ["2001:db8::10"])
    #expect(loader.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: paths.chinaCache.path))
}

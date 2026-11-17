import Darwin
import Foundation
import TailscaleRouteCore

struct Arguments {
    var desiredPath: String?
    var gateway = "192.168.1.1"
    var interfaceName = "en0"
    var oldGateway: String?
    var failTarget: String?
    var liveReplace = false
    var benchmark = false
    var benchmarkTargets = 2_000
    var help = false

    init(_ values: [String]) {
        var index = 0
        while index < values.count {
            switch values[index] {
            case "--desired":
                if index + 1 < values.count { index += 1; desiredPath = values[index] }
            case "--gateway":
                if index + 1 < values.count { index += 1; gateway = values[index] }
            case "--interface":
                if index + 1 < values.count { index += 1; interfaceName = values[index] }
            case "--old-gateway":
                if index + 1 < values.count { index += 1; oldGateway = values[index] }
            case "--fail-target":
                if index + 1 < values.count { index += 1; failTarget = values[index] }
            case "--live-replace":
                liveReplace = true
            case "--benchmark":
                benchmark = true
            case "--benchmark-targets":
                if index + 1 < values.count { index += 1; benchmarkTargets = Int(values[index]) ?? benchmarkTargets }
            case "--help", "-h":
                help = true
            default:
                break
            }
            index += 1
        }
    }
}

func printHelp() {
    print("""
    tailscale-route 路由事务模拟器

    用法:
      tailscale-route-cli --desired /path/to/desired.cidrs [选项]
      tailscale-route-cli --live-replace
      tailscale-route-cli --benchmark [--benchmark-targets COUNT]

    选项:
      --gateway IP       模拟当前物理网关，默认 192.168.1.1
      --interface NAME   模拟物理接口，默认 en0
      --old-gateway IP   预置旧网关，用于验证网络切换重建
      --fail-target CIDR 模拟某一条添加失败，用于验证部分状态保留
      --live-replace    通过已安装 Helper 重建真实路由并清理旧脚本路由
      --benchmark       只读采集当前路由快照，并模拟冷启动、增量更新、网络切换和部分失败耗时
      --benchmark-targets COUNT  基准模拟目标数（1–100000，默认 2000）

    默认模式只使用内存路由后端；--live-replace 会通过已安装 Helper 修改真实系统路由。
    --benchmark 的算法测量只使用内存后端，不会修改系统路由。
    """)
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
if arguments.help {
    printHelp()
    exit(0)
}

if arguments.benchmark {
    runBenchmark(targetCount: arguments.benchmarkTargets)
    exit(0)
}

if arguments.liveReplace {
    let configuration = AtomicStore(paths: .user).loadConfiguration()
    let clients = [
        UnixHelperClient(socketPath: "/var/run/tailscale-route-helper.sock"),
        UnixHelperClient()
    ]
    var lastError: Error?
    for client in clients {
        do {
            let response = try client.send(
                HelperRequest(action: .reapply, configuration: configuration),
                onProgress: { progress in
                    print("\(progress.message) [\(progress.completed)/\(progress.total)]")
                }
            )
            print(response.message)
            if let operation = response.operation {
                print("应用 \(operation.appliedCount) 条 IPv4/主路由；清理 \(operation.removedCount) 条；失败 \(operation.failedCount) 条")
                for warning in operation.warnings { print("⚠️  \(warning)") }
            }
            exit(response.success ? 0 : 1)
        } catch {
            lastError = error
        }
    }
    fputs("无法连接 tailscale-route Helper：\(lastError?.localizedDescription ?? "未知错误")\n", stderr)
    exit(1)
}

guard let desiredPath = arguments.desiredPath,
      let contents = try? String(contentsOf: URL(fileURLWithPath: desiredPath), encoding: .utf8)
else {
    printHelp()
    exit(2)
}

let targets = DesiredTargetParser.parse(contents)
guard !targets.isEmpty else {
    fputs("目标清单为空\n", stderr)
    exit(2)
}

var oldRoutes: [RouteEntry] = []
if let oldGateway = arguments.oldGateway {
    oldRoutes = targets.map {
        RouteEntry(
            destination: $0,
            gateway: oldGateway,
            flags: "UGSc",
            interfaceName: arguments.interfaceName,
            rawLine: "\($0) \(oldGateway) UGSc \(arguments.interfaceName)"
        )
    }
}
oldRoutes.append(RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun-sim", rawLine: "0/0 - UGSc utun-sim"))
let backend = InMemoryRouteBackend(routes: oldRoutes)
backend.failOnAddTarget = arguments.failTarget
let coordinator = RouteCoordinator(backend: backend)
let snapshot = NetworkSnapshot(
    physicalInterface: arguments.interfaceName,
    physicalPortName: "模拟网络",
    gateway: arguments.gateway,
    defaultRouteSignature: "physical->\(arguments.gateway) via \(arguments.interfaceName)",
    tailscaleInterface: "utun-sim",
    tailscaleAddress: "100.64.0.1",
    tailscaleExitNode: "simulated-exit-node"
)

let result = coordinator.apply(
    targets: targets,
    snapshot: snapshot,
    progress: { progress in
        print("\(progress.message) [\(progress.completed)/\(progress.total)]")
    }
)
print()
print("成功：\(result.success)")
print("应用：\(result.appliedCount)，清理：\(result.removedCount)，失败：\(result.failedCount)")
if let error = result.lastError { print("错误：\(error)") }
print("最终内存路由：\(backend.currentRoutes().count) 条")
exit(result.success ? 0 : 1)

private func runBenchmark(targetCount requestedCount: Int) {
    let targetCount = min(max(requestedCount, 1), 100_000)
    let processRunner = CountingCommandRunner()
    let systemBackend = SystemRouteBackend(runner: processRunner)
    let realSnapshotStarted = ProcessInfo.processInfo.systemUptime
    let realSnapshot = systemBackend.routeTableSnapshot()
    let realSnapshotMS = (ProcessInfo.processInfo.systemUptime - realSnapshotStarted) * 1_000
    _ = systemBackend.lookup(address: "8.8.8.8")
    print("只读系统基线：路由数 \(realSnapshot.routes.count)，快照 \(String(format: "%.2f", realSnapshotMS)) ms，命令启动 \(processRunner.invocationCount) 次\(realSnapshot.succeeded ? "" : "，失败：\(realSnapshot.failureReason ?? "未知")")")

    let targets = (1...targetCount).map { offset in
        "\(IPv4CIDR.string(from: 0xC612_0000 &+ UInt32(offset)))/32"
    }
    let defaultRoute = RouteEntry(destination: "0/0", gateway: "-", flags: "UGSc", interfaceName: "utun9", rawLine: "0/0 - UGSc utun9")
    let backend = InMemoryRouteBackend(routes: [defaultRoute])
    let coordinator = RouteCoordinator(backend: backend)
    let oldSnapshot = benchmarkSnapshot(gateway: "192.0.2.1")

    let coldStarted = ProcessInfo.processInfo.systemUptime
    let coldResult = coordinator.apply(targets: targets, snapshot: oldSnapshot)
    let coldMS = (ProcessInfo.processInfo.systemUptime - coldStarted) * 1_000
    print("模拟冷启动：目标 \(targetCount)，路由 \(backend.currentRoutes().count)，新增 \(coldResult.appliedCount)，耗时 \(String(format: "%.2f", coldMS)) ms")

    let managed = targets.map { RouteSpec(cidr: $0, gateway: "192.0.2.1", interfaceName: "en9") }
    let incrementalStarted = ProcessInfo.processInfo.systemUptime
    let incrementalResult = coordinator.apply(targets: targets, snapshot: oldSnapshot, previouslyManagedRoutes: managed)
    let incrementalMS = (ProcessInfo.processInfo.systemUptime - incrementalStarted) * 1_000
    print("模拟增量无变更：新增 \(incrementalResult.appliedCount)，清理 \(incrementalResult.removedCount)，耗时 \(String(format: "%.2f", incrementalMS)) ms")

    let newSnapshot = benchmarkSnapshot(gateway: "192.0.2.2")
    let switchStarted = ProcessInfo.processInfo.systemUptime
    let switchResult = coordinator.apply(targets: targets, snapshot: newSnapshot, previouslyManagedRoutes: managed)
    let switchMS = (ProcessInfo.processInfo.systemUptime - switchStarted) * 1_000
    print("模拟网关切换：原子切换 \(switchResult.appliedCount) 条，清理 \(switchResult.removedCount)，耗时 \(String(format: "%.2f", switchMS)) ms")
    let estimatedSwitchCommands = 5 // four netstat snapshots and one foreign-route lookup
    print("网关切换系统调用估算：PF_ROUTE 单 socket \(switchResult.appliedCount) 次 RTM_CHANGE；快照/选路读取启动 \(estimatedSwitchCommands) 个子进程（4 次 netstat + 1 次 route get）")

    let failureBackend = InMemoryRouteBackend(routes: [defaultRoute])
    failureBackend.failOnAddTarget = targets.last
    let failureStarted = ProcessInfo.processInfo.systemUptime
    let failureResult = RouteCoordinator(backend: failureBackend).apply(targets: targets, snapshot: oldSnapshot)
    let failureMS = (ProcessInfo.processInfo.systemUptime - failureStarted) * 1_000
    print("模拟部分失败恢复点：成功保留 \(failureResult.managedRoutes?.count ?? 0) 条，待清理 \(failureResult.pendingRemovals?.count ?? 0)，检测耗时 \(String(format: "%.2f", failureMS)) ms")

    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 {
        print("进程峰值常驻内存：\(usage.ru_maxrss) bytes")
    }
    print("算法场景均使用内存路由后端；耗时不能代表真实内核批量写入性能。")
}

private func benchmarkSnapshot(gateway: String) -> NetworkSnapshot {
    NetworkSnapshot(
        physicalInterface: "en9",
        physicalPortName: "Benchmark",
        gateway: gateway,
        defaultRouteSignature: "physical->\(gateway) via en9",
        tailscaleInterface: "utun9",
        tailscaleAddress: "100.64.0.9",
        tailscaleExitNode: "benchmark-exit"
    )
}

private final class CountingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let underlying = ProcessCommandRunner()
    private var count = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func run(_ executable: String, arguments: [String]) -> CommandResult {
        lock.lock()
        count += 1
        lock.unlock()
        return underlying.run(executable, arguments: arguments)
    }
}

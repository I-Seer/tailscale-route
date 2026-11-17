import Darwin
import Foundation
import TailscaleRouteCore

struct Arguments {
    var json = false
    var desiredPath: String?
    var explainAddress: String?
    var connectivityAddress: String?
    var tcpPort: Int?
    var httpURL: URL?
    var showHelp = false

    init(_ values: [String]) {
        var index = 0
        while index < values.count {
            switch values[index] {
            case "--json":
                json = true
            case "--desired":
                if index + 1 < values.count {
                    index += 1
                    desiredPath = values[index]
                }
            case "--explain":
                if index + 1 < values.count {
                    index += 1
                    explainAddress = values[index]
                }
            case "--connectivity":
                if index + 1 < values.count {
                    index += 1
                    connectivityAddress = values[index]
                }
            case "--tcp-port":
                if index + 1 < values.count {
                    index += 1
                    tcpPort = Int(values[index])
                }
            case "--http":
                if index + 1 < values.count {
                    index += 1
                    httpURL = URL(string: values[index])
                }
            case "--help", "-h":
                showHelp = true
            default:
                break
            }
            index += 1
        }
    }
}

func printHelp() {
    print("""
    tailscale-route 只读诊断

    用法:
      tailscale-route-diagnose [--json] [--desired /path/to/desired.cidrs]
      tailscale-route-diagnose --explain IPv4_ADDRESS [--json]
      tailscale-route-diagnose --connectivity IPv4_ADDRESS [--tcp-port PORT] [--http URL] [--json]

    本命令只读取默认路由、硬件端口、Tailscale 状态和当前路由表，绝不修改系统路由。
    连通性检查读取路由/ARP，并按需发送目标及下一跳探测；仅在提供选项时建立 TCP/HTTP 连接。
    """)
}

func display(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "未识别" }
    return value
}

func printReport(_ report: DiagnosticReport) {
    let snapshot = report.snapshot
    print("=== tailscale-route · 只读诊断 ===")
    print()

    if report.errors.isEmpty {
        print("状态       可读取")
    } else {
        print("状态       需要注意（\(report.errors.count) 个错误）")
    }
    print("采集时间   \(report.generatedAt.formatted(date: .abbreviated, time: .standard))")
    print()

    print("当前网络")
    print("  接口       \(display(snapshot.physicalInterface))")
    print("  类型       \(display(snapshot.physicalPortName))")
    print("  本地网关   \(display(snapshot.gateway))")
    print("  默认路由   \(display(snapshot.defaultRouteSignature))")
    print()

    print("Tailscale")
    print("  CLI 状态   \(report.tailscale.isInstalled ? (report.tailscale.isRunning ? "运行中" : "已安装但不可用") : "未安装")")
    print("  地址       \(display(snapshot.tailscaleAddress))")
    print("  接口       \(display(snapshot.tailscaleInterface))")
    print("  Exit Node  \(display(snapshot.tailscaleExitNode))")
    print("  端点       \(display(snapshot.tailscaleExitNodeEndpoint))")
    let lanAccess: String
    if snapshot.tailscaleExitNode == nil {
        lanAccess = "不适用"
    } else if let enabled = report.tailscale.exitNodeAllowLANAccess {
        lanAccess = enabled ? "已开启" : "未开启"
    } else {
        lanAccess = "未确认"
    }
    print("  LAN access \(lanAccess)")
    print()

    print("网络指纹")
    print("  \(snapshot.fingerprint)")
    print()

    print("路由概览")
    print("  受管理目标 \(report.managedTargets.count) 条")
    print("  实际路由   \(report.actualRoutes.count) 条")
    for route in report.actualRoutes.prefix(12) {
        print("  · \(route.destination) via \(route.gateway) dev \(route.interfaceName)")
    }
    if report.actualRoutes.count > 12 {
        print("  · … 其余 \(report.actualRoutes.count - 12) 条未展开")
    }
    print()

    for warning in report.warnings {
        print("⚠️  \(warning)")
    }
    for error in report.errors {
        print("❌  \(error)")
    }
    print()
    print("只读模式：本次未执行任何路由、配置或权限修改。")
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
if arguments.showHelp {
    printHelp()
    exit(0)
}

let desiredURL = arguments.desiredPath.map { URL(fileURLWithPath: $0) }
let report = DiagnosticService(desiredTargetsURL: desiredURL).run()
let routeExplanation = arguments.explainAddress.map { address in
    let lookup = ProcessCommandRunner().run("/sbin/route", arguments: ["-n", "get", address])
    let selectedRoute = lookup.succeeded ? RouteOutputParser.parseRouteGetEntry(lookup.stdout) : nil
    return RouteExplanationService.explain(
        address: address,
        actualRoutes: report.actualRoutes,
        desiredTargets: report.managedTargets,
        state: AtomicStore(paths: .user).loadState(),
        kernelSelection: selectedRoute
    )
}
let connectivityReport = arguments.connectivityAddress.map { address in
    ConnectivityDiagnosticService().run(
        target: address,
        tcpPort: arguments.tcpPort,
        httpURL: arguments.httpURL
    )
}

if let connectivityReport {
    if arguments.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(connectivityReport), let output = String(data: data, encoding: .utf8) {
            print(output)
        } else {
            fputs("无法编码连通性诊断报告\n", stderr)
            exit(1)
        }
    } else {
        print("=== 连通性分层检查：\(connectivityReport.target) ===")
        for layer in connectivityReport.layers {
            let marker: String
            switch layer.status {
            case .passed: marker = "✓"
            case .failed: marker = "✗"
            case .unknown: marker = "?"
            case .skipped: marker = "–"
            case .serviceError: marker = "!"
            }
            print("\(marker) \(layer.layer)：\(layer.detail)")
        }
    }
    exit(connectivityReport.layers.contains { $0.status == .failed || $0.status == .serviceError } ? 1 : 0)
}

if arguments.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = routeExplanation.map { try? encoder.encode($0) } ?? (try? encoder.encode(report))
    if let data, let output = String(data: data, encoding: .utf8) {
        print(output)
    } else {
        fputs("无法编码诊断报告\n", stderr)
        exit(1)
    }
} else {
    printReport(report)
    if let routeExplanation {
        print()
        print("=== 路由解释：\(routeExplanation.address) ===")
        print(routeExplanation.summary)
        if !routeExplanation.candidates.isEmpty {
            for candidate in routeExplanation.candidates {
                let owner = candidate.isAppManaged ? "App 管理" : "外部/系统"
                let selected = candidate.isSelected ? "已选中" : "候选"
                print("  · /\(candidate.prefixLength) \(candidate.route.destination) via \(candidate.route.gateway) dev \(candidate.route.interfaceName) [\(selected)，\(owner)] — \(candidate.explanation)")
            }
        }
    }
}

exit(report.errors.isEmpty ? 0 : 1)

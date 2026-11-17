import Foundation

/// Runs explicit, read-only connectivity probes. Route and neighbor inspection
/// are separated from ICMP, TCP, and HTTP so an application error is not
/// misreported as a routing failure.
public struct ConnectivityDiagnosticService: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func run(target rawTarget: String, tcpPort: Int? = nil, httpURL: URL? = nil) -> ConnectivityDiagnosticReport {
        guard let target = IPv4CIDR.parseAddress(rawTarget).map(IPv4CIDR.string(from:)) else {
            return ConnectivityDiagnosticReport(target: rawTarget, layers: [
                ConnectivityLayerResult(layer: "输入", status: .failed, detail: "请输入有效的 IPv4 地址")
            ])
        }

        var layers: [ConnectivityLayerResult] = []
        let routeResult = runner.run("/sbin/route", arguments: ["-n", "get", target])
        let route = routeResult.succeeded ? RouteOutputParser.parseRouteGetEntry(routeResult.stdout) : nil
        if let route {
            layers.append(ConnectivityLayerResult(
                layer: "路由选择",
                status: .passed,
                detail: "\(route.destination) via \(route.gateway) dev \(route.interfaceName)"
            ))
        } else {
            layers.append(ConnectivityLayerResult(
                layer: "路由选择",
                status: .failed,
                detail: routeResult.succeeded ? "route get 未返回可解析的选路" : routeResult.failureReason
            ))
        }

        if let route, IPv4CIDR.parseAddress(route.gateway) != nil {
            var neighbor = runner.run("/usr/sbin/arp", arguments: ["-n", route.gateway])
            var neighborText = (neighbor.stdout + " " + neighbor.stderr).lowercased()
            var isIncomplete = neighborText.contains("incomplete") || neighborText.contains("no entry")
            var hasNeighbor = neighbor.succeeded
                && !isIncomplete
                && neighborText.contains(route.gateway.lowercased())
                && neighborText.contains(" at ")
            if !hasNeighbor {
                // A single gateway probe asks the kernel to resolve its L2
                // neighbor; inspect ARP again even if the gateway blocks ICMP.
                _ = runner.run("/sbin/ping", arguments: ["-n", "-c", "1", "-W", "1000", route.gateway])
                neighbor = runner.run("/usr/sbin/arp", arguments: ["-n", route.gateway])
                neighborText = (neighbor.stdout + " " + neighbor.stderr).lowercased()
                isIncomplete = neighborText.contains("incomplete") || neighborText.contains("no entry")
                hasNeighbor = neighbor.succeeded
                    && !isIncomplete
                    && neighborText.contains(route.gateway.lowercased())
                    && neighborText.contains(" at ")
            }
            layers.append(ConnectivityLayerResult(
                layer: "L2 邻居/ARP",
                status: hasNeighbor ? .passed : .failed,
                detail: hasNeighbor
                    ? "已读取到下一跳邻居项：\(route.gateway)"
                    : (neighbor.succeeded || isIncomplete ? "没有可用的下一跳邻居项：\(route.gateway)" : neighbor.failureReason)
            ))
        } else {
            layers.append(ConnectivityLayerResult(layer: "L2 邻居/ARP", status: .skipped, detail: "当前选路没有可检查的 IPv4 下一跳网关"))
        }

        let ping = runner.run("/sbin/ping", arguments: ["-n", "-c", "1", "-W", "1000", target])
        layers.append(ConnectivityLayerResult(
            layer: "ICMP",
            status: ping.succeeded ? .passed : .failed,
            detail: ping.succeeded ? "收到 ICMP 响应" : ping.failureReason
        ))

        if let tcpPort {
            if (1...65_535).contains(tcpPort) {
                let tcp = runner.run("/usr/bin/nc", arguments: ["-z", "-G", "3", target, String(tcpPort)])
                layers.append(ConnectivityLayerResult(
                    layer: "TCP \(tcpPort)",
                    status: tcp.succeeded ? .passed : .failed,
                    detail: tcp.succeeded ? "TCP 连接已建立" : tcp.failureReason
                ))
            } else {
                layers.append(ConnectivityLayerResult(layer: "TCP", status: .failed, detail: "端口必须在 1–65535 之间"))
            }
        } else {
            layers.append(ConnectivityLayerResult(layer: "TCP", status: .skipped, detail: "未指定 TCP 端口"))
        }

        if let httpURL {
            guard ["http", "https"].contains(httpURL.scheme?.lowercased() ?? "") else {
                layers.append(ConnectivityLayerResult(layer: "HTTP", status: .failed, detail: "HTTP 检查只接受 http/https URL"))
                return ConnectivityDiagnosticReport(target: target, layers: layers)
            }
            let http = runner.run("/usr/bin/curl", arguments: [
                "--max-time", "5", "--silent", "--show-error", "--output", "/dev/null",
                "--write-out", "%{http_code}", httpURL.absoluteString
            ])
            let statusCode = Int(http.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if let statusCode, (100...599).contains(statusCode) {
                if statusCode == 502 {
                    layers.append(ConnectivityLayerResult(layer: "HTTP", status: .serviceError, detail: "HTTP 502：已到达 Web 服务，后端返回错误"))
                } else if statusCode >= 400 {
                    layers.append(ConnectivityLayerResult(layer: "HTTP", status: .serviceError, detail: "已到达 Web 服务，返回 HTTP \(statusCode)"))
                } else {
                    layers.append(ConnectivityLayerResult(layer: "HTTP", status: .passed, detail: "HTTP \(statusCode)"))
                }
            } else {
                layers.append(ConnectivityLayerResult(
                    layer: "HTTP",
                    status: .failed,
                    detail: http.succeeded ? "没有收到有效 HTTP 状态码" : http.failureReason
                ))
            }
        } else {
            layers.append(ConnectivityLayerResult(layer: "HTTP", status: .skipped, detail: "未指定 HTTP URL"))
        }

        return ConnectivityDiagnosticReport(target: target, layers: layers)
    }
}

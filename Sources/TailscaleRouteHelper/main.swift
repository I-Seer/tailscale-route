import Foundation
import TailscaleRouteCore

let arguments = CommandLine.arguments
let socketPath: String
if let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count {
    socketPath = arguments[index + 1]
} else {
    socketPath = "/var/run/tailscale-route-helper.sock"
}

let serviceRoot: TailscaleRoutePaths
if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count {
    serviceRoot = TailscaleRoutePaths(root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
} else {
    serviceRoot = .system
}

/// Route batches report progress once per route. Forward at most ~12 updates
/// per second (plus every percent step and the first/last update) so a
/// several-thousand-route apply does not produce thousands of JSON lines and
/// UI refreshes.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmit = Date.distantPast
    private var lastCompleted = Int.min
    private var lastMessagePrefix = ""

    func shouldEmit(_ progress: RouteProgress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        // Stage messages ("检查网络…", "开始增量更新路由") differ before any digit.
        let prefix = String(progress.message.prefix(while: { !$0.isNumber }))
        let emit = progress.completed <= 0
            || progress.completed >= progress.total
            || prefix != lastMessagePrefix
            || (progress.total <= 100 && progress.completed != lastCompleted)
            || now.timeIntervalSince(lastEmit) >= 0.08
        if emit {
            lastEmit = now
            lastCompleted = progress.completed
            lastMessagePrefix = prefix
        }
        return emit
    }
}

let service = HelperService(paths: serviceRoot)
// 断网保护 runs its own periodic check on a background queue, independent
// of the App, so a blocked network stays blocked even if the App quits or
// crashes (App quit sends shutdown, which releases it).
service.killSwitch.start()
do {
    try UnixSocketTransport.serve(path: socketPath) { requestLine, emit in
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let request = try? decoder.decode(HelperRequest.self, from: Data(requestLine.utf8)) else {
            let response = HelperResponse(
                requestID: UUID(),
                success: false,
                message: "无效的 Helper 请求"
            )
            return String(decoding: (try? encoder.encode(response)) ?? Data(), as: UTF8.self)
        }
        let throttle = ProgressThrottle()
        let response = service.handle(request) { progress in
            guard throttle.shouldEmit(progress) else { return }
            let progressResponse = HelperResponse(
                requestID: request.requestID,
                success: true,
                message: progress.message,
                isFinal: false,
                progress: progress
            )
            if let data = try? encoder.encode(progressResponse) {
                emit(String(decoding: data, as: UTF8.self))
            }
        }
        return String(decoding: (try? encoder.encode(response)) ?? Data(), as: UTF8.self)
    }
} catch {
    fputs("tailscale-route-helper 启动失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}

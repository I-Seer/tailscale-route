import Darwin
import Foundation

public enum UnixSocketError: LocalizedError {
    case pathTooLong
    case createFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "Unix socket 路径过长"
        case .createFailed(let reason): return "创建 Unix socket 失败：\(reason)"
        case .bindFailed(let reason): return "绑定 Unix socket 失败：\(reason)"
        case .listenFailed(let reason): return "监听 Unix socket 失败：\(reason)"
        case .connectFailed(let reason): return "连接 Helper 失败：\(reason)"
        case .readFailed(let reason): return "读取 Helper 响应失败：\(reason)"
        case .writeFailed(let reason): return "写入 Helper 请求失败：\(reason)"
        case .invalidMessage: return "Helper 返回了无效消息"
        }
    }
}

public enum UnixSocketTransport {
    public static func sendLine(_ line: String, to path: String) throws -> String {
        let lines = try sendLines(line, to: path)
        guard let last = lines.last else { throw UnixSocketError.invalidMessage }
        return last
    }

    public static func sendLines(
        _ line: String,
        to path: String,
        onLine: ((String) -> Bool)? = nil
    ) throws -> [String] {
        let descriptor = try connect(path: path)
        defer { Darwin.close(descriptor) }
        try writeAll(Data((line + "\n").utf8), to: descriptor)
        return try readLines(from: descriptor, onLine: onLine)
    }

    public static func serve(
        path: String,
        handler: @escaping (_ request: String, _ emit: @Sendable @escaping (String) -> Void) -> String
    ) throws {
        let descriptor = try listen(path: path)
        defer {
            Darwin.close(descriptor)
            unlink(path)
        }

        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                throw UnixSocketError.readFailed(String(cString: strerror(errno)))
            }
            defer { Darwin.close(client) }
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) {
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
            }
            do {
                let request = try readLine(from: client)
                let emit: @Sendable (String) -> Void = { line in
                    try? writeAll(Data((line + "\n").utf8), to: client)
                }
                let response = handler(request, emit)
                try writeAll(Data((response + "\n").utf8), to: client)
            } catch {
                let response = "{\"success\":false,\"message\":\"\(escapeJSON(error.localizedDescription))\"}"
                try? writeAll(Data((response + "\n").utf8), to: client)
            }
        }
    }

    private static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.createFailed(String(cString: strerror(errno)))
        }
        // A cold start can legitimately apply several thousand managed
        // routes.  Twenty seconds lets the App time out, reload the Helper,
        // and interrupt the still-valid route transaction before the Helper
        // can return its final response. Keep the wait bounded, but long
        // enough for a full restore on a real route table.
        var timeout = timeval(tv_sec: 180, tv_usec: 0)
        let receiveTimeoutResult = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        let sendTimeoutResult = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        guard receiveTimeoutResult == 0, sendTimeoutResult == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw UnixSocketError.connectFailed(reason)
        }
        var address = try socketAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw UnixSocketError.connectFailed(reason)
        }
        return descriptor
    }

    private static func listen(path: String) throws -> Int32 {
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.createFailed(String(cString: strerror(errno)))
        }
        var address: sockaddr_un
        do {
            address = try socketAddress(path: path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw UnixSocketError.bindFailed(reason)
        }
        setConsoleUserOwnership(path)
        guard Darwin.listen(descriptor, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw UnixSocketError.listenFailed(reason)
        }
        return descriptor
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8) + [0]
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxLength else { throw UnixSocketError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }
        return address
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else {
                throw UnixSocketError.writeFailed(String(cString: strerror(errno)))
            }
            offset += written
        }
    }

    private static func readLine(from descriptor: Int32) throws -> String {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < 1_048_576 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                throw UnixSocketError.readFailed(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            // Only the newly received chunk can contain the terminator.
            let chunk = buffer.prefix(count)
            bytes.append(contentsOf: chunk)
            if chunk.contains(10) { break }
        }
        guard !bytes.isEmpty, let line = String(bytes: bytes, encoding: .utf8) else {
            throw UnixSocketError.invalidMessage
        }
        return line.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? line
    }

    private static func readLines(
        from descriptor: Int32,
        onLine: ((String) -> Bool)?
    ) throws -> [String] {
        var pending = Data()
        var lines: [String] = []
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var receivedBytes = 0
        // Bytes of `pending` already known to contain no newline, so a large
        // single-line response is scanned once instead of once per chunk.
        var scannedBytes = 0
        while receivedBytes < 8 * 1_048_576 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.readFailed(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            receivedBytes += count
            pending.append(contentsOf: buffer.prefix(count))

            while let newline = pending[(pending.startIndex + scannedBytes)...].firstIndex(of: 10) {
                scannedBytes = 0
                let lineData = pending.prefix(upTo: newline)
                pending.removeSubrange(pending.startIndex..<pending.index(after: newline))
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                lines.append(line)
                if onLine?(line) == true { return lines }
            }
            scannedBytes = pending.count
        }
        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lines.append(line)
                _ = onLine?(line)
            }
        }
        guard !lines.isEmpty else { throw UnixSocketError.invalidMessage }
        return lines
    }

    private static func unlink(_ path: String) {
        _ = path.withCString { Darwin.unlink($0) }
    }

    private static func setConsoleUserOwnership(_ path: String) {
        var consoleStat = stat()
        let foundConsoleUser = "/dev/console".withCString { stat($0, &consoleStat) == 0 }
        if foundConsoleUser {
            _ = path.withCString { Darwin.chown($0, consoleStat.st_uid, consoleStat.st_gid) }
        }
        _ = path.withCString { chmod($0, 0o600) }
    }

    private static func escapeJSON(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

public struct UnixHelperClient: Sendable {
    public let socketPath: String

    public init(socketPath: String = TailscaleRoutePaths.user.root.appendingPathComponent("helper.sock").path) {
        self.socketPath = socketPath
    }

    public func send(
        _ request: HelperRequest,
        onProgress: (@Sendable (RouteProgress) -> Void)? = nil
    ) throws -> HelperResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        let line = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var finalResponse: HelperResponse?
        var responseIDMismatch = false
        _ = try UnixSocketTransport.sendLines(line, to: socketPath) { responseLine in
            guard let response = try? decoder.decode(HelperResponse.self, from: Data(responseLine.utf8)) else {
                return false
            }
            guard response.requestID == request.requestID else {
                responseIDMismatch = true
                return true
            }
            if let progress = response.progress, !response.isFinal {
                onProgress?(progress)
            }
            if response.isFinal {
                finalResponse = response
                return true
            }
            return false
        }
        if responseIDMismatch { throw UnixSocketError.invalidMessage }
        guard let finalResponse else { throw UnixSocketError.invalidMessage }
        return finalResponse
    }
}

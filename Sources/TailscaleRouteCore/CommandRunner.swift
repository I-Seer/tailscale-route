import Foundation

public struct CommandResult: Sendable {
    public let executable: String
    public let arguments: [String]
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(
        executable: String,
        arguments: [String],
        stdout: String,
        stderr: String,
        exitCode: Int32
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var succeeded: Bool { exitCode == 0 }

    public var failureReason: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return detail }
        return "退出码 \(exitCode)"
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning, Sendable {
    public init() {}

    public func run(_ executable: String, arguments: [String]) -> CommandResult {
        // The IPv4 routing table is read on every status, apply and
        // verification pass. Read it straight from the kernel instead of
        // launching netstat(8); the text uses the same columns, so all
        // existing parsing and ownership checks are unchanged.
        if executable == "/usr/sbin/netstat",
           arguments == ["-rn", "-f", "inet"],
           let table = NativeNetworkReader.ipv4RouteTableText()
        {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                stdout: table,
                stderr: "",
                exitCode: 0
            )
        }
        if Self.pipeSafeExecutables.contains(executable) {
            return runWithPipes(executable, arguments: arguments)
        }
        return runWithFiles(executable, arguments: arguments)
    }

    /// Short-lived system tools that never leave descendants holding the
    /// output pipe. Anything else (notably `su -l`, whose login shell may
    /// start background jobs that inherit stdout) keeps using temporary
    /// files so a lingering descendant can never block the Helper.
    private static let pipeSafeExecutables: Set<String> = [
        "/sbin/route",
        "/sbin/ifconfig",
        "/usr/sbin/netstat",
        "/usr/sbin/networksetup",
        "/usr/sbin/ipconfig",
        "/usr/sbin/ioreg",
        "/usr/bin/stat",
    ]

    private func runWithFiles(_ executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscale-route-stdout-\(UUID().uuidString)")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscale-route-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        do {
            let outputFile = try FileHandle(forWritingTo: outputURL)
            defer { try? outputFile.close() }
            let errorFile = try FileHandle(forWritingTo: errorURL)
            defer { try? errorFile.close() }
            process.standardOutput = outputFile
            process.standardError = errorFile
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: 127
            )
        }

        let stdoutData = (try? Data(contentsOf: outputURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: errorURL)) ?? Data()
        return CommandResult(
            executable: executable,
            arguments: arguments,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// Runs a command with stdout/stderr pipes. stderr is drained on a
    /// separate thread so a chatty command can never block on a full pipe,
    /// and no temporary files are created per invocation.
    private func runWithPipes(_ executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        defer {
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForWriting.close()
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return CommandResult(
                executable: executable,
                arguments: arguments,
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: 127
            )
        }

        let errorReader = PipeDrain(errorPipe.fileHandleForReading)
        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorReader.wait()
        process.waitUntilExit()
        return CommandResult(
            executable: executable,
            arguments: arguments,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}

/// Reads a file handle to EOF on a background queue.
private final class PipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let handle: FileHandle
    private var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = self.handle.readDataToEndOfFile()
            group.leave()
        }
    }

    func wait() -> Data {
        group.wait()
        return data
    }
}

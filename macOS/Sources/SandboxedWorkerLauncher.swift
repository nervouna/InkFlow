import Foundation
import Darwin

struct IFSandboxedWorkerLauncher {
    enum Interruption {
        case cancelled
        case timeout
    }

    struct Exit {
        let status: Int32
        let interruption: Interruption?
        let stderr: String
    }

    let profile: String
    let roots: [(name: String, path: String)]
    let helper: URL
    let arguments: [String]
    let directory: URL
    let timeout: TimeInterval
    let killGrace: TimeInterval
    var isCancelled: () -> Bool = { false }
    var stdoutLimit: Int?
    var onStdoutLine: (@Sendable (Data) -> Void)?
    var stderrLimit: Int?

    func run() throws -> Exit {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        var sandboxArguments = [String]()
        for root in roots {
            sandboxArguments += ["-D", "\(root.name)=\(root.path)"]
        }
        process.arguments = sandboxArguments + ["-p", profile, helper.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": directory.path, "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = stdoutLimit == nil ? nil : Pipe()
        let stderr = stderrLimit == nil ? nil : Pipe()
        process.standardOutput = stdout ?? FileHandle.nullDevice
        process.standardError = stderr ?? FileHandle.nullDevice
        try process.run()
        try? stdout?.fileHandleForWriting.close()
        try? stderr?.fileHandleForWriting.close()
        let readers = DispatchGroup()
        let diagnostics = Capture()
        if let stdout, let stdoutLimit {
            readers.enter()
            DispatchQueue.global().async {
                Self.readLines(stdout.fileHandleForReading, limit: stdoutLimit, onLine: onStdoutLine)
                readers.leave()
            }
        }
        if let stderr, let stderrLimit {
            readers.enter()
            DispatchQueue.global().async {
                diagnostics.read(stderr.fileHandleForReading, limit: stderrLimit)
                readers.leave()
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        var interruption: Interruption?
        while process.isRunning {
            if isCancelled() {
                interruption = .cancelled
                break
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout {
                interruption = .timeout
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if interruption != nil, process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + killGrace
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        readers.wait()
        if isCancelled() {
            interruption = .cancelled
        }
        return Exit(status: process.terminationStatus, interruption: interruption, stderr: diagnostics.text)
    }

    private static func readLines(_ handle: FileHandle, limit: Int, onLine: (@Sendable (Data) -> Void)?) {
        defer { try? handle.close() }
        var partial = Data()
        while let bytes = try? handle.read(upToCount: 8192), !bytes.isEmpty {
            partial.append(bytes)
            while let newline = partial.firstIndex(of: 0x0a) {
                let line = Data(partial[..<newline])
                partial.removeSubrange(...newline)
                onLine?(line)
            }
            if partial.count > limit {
                partial.removeAll()
            }
        }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        func read(_ handle: FileHandle, limit: Int) {
            defer { try? handle.close() }
            while let bytes = try? handle.read(upToCount: 8192), !bytes.isEmpty {
                lock.lock()
                let available = max(0, limit - data.count)
                data.append(bytes.prefix(available))
                truncated = truncated || bytes.count > available
                lock.unlock()
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self) + (truncated ? "\n[diagnostic output truncated]" : "")
        }
    }
}

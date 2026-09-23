import Foundation
import Darwin

struct DiagnosticCrashSummary: Encodable, Sendable {
    enum Exception: String, Codable, Sendable {
        case badAccess = "EXC_BAD_ACCESS", badInstruction = "EXC_BAD_INSTRUCTION", arithmetic = "EXC_ARITHMETIC"
        case breakpoint = "EXC_BREAKPOINT", crash = "EXC_CRASH", resource = "EXC_RESOURCE", guardViolation = "EXC_GUARD"
        case corpseNotify = "EXC_CORPSE_NOTIFY", unknown
    }
    let timestamp: Date
    let process: String = "InkFlow"
    let pid: Int32?
    let version: String?
    let build: String?
    let exception: Exception
}

struct DiagnosticCrashCollection: Encodable, Sendable {
    enum Issue: String, Codable, Sendable { case missingDirectory, noMatchingReport, permissionDenied, unsupported, truncated, unsafePath, unreadable, nonfatal, simulated }
    let summaries: [DiagnosticCrashSummary]
    let issues: [Issue]
}

/// Reads only bounded regular .ips files and immediately projects them into a finite safe schema.
struct DiagnosticCrashReader: Sendable {
    let directories: [URL]
    var maximumFiles = 128
    var maximumFileBytes = 4 * 1_024 * 1_024
    var maximumTotalBytes = 16 * 1_024 * 1_024

    func collect(since: Date, until: Date) async -> DiagnosticCrashCollection {
        await Task.detached(priority: .utility) { read(since: since, until: until) }.value
    }

    private func read(since: Date, until: Date) -> DiagnosticCrashCollection {
        var summaries: [DiagnosticCrashSummary] = [], issues = Set<DiagnosticCrashCollection.Issue>()
        var examined = 0, bytesRead = 0
        for directory in directories {
            // Walk ancestors without following links, including the report directory itself.
            var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { issues.insert(.unreadable); continue }
            var failed = false
            for component in directory.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    issues.insert(errno == ENOENT ? .missingDirectory : (errno == EACCES || errno == EPERM ? .permissionDenied : .unsafePath))
                    failed = true; break
                }
                close(fd); fd = next
            }
            if failed { close(fd); continue }
            guard let stream = fdopendir(fd) else { close(fd); issues.insert(.unreadable); continue }
            defer { closedir(stream) }
            var directoryEntries = 0
            while let entry = readdir(stream) {
                directoryEntries += 1
                if directoryEntries > 16_384 { issues.insert(.truncated); break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard (name.hasPrefix("InkFlow") || name.hasPrefix("Ink Flow")), name.hasSuffix(".ips") else { continue }
                examined += 1
                guard examined <= maximumFiles else { issues.insert(.truncated); break }
                let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard file >= 0 else {
                    issues.insert(errno == ELOOP ? .unsafePath : (errno == EACCES || errno == EPERM ? .permissionDenied : .unreadable)); continue
                }
                defer { close(file) }
                var info = stat()
                guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { issues.insert(.unsafePath); continue }
                guard info.st_size > 0, info.st_size <= maximumFileBytes,
                      info.st_size <= maximumTotalBytes - bytesRead else { issues.insert(.truncated); continue }
                let size = Int(info.st_size)
                var data = Data(count: size)
                let complete = data.withUnsafeMutableBytes { buffer in
                    var position = 0
                    while position < size {
                        let count = Darwin.read(file, buffer.baseAddress!.advanced(by: position), size - position)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { return false }; position += count
                    }
                    return true
                }
                bytesRead += size
                guard complete else { issues.insert(.unreadable); continue }
                parse(data, since: since, until: until, summaries: &summaries, issues: &issues)
            }
        }
        if summaries.isEmpty && issues.isEmpty { issues.insert(.noMatchingReport) }
        return .init(summaries: summaries.sorted { $0.timestamp < $1.timestamp }, issues: issues.sorted { $0.rawValue < $1.rawValue })
    }

    private func parse(_ data: Data, since: Date, until: Date, summaries: inout [DiagnosticCrashSummary],
                       issues: inout Set<DiagnosticCrashCollection.Issue>) {
        guard let separator = data.firstIndex(of: 10),
              let metadata = (try? JSONSerialization.jsonObject(with: data[..<separator])) as? [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: data[(separator + 1)...])) as? [String: Any] else {
            issues.insert(.unsupported); return
        }
        let bundle = body["bundleInfo"] as? [String: Any]
        let identity = "io.damao.inputmethod.inkflow"
        guard bundle?["CFBundleIdentifier"] as? String == identity,
              (metadata["bundleID"] == nil || metadata["bundleID"] as? String == identity) else { return }
        guard metadata["bug_type"] as? String == "309" else { issues.insert(.unsupported); return }
        guard let captured = body["captureTime"] as? String, captured.utf8.count <= 64,
              let timestamp = Self.date(captured) else { issues.insert(.unsupported); return }
        guard timestamp >= since && timestamp <= until else { return }
        let exception = body["exception"] as? [String: Any]
        guard let simulated = Self.flag(body["isSimulated"]), let nonfatal = Self.flag(body["isNonFatal"]) else {
            issues.insert(.unsupported); return
        }
        if simulated { issues.insert(.simulated); return }
        if nonfatal { issues.insert(.nonfatal); return }
        if exception?["type"] as? String == "EXC_RESOURCE" || exception?["type"] as? String == "EXC_GUARD" {
            // Fatality varies for these reports. Do not infer a confirmed crash or confirmed nonfatal event.
            issues.insert(.unsupported); return
        }
        let pid = (body["pid"] as? NSNumber).flatMap { value -> Int32? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            return number > 0 && number <= Double(Int32.max) && number.rounded() == number ? Int32(number) : nil
        }
        summaries.append(.init(timestamp: timestamp, pid: pid,
            version: Self.numericVersion(bundle?["CFBundleShortVersionString"]), build: Self.numericVersion(bundle?["CFBundleVersion"]),
            exception: (exception?["type"] as? String).flatMap(DiagnosticCrashSummary.Exception.init(rawValue:)) ?? .unknown))
    }

    // Apple documents these Boolean flags as strings; reports also use JSON Boolean/numeric values.
    private static func flag(_ value: Any?) -> Bool? {
        guard let value else { return false }
        if let text = value as? String {
            if text == "true" || text == "1" { return true }
            if text == "false" || text == "0" { return false }
            return nil
        }
        if let number = value as? NSNumber {
            if number.doubleValue == 1 { return true }
            if number.doubleValue == 0 { return false }
        }
        return nil
    }

    private static func numericVersion(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 32,
              text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        return text
    }
    private static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"; formatter.isLenient = false
        return formatter.date(from: value)
    }
}

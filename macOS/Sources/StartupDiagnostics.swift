import Foundation
import os

/// Content-free, constant-size events. Run ID and PID separate cold starts from client switches.
struct IFStartupDiagnostics: Sendable {
    enum Stage: String, Sendable {
        case process, bootstrap, backend, journal, fingerprint, cacheValidation, indexes, rebuild
        case worker, engine, initialization, maintenance, server, eventLoop, activation, deactivation
    }
    enum Source: String, Sendable { case process, bundled, downloaded, prepared, client }
    enum Status: String, Sendable { case begin, ready, failed, skipped, cancelled, timeout }
    struct Span: Sendable {
        let id: UUID
        let stage: Stage
        let source: Source
        let started: TimeInterval
    }
    static let shared = IFStartupDiagnostics()
    private static let logger = Logger(subsystem: "io.damao.inputmethod.inkflow", category: "startup")
    let run: UUID
    let pid: Int32
    private let clock: @Sendable () -> TimeInterval
    private let sink: @Sendable (String) -> Void

    init(run: UUID = UUID(), pid: Int32 = ProcessInfo.processInfo.processIdentifier,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping @Sendable (String) -> Void = { message in
             IFStartupDiagnostics.logger.notice("\(message, privacy: .public)")
         }) {
        self.run = run; self.pid = pid; self.clock = clock; self.sink = sink
    }
    func begin(_ stage: Stage, source: Source = .process) -> Span {
        let span = Span(id: UUID(), stage: stage, source: source, started: clock())
        emit(span, .begin)
        return span
    }
    func end(_ span: Span, _ status: Status = .ready) { emit(span, status) }
    private func emit(_ span: Span, _ status: Status) {
        let elapsed = max(0, clock() - span.started) * 1000
        sink("run=\(run) pid=\(pid) span=\(span.id) stage=\(span.stage.rawValue) source=\(span.source.rawValue) status=\(status.rawValue) elapsed_ms=\(String(format: "%.3f", elapsed))")
    }
    func measure<T>(_ stage: Stage, source: Source = .process, _ body: () throws -> T) rethrows -> T {
        let span = begin(stage, source: source)
        do { let value = try body(); end(span); return value }
        catch { end(span, .failed); throw error }
    }
}

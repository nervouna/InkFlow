import Foundation
import os

/// Content-free, constant-size events. Run ID and PID separate cold starts from client switches.
package struct IFStartupDiagnostics: Sendable {
    package enum Stage: String, DiagnosticLabel {
        case process, bootstrap, backend, journal, fingerprint, cacheValidation, indexes, rebuild
        case worker, engine, initialization, maintenance, server, eventLoop, activation, deactivation
    }
    package enum Source: String, Codable, Sendable { case process, bundled, downloaded, prepared, client }
    package enum Status: String, DiagnosticLabel { case begin, ready, failed, skipped, cancelled, timeout }
    package struct Span: Sendable {
        let id: UUID
        let stage: Stage
        let source: Source
        let started: TimeInterval
    }
    package static let shared = IFStartupDiagnostics()
    private static let logger = Logger(subsystem: "io.damao.inputmethod.inkflow", category: "startup")
    package let run: UUID
    package let pid: Int32
    private let clock: @Sendable () -> TimeInterval
    private let sink: @Sendable (String) -> Void

    package init(run: UUID = UUID(), pid: Int32 = ProcessInfo.processInfo.processIdentifier,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping @Sendable (String) -> Void = { message in
             IFStartupDiagnostics.logger.notice("\(message, privacy: .public)")
         }) {
        self.run = run; self.pid = pid; self.clock = clock; self.sink = sink
    }
    package func begin(_ stage: Stage, source: Source = .process) -> Span {
        let span = Span(id: UUID(), stage: stage, source: source, started: clock())
        emit(span, .begin)
        return span
    }
    package func end(_ span: Span, _ status: Status = .ready) { emit(span, status) }
    private func emit(_ span: Span, _ status: Status) {
        let elapsed = max(0, clock() - span.started) * 1000
        LocalDiagnostics.shared.submit(.init(module: .startup, event: span.stage,
            outcome: .init(rawValue: status.rawValue) ?? .completed, reason: status,
            correlation: span.id, elapsedMilliseconds: elapsed, context: .init(startupRun: run, source: span.source)))
        sink("run=\(run) pid=\(pid) span=\(span.id) stage=\(span.stage.rawValue) source=\(span.source.rawValue) status=\(status.rawValue) elapsed_ms=\(String(format: "%.3f", elapsed))")
    }
    package func measure<T>(_ stage: Stage, source: Source = .process, _ body: () throws -> T) rethrows -> T {
        let span = begin(stage, source: source)
        do { let value = try body(); end(span); return value }
        catch { end(span, .failed); throw error }
    }
}

package enum InputDiagnosticStage: String, Codable, Sendable {
    case routing, context, rime, commit, refresh
}

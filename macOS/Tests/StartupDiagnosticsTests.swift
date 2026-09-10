import Foundation

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var time: TimeInterval = 10
    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ delta: TimeInterval) { lock.lock(); defer { lock.unlock() }; time += delta }
}

@main struct StartupDiagnosticsTests {
    static func main() {
        let capture = Capture()
        let trace = IFStartupDiagnostics(pid: 42, clock: { capture.now() }, sink: { capture.append($0) })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let boot = trace.begin(.bootstrap)
            trace.measure(.worker, source: .downloaded) {
                entered.signal()
                release.wait()
            }
            trace.end(boot)
            trace.measure(.server) {}
            done.signal()
        }
        precondition(entered.wait(timeout: .now() + 2) == .success)
        let blocked = capture.snapshot()
        precondition(blocked.count == 2 && blocked.last!.contains("stage=worker") && blocked.last!.contains("status=begin"))
        precondition(!blocked.contains { $0.contains("stage=server") })
        capture.advance(12.5)
        release.signal()
        precondition(done.wait(timeout: .now() + 2) == .success)
        let completed = capture.snapshot()
        precondition(completed[2].contains("stage=worker") && completed[2].contains("elapsed_ms=12500.000"))
        precondition(completed[3].contains("stage=bootstrap") && completed[3].contains("elapsed_ms=12500.000"))
        precondition(completed[4].contains("stage=server") && completed[5].contains("elapsed_ms=0.000"))
        enum Synthetic: Error { case secretContentMustNeverAppear }
        do { try trace.measure(.indexes) { throw Synthetic.secretContentMustNeverAppear } }
        catch {}
        for status: IFStartupDiagnostics.Status in [.cancelled, .timeout, .skipped] {
            trace.end(trace.begin(.worker), status)
        }
        let events = capture.snapshot()
        precondition(events.allSatisfy { $0.contains("run=\(trace.run) pid=42") && $0.utf8.count < 300 })
        precondition(!events.joined().contains("secretContent"))
        precondition(events.contains { $0.contains("stage=indexes") && $0.contains("status=failed") })
        // Every completion retains its begin span ID. Repeated stages receive distinct IDs.
        for pair in stride(from: 0, to: events.count, by: 2) where pair >= 6 {
            let beginSpan = events[pair].split(separator: " ")[2]
            precondition(events[pair + 1].contains(beginSpan))
        }
        events.forEach { print($0) }
        print("PASS startup diagnostics: gated stage, monotonic delay, readiness order, failure/cancel/skip, bounded content-free correlation")
    }
}

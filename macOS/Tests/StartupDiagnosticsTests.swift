import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var time: TimeInterval = 10
    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ delta: TimeInterval) { lock.lock(); defer { lock.unlock() }; time += delta }
}

private final class InputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InputDiagnosticRecord] = []
    func append(_ record: InputDiagnosticRecord) { lock.withLock { storage.append(record) } }
    var records: [InputDiagnosticRecord] { lock.withLock { storage } }
}

@main struct StartupDiagnosticsTests {
    @MainActor static func main() {
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
        inputLifecycle()
        compositionLifecycle()
        print("PASS startup diagnostics: gated stage, monotonic delay, readiness order, failure/cancel/skip, bounded content-free correlation")
    }

    @MainActor static func compositionLifecycle() {
        let capture = InputCapture()
        InputDiagnostics.$observe.withValue({ capture.append($0) }) {
            let lifecycle = IFInputLifecycleDiagnostics()
            lifecycle.beginActivation()
            let first = lifecycle.beginComposition()
            precondition(lifecycle.beginComposition().id == first.id)
            let insertion = lifecycle.insertionBegan(clientPresent: true)
            lifecycle.deactivationEntered()
            lifecycle.beginActivation()
            let second = lifecycle.beginComposition()
            lifecycle.deactivationFinished()
            lifecycle.insertionFinished(insertion, clientPresent: true)
            precondition(lifecycle.beginComposition().id == second.id,
                "Old deactivation/insert return must not close a reentrant new composition")
            lifecycle.engineAvailability(false)
            lifecycle.engineAvailability(false)
            lifecycle.engineAvailability(true)
            lifecycle.engineAvailability(false)
            lifecycle.controllerReleased()
        }
        let records = capture.records
        precondition(records.filter { $0.event == .compositionBegan }.count == 2)
        precondition(records.filter { $0.event == .compositionEnded }.count == 2)
        let issued = records.first { $0.event == .insertionIssued }!
        let returned = records.first { $0.event == .insertionReturned }!
        precondition(issued.composition == returned.composition && issued.activation == returned.activation)
        precondition(records.filter { $0.event == .engineUnavailable }.count == 2)
        precondition(records.contains { $0.event == .compositionEnded && $0.reason == .teardown })
    }

    @MainActor static func inputLifecycle() {
        let capture = InputCapture()
        let controller = UUID()
        InputDiagnostics.$observe.withValue({ capture.append($0) }) {
            let lifecycle = IFInputLifecycleDiagnostics(controller: controller)
            lifecycle.controllerCreated()
            lifecycle.beginActivation()
            lifecycle.finishActivation(engineAvailable: true)
            let first = lifecycle.beginFirstKey()
            lifecycle.checkpointFirstKey(first, stage: .routing)
            lifecycle.checkpointFirstKey(first, stage: .context)
            lifecycle.checkpointFirstKey(first, stage: .rime)
            lifecycle.checkpointFirstKey(first, stage: .commit)
            lifecycle.checkpointFirstKey(first, stage: .refresh)
            lifecycle.finishFirstKey(first, outcome: .handled, reason: .rime,
                delivery: .init(clientPresent: true, commitInsertion: false,
                                markedTextUpdate: true, markedTextClear: false))
            lifecycle.recordFirstKey(outcome: .passThrough, reason: .rime)
            lifecycle.deactivationEntered()
            lifecycle.deactivationBeforeSuper()
            lifecycle.deactivationAfterSuper()
            lifecycle.deactivationFinished()
            lifecycle.beginActivation()
            lifecycle.finishActivation(engineAvailable: false)
            lifecycle.recordFirstKey(outcome: .skipped, reason: .engineUnavailable)
            lifecycle.controllerReleased()
        }
        let records = capture.records
        let arrivals = records.filter { $0.event == .firstKeyEntered }
        let checkpoints = records.filter { $0.event == .firstKeyCheckpoint }
        let completions = records.filter { $0.event == .firstKeyCompleted }
        precondition(arrivals.count == 2 && completions.count == 2,
                     "Only one first-key pair in each activation is retained")
        precondition(completions[0].outcome == .handled && completions[0].reason == .rime &&
                     completions[0].clientPresent == true && completions[0].markedTextUpdate == true &&
                     completions[0].commitInsertion == false && completions[0].markedTextClear == false)
        precondition(checkpoints.map(\.stage) == [.routing, .context, .rime, .commit, .refresh] &&
                     checkpoints.allSatisfy { $0.key == arrivals[0].key && $0.activation == arrivals[0].activation &&
                         $0.elapsedMilliseconds != nil && $0.message.contains("elapsed_ms=") },
                     "First-key checkpoints must be ordered, correlated, and include elapsed time")
        precondition(completions[1].outcome == .skipped && completions[1].reason == .engineUnavailable)
        precondition(arrivals[0].key == completions[0].key && arrivals[1].key == completions[1].key)
        precondition(completions[0].activation != completions[1].activation,
                     "A new activation permits one new first-key record")
        precondition(records.allSatisfy { $0.controller == controller && $0.message.utf8.count < 400 })
        let message = records.map(\.message).joined(separator: "\n")
        for sentinel in ["sentinel-private-input", "拼音秘密", "候选秘密", "/private/secret", "error detail"] {
            precondition(!message.contains(sentinel))
        }
        for event: InputDiagnosticEvent in [.controllerCreated, .activationReady, .deactivationEntered,
                                             .deactivationBeforeSuper, .deactivationAfterSuper,
                                             .deactivationFinished, .activationSkipped, .controllerReleased] {
            precondition(records.contains { $0.event == event }, "Missing input lifecycle event \(event)")
        }
        print("PASS input diagnostics: activation correlation, first-key dedupe, bounded content-free delivery outcomes")
    }
}

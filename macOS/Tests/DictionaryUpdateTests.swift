import InkFlowDictionaryTestSupport
@testable import InkFlowRime
@testable import InkFlowDomain
import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

private func check(_ value: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fatalError(message, file: (file), line: line) }
}
private func fails(_ code: String? = nil, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure \(code ?? "")") }
    catch let error as IFDictionaryUpdateError { if let code { check(error.code == code, "Expected \(code), got \(error.technicalDetails)") } }
    catch { check(code == nil, "Unexpected error \(error)") }
}
private func asyncFails(_ code: String? = nil, _ body: () async throws -> Void) async {
    do { try await body(); fatalError("Expected failure \(code ?? "")") }
    catch let error as IFDictionaryUpdateError { if let code { check(error.code == code, "Expected \(code), got \(error.technicalDetails)") } }
    catch { check(code == nil, "Unexpected error \(error)") }
}

@main struct DictionaryUpdateTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let modes = ["--source", "--store", "--worker"]
        check(arguments.count == 3 || (arguments.count == 4 && modes.contains(arguments[3])), "Unknown dictionary scenario")
        let mode = arguments.count == 3 ? "all" : arguments[3]
        let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: arguments[2])
        if mode == "all" || mode == "--source" { try await verifyDictionarySources(repository: repository) }
        if mode == "all" || mode == "--store" {
            try verifyDictionaryStore(in: root)
        }
        if mode == "all" || mode == "--worker" {
            let runtime = IFDictionaryRuntime.bundled(helper: repository.appendingPathComponent("build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"))
            let fingerprint = try runtime.fingerprint()
            try await runnerFailures(root: root, runtime: runtime, repository: repository, fingerprint: fingerprint)
            let preparation = DictionaryPreparationRegression(makeServices: { runtime, user, store in
                .init(client: .init(), worker: .init(runtime: runtime, protectedUserRoot: user,
                    candidatesRoot: store.root.appendingPathComponent("candidates")))
            }, copyRuntime: { runtime, destination in
                try FileManager.default.copyItem(at: runtime.helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), to: destination)
                return .bundled(helper: destination.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker"))
            })
            try await preparation.run(root: root, runtime: runtime, repository: repository)
        }
        print("PASS dictionary updates: \(mode)")
    }
    static func runnerFailures(root: URL, runtime: IFDictionaryRuntime, repository: URL, fingerprint: String) async throws {
        let user = root.appendingPathComponent("protected")
        let store = try IFDictionaryStore(root: user.appendingPathComponent("updates"))
        try Data("private sentinel".utf8).write(to: store.root.appendingPathComponent("blocked.txt"))
        let fixtureRuntime = IFDictionaryRuntime(resources: runtime.resources, helper: repository.appendingPathComponent("build/dictionary-worker-fixture"), libraries: [])
        let runner = IFDictionaryWorkerRunner(runtime: fixtureRuntime, protectedUserRoot: user, candidatesRoot: store.root.appendingPathComponent("candidates"), timeout: 10)
        for mode in ["stderr", "typed", "timeout", "sandbox"] {
            let candidate = try store.candidate()
            let request = IFDictionaryWorkerRequest(candidate: candidate, runtimeFingerprint: fingerprint, receipts: [], reuseDictionary: false,
                existing: .init(contentVersion: mode, runtimeFingerprint: fingerprint))
            let start = Date()
            var fixtureRunner = runner; if mode == "timeout" { fixtureRunner.timeout = 2 }
            do { _ = try fixtureRunner.runBlocking(request); fatalError("Expected fixture failure") }
            catch let error as IFDictionaryUpdateError {
                if mode == "stderr" { check(error.exitStatus == 17 && error.stderr!.contains("truncated") && error.stderr!.count < 16500, "Bounded draining stderr: \(error.technicalDetails.prefix(300)) count=\(error.stderr?.count ?? 0)") }
                if mode == "typed" { check(error.code == "fixture-compile" && error.stage == .prepare, "Typed prepare detail") }
                if mode == "timeout" { check(error.code == "worker-timeout" && error.stage == .verify && Date().timeIntervalSince(start) < 5,
                    "Timeout kills resistant helper: \(error.technicalDetails), elapsed=\(Date().timeIntervalSince(start))") }
                if mode == "sandbox" {
                    check(error.exitStatus == 23, "Sandbox denied protected read")
                    check(FileManager.default.fileExists(atPath: candidate.appendingPathComponent("allowed.txt").path), "Sandbox allows candidate writes")
                }
            }
            try store.removeCandidate(candidate)
        }
        fails("unsafe-candidate") {
            _ = try runner.runBlocking(.init(candidate: user.appendingPathComponent("pinyin_simp.userdb"), runtimeFingerprint: fingerprint,
                receipts: [], reuseDictionary: false, existing: nil))
        }
        let candidate = try store.candidate(), cancellation = IFDictionaryCancellation()
        cancellation.cancel()
        fails("cancelled") { _ = try runner.runBlocking(.init(candidate: candidate, runtimeFingerprint: fingerprint, receipts: [], reuseDictionary: false, existing: nil), cancellation: cancellation) }
        let runningCancellation = IFDictionaryCancellation()
        let request = IFDictionaryWorkerRequest(candidate: candidate, runtimeFingerprint: fingerprint, receipts: [], reuseDictionary: false,
            existing: .init(contentVersion: "timeout", runtimeFingerprint: fingerprint))
        var longRunner = runner; longRunner.timeout = 60
        let cancellableRunner = longRunner
        let task = Task.detached { try cancellableRunner.runBlocking(request, cancellation: runningCancellation) }
        try await Task.sleep(for: .milliseconds(150)); runningCancellation.cancel()
        await asyncFails("cancelled") { _ = try await task.value }
        let inputs = try IFDictionaryCatalog.sources.filter(\.isUpdatable).map { spec in
            IFDictionaryInput(receipt: spec.pinnedReceipt, data: try Data(contentsOf: repository.appendingPathComponent("build/dictionary-sources/\(spec.id).yaml")))
        }
        for asynchronousPreparation in [false, true] {
            let ownedCandidate = try store.candidate()
            let ownedRequest = IFDictionaryWorkerRequest(candidate: ownedCandidate, runtimeFingerprint: fingerprint, receipts: [], reuseDictionary: false,
                existing: .init(contentVersion: "timeout", runtimeFingerprint: fingerprint))
            var boundedRunner = runner; boundedRunner.timeout = 5
            let ownedRunner = boundedRunner
            let owned = Task.detached {
                if asynchronousPreparation { return try await ownedRunner.prepare(candidate: ownedCandidate, inputs: inputs, existing: ownedRequest.existing) }
                return try ownedRunner.runBlocking(ownedRequest)
            }
            let pidURL = ownedCandidate.appendingPathComponent("worker.pid")
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: pidURL.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            check(FileManager.default.fileExists(atPath: pidURL.path), "Resistant worker entered its writer loop before cancellation")
            let pid = pid_t(try String(contentsOf: pidURL, encoding: .utf8))!
            let start = ContinuousClock.now
            owned.cancel()
            await asyncFails("cancelled") { _ = try await owned.value }
            check(start.duration(to: .now) < .seconds(3), "Task cancellation bounds resistant worker drain")
            check(kill(pid, 0) == -1 && errno == ESRCH, "Worker exits before returning to candidate cleanup")
            try store.removeCandidate(ownedCandidate)
            try await Task.sleep(for: .milliseconds(100))
            check(!FileManager.default.fileExists(atPath: ownedCandidate.path), "No producer recreates a cleaned candidate")
            print("PASS worker Task.cancel: async prepare=\(asynchronousPreparation), terminated and reaped resistant writer in \(start.duration(to: .now))")
        }
        print("PASS runner: sandbox protected read/candidate write, concurrent bounded stderr, prepare detail, verify timeout, cancellation cleanup")
    }

}

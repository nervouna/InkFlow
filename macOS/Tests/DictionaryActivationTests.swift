import Foundation
@testable import InkFlowRime
@testable import InkFlowCore
import InkFlowTestSupport
import InkFlowDictionaryTestSupport

@main struct DictionaryActivationTests {
    @MainActor static func main() async throws {
        check(CommandLine.arguments.count == 3)
        let diagnostic = String(repeating: "中文🙂e\u{301}诊断\n", count: 3000) + "TAIL-END"
        let parts = IFDictionaryCoordinator.diagnosticChunks(diagnostic)
        check(parts.count > 1 && parts.allSatisfy { $0.utf8.count <= 700 && !$0.isEmpty } && parts.joined() == diagnostic,
              "Persistent diagnostics retain every UTF-8 scalar through bounded chunks")
        print("PASS logging: <=700-byte chunks rejoin complete Chinese/emoji/combining-scalar diagnostics")
        let root = try IFDictionaryFiles.canonical(URL(fileURLWithPath: CommandLine.arguments[1]))
        let repository = URL(fileURLWithPath: CommandLine.arguments[2])
        let runtime = IFDictionaryRuntime.bundled(helper: repository.appendingPathComponent("build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"))
        let regression = DictionaryActivationRegression(makeServices: { runtime, user, store in
            let worker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: user,
                candidatesRoot: store.root.appendingPathComponent("candidates"))
            return .init(client: .init(), worker: worker)
        }, copyRuntime: { runtime, destination in
            try FileManager.default.copyItem(at: runtime.helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), to: destination)
            return .bundled(helper: destination.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker"))
        }, verifyUnavailableEvent: { engine in
            check(!engine.event(keyEvent(0, "a")))
        })
        try await regression.run(root: root, runtime: runtime, repository: repository)
    }
}

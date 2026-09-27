import Foundation
import InkFlowDomain
import InkFlowRime
import InkFlowDictionaryTestSupport

@main struct CoreDictionaryTests {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let repository = URL(fileURLWithPath: arguments[2])
        if arguments[1] == "--source" {
            try await verifyDictionarySources(repository: repository)
            return
        }
        guard ["--preparation", "--activation"].contains(arguments[1]), arguments.count == 8 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let root = try IFDictionaryFiles.canonical(URL(fileURLWithPath: arguments[3]))
        let runtime = IFDictionaryRuntime(resources: URL(fileURLWithPath: arguments[4]),
            helper: URL(fileURLWithPath: arguments[5]),
            libraries: arguments.dropFirst(6).map { URL(fileURLWithPath: $0) })
        _ = try IFPackagedCache.descriptor(resources: runtime.resources)
        let makeServices: @Sendable (IFDictionaryRuntime, URL, IFDictionaryStore) -> IFDictionaryServices = { runtime, _, _ in
            NativePreparationFixture(runtime: runtime, exchanges: root.appendingPathComponent("exchanges")).services
        }
        let preparation = DictionaryPreparationRegression(makeServices: makeServices, copyRuntime: NativePreparationFixture.copyRuntime)
        try await preparation.run(root: root.appendingPathComponent("preparation"), runtime: runtime, repository: repository)
        if arguments[1] == "--preparation" { return }
        let regression = DictionaryActivationRegression(makeServices: makeServices, copyRuntime: NativePreparationFixture.copyRuntime)
        try await regression.run(root: root, runtime: runtime, repository: repository)
    }
}

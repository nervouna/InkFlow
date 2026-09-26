import InkFlowRime
import Foundation

package enum IFDictionaryWorkerBootstrap {
    package typealias EngineOperation = IFDictionaryPreparation.EngineOperation

    package static func run(arguments: [String], executablePath: String,
                            compile: EngineOperation, probe: EngineOperation) -> Int32 {
        func emit(_ event: IFDictionaryWorkerEvent) throws {
            var data = try JSONEncoder().encode(event)
            data.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
        let request: IFDictionaryWorkerRequest
        let runtime: IFDictionaryRuntime
        do {
            guard arguments.count == 2 else { throw IFDictionaryUpdateError(.prepare, "worker-arguments") }
            let requestURL = try IFDictionaryFiles.canonical(URL(fileURLWithPath: arguments[1]))
            request = try IFDictionaryFiles.decode(IFDictionaryWorkerRequest.self, at: requestURL)
            let root = request.candidate
            guard root.path == (try IFDictionaryFiles.canonical(root)).path,
                  requestURL.path == root.appendingPathComponent("request.json").path else {
                throw IFDictionaryUpdateError(.prepare, "unsafe-candidate")
            }
            let executable = URL(fileURLWithPath: executablePath).standardizedFileURL.resolvingSymlinksInPath()
            runtime = IFDictionaryRuntime.bundled(helper: executable)
        } catch {
            let failure = IFDictionaryUpdateError.wrapping(error, stage: .prepare)
            try? emit(.init(failure: .init(failure.stage, failure.code, source: failure.source, file: failure.file,
                detail: "operation=request; \(failure.detail)")))
            return 1
        }
        do {
            _ = try IFDictionaryPreparation.prepare(request: request, runtime: runtime,
                                                    compile: compile, probe: probe, emit: emit)
            return 0
        } catch {
            try? emit(.init(failure: .wrapping(error, stage: .prepare)))
            return 1
        }
    }
}

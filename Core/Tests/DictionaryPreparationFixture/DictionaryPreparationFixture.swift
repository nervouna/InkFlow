import Foundation
import InkFlowDomain
import InkFlowRime
import InkFlowRimeWorker

/// Test host only. A separate process prevents compile/finalize from touching a serving Rime runtime.
@main struct DictionaryPreparationFixture {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5 else { throw CocoaError(.fileReadInvalidFileName) }
        let request = try IFDictionaryFiles.decode(IFDictionaryWorkerRequest.self, at: URL(fileURLWithPath: arguments[1]))
        let runtime = IFDictionaryRuntime(resources: URL(fileURLWithPath: arguments[2]),
            helper: URL(fileURLWithPath: arguments[0]).standardizedFileURL,
            libraries: arguments.dropFirst(4).map { URL(fileURLWithPath: $0) })
        let output = URL(fileURLWithPath: arguments[3])
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let events = try FileHandle(forWritingTo: output)
        defer { try? events.close() }
        func emit(_ event: IFDictionaryWorkerEvent) throws {
            var data = try JSONEncoder().encode(event); data.append(0x0a)
            try events.write(contentsOf: data)
        }
        do {
            _ = try IFDictionaryPreparation.prepare(request: request, runtime: runtime,
                compile: { IFDictionaryCompile($0, $1, $2) },
                probe: { IFDictionaryProbe($0, $1, $2) }, emit: emit)
        } catch {
            try emit(.init(failure: .wrapping(error, stage: .prepare)))
            exit(1)
        }
    }
}

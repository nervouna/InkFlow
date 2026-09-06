import Foundation
import Darwin

@main struct WorkerFixture {
    static func main() throws {
        let request = try IFDictionaryFiles.decode(IFDictionaryWorkerRequest.self, at: URL(fileURLWithPath: CommandLine.arguments[1]))
        var event = try JSONEncoder().encode(IFDictionaryWorkerEvent(progress: .init(stage: .verify, completed: 0, total: 1)))
        event.append(10); try FileHandle.standardOutput.write(contentsOf: event)
        switch request.existing?.contentVersion {
        case "timeout":
            signal(SIGTERM, SIG_IGN)
            while true { Thread.sleep(forTimeInterval: 0.1) }
        case "sandbox":
            let blocked = request.candidate.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("blocked.txt")
            if (try? Data(contentsOf: blocked)) != nil { exit(99) }
            try Data("allowed".utf8).write(to: request.candidate.appendingPathComponent("allowed.txt"))
            exit(23)
        case "typed":
            var failure = try JSONEncoder().encode(IFDictionaryWorkerEvent(failure: .init(.prepare, "fixture-compile", file: "fixed.schema.yaml")))
            failure.append(10); try FileHandle.standardOutput.write(contentsOf: failure); exit(18)
        default:
            try FileHandle.standardError.write(contentsOf: Data(repeating: 120, count: 1_048_576)); exit(17)
        }
    }
}

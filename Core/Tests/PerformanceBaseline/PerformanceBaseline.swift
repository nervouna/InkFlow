import Foundation
import Darwin
import InkFlowDomain
import InkFlowRime

private struct Corpus: Decodable {
    struct Sample: Decodable {
        let id: String
        let input: String
    }
    let candidateCount: Int
    let samples: [Sample]
}

private struct KeyTiming: Encodable {
    let pass: Int
    let sample: String
    let offset: Int
    let milliseconds: Double
}

private struct PerformanceReport: Encodable {
    let formatVersion = 1
    let startupMilliseconds: Double
    let peakResidentBytesAfterStartup: Int
    let peakResidentBytesAfterInput: Int
    let inputOptions: [String: Bool]
    let candidateCount: Int
    let timings: [KeyTiming]
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func milliseconds(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

private func peakResidentBytes() throws -> Int {
    var usage = rusage()
    try require(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed")
    return Int(usage.ru_maxrss)
}

@main struct PerformanceBaseline {
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL performance baseline: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run() throws {
        let args = CommandLine.arguments
        try require(args.count == 5, "Usage: performance-baseline SHARED ABSENT_USER CORPUS OUTPUT")
        let shared = URL(fileURLWithPath: args[1])
        let user = args[2]
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        try require(!FileManager.default.fileExists(atPath: user), "User directory must start absent")
        try require(corpus.candidateCount == 9 && !corpus.samples.isEmpty, "Unsupported corpus")
        for sample in corpus.samples {
            try require(!sample.input.isEmpty && sample.input.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) },
                        "Expected ASCII letter input")
        }
        let start = now()
        guard let cache = try IFPackagedCache.descriptor(resources: shared).cache else {
            throw Failure(description: "Prepared cache missing")
        }
        let ranker = try IFContextRanker(dictionary: shared.appendingPathComponent("pinyin_simp.dict.yaml").path)
        try IFEngine.start(IFEngineConfiguration(shared: shared, cache: cache, user: user, ranker: ranker))
        defer { IFEngine.stop() }
        guard let engine = IFEngine() else { throw Failure(description: "Session creation failed") }
        engine.setConfiguration(candidateCount: corpus.candidateCount, customPhrases: [], inputPreferences: InputPreferences())
        try require(engine.configurationError == nil, "Configuration failed")
        engine.setPrecedingText("")
        let startup = milliseconds(since: start)
        let startupResident = try peakResidentBytes()
        var timings: [KeyTiming] = []
        timings.reserveCapacity(corpus.samples.reduce(0) { $0 + $1.input.utf8.count } * 5)
        for pass in 0..<5 {
            for sample in corpus.samples {
                engine.clear()
                engine.setPrecedingText("")
                for (offset, byte) in sample.input.utf8.enumerated() {
                    let modifiers: Int32 = (65...90).contains(byte) ? 1 : 0
                    let began = now()
                    let handled = engine.input(Int32(byte), modifiers: modifiers)
                    let commit = engine.takeCommit()
                    let snapshot = engine.snapshot()
                    let elapsed = milliseconds(since: began)
                    try require(handled && commit.isEmpty && !snapshot.preedit.isEmpty,
                                "Unexpected input result in \(sample.id) at \(offset)")
                    timings.append(KeyTiming(pass: pass, sample: sample.id, offset: offset, milliseconds: elapsed))
                }
            }
        }
        engine.clear()
        let report = PerformanceReport(startupMilliseconds: startup, peakResidentBytesAfterStartup: startupResident,
                                       peakResidentBytesAfterInput: try peakResidentBytes(),
                                       inputOptions: InputPreferences().recordedValues,
                                       candidateCount: corpus.candidateCount, timings: timings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
        print("PASS performance baseline: \(timings.count) key operations; startup_ms=\(startup)")
    }
}

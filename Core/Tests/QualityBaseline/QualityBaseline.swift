import Foundation
import CryptoKit
import InkFlowDomain
import InkFlowRime

struct Sample: Codable, Equatable {
    let id: String
    let category: String
    let input: String
    let target: String
    let source: String
}
struct Corpus: Codable, Equatable {
    let formatVersion: Int
    let learningSelections: Int
    let candidateCount: Int
    let pageLimit: Int
    let samples: [Sample]
}
struct Observation: Codable, Equatable {
    let first: String
    let topThree: [String]
    let targetRank: Int?
    let inputOperations: Int
    let pagingOperations: Int
    let selectionOperations: Int
    let totalOperations: Int?
    let committedText: String?
    let searchExhausted: Bool
}
struct Result: Codable, Equatable {
    let sample: Sample
    let initial: Observation
    let trainingCommits: Int
    let learned: Observation
}
struct Report: Codable {
    let formatVersion: Int
    let provenance: [String: String]
    let inputOptions: [String: Bool]
    let corpus: Corpus
    let results: [Result]
}
struct BaselineError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw BaselineError(message) }
}
func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
func treeDigest(_ root: URL) throws -> String {
    let hashes = try IFDictionaryFiles.hashes(in: root)
    let lines = hashes.keys.sorted().map { "\($0)\t\(hashes[$0]!)" }.joined(separator: "\n")
    return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
}

@main struct QualityBaseline {
    @MainActor static func engine() throws -> IFEngine {
        guard let engine = IFEngine() else { throw BaselineError("Cannot create Rime session") }
        engine.setConfiguration(candidateCount: 9, customPhrases: [], inputPreferences: InputPreferences())
        try require(engine.configurationError == nil, "Cannot apply baseline configuration")
        engine.setPrecedingText("")
        return engine
    }

    // Observe and commit through the same shared-core boundary as production typing.
    // Initial observation is also selection 1 of the fixed learning recipe.
    @MainActor static func observe(_ sample: Sample, engine: IFEngine, pageLimit: Int) throws -> Observation {
        engine.clear()
        engine.setPrecedingText("")
        for byte in sample.input.utf8 {
            let modifiers: Int32 = (65...90).contains(byte) ? 1 : 0
            try require(engine.key(Int32(byte), modifiers: modifiers), "Unhandled key in \(sample.id)")
            try require(engine.takeCommit().isEmpty, "Unexpected early commit in \(sample.id)")
        }
        let firstPage = engine.snapshot().candidates
        var offset = 0
        var paging = 0
        var exhausted = false
        var rank: Int?
        var committed: String?
        for page in 0..<pageLimit {
            let snapshot = engine.snapshot()
            if let index = snapshot.candidates.firstIndex(of: sample.target) {
                rank = offset + index + 1
                engine.select(index)
                committed = engine.takeCommit()
                try require(committed == sample.target && engine.snapshot().preedit.isEmpty,
                            "Selection did not consume complete input: \(sample.id)")
                break
            }
            if page + 1 == pageLimit { break }
            engine.key(0xff56)
            if engine.snapshot().page == snapshot.page { exhausted = true; break }
            paging += 1
            offset += snapshot.candidates.count
        }
        engine.clear()
        return Observation(first: firstPage.first ?? "", topThree: Array(firstPage.prefix(3)), targetRank: rank,
                           inputOperations: sample.input.utf8.count, pagingOperations: paging,
                           selectionOperations: committed == nil ? 0 : 1,
                           totalOperations: committed == nil ? nil : sample.input.utf8.count + paging + 1,
                           committedText: committed, searchExhausted: exhausted)
    }

    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL quality baseline: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() throws {
        let args = CommandLine.arguments
        try require(args.count == 8, "Usage: quality-baseline ROOT SHARED SCRATCH CORPUS OUTPUT REVISION BASELINE|- ")
        let root = URL(fileURLWithPath: args[1]).standardizedFileURL
        let shared = URL(fileURLWithPath: args[2]).standardizedFileURL
        let scratch = URL(fileURLWithPath: args[3]).standardizedFileURL
        let fixture = URL(fileURLWithPath: args[4]).standardizedFileURL
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
        try require(corpus.formatVersion == 1 && corpus.learningSelections > 0 && corpus.candidateCount == 9 && corpus.pageLimit > 0,
                    "Unsupported corpus configuration")
        try require(!corpus.samples.isEmpty && Set(corpus.samples.map(\.id)).count == corpus.samples.count, "Duplicate or empty corpus")
        for sample in corpus.samples {
            try require(!sample.id.isEmpty && sample.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                        && !sample.target.isEmpty && !sample.input.isEmpty && sample.input.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) },
                        "Invalid sample \(sample.id)")
        }
        var results: [Result] = []
        guard let cache = try IFPackagedCache.descriptor(resources: shared).cache else {
            throw BaselineError("Packaged cache is missing")
        }
        let ranker = try IFContextRanker(index: shared.appendingPathComponent(IFDictionaryCatalog.contextIndexFilename).path)
        for sample in corpus.samples {
            let user = scratch.appendingPathComponent(sample.id)
            try require(!FileManager.default.fileExists(atPath: user.path), "User state must start absent: \(sample.id)")
            let configuration = IFEngineConfiguration(shared: shared, cache: cache, user: user.path, ranker: ranker)
            try IFEngine.start(configuration)
            let initial: Observation
            var trainingCommits = 0
            do {
                let session = try engine()
                initial = try observe(sample, engine: session, pageLimit: corpus.pageLimit)
                if initial.committedText != nil {
                    trainingCommits = 1
                    for _ in 1..<corpus.learningSelections {
                        let training = try observe(sample, engine: session, pageLimit: corpus.pageLimit)
                        try require(training.committedText == sample.target, "Learning target disappeared: \(sample.id)")
                        trainingCommits += 1
                    }
                }
            }
            IFEngine.stop()
            try IFEngine.start(configuration)
            let learned: Observation
            do { learned = try observe(sample, engine: engine(), pageLimit: corpus.pageLimit) }
            IFEngine.stop()
            results.append(Result(sample: sample, initial: initial, trainingCommits: trainingCommits, learned: learned))
            print("\(sample.id): rank \(initial.targetRank.map(String.init) ?? "unavailable") → \(learned.targetRank.map(String.init) ?? "unavailable"); training commits \(trainingCommits)")
        }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("macOS/Info.plist")), format: nil) as! [String: Any]
        var provenance = ["sourceRevision": args[6], "appVersion": plist["CFBundleShortVersionString"] as! String,
                          "fixtureSHA256": try digest(fixture), "resourcesSHA256": try treeDigest(shared),
                          "compiledResourcesSHA256": try treeDigest(cache),
                          "runnerBinarySHA256": try digest(URL(fileURLWithPath: args[0])),
                          "librimeSHA256": try digest(root.appendingPathComponent("build/deps/dist/lib/librime.1.17.0.dylib")),
                          "luaPluginSHA256": try digest(root.appendingPathComponent("build/deps/dist/lib/rime-plugins/librime-lua.dylib")),
                          "system": ProcessInfo.processInfo.operatingSystemVersionString]
        for path in ["Core/Sources", "schemas", "Core/config", "Core/Data"] {
            provenance[path + "SHA256"] = try treeDigest(root.appendingPathComponent(path))
        }
        provenance["runnerSHA256"] = try digest(root.appendingPathComponent("Core/Tests/QualityBaseline/QualityBaseline.swift"))
        for path in ["Core/Package.swift", "Core/scripts/swift-package.sh", "Core/scripts/test-quality-baseline.sh", "macOS/scripts/dependencies.sh", "Core/scripts/prepare-rime.sh"] {
            provenance[path + "SHA256"] = try digest(root.appendingPathComponent(path))
        }
        let report = Report(formatVersion: 1, provenance: provenance, inputOptions: InputPreferences().recordedValues, corpus: corpus, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[5]), options: .atomic)
        if args[7] != "-" {
            let baseline = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: args[7])))
            try require(baseline.formatVersion == report.formatVersion && baseline.corpus == corpus && baseline.inputOptions == report.inputOptions,
                        "Baseline corpus/configuration differs; review before capturing a replacement")
            let provenanceChanges = provenance.keys.filter { baseline.provenance[$0] != provenance[$0] }.sorted()
            if !provenanceChanges.isEmpty { print("Provenance changes: \(provenanceChanges.joined(separator: ", "))") }
            var changed: [String] = []
            for (expected, actual) in zip(baseline.results, results) where expected != actual { changed.append(actual.sample.id) }
            try require(baseline.results.count == results.count && changed.isEmpty, "Quality baseline drift: \(changed.joined(separator: ", ")); inspect \(args[5])")
            print("PASS fixed quality baseline: \(results.count) samples, initial and persisted learned states")
        }
    }
}

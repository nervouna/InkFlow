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
    let retentionCommits: Int
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
    let training: [Observation]
    let learned: Observation
    let retentionCommits: Int
    let retained: Observation
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

    // Han ranges as the portable replay instrument counts them (Core/Portable/src/ranking.rs is_han).
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x30000...0x323AF:
            return true
        default:
            return false
        }
    }

    static func isHan(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { isHan($0) }
    }

    // Retention pass: commit the shown-first of unrelated Han samples into the same user directory.
    @MainActor static func retain(_ index: Int, corpus: Corpus, engine: IFEngine) throws -> Int {
        let sample = corpus.samples[index]
        let pool = (corpus.samples[(index + 1)...] + corpus.samples[..<index])
            .filter { $0.target != sample.target && isHan($0.target) }
        var made = 0
        for other in pool.prefix(corpus.retentionCommits) {
            engine.clear()
            engine.setPrecedingText("")
            for byte in other.input.utf8 {
                let modifiers: Int32 = (65...90).contains(byte) ? 1 : 0
                try require(engine.key(Int32(byte), modifiers: modifiers), "Unhandled key in \(other.id)")
                try require(engine.takeCommit().isEmpty, "Unexpected early commit in \(other.id)")
            }
            engine.select(0)
            try require(!engine.takeCommit().isEmpty && engine.snapshot().preedit.isEmpty,
                        "Retention commit did not consume complete input: \(other.id)")
            engine.clear()
            made += 1
        }
        return made
    }

    // Beneficial effort: selections after which the target is first shown-first; nil when never within the recipe.
    static func eb(_ result: Result) -> Int? {
        if result.initial.targetRank == 1 { return 0 }
        if let index = result.training.firstIndex(where: { $0.targetRank == 1 }) { return index + 1 }
        return result.learned.targetRank == 1 ? result.trainingCommits : nil
    }

    static func rank(_ observation: Observation) -> String {
        observation.targetRank.map(String.init) ?? "-"
    }

    static func line(_ result: Result) -> String {
        let steps = (0..<4).map { index in index < result.training.count ? rank(result.training[index]) : "-" }
        let eb = eb(result).map(String.init) ?? "unlearned"
        let utility = result.learned.targetRank == 1 ? (result.retained.targetRank == 1 ? "1" : "0") : "unavailable"
        return "\(result.sample.id): cold \(rank(result.initial)) → \(steps.joined(separator: " → ")) → "
            + "learned \(rank(result.learned)) → retained \(rank(result.retained)); Eb \(eb); U \(utility)"
    }

    // Learning curve over the corpus. Eb, U and ER are derived here and never stored in the baseline.
    static func summary(_ results: [Result]) -> String {
        let histogram = ((0...5).map { value in "\(value): \(results.filter { eb($0) == value }.count)" }
            + ["unlearned: \(results.filter { eb($0) == nil }.count)"]).joined(separator: ", ")
        func utility(_ group: [Result]) -> String {
            let reached = group.filter { $0.learned.targetRank == 1 }
            return "\(reached.filter { $0.retained.targetRank == 1 }.count)/\(reached.count)"
        }
        var categories: [String] = []
        for result in results where !categories.contains(result.sample.category) {
            categories.append(result.sample.category)
        }
        let perCategory = categories.map { category in
            "\(category) \(utility(results.filter { $0.sample.category == category }))"
        }.joined(separator: ", ")
        let chinese = results.filter { isHan($0.sample.target) }
        let fixed = results.filter { $0.initial.targetRank != 1 && $0.learned.targetRank == 1 }.count
        let broken = results.filter { $0.initial.targetRank == 1 && $0.learned.targetRank != 1 }.count
        let ratio = fixed == 0 ? "unavailable" : String(format: "%.2f", Double(broken) / Double(fixed))
        return "Learning curve: Eb {\(histogram)}; U = \(utility(chinese)) (Chinese), \(utility(results)) (all); "
            + "U by category \(perCategory); fixed \(fixed), broken \(broken), ER \(ratio)"
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
        try require(corpus.formatVersion == 2 && corpus.learningSelections > 0 && corpus.retentionCommits > 0
                    && corpus.candidateCount == 9 && corpus.pageLimit > 0,
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
        let contextIndex = shared.appendingPathComponent(IFDictionaryCatalog.contextIndexFilename)
        for (index, sample) in corpus.samples.enumerated() {
            let user = scratch.appendingPathComponent(sample.id)
            try require(!FileManager.default.fileExists(atPath: user.path), "User state must start absent: \(sample.id)")
            let configuration = IFEngineConfiguration(shared: shared, cache: cache, user: user.path, contextIndex: contextIndex)
            try IFEngine.start(configuration)
            let initial: Observation
            var trainingCommits = 0
            var training: [Observation] = []
            do {
                let session = try engine()
                initial = try observe(sample, engine: session, pageLimit: corpus.pageLimit)
                if initial.committedText != nil {
                    trainingCommits = 1
                    for _ in 1..<corpus.learningSelections {
                        let repeated = try observe(sample, engine: session, pageLimit: corpus.pageLimit)
                        try require(repeated.committedText == sample.target,
                                    "Learning target disappeared: \(sample.id)")
                        training.append(repeated)
                        trainingCommits += 1
                    }
                }
            }
            IFEngine.stop()
            try IFEngine.start(configuration)
            let learned: Observation
            let retentionCommits: Int
            let retained: Observation
            do {
                let session = try engine()
                learned = try observe(sample, engine: session, pageLimit: corpus.pageLimit)
                retentionCommits = try retain(index, corpus: corpus, engine: session)
                retained = try observe(sample, engine: session, pageLimit: corpus.pageLimit)
            }
            IFEngine.stop()
            let result = Result(sample: sample, initial: initial, trainingCommits: trainingCommits, training: training,
                                learned: learned, retentionCommits: retentionCommits, retained: retained)
            results.append(result)
            print(line(result))
        }
        print(summary(results))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("macOS/Info.plist")), format: nil) as! [String: Any]
        var provenance = ["sourceRevision": args[6], "appVersion": plist["CFBundleShortVersionString"] as! String,
                          "fixtureSHA256": try digest(fixture), "resourcesSHA256": try treeDigest(shared),
                          "compiledResourcesSHA256": try treeDigest(cache),
                          "runnerBinarySHA256": try digest(URL(fileURLWithPath: args[0])),
                          "librimeSHA256": try digest(root.appendingPathComponent("build/portable/prefix/lib/librime.1.17.0.dylib")),
                          "system": ProcessInfo.processInfo.operatingSystemVersionString]
        for path in ["Core/Sources", "schemas", "Core/config", "Core/Data"] {
            provenance[path + "SHA256"] = try treeDigest(root.appendingPathComponent(path))
        }
        provenance["runnerSHA256"] = try digest(root.appendingPathComponent("Core/Tests/QualityBaseline/QualityBaseline.swift"))
        for path in ["Core/Package.swift", "Core/scripts/swift-package.sh", "Core/scripts/test-quality-baseline.sh", "macOS/scripts/dependencies.sh", "Core/scripts/prepare-rime.sh"] {
            provenance[path + "SHA256"] = try digest(root.appendingPathComponent(path))
        }
        let report = Report(formatVersion: 2, provenance: provenance,
                            inputOptions: InputPreferences().recordedValues, corpus: corpus, results: results)
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
            print("PASS fixed quality baseline: \(results.count) samples, learning curve and persisted learned states")
        }
    }
}

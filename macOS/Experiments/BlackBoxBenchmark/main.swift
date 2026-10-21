import AppKit
import Carbon
import CryptoKit
import Foundation

// Black-box benchmark driver. It types the quality corpus through any enabled input method into a plain
// text view and scores what the view reads back: R1 on T0 (= R-sent), R-char and E-kspc.
// Public API only: events go through NSApp.sendEvent inside this process, so no Accessibility grant is needed
// and nothing leaves the process. It never reads or writes quality.sqlite3, a Rime user directory or InkFlow
// preferences, and it never enables, disables or registers an input source.
// Run it through macOS/scripts/probe-blackbox-benchmark.sh from a logged-in GUI session, outside the sandbox.

let inkflowBundleID = "io.damao.inputmethod.inkflow"
let policy = "full code, one Space, read back"
let eventPath = "nsapp"
let defaultCorpus = "Core/Fixtures/QualityBaseline/corpus.json"
let driverSourcePath = "macOS/Experiments/BlackBoxBenchmark/main.swift"
let outputDirectory = "build/blackbox-benchmark"

let usage = """
Usage:
  BlackBoxBenchmark --list
  BlackBoxBenchmark --score REPORT
  BlackBoxBenchmark --input-source ID --fresh-profile yes|no --cloud off|on|unknown
      [--corpus PATH] [--output PATH] [--settle-ms 400] [--timeout-ms 3000]

--list prints the current input source and every installed source without switching.
--score recomputes the aggregates of a driver report or of Core/Fixtures/QualityBaseline/baseline.json.
A run types the corpus through the given input source and writes a report under build/blackbox-benchmark/.
"""

// MARK: Rows and scoring

struct Sample: Decodable {
    let id: String
    let category: String
    let input: String
    let target: String
}

struct CorpusFile: Decodable {
    let samples: [Sample]
}

struct Row: Codable {
    let id: String
    let category: String
    let input: String
    let target: String
    let committed: String
    let trailingSpace: Bool
    let keys: Int
    let hit: Bool
    let charAccuracy: Double
    let hanCount: Int
    let uncommitted: Bool
    let elapsedMs: Int
}

struct Kspc: Codable {
    let keys: Int
    let hanCount: Int
    let value: Double?

    // value is an explicit null where the read-back has no Han scalar: unavailable, not zero.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys, forKey: .keys)
        try container.encode(hanCount, forKey: .hanCount)
        try container.encode(value, forKey: .value)
    }
}

struct Aggregate: Codable {
    let n: Int
    let hits: Int
    let rate: Double
    let wilsonLow: Double
    let wilsonHigh: Double
    let meanCharAccuracy: Double
    let kspc: Kspc?
}

struct Aggregates: Codable {
    let overall: Aggregate
    let chinese: Aggregate
    let categories: [String: Aggregate]
}

struct State: Codable {
    let freshProfile: String
    let cloud: String
}

struct Report: Codable {
    let formatVersion: Int
    let generatedAt: String
    let inputSourceID: String
    let bundleID: String
    let inputMethodVersion: String
    let system: String
    let corpusPath: String
    let corpusSHA256: String
    let driverSHA256: String
    let policy: String
    let state: State
    let eventPath: String
    let settleMs: Int
    let timeoutMs: Int
    let rows: [Row]
    let aggregates: Aggregates
}

// The Han ranges the portable replay instrument counts (Core/Portable/src/ranking.rs is_han).
func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x30000...0x323AF:
        return true
    default:
        return false
    }
}

func isEntirelyHan(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { isHan($0) }
}

func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for (i, x) in a.enumerated() {
        var current = [i + 1]
        for (j, y) in b.enumerated() {
            let substitution = previous[j] + (x == y ? 0 : 1)
            current.append(min(substitution, previous[j + 1] + 1, current[j] + 1))
        }
        previous = current
    }
    return previous[b.count]
}

// Read-back rule: exactly one trailing U+0020 is stripped before hit, charAccuracy and hanCount.
// An input method that passes uppercase or non-pinyin letters through and then inserts the Space as a literal
// space is not a miss by policy artifact. The driver and --score apply the same rule.
func scored(_ sample: Sample, committed: String, uncommitted: Bool, elapsedMs: Int) -> Row {
    var read = committed.unicodeScalars
    let trailingSpace = read.last == " "
    if trailingSpace { read.removeLast() }
    let target = Array(sample.target.unicodeScalars)
    let distance = levenshtein(Array(read), target)
    return Row(id: sample.id, category: sample.category, input: sample.input, target: sample.target,
               committed: committed, trailingSpace: trailingSpace, keys: sample.input.utf8.count + 1,
               hit: Array(read) == target, charAccuracy: 1 - Double(distance) / Double(target.count),
               hanCount: read.filter { isHan($0) }.count, uncommitted: uncommitted, elapsedMs: elapsedMs)
}

// 95% Wilson score interval.
func wilson(_ hits: Int, _ n: Int) -> (low: Double, high: Double) {
    guard n > 0 else { return (0, 0) }
    let z = 1.96
    let total = Double(n)
    let p = Double(hits) / total
    let denominator = 1 + z * z / total
    let center = (p + z * z / (2 * total)) / denominator
    let half = z * (p * (1 - p) / total + z * z / (4 * total * total)).squareRoot() / denominator
    return (max(0, center - half), min(1, center + half))
}

func kspc(_ rows: [Row]) -> Kspc {
    let keys = rows.reduce(0) { $0 + $1.keys }
    let han = rows.reduce(0) { $0 + $1.hanCount }
    return Kspc(keys: keys, hanCount: han, value: han > 0 ? Double(keys) / Double(han) : nil)
}

// E-kspc is a ratio of sums and only exists for the Chinese series and per category, never overall.
func aggregate(_ rows: [Row], withKspc: Bool) -> Aggregate {
    let hits = rows.filter(\.hit).count
    let interval = wilson(hits, rows.count)
    let mean = rows.isEmpty ? 0 : rows.reduce(0) { $0 + $1.charAccuracy } / Double(rows.count)
    return Aggregate(n: rows.count, hits: hits, rate: rows.isEmpty ? 0 : Double(hits) / Double(rows.count),
                     wilsonLow: interval.low, wilsonHigh: interval.high, meanCharAccuracy: mean,
                     kspc: withKspc ? kspc(rows) : nil)
}

func categories(_ rows: [Row]) -> [String] {
    var seen: [String] = []
    for row in rows where !seen.contains(row.category) {
        seen.append(row.category)
    }
    return seen
}

func aggregates(_ rows: [Row]) -> Aggregates {
    var byCategory: [String: Aggregate] = [:]
    for category in categories(rows) {
        byCategory[category] = aggregate(rows.filter { $0.category == category }, withKspc: true)
    }
    return Aggregates(overall: aggregate(rows, withKspc: false),
                      chinese: aggregate(rows.filter { isEntirelyHan($0.target) }, withKspc: true),
                      categories: byCategory)
}

// MARK: Printing

func percent(_ value: Double) -> String {
    String(format: "%.1f", value * 100)
}

func decimals(_ value: Double, _ places: Int) -> String {
    String(format: "%.\(places)f", value)
}

func rateText(_ a: Aggregate) -> String {
    "\(a.hits)/\(a.n) = \(percent(a.rate))% [\(percent(a.wilsonLow)), \(percent(a.wilsonHigh))]"
}

func kspcText(_ k: Kspc?) -> String {
    guard let k, let value = k.value else { return "unavailable" }
    return "\(k.keys) / \(k.hanCount) = \(decimals(value, 2))"
}

func rowLine(_ row: Row) -> String {
    var line = "\(row.id)  \(row.category)  keys \(row.keys)  trailingSpace \(row.trailingSpace)  hit \(row.hit)  "
        + "charAccuracy \(decimals(row.charAccuracy, 3))  hanCount \(row.hanCount)"
    if row.uncommitted { line += "  uncommitted" }
    return line + "  committed \"\(row.committed)\""
}

func printAggregates(_ rows: [Row], _ all: Aggregates) {
    let misses = rows.filter { !$0.hit }.map(\.id)
    print("R1 on T0: \(rateText(all.overall))")
    print("R-sent: \(rateText(all.overall)) (one composition is one decision under this policy)")
    print("misses: \(misses.isEmpty ? "none" : misses.joined(separator: ", "))")
    print("R-char (mean): \(decimals(all.overall.meanCharAccuracy, 3))")
    print("E-kspc (Chinese series): \(kspcText(all.chinese.kspc))")
    print("Chinese series: hits \(rateText(all.chinese)), R-char \(decimals(all.chinese.meanCharAccuracy, 3))")
    print("By category:")
    for category in categories(rows) {
        guard let bucket = all.categories[category] else { continue }
        print("  \(category) \(rateText(bucket)), R-char \(decimals(bucket.meanCharAccuracy, 3)), "
              + "E-kspc \(kspcText(bucket.kspc))")
    }
    print("Every bucket is under 200 units: intervals only, no verdict.")
}

// MARK: Process exit and input source

var originalSource: TISInputSource?
var signalSources: [DispatchSourceSignal] = []

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func flagProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let raw = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
}

func currentSource() -> TISInputSource? {
    TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
}

func installedSources() -> [TISInputSource] {
    (TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

// Selects the remembered source again when something else is current. Safe to call any number of times:
// it does nothing when the driver never switched.
func restoreInputSource() {
    guard let original = originalSource else { return }
    guard let current = currentSource() else { return }
    let wanted = stringProperty(original, kTISPropertyInputSourceID)
    if stringProperty(current, kTISPropertyInputSourceID) == wanted { return }
    let status = TISSelectInputSource(original)
    if status != noErr {
        fputs("warning: could not restore the input source \(wanted ?? "?") (status \(status))\n", stderr)
    }
}

// Every exit goes through here: normal, refusal, error, SIGINT and SIGTERM.
func finish(_ code: Int32) -> Never {
    restoreInputSource()
    exit(code)
}

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    fputs("error: \(message)\n", stderr)
    finish(code)
}

func installSignalHandlers() {
    signal(SIGPIPE, SIG_IGN)
    atexit { restoreInputSource() }
    for (number, code) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143))] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            fputs("interrupted; restoring the input source\n", stderr)
            finish(code)
        }
        source.resume()
        signalSources.append(source)
    }
}

func listSources() {
    let current = currentSource().flatMap { stringProperty($0, kTISPropertyInputSourceID) } ?? "unknown"
    print("current input source: \(current)")
    for source in installedSources() {
        let id = stringProperty(source, kTISPropertyInputSourceID) ?? "?"
        let bundle = stringProperty(source, kTISPropertyBundleID) ?? "-"
        let enabled = flagProperty(source, kTISPropertyInputSourceIsEnabled) ? "yes" : "no"
        let selectable = flagProperty(source, kTISPropertyInputSourceIsSelectCapable) ? "yes" : "no"
        print("\(id)  bundle=\(bundle)  enabled=\(enabled)  selectable=\(selectable)")
    }
}

// MARK: Score mode

struct StoredRow: Decodable {
    let id: String
    let category: String
    let input: String
    let target: String
    let committed: String
    let uncommitted: Bool?
    let elapsedMs: Int?
}

struct BaselineFirst: Decodable {
    let first: String
}

struct BaselineResult: Decodable {
    let sample: Sample
    let initial: BaselineFirst
}

struct StoredReport: Decodable {
    let rows: [StoredRow]?
    let results: [BaselineResult]?
}

// A driver report scores its stored committed text; baseline.json scores the shown-first of the cold
// observation, which is what one Space would commit.
func rowsForScoring(_ path: String) -> [Row] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    guard let report = try? JSONDecoder().decode(StoredReport.self, from: data) else {
        fail("\(path) is not a driver report or a quality baseline")
    }
    if let stored = report.rows {
        return stored.map {
            let sample = Sample(id: $0.id, category: $0.category, input: $0.input, target: $0.target)
            return scored(sample, committed: $0.committed, uncommitted: $0.uncommitted ?? false,
                          elapsedMs: $0.elapsedMs ?? 0)
        }
    }
    if let results = report.results {
        return results.map { scored($0.sample, committed: $0.initial.first, uncommitted: false, elapsedMs: 0) }
    }
    fail("\(path) has neither rows nor results")
}

func scoreFile(_ path: String) {
    let rows = rowsForScoring(path)
    if rows.contains(where: { $0.target.isEmpty }) { fail("\(path) has a sample with an empty target") }
    print("scoring \(rows.count) samples from \(path)")
    for row in rows {
        print(rowLine(row))
    }
    printAggregates(rows, aggregates(rows))
}

// MARK: Typing

let usKeyCodes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]
let spaceKeyCode: UInt16 = 49
let escapeKeyCode: UInt16 = 53

// Lets the run loop deliver input-method callbacks and signal handlers.
func pump(_ seconds: TimeInterval) {
    if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: seconds)) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

func secondsSince(_ start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
}

func send(_ text: String, code: UInt16, shift: Bool, window: NSWindow) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? [.shift] : [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: text,
                                     charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
        if let event { NSApp.sendEvent(event) }
        pump(0)
    }
}

func makeWindow() -> (window: NSWindow, textView: NSTextView) {
    let scroll = NSTextView.scrollableTextView()
    guard let textView = scroll.documentView as? NSTextView else { fail("cannot create the text view", 1) }
    textView.isRichText = false
    textView.allowsUndo = false
    textView.font = NSFont.systemFont(ofSize: 18)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.smartInsertDeleteEnabled = false
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.title = "InkFlow black-box benchmark"
    window.contentView = scroll
    window.center()
    return (window, textView)
}

func resetView(_ textView: NSTextView, _ window: NSWindow) {
    if textView.hasMarkedText() {
        send("\u{1B}", code: escapeKeyCode, shift: false, window: window)
        pump(0.1)
    }
    textView.inputContext?.discardMarkedText()
    textView.string = ""
    window.makeFirstResponder(textView)
    pump(0.1)
}

// Types one sample: the full code, then one Space. Reads the view once it has not changed for settleMs
// and holds no marked text, or at timeoutMs: then Escape discards what is still composing, the text that
// remains is read and the row is flagged uncommitted.
func typeSample(_ sample: Sample, textView: NSTextView, window: NSWindow, settleMs: Int, timeoutMs: Int) -> Row {
    resetView(textView, window)
    let start = DispatchTime.now()
    for character in sample.input {
        let lower = Character(character.lowercased())
        guard let code = usKeyCodes[lower] else { fail("no US key code for \(character) in \(sample.id)") }
        send(String(character), code: code, shift: character.isUppercase, window: window)
    }
    send(" ", code: spaceKeyCode, shift: false, window: window)
    let spaceSent = DispatchTime.now()
    var last = textView.string
    var changedAt = spaceSent
    var committed = ""
    var uncommitted = false
    while true {
        pump(0.01)
        let current = textView.string
        if current != last {
            last = current
            changedAt = DispatchTime.now()
        }
        if secondsSince(changedAt) * 1000 >= Double(settleMs) && !textView.hasMarkedText() {
            committed = current
            break
        }
        if secondsSince(spaceSent) * 1000 >= Double(timeoutMs) {
            send("\u{1B}", code: escapeKeyCode, shift: false, window: window)
            pump(0.1)
            textView.inputContext?.discardMarkedText()
            committed = textView.string
            uncommitted = true
            break
        }
    }
    let elapsed = Int((secondsSince(start) * 1000).rounded())
    return scored(sample, committed: committed, uncommitted: uncommitted, elapsedMs: elapsed)
}

// MARK: Run mode

struct Options {
    var list = false
    var score: String?
    var inputSource: String?
    var freshProfile: String?
    var cloud: String?
    var corpus = defaultCorpus
    var output: String?
    var settleMs = 400
    var timeoutMs = 3000
}

func usageError(_ message: String) -> Never {
    fputs("error: \(message)\n\(usage)\n", stderr)
    finish(2)
}

func parseArguments() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst()
    func value(_ flag: String) -> String {
        guard let next = arguments.popFirst() else { usageError("\(flag) needs a value") }
        return next
    }
    func number(_ flag: String) -> Int {
        guard let parsed = Int(value(flag)), parsed > 0 else { usageError("\(flag) needs a positive integer") }
        return parsed
    }
    while let flag = arguments.popFirst() {
        switch flag {
        case "--list": options.list = true
        case "--score": options.score = value(flag)
        case "--input-source": options.inputSource = value(flag)
        case "--fresh-profile": options.freshProfile = value(flag)
        case "--cloud": options.cloud = value(flag)
        case "--corpus": options.corpus = value(flag)
        case "--output": options.output = value(flag)
        case "--settle-ms": options.settleMs = number(flag)
        case "--timeout-ms": options.timeoutMs = number(flag)
        case "--help", "-h":
            print(usage)
            finish(0)
        default: usageError("unknown argument \(flag)")
        }
    }
    return options
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func inputMethodVersion(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
          let bundle = Bundle(url: url) else { return "unknown" }
    let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (short, build) {
    case let (short?, build?): return "\(short) (\(build))"
    case let (short?, nil): return short
    case let (nil, build?): return build
    default: return "unknown"
    }
}

func defaultOutputPath(_ inputSource: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let safe = String(inputSource.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    return "\(outputDirectory)/\(safe)-\(formatter.string(from: Date())).json"
}

func runBenchmark(_ options: Options) -> Never {
    guard let inputSource = options.inputSource else { usageError("--input-source is required") }
    guard let freshProfile = options.freshProfile, ["yes", "no"].contains(freshProfile) else {
        usageError("--fresh-profile yes|no is required")
    }
    guard let cloud = options.cloud, ["off", "on", "unknown"].contains(cloud) else {
        usageError("--cloud off|on|unknown is required")
    }
    // The installed InkFlow would learn every sample into the live user dictionary and write synthetic
    // decisions into quality.sqlite3; the white-box runner is InkFlow's number. Refused before any input
    // source is read.
    if inputSource.hasPrefix(inkflowBundleID) {
        fail("refusing \(inputSource): this driver never types through InkFlow (\(inkflowBundleID))")
    }
    guard let corpusData = FileManager.default.contents(atPath: options.corpus),
          let corpus = try? JSONDecoder().decode(CorpusFile.self, from: corpusData) else {
        fail("cannot read the corpus \(options.corpus)")
    }
    guard !corpus.samples.isEmpty, !corpus.samples.contains(where: { $0.target.isEmpty || $0.input.isEmpty }) else {
        fail("the corpus has no samples or an empty input or target")
    }
    guard let driverData = FileManager.default.contents(atPath: driverSourcePath) else {
        fail("cannot read \(driverSourcePath); run from the repository root so the report can name the driver")
    }
    originalSource = currentSource()
    guard let source = installedSources().first(where: {
        stringProperty($0, kTISPropertyInputSourceID) == inputSource
    }) else {
        fail("input source \(inputSource) is not installed; see --list")
    }
    let bundleID = stringProperty(source, kTISPropertyBundleID) ?? "unknown"
    if bundleID == inkflowBundleID {
        fail("refusing \(inputSource): this driver never types through InkFlow (\(inkflowBundleID))")
    }
    let enableHint = "enable it by hand in System Settings > Keyboard > Text Input > Input Sources; "
        + "this driver never enables, disables or registers an input source"
    guard flagProperty(source, kTISPropertyInputSourceIsEnabled) else {
        fail("input source \(inputSource) is not enabled; \(enableHint)")
    }
    guard flagProperty(source, kTISPropertyInputSourceIsSelectCapable) else {
        fail("input source \(inputSource) is not select-capable; \(enableHint)")
    }
    installSignalHandlers()
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.finishLaunching()
    let (window, textView) = makeWindow()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)
    application.activate()
    pump(0.5)
    let status = TISSelectInputSource(source)
    guard status == noErr else { fail("TISSelectInputSource failed (status \(status))", 1) }
    pump(0.5)
    let selected = currentSource().flatMap { stringProperty($0, kTISPropertyInputSourceID) }
    guard selected == inputSource else {
        fail("the input source switch did not take effect (current: \(selected ?? "unknown"))", 1)
    }
    print("typing \(corpus.samples.count) samples through \(inputSource) (\(bundleID))")
    var rows: [Row] = []
    for sample in corpus.samples {
        let row = typeSample(sample, textView: textView, window: window,
                             settleMs: options.settleMs, timeoutMs: options.timeoutMs)
        rows.append(row)
        print(rowLine(row))
    }
    restoreInputSource()
    window.orderOut(nil)
    let all = aggregates(rows)
    let report = Report(formatVersion: 1, generatedAt: ISO8601DateFormatter().string(from: Date()),
                        inputSourceID: inputSource, bundleID: bundleID,
                        inputMethodVersion: inputMethodVersion(bundleID),
                        system: ProcessInfo.processInfo.operatingSystemVersionString,
                        corpusPath: options.corpus, corpusSHA256: sha256(corpusData),
                        driverSHA256: sha256(driverData), policy: policy,
                        state: State(freshProfile: freshProfile, cloud: cloud), eventPath: eventPath,
                        settleMs: options.settleMs, timeoutMs: options.timeoutMs, rows: rows, aggregates: all)
    let path = options.output ?? defaultOutputPath(inputSource)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        fail("cannot write the report \(path): \(error)", 1)
    }
    printAggregates(rows, all)
    print("report: \(path)")
    finish(0)
}

// MARK: Entry

let options = parseArguments()
if options.list {
    listSources()
    finish(0)
}
if let path = options.score {
    scoreFile(path)
    finish(0)
}
runBenchmark(options)

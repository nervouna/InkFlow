import AppKit
import InputMethodKit

@MainActor
private final class RuntimeFixture {
    let isolated = IsolatedSettings()
    let service = DelayedAIService()
    let client = NSObject()
    var state: AISuggestionState?
    var content = AISurroundingContext(precedingText: "前文😀", followingText: "后文", precedingAvailable: true, followingAvailable: true)
    var reads = 0
    var shown: String?
    var readHook: (() -> Void)?
    var stateHook: (() -> Void)?
    var contextAvailable = true
    var presentationAvailable = true
    let statistics: AIStatisticsStore?
    var compositionID = "composition-A"
    var associationHook: (() -> Void)?
    var associationReads = 0
    lazy var coordinator = AISuggestionCoordinator(settings: isolated.settings.smart, service: service,
        statisticsStore: statistics,
        statisticsAssociation: { [weak self] in
            self?.associationReads += 1; self?.associationHook?()
            return .init(compositionID: self?.compositionID, candidates: ["你好吗"], candidatePage: 0)
        },
        current: { [weak self] in self?.stateHook?(); return self?.state }, context: { [weak self] anchor in
            guard let self, self.state?.anchor == anchor else { return nil }
            self.reads += 1; self.readHook?(); return self.contextAvailable ? self.content : nil
        }, present: { [weak self] text in
            guard let self, self.presentationAvailable else { return false }
            self.shown = text; return true
        },
        visible: { [weak self] in self?.shown != nil }, hide: { [weak self] in self?.shown = nil })

    init(statistics: AIStatisticsStore? = nil) throws {
        self.statistics = statistics
        try isolated.settings.smart.save(baseURL: "https://example.invalid", apiKey: "synthetic", model: "fixture")
        isolated.settings.smart.isEnabled = true
        setInput("nihao")
    }
    func setInput(_ input: String, length: Int? = nil) {
        let count = length ?? input.utf16.count
        state = AISuggestionState(input: AIInputIdentity(rawInput: input, caret: input.count, selectedPrefix: ""),
            anchor: AIClientAnchor(client: ObjectIdentifier(client), mark: NSRange(location: 4, length: count),
                                   selection: NSRange(location: 4 + count, length: 0)))
    }
    func stop() { coordinator.invalidate(); isolated.cleanup() }
}

@main
struct AIRuntimeTests {
    @MainActor static func verify(_ condition: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { check(condition, message, file: file, line: line) }
    @MainActor static func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let diagnostics = AIDiagnosticCapture()
        try await AIDiagnostics.$observe.withValue({ diagnostics.append($0) }) {
            contextChecks()
            try await debounceChecks()
            try await invalidationChecks()
            try await reentrantChecks()
            try await statisticsChecks()
        }
        for event in [AIDiagnosticEvent.scheduled, .dispatched, .shown, .adoptionRequested, .cancelled, .failed, .discarded, .invalidated] {
            verify(diagnostics.contains(event), "Every request lifecycle outcome is observable")
        }
        for reason in [AIDiagnosticReason.secureInput, .unownedMark, .invalidMark, .selectionOutsideMark] {
            verify(diagnostics.contains(.anchorRejected, reason: reason), "Anchor rejection includes its concrete reason")
        }
        verify(diagnostics.contains(.contextCaptured, reason: .documentShorterThanMark))
        verify(diagnostics.contains(.discarded, reason: .staleState))
        verify(diagnostics.contains(.discarded, reason: .contextUnavailable) && diagnostics.contains(.discarded, reason: .presentation))
        let lifecycle = diagnostics.records.filter { [.scheduled, .dispatched, .shown, .adoptionRequested, .cancelled, .failed, .discarded, .invalidated].contains($0.event) }
        verify(lifecycle.allSatisfy { $0.attempt != nil && $0.session != nil }, "Attempt and session survive async and acceptance paths")
        let adoption = lifecycle.first { $0.event == .adoptionRequested }!.attempt
        for event in [AIDiagnosticEvent.scheduled, .dispatched, .shown] {
            verify(lifecycle.contains { $0.attempt == adoption && $0.event == event }, "One logical request is correlated through the adoption command")
        }
        verify(!diagnostics.contains(.insertionIssued) && !diagnostics.contains(.insertionReturned),
               "Consuming a coordinator preview alone does not claim delivery to an editor")
        verify(diagnostics.excludes(["example.invalid", "synthetic", "fixture", "nihao", "前文", "后文", "你好"]), "Runtime records omit all content and configuration values")
        print("PASS AI diagnostics runtime pid=\(ProcessInfo.processInfo.processIdentifier)")
        print("PASS AI runtime: bounded Unicode context captured once, actual 0.5s debounce, navigation, stale results, errors, repeat sessions and reentrant reads")
    }

    @MainActor static func statisticsChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkflow-ai-runtime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = AIStatisticsTestDatabase(url: root.appendingPathComponent("ai-statistics.sqlite3"))
        let rule = AIPriceRule(id: "synthetic", provider: "https://example.invalid", model: "fixture", currency: "USD", inputPerMillion: 2, cachedInputPerMillion: Decimal(string: "0.2"), outputPerMillion: 4)
        let store = AIStatisticsStore(url: db.url, pricing: .init(version: 1, rules: [rule]))
        let fixture = try RuntimeFixture(statistics: store)
        await fixture.service.setStatisticsMetadata(.parse(Data(#"{"usage":{"prompt_tokens":250,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":100},"completion_tokens_details":{"reasoning_tokens":10}}}"#.utf8)))
        fixture.coordinator.synchronize(); await wait(0.56)
        fixture.compositionID = "composition-B"; fixture.setInput("nihaoma")
        fixture.coordinator.synchronize(); await wait(0.56)
        verify(await fixture.service.count() == 2)
        await fixture.service.resolve(1); await wait(0.03)
        fixture.coordinator.validate(); fixture.coordinator.validate()
        let adoption = fixture.coordinator.takeSuggestion()
        verify(adoption != nil && fixture.coordinator.takeSuggestion() == nil)
        await fixture.service.resolve(0); await wait(0.03)
        fixture.stop(); await store.close()
        let attempts = db.rows("SELECT * FROM attempts ORDER BY scheduled_at")
        verify(attempts.count == 2 && attempts.allSatisfy { $0["estimated_cost"] == "0.00052" }, "Both overlapping attempts retain late independently observed costs")
        verify(attempts[0]["composition_id"] == "composition-A" && attempts[0]["dispatch_composition_id"] == "composition-A" && attempts[1]["dispatch_composition_id"] == "composition-B", "Async responses never query a later composition")
        verify(db.rows("SELECT * FROM attempt_events WHERE kind='shown'").count == 1 && db.rows("SELECT * FROM attempt_events WHERE kind='adoptionRequested'").count == 1, "Refresh and repeated Tab do not add exposure/adoption")
        verify(db.rows("SELECT * FROM attempt_events WHERE kind='insertionIssued'").isEmpty, "Coordinator consumption never claims editor insertion")
        verify(db.rows("SELECT * FROM samples WHERE response_text IS NOT NULL").count == 2, "Undisplayed and adopted recommendations are retained independently")
        for phase in [1, 2] {
            let reentrantDB = AIStatisticsTestDatabase(url: root.appendingPathComponent("reentrant-\(phase).sqlite3"))
            let reentrantStore = AIStatisticsStore(url: reentrantDB.url)
            let reentrant = try RuntimeFixture(statistics: reentrantStore)
            reentrant.associationHook = {
                guard reentrant.associationReads == phase else { return }
                reentrant.associationHook = nil
                reentrant.compositionID = "composition-B"; reentrant.setInput("nihaoma")
                reentrant.coordinator.synchronize()
            }
            reentrant.coordinator.synchronize(); await wait(1.1)
            verify(await reentrant.service.count() == 1, "Reentrant association cannot dispatch stale input")
            await reentrant.service.resolve(0); await wait(0.03)
            verify(reentrant.coordinator.takeSuggestion() != nil)
            reentrant.stop(); await reentrantStore.close()
            let rows = reentrantDB.rows("SELECT * FROM attempts WHERE dispatch_composition_id IS NOT NULL")
            verify(rows.count == 1 && rows[0]["composition_id"] == "composition-B" && rows[0]["dispatch_composition_id"] == "composition-B", "Scheduling/dispatch association cannot overwrite a newer handle")
            verify(reentrantDB.rows("SELECT * FROM attempt_events e JOIN attempts a ON a.id=e.attempt_id WHERE a.dispatch_composition_id IS NULL AND e.kind='serviceFailed'").isEmpty, "Cancelled debounce is not a service invocation failure")
        }
        print("PASS AI statistics coordinator: overlapping original associations, late costs, unshown results and exact-once first display/adoption")
    }

    @MainActor static func contextChecks() {
        let client = RecordingClient(document: "前😀nihao后😀文")
        client.mark = NSRange(location: 3, length: 5); client.selection = NSRange(location: 8, length: 0)
        func read() -> AISurroundingContext? {
            guard let anchor = AIClientAnchor.read(client, ownsMarkedText: true, secureInput: false) else { return nil }
            return AISurroundingContext.read(client, anchor: anchor)
        }
        verify(read()?.precedingText == "前😀" && read()?.followingText == "后😀文")
        verify(client.requests.allSatisfy { NSMaxRange($0) <= client.document!.utf16.count }, "Never overshoot known document end")
        client.updatesActualRange = false
        verify(read()?.followingText == "后😀文", "Client need not update an exact actualRange")
        client.document = "前😀nihao"; client.requests.removeAll()
        verify(read()?.followingText == "" && client.requests.count == 1, "Document end needs no suffix request")
        client.contextAvailable = false
        verify(read()?.precedingText == "" && read()?.precedingAvailable == false, "Unavailable context permits empty input")
        client.contextAvailable = true
        let count = client.requests.count
        verify(AIClientAnchor.read(client, ownsMarkedText: true, secureInput: true) == nil)
        verify(AIClientAnchor.read(client, ownsMarkedText: false, secureInput: false) == nil)
        verify(client.requests.count == count, "Secure and foreign marks never request document text")
        client.selection = NSRange(location: 0, length: 0); verify(read() == nil)
        client.mark = NSRange(location: NSNotFound, length: 0); verify(read() == nil)
        client.mark = NSRange(location: Int.max - 1, length: 1)
        client.selection = NSRange(location: Int.max - 1, length: 0)
        client.reportedLength = NSNotFound
        verify(read() == nil, "Untrusted extreme ranges must suppress without overflow")
        client.mark = NSRange(location: 3, length: 5); client.selection = NSRange(location: 8, length: 0)
        for length in [0, 4, -1] {
            client.reportedLength = length
            let result = read()
            verify(result?.precedingText == "前😀" && result?.followingAvailable == false,
                   "Short or negative advisory length keeps available text and permits an empty suffix")
        }
        client.reportedLength = NSNotFound
        verify(read()?.precedingText == "前😀", "Unknown length still permits bounded available text")

        let bounded = RecordingClient(document: String(repeating: "前", count: 270) + "nihao" + String(repeating: "后", count: 270))
        bounded.mark = NSRange(location: 270, length: 5); bounded.selection = NSRange(location: 275, length: 0)
        let anchor = AIClientAnchor.read(bounded, ownsMarkedText: true, secureInput: false)!
        let result = AISurroundingContext.read(bounded, anchor: anchor)!
        verify(result.precedingText.count == 256 && result.followingText.count == 256)
        let character = "👨‍👩‍👧‍👦"
        bounded.substringResponse = { request in
            if request.location < 270 { return ("省略" + String(repeating: character, count: 256), request) }
            return (String(repeating: character, count: 256) + "省略", request)
        }
        let expanded = AISurroundingContext.read(bounded, anchor: anchor)!
        verify(expanded.precedingText == String(repeating: character, count: 256) &&
               expanded.followingText == String(repeating: character, count: 256),
               "Longer Unicode client text stays bounded without splitting extended graphemes")
        bounded.substringResponse = { request in ("😀", request) }
        let shorter = AISurroundingContext.read(bounded, anchor: anchor)!
        verify(shorter.precedingText == "😀" && shorter.followingText == "😀", "Shorter returned Unicode text remains useful context")
        print("PASS AI context: both sides/end bounds, advisory length fallback, missing/secure/foreign/moved clients and character-safe limits")
    }

    @MainActor static func debounceChecks() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.stop() }
        fixture.coordinator.synchronize()
        await wait(0.27)
        verify(await fixture.service.count() == 0, "No paid request before 0.5s")
        fixture.coordinator.validate()
        fixture.setInput("nihao", length: 6) // Rime's display mark changes while raw input is identical.
        fixture.coordinator.synchronize(ownedRefresh: true)
        await wait(0.30)
        verify(await fixture.service.count() == 1, "Navigation mark update must retain original deadline")
        verify(fixture.reads == 1, "Position tracking reads no document context")
        fixture.coordinator.validate(); fixture.setInput("nihao", length: 7)
        fixture.coordinator.synchronize(ownedRefresh: true)
        await fixture.service.resolve(0); await wait(0.05)
        verify(fixture.shown == "你好", "In-flight result binds to the latest owned display mark")
        fixture.coordinator.validate(); fixture.setInput("nihao", length: 5)
        fixture.coordinator.synchronize(ownedRefresh: true)
        await wait(0.55)
        verify(await fixture.service.count() == 1 && fixture.shown != nil, "Paging a visible suggestion never repeats inference")
        let adoption = fixture.coordinator.takeSuggestion()
        verify(adoption?.text == "你好" && adoption?.attempt != nil, "Adoption retains request identity after coordinator invalidation")
        verify(fixture.coordinator.takeSuggestion() == nil, "Acceptance consumes eligibility exactly once")
        verify(fixture.reads == 1, "Response, navigation and Tab do not recapture request context")

        fixture.setInput("ni"); fixture.coordinator.synchronize(); await wait(0.30)
        fixture.setInput("nihao"); fixture.coordinator.synchronize(); await wait(0.26)
        verify(await fixture.service.count() == 1, "Actual input edits reset the deadline")
        await wait(0.28); verify(await fixture.service.count() == 2)
        fixture.coordinator.invalidate(); fixture.coordinator.synchronize(); await wait(0.54)
        verify(await fixture.service.count() == 3, "Identical retyping after a ended composition gets a fresh request")
        await fixture.service.resolve(1); await wait(0.03); verify(fixture.shown == nil)
        await fixture.service.resolve(2); await wait(0.03); verify(fixture.shown != nil)

        let nested = try RuntimeFixture(); defer { nested.stop() }
        nested.coordinator.synchronize(); await wait(0.28)
        nested.coordinator.beginRefresh(); nested.setInput("nihao", length: 6)
        await wait(0.28)
        verify(await nested.service.count() == 0, "Nested client run loop cannot dispatch from a transient owned mark")
        nested.coordinator.endRefresh(); await wait(0.03)
        verify(await nested.service.count() == 1, "Expired deadline resumes immediately after the owned refresh")
        nested.coordinator.beginRefresh(); nested.setInput("nihao", length: 7)
        await nested.service.resolve(0); await wait(0.03)
        verify(nested.shown == nil, "Response waits for an in-progress owned refresh")
        nested.coordinator.endRefresh(); await wait(0.03)
        verify(nested.shown != nil)
    }

    @MainActor static func invalidationChecks() async throws {
        for action in ["input", "client", "selection", "configuration", "off", "lifecycle", "hidden", "secure"] {
            let fixture = try RuntimeFixture(); defer { fixture.stop() }
            fixture.coordinator.synchronize(); await wait(0.54)
            verify(await fixture.service.count() == 1)
            switch action {
            case "input": fixture.setInput("nihaoma")
            case "client":
                let old = fixture.state!
                fixture.state = AISuggestionState(input: old.input, anchor: AIClientAnchor(client: ObjectIdentifier(NSApp), mark: old.anchor.mark, selection: old.anchor.selection))
            case "selection":
                let old = fixture.state!
                fixture.state = AISuggestionState(input: old.input, anchor: AIClientAnchor(client: old.anchor.client, mark: old.anchor.mark, selection: NSRange(location: 4, length: 0)))
            case "configuration": try fixture.isolated.settings.smart.save(baseURL: "https://changed.invalid", apiKey: "synthetic", model: "fixture")
            case "off": fixture.isolated.settings.smart.isEnabled = false
            case "lifecycle": fixture.coordinator.invalidate()
            default: fixture.state = nil
            }
            await fixture.service.resolve(0); await wait(0.03)
            verify(fixture.shown == nil && fixture.coordinator.takeSuggestion() == nil, "Late result rejected after \(action)")
        }
        let failure = try RuntimeFixture(); defer { failure.stop() }
        failure.coordinator.synchronize(); await wait(0.54)
        await failure.service.resolve(0, .failure(AIServiceError.httpStatus(401))); await wait(0.03)
        verify(failure.isolated.settings.smart.requestError?.contains("401") == true && failure.shown == nil)
        failure.coordinator.synchronize(); await wait(0.54)
        verify(await failure.service.count() == 1, "Failure has no automatic paid retry")
    }

    @MainActor static func reentrantChecks() async throws {
        let dispatch = try RuntimeFixture(); defer { dispatch.stop() }
        dispatch.readHook = { dispatch.isolated.settings.smart.isEnabled = false }
        dispatch.coordinator.synchronize(); await wait(0.55)
        verify(await dispatch.service.count() == 0, "A context read disabling AI must not dispatch")
        let acceptance = try RuntimeFixture(); defer { acceptance.stop() }
        acceptance.coordinator.synchronize(); await wait(0.54)
        await acceptance.service.resolve(0); await wait(0.03)
        verify(acceptance.shown != nil)
        acceptance.stateHook = { acceptance.coordinator.invalidate() }
        verify(acceptance.coordinator.takeSuggestion() == nil, "Reentrant state getter invalidation prevents acceptance")

        let missingContext = try RuntimeFixture(); defer { missingContext.stop() }
        missingContext.contextAvailable = false
        missingContext.coordinator.synchronize(); await wait(0.55)
        verify(await missingContext.service.count() == 0, "Unreadable anchor prevents dispatch with a terminal diagnostic")

        let missingPanel = try RuntimeFixture(); defer { missingPanel.stop() }
        missingPanel.presentationAvailable = false
        missingPanel.coordinator.synchronize(); await wait(0.54)
        await missingPanel.service.resolve(0); await wait(0.03)
        verify(missingPanel.shown == nil, "Presentation failure remains a safe fallback with a diagnostic")
    }
}

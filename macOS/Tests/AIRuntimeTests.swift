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
    lazy var coordinator = AISuggestionCoordinator(settings: isolated.settings.smart, service: service,
        current: { [weak self] in self?.state }, context: { [weak self] anchor in
            guard let self, self.state?.anchor == anchor else { return nil }
            self.reads += 1; self.readHook?(); return self.content
        }, present: { [weak self] text in self?.shown = text; return true },
        visible: { [weak self] in self?.shown != nil }, hide: { [weak self] in self?.shown = nil })

    init() throws {
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
        contextChecks()
        try await debounceChecks()
        try await invalidationChecks()
        try await reentrantChecks()
        print("PASS AI runtime: two-sided UTF-16 context, actual 0.5s debounce, navigation, stale results, errors, repeat sessions and reentrant reads")
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
        client.mark = NSRange(location: Int.max - 1, length: 1)
        client.selection = NSRange(location: Int.max - 1, length: 0)
        client.reportedLength = NSNotFound
        verify(read() == nil, "Untrusted extreme ranges must suppress without overflow")
        client.mark = NSRange(location: 3, length: 5); client.selection = NSRange(location: 8, length: 0)
        client.reportedLength = 4
        verify(read() == nil, "A known document length shorter than the owned mark suppresses requests and acceptance")
        client.reportedLength = NSNotFound
        verify(read()?.precedingText == "前😀", "Unknown length still permits bounded available text")

        let bounded = RecordingClient(document: String(repeating: "前", count: 270) + "nihao" + String(repeating: "后", count: 270))
        bounded.mark = NSRange(location: 270, length: 5); bounded.selection = NSRange(location: 275, length: 0)
        let anchor = AIClientAnchor.read(bounded, ownsMarkedText: true, secureInput: false)!
        let result = AISurroundingContext.read(bounded, anchor: anchor)!
        verify(result.precedingText.count == 256 && result.followingText.count == 256)
        bounded.substringResponse = { request in
            if request.location < 270 { return ("😀" + String(repeating: "前", count: 255), NSRange(location: 13, length: 257)) }
            return (String(repeating: "后", count: 255) + "😀", NSRange(location: 275, length: 257))
        }
        let expanded = AISurroundingContext.read(bounded, anchor: anchor)!
        verify(expanded.precedingText.hasPrefix("😀") && expanded.followingText.hasSuffix("😀"), "Surrogate-safe adjusted bounds")
        bounded.substringResponse = { _ in ("😀", NSRange(location: 269, length: 2)) }
        verify(AISurroundingContext.read(bounded, anchor: anchor)?.precedingAvailable == false, "Reject a caret splitting a surrogate")
        bounded.substringResponse = { _ in ("bad", NSRange(location: Int.max - 1, length: 3)) }
        verify(AISurroundingContext.read(bounded, anchor: anchor)?.followingAvailable == false)
        print("PASS AI context: both sides/end bounds, missing/secure/foreign/moved clients, 256-unit limits and surrogate/range validation")
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
        verify(fixture.shown == "你好吗", "In-flight result binds to the latest owned display mark")
        fixture.coordinator.validate(); fixture.setInput("nihao", length: 5)
        fixture.coordinator.synchronize(ownedRefresh: true)
        await wait(0.55)
        verify(await fixture.service.count() == 1 && fixture.shown != nil, "Paging a visible suggestion never repeats inference")
        verify(fixture.coordinator.takeSuggestion()?.anchor.mark.length == 5)
        verify(fixture.coordinator.takeSuggestion() == nil, "Acceptance consumes eligibility exactly once")

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
        for action in ["input", "client", "selection", "context", "configuration", "off", "lifecycle", "hidden", "secure"] {
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
            case "context": fixture.content = AISurroundingContext(precedingText: "changed", followingText: "后文", precedingAvailable: true, followingAvailable: true)
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
        acceptance.readHook = { acceptance.coordinator.invalidate() }
        verify(acceptance.coordinator.takeSuggestion() == nil, "Reentrant context invalidation prevents acceptance")
    }
}

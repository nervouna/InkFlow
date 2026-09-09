import AppKit
@preconcurrency import InputMethodKit

@main
struct AIHeadlessPipelineTests {
    static let preceding = "输入法开发记录😀："
    static let following = "。下一项是候选排序。"

    @MainActor static func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    @MainActor static func until(_ predicate: () -> Bool, seconds: Double = 3) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate(), ContinuousClock.now < deadline { await wait(0.02) }
        check(predicate(), "Timed out waiting for production pipeline presentation")
    }

    @MainActor static func fixture(settings: IFSettings, service: any AISuggestionServing,
                                   delay: Duration = .zero, secure: @escaping () -> Bool = { false }) ->
        (InkFlowInputController, RecordingClient, HeadlessAIInputPresentation) {
        let client = RecordingClient(document: preceding + following)
        client.selection = NSRange(location: preceding.utf16.count, length: 0)
        let endpoint = HeadlessAIInputPresentation(showDelay: delay)
        let controller = InkFlowInputController(server: nil, delegate: nil, client: client,
            settings: settings, settingsWindow: IFSettingsWindowController(settings: settings),
            smartService: service, secureInput: secure, presentation: endpoint)!
        check(controller.panel == nil, "Headless mode allocates no IMK candidate windows")
        return (controller, client, endpoint)
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        // No NSApp activation, key window, event posting or global secure-input mutation.
        IFStubHeadlessControllerFramework()
        do {
            check(CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5)
            let isolated = IsolatedSettings(); defer { isolated.cleanup() }
            let settings = isolated.settings
            let live = CommandLine.arguments.count == 5
            if live {
                check(CommandLine.arguments[3] == "--live")
                check(CommandLine.arguments[4].hasPrefix("/"), "Live configuration path must be absolute")
                let configuration = try AILiveConfiguration.loadConfiguration(path: CommandLine.arguments[4])
                check(URLComponents(string: configuration.baseURL)?.host?.lowercased() == "api.deepseek.com" &&
                    configuration.model.lowercased() == "deepseek-v4-flash", "Acceptance requires its specified provider/model")
                try settings.smart.save(baseURL: configuration.baseURL, apiKey: configuration.apiKey, model: configuration.model)
            } else {
                try settings.smart.save(baseURL: "https://example.invalid", apiKey: "synthetic", model: "fixture")
            }
            settings.smart.isEnabled = true
            try IFEngine.start(shared: CommandLine.arguments[1], user: CommandLine.arguments[2], qualityStore: nil)
            defer { IFEngine.stop() }
            if CommandLine.arguments.count == 4 {
                check(CommandLine.arguments[3] == "--delayed-visibility")
                try await delayedVisibility(settings)
                print("PASS headless AI delayed visibility"); return
            }
            for value in AIHeadlessCase.effects { try await effect(value, settings: settings, live: live) }
            if !live {
                try await ordinaryControls(settings)
                try await adoptionLearning(settings)
                try await profiles(settings)
                try await changedSurroundings(settings)
                try await secureChecks(settings)
                try await delayedVisibility(settings)
                try await visibilityLifecycle(settings)
            }
            check(NSApp.windows.isEmpty, "Acceptance creates no native windows")
            print("PASS headless AI pipeline: mode=\(live ? "live" : "stub") per-key controller/Rime/mark/context/debounce/service/presentation/Tab")
        } catch {
            print("FAIL headless AI pipeline: \((error as? AIServiceError)?.localizedDescription ?? "isolated setup failed")")
            exit(1)
        }
    }

    @MainActor static func effect(_ value: AIHeadlessCase, settings: IFSettings, live: Bool) async throws {
        let records = AIDiagnosticCapture()
        await AIDiagnostics.$observe.withValue({ records.append($0) }) {
            let service = AIHeadlessService(live: live, response: value.stub)
            let (controller, client, endpoint) = fixture(settings: settings, service: service)
            if live { client.reportedLength = 0 }
            defer { controller.engine?.clear(); controller.refresh(client) }
            let lastKey = await AIHeadlessKeyboard.type(value.pinyin, into: controller, client: client)
            check(endpoint.candidatesVisible && !endpoint.candidates.isEmpty && endpoint.refreshCount == value.pinyin.count,
                  "Only normal per-key refresh populates and shows candidates")
            check(controller.engine?.aiInputIdentity()?.rawInput == value.pinyin, "Raw original Pinyin survives real Rime, including typo")
            let beforePause = await service.captured(); check(beforePause.isEmpty, "Typing below threshold does not request")
            let scheduled = records.records.filter { $0.event == .scheduled }.count
            let identity = controller.engine?.aiInputIdentity(), page = controller.engine!.snapshot().page
            await wait(0.10)
            check(controller.handle(AIHeadlessKeyboard.event(121), client: client))
            check(controller.engine!.snapshot().page != page, "Page-down goes through actual Rime")
            check(controller.handle(AIHeadlessKeyboard.event(116), client: client))
            check(controller.handle(AIHeadlessKeyboard.event(125), client: client))
            check(controller.engine?.aiInputIdentity() == identity, "Paging and highlighting retain request identity")
            check(records.records.filter { $0.event == .scheduled }.count == scheduled, "Paging does not restart the input deadline")
            await until({ endpoint.suggestionVisible || settings.smart.requestError != nil }, seconds: live ? 25 : 3)
            check(settings.smart.requestError == nil, settings.smart.requestError ?? "")
            let calls = await service.captured()
            check(calls.count == 1, "One request follows the input pause")
            check(lastKey.duration(to: calls[0].started) >= .milliseconds(480), "Request respects the real 0.5s threshold")
            let input = calls[0].input
            check(input.pinyin == value.pinyin && input.selectedPrefix.isEmpty, "Service receives entire unmodified raw Pinyin")
            check(input.precedingText == preceding && input.followingText == (live ? "" : following),
                  "Service receives available context; zero reported length uses a bounded suffix which this client cannot read")
            if live {
                check(records.records.contains { $0.event == .contextCaptured && $0.reason == .documentShorterThanMark &&
                    $0.reportedDocumentLength == 0 && $0.markedEnd == NSMaxRange(client.mark) &&
                    $0.precedingAvailable == true && $0.followingAvailable == false },
                      "Every live fixture exercises the observed zero-length fallback")
            }
            let suggestion = endpoint.suggestion!
            check(value.required.allSatisfy { suggestion.lowercased().contains($0) }, "Suggestion preserves the fixture's intended meaning")
            await wait(0.15)
            check(controller.handle(AIHeadlessKeyboard.event(121), client: client))
            check(controller.handle(AIHeadlessKeyboard.event(116), client: client))
            check(controller.handle(AIHeadlessKeyboard.event(125), client: client))
            await wait(0.55)
            let afterNavigation = await service.captured()
            check(afterNavigation.count == 1 && endpoint.suggestion == suggestion, "Navigation neither duplicates requests nor removes ready suggestion")
            client.mutations.removeAll()
            var callbacks = 0
            client.onMutation = {
                callbacks += 1
                check(!IFEngine.allSessionsIdle, "AI insertion holds the dictionary delivery lease")
                check(controller.engine!.snapshot().preedit.isEmpty && client.mark.location != NSNotFound,
                      "Rime is cleared internally while the client's mark remains available for insertion")
                check(records.records.last?.event == .insertionIssued && !records.contains(.insertionReturned),
                      "The insertion call is observable before the editor callback, with no premature return record")
                controller.commitComposition(client)
                check(!controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client), "Reentrant Tab cannot adopt twice")
            }
            check(controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client))
            client.onMutation = nil
            check(callbacks == 1, "Adoption invokes the editor once without an empty mark update")
            check(client.document == preceding + suggestion + following, "Tab preserves committed surroundings")
            check(client.mark.location == NSNotFound && controller.engine!.snapshot().preedit.isEmpty && !endpoint.candidatesVisible && !endpoint.suggestionVisible)
            print("OBSERVED AI delivery: mutation_count=\(client.mutations.count) default_range=\(client.insertions.last?.replacementRange.location == NSNotFound) active_mark=\(client.insertions.last?.markedRange.location != NSNotFound)")
            fflush(stdout)
            check(client.mutations == ["insert:" + suggestion], "Tab must insert once while the client mark remains, without a preliminary empty mark")
            check(client.insertions.count == 1 && client.insertions[0].replacementRange == NSRange(location: NSNotFound, length: 0) &&
                client.insertions[0].markedRange.location == preceding.utf16.count && client.insertions[0].markedRange.length > 0,
                  "AI uses the same active-mark/default-range delivery contract as ordinary candidates")
            _ = controller.handle(AIHeadlessKeyboard.event(48, "\t", repeated: true), client: client)
            _ = controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client)
            controller.commitComposition(client)
            check(client.mutations.filter { $0.hasPrefix("insert:") }.count == 1, "Repeated Tab and finish do not insert twice")
            let adoption = records.records.filter { $0.event == .adoptionRequested }
            check(adoption.count == 1 && adoption[0].attempt != nil && adoption[0].session != nil)
            let lifecycle: [AIDiagnosticEvent] = live ? [.scheduled, .dispatched, .transportStarted, .httpResponse, .transportSucceeded, .shown, .adoptionRequested, .insertionIssued, .insertionReturned] : [.scheduled, .dispatched, .shown, .adoptionRequested, .insertionIssued, .insertionReturned]
            let correlated = records.records.filter { $0.attempt == adoption[0].attempt && $0.session == adoption[0].session }
            check(correlated.filter { lifecycle.contains($0.event) }.map(\.event) == lifecycle,
                  "Request, display, adoption command and insertion call/return are ordered once with the same correlation IDs")
            check(records.excludes([value.pinyin, preceding, following, suggestion, "synthetic", "example.invalid"]), "Logs omit input/output/key/URL")
            // All text printed here is a declared synthetic fixture, never a real user's document.
            print("PASS effect \(value.name): context=\(live ? "zero-length-best-effort" : "two-sided") suggestion=\(suggestion) request_count=1 latency=\(lastKey.duration(to: calls[0].started))")
            fflush(stdout)
        }
    }

    @MainActor static func adoptionLearning(_ settings: IFSettings) async throws {
        let word = "星墨舟", raw = "xingmozhou"
        let service = AIHeadlessService(response: word)
        let (controller, client, endpoint) = fixture(settings: settings, service: service)
        defer { controller.engine?.clear(); controller.refresh(client) }
        _ = await AIHeadlessKeyboard.type(raw, into: controller, client: client)
        let engine = controller.engine!
        check(engine.snapshot().candidates.first != word, "Novel adoption starts below first place")
        await until { endpoint.suggestionVisible }
        check(engine.snapshot().candidates.first != word, "Display alone never learns")
        client.mutations.removeAll()
        var callbacks = 0
        client.onMutation = {
            callbacks += 1
            controller.commitComposition(client)
            _ = controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client)
        }
        check(controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client))
        client.onMutation = nil
        check(callbacks == 1 && client.mutations == ["insert:" + word], "Adoption inserts exactly once")
        settings.smart.isEnabled = false
        _ = await AIHeadlessKeyboard.type(raw, into: controller, client: client)
        check(engine.snapshot().candidates.first == word, "Genuine Tab improves local candidates with AI disabled")
        engine.clear(); controller.refresh(client)
        settings.smart.isEnabled = true

        let expansion = AIHeadlessService(response: "你好，很高兴认识你")
        let (other, otherClient, otherEndpoint) = fixture(settings: settings, service: expansion)
        defer { other.engine?.clear(); other.refresh(otherClient) }
        _ = await AIHeadlessKeyboard.type("nihao", into: other, client: otherClient)
        await until { settings.smart.requestError != nil }
        check(!otherEndpoint.suggestionVisible && otherClient.insertions.isEmpty, "Clearly expanded result is not displayed or adopted")
        print("PASS headless AI learning: no pre-adoption learning, exact-once Tab, local recall with AI off and expansion rejection")
    }

    @MainActor static func ordinaryControls(_ settings: IFSettings) async throws {
        for action in ["space", "digit", "partial"] {
            let service = AIHeadlessService(response: "你好")
            let (controller, client, endpoint) = fixture(settings: settings, service: service)
            defer { controller.engine?.clear(); controller.refresh(client) }
            _ = await AIHeadlessKeyboard.type("nihao", into: controller, client: client)
            if action == "partial" {
                let index = endpoint.candidates.firstIndex(of: "你")!
                let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
                check(controller.handle(AIHeadlessKeyboard.event(digitCodes[index], String(index + 1)), client: client))
                check(controller.engine?.aiInputIdentity()?.selectedPrefix == "你", "Physical digit selects a partial Rime prefix")
            }
            await until { endpoint.suggestionVisible }
            client.mutations.removeAll()
            if action == "partial" {
                let calls = await service.captured()
                check(calls.count == 1 && calls[0].input.pinyin == "nihao" && calls[0].input.selectedPrefix == "你")
                var callbacks = 0
                client.onMutation = {
                    callbacks += 1
                    controller.commitComposition(client)
                    _ = controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client)
                }
                check(controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client))
                client.onMutation = nil
                check(callbacks == 1 && client.insertions.count == 1 &&
                    client.insertions[0].replacementRange.location == NSNotFound && client.insertions[0].markedRange.location != NSNotFound,
                      "Selected-prefix adoption retains active-mark insertion and reentrant exact-once behavior")
                check(client.document == preceding + "你好" + following && client.mutations == ["insert:你好"])
            } else {
                let index = action == "space" ? endpoint.highlight : 1
                let expected = endpoint.candidates[index]
                check(controller.handle(AIHeadlessKeyboard.event(action == "space" ? 49 : 19, action == "space" ? " " : "2"), client: client))
                check(client.document == preceding + expected + following && client.mutations == ["insert:" + expected], "Ordinary candidate key preserves native selection")
            }
            check(!endpoint.suggestionVisible && !endpoint.candidatesVisible && client.mark.location == NSNotFound)
        }
        print("PASS headless ordinary space/digit and selected-prefix Tab")
    }

    @MainActor static func profiles(_ settings: IFSettings) async throws {
        for profile in ["zero-length", "short-document", "exact", "unknown-length", "negative-length", "unchanged-actual-range", "unavailable-context", "invalid-mark", "outside-selection"] {
            let records = AIDiagnosticCapture(), service = AIHeadlessService()
            let (controller, client, endpoint) = fixture(settings: settings, service: service)
            defer { controller.engine?.clear(); controller.refresh(client) }
            await AIDiagnostics.$observe.withValue({ records.append($0) }) {
                _ = await AIHeadlessKeyboard.type("nihao", into: controller, client: client)
                switch profile {
                case "unknown-length":
                    client.reportedLength = NSNotFound
                    client.substringResponse = { [weak client] range in
                        guard let document = client?.document, range.location <= document.utf16.count else { return (nil, range) }
                        let actual = NSRange(location: range.location, length: min(range.length, document.utf16.count - range.location))
                        return ((document as NSString).substring(with: actual), actual)
                    }
                case "unchanged-actual-range": client.updatesActualRange = false
                case "unavailable-context": client.contextAvailable = false
                case "zero-length": client.reportedLength = 0
                case "short-document": client.reportedLength = 4
                case "negative-length": client.reportedLength = -1
                case "invalid-mark": client.mark = NSRange(location: NSNotFound, length: 0)
                case "outside-selection": client.selection = NSRange(location: 0, length: 0)
                default: break
                }
                await wait(0.75)
                let calls = await service.captured()
                let valid = !["invalid-mark", "outside-selection"].contains(profile)
                print("OBSERVED client profile \(profile): requests=\(calls.count) suggestion=\(endpoint.suggestionVisible)")
                fflush(stdout)
                check(calls.count == (valid ? 1 : 0) && endpoint.suggestionVisible == valid, "Advisory document length must allow request and preview for a valid owned composition")
                if valid {
                    let expectedBefore = profile == "unavailable-context" ? "" : preceding
                    let unavailableSuffix = ["unavailable-context", "zero-length", "short-document", "negative-length"].contains(profile)
                    let expectedAfter = unavailableSuffix ? "" : following
                    check(calls[0].input.precedingText == expectedBefore && calls[0].input.followingText == expectedAfter)
                    if ["zero-length", "short-document", "negative-length"].contains(profile) {
                        check(records.records.contains { $0.event == .contextCaptured && $0.reason == .documentShorterThanMark &&
                            $0.reportedDocumentLength == client.reportedLength && $0.markedEnd == NSMaxRange(client.mark) &&
                            $0.precedingAvailable == true && $0.followingAvailable == false },
                              "Fallback is observable as captured context with actual scalar length and availability")
                    }
                    client.mutations.removeAll()
                    check(controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client))
                    check(client.document == preceding + "你好" + following && client.mutations == ["insert:你好"],
                          "Best-effort context permits exact-once Tab while preserving both document sides")
                } else {
                    let reason: AIDiagnosticReason = profile == "invalid-mark" ? .invalidMark : .selectionOutsideMark
                    check(records.records.contains { $0.reason == reason }, "Rejected profile includes the exact observed gate")
                }
            }
            // Restore test-client range consistency before normal teardown clears its mark.
            if ["invalid-mark", "outside-selection"].contains(profile) {
                client.mark = NSRange(location: preceding.utf16.count, length: controller.engine!.snapshot().preedit.utf16.count)
                client.selection = NSRange(location: NSMaxRange(client.mark), length: 0)
            }
            print("PASS headless client profile \(profile)")
        }
    }

    @MainActor static func changedSurroundings(_ settings: IFSettings) async throws {
        for phase in ["request", "preview"] {
            for unavailable in [false, true] {
                let service = DelayedAIService()
                let (controller, client, endpoint) = fixture(settings: settings, service: service)
                defer { controller.engine?.clear(); controller.refresh(client) }
                _ = await AIHeadlessKeyboard.type("nihao", into: controller, client: client)
                await wait(0.6)
                let calls = await service.count(); check(calls == 1)
                let reads = client.requests.count, lengthReads = client.lengthReads
                if phase == "preview" {
                    await service.resolve(0)
                    await until { endpoint.suggestionVisible }
                }
                let expectedBefore = unavailable ? preceding : preceding.replacingOccurrences(of: "记录", with: "修改")
                let expectedAfter = unavailable ? following : following.replacingOccurrences(of: "候选", with: "词库")
                client.contextAvailable = !unavailable
                if !unavailable {
                    client.document = client.document!.replacingOccurrences(of: preceding, with: expectedBefore)
                        .replacingOccurrences(of: following, with: expectedAfter)
                }
                if phase == "request" {
                    await service.resolve(0)
                    await until { endpoint.suggestionVisible }
                }
                client.mutations.removeAll()
                check(controller.handle(AIHeadlessKeyboard.event(48, "\t"), client: client))
                check(client.document == expectedBefore + "你好" + expectedAfter &&
                    client.mutations == ["insert:你好"],
                      "Same-composition Tab preserves current document despite changed or unavailable surroundings after \(phase)")
                check(client.requests.count == reads && client.lengthReads == lengthReads && lengthReads == 1,
                      "Response and Tab never reread surrounding document text or length")
            }
        }
        print("PASS headless changed/unavailable surroundings during request/preview and no response/Tab document reads")
    }

    @MainActor static func secureChecks(_ settings: IFSettings) async throws {
        for changesDuringRead in [false, true] {
            var secure = !changesDuringRead
            let service = AIHeadlessService(), records = AIDiagnosticCapture()
            let (controller, client, endpoint) = fixture(settings: settings, service: service, secure: { secure })
            defer { controller.engine?.clear(); controller.refresh(client) }
            await AIDiagnostics.$observe.withValue({ records.append($0) }) {
                _ = await AIHeadlessKeyboard.type("nihao", into: controller, client: client)
                if changesDuringRead {
                    client.substringResponse = { [weak client] range in
                        secure = true
                        guard let document = client?.document, NSMaxRange(range) <= document.utf16.count else { return (nil, range) }
                        return ((document as NSString).substring(with: range), range)
                    }
                }
                await wait(0.75)
                let calls = await service.captured()
                check(calls.isEmpty && !endpoint.suggestionVisible, "Secure input blocks service even when it starts during context capture")
                check(records.records.contains { $0.reason == .secureInput })
            }
        }
        print("PASS headless secure source at eligibility and both context anchor checks")
    }

    @MainActor static func delayedVisibility(_ settings: IFSettings) async throws {
        let service = AIHeadlessService()
        let (controller, client, endpoint) = fixture(settings: settings, service: service, delay: .milliseconds(160))
        defer { controller.engine?.clear(); controller.refresh(client) }
        _ = await AIHeadlessKeyboard.type("nihao", into: controller, client: client)
        check(!endpoint.candidatesVisible, "Window show has not completed when final input refresh returns")
        await wait(0.85)
        check(endpoint.candidatesVisible, "Window endpoint becomes visible on a later main-actor turn")
        let calls = await service.captured()
        print("OBSERVED delayed visibility: visible=\(endpoint.candidatesVisible) requests=\(calls.count) suggestion=\(endpoint.suggestionVisible)")
        check(calls.count == 1 && endpoint.suggestionVisible, "Late native show must become eligible without another user key")
    }

    @MainActor static func visibilityLifecycle(_ settings: IFSettings) async throws {
        // The deadline expires before show completes. No context read or request may
        // occur while hidden, and paging must not introduce a new debounce deadline.
        let service = AIHeadlessService(), records = AIDiagnosticCapture()
        let (controller, client, endpoint) = fixture(settings: settings, service: service, delay: .milliseconds(900))
        await AIDiagnostics.$observe.withValue({ records.append($0) }) {
            let lastKey = await AIHeadlessKeyboard.type("nihao", into: controller, client: client)
            let reads = client.requests.count
            await wait(0.62)
            let calls = await service.captured()
            check(calls.isEmpty && !endpoint.candidatesVisible && client.requests.count == reads, "Pending native show never captures surrounding text or requests")
            let scheduled = records.records.filter { $0.event == .scheduled }.count
            check(controller.handle(AIHeadlessKeyboard.event(121), client: client))
            check(controller.handle(AIHeadlessKeyboard.event(116), client: client))
            check(records.records.filter { $0.event == .scheduled }.count == scheduled)
            await until { endpoint.suggestionVisible }
            let readyCalls = await service.captured()
            check(readyCalls.count == 1 && lastKey.duration(to: readyCalls[0].started) < .milliseconds(1100),
                  "A late show requests on readiness without an extra debounce after paging")
            controller.engine?.clear(); controller.refresh(client)
        }

        for phase in ["pending", "inflight"] {
            for action in ["hide", "escape", "secure", "disable", "deactivate"] {
                var secure = false
                let service = DelayedAIService()
                let (controller, client, endpoint) = fixture(settings: settings, service: service,
                    delay: phase == "pending" ? .seconds(2) : .zero, secure: { secure })
                _ = await AIHeadlessKeyboard.type("nihao", into: controller, client: client)
                await wait(0.6)
                let count = await service.count()
                check(count == (phase == "pending" ? 0 : 1))
                switch action {
                case "hide":
                    // A native window can close independently of a controller callback.
                    if phase == "inflight" { endpoint.hideCandidates() }
                    else { controller.hidePalettes() }
                case "escape": check(controller.handle(AIHeadlessKeyboard.event(53), client: client))
                case "secure": secure = true
                case "disable": settings.smart.isEnabled = false
                case "deactivate": controller.deactivateServer(client)
                default: break
                }
                await wait(0.2)
                if phase == "inflight" { await service.resolve(0) }
                await wait(0.2)
                let after = await service.count()
                check(after == count && !endpoint.suggestionVisible, "Visibility wait and stale response stop on every lifecycle invalidation")
                controller.engine?.clear(); controller.refresh(client)
                settings.smart.isEnabled = true
            }
        }
        print("PASS headless delayed show deadline, hidden context isolation, pending cancellation and in-flight hides")
    }
}

import AppKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

/// Only the window endpoint is simulated. Candidate data arrives exclusively from
/// the production controller's refresh after real per-key Rime processing.
@MainActor
package final class HeadlessAIInputPresentation: AIInputPresentation {
    package private(set) var candidates: [String] = []
    package private(set) var highlight = 0
    package private(set) var candidatesVisible = false
    package private(set) var suggestion: String?
    package private(set) var refreshCount = 0
    package private(set) var showCount = 0
    package private(set) var hideCount = 0
    package let showDelay: Duration
    private var showTask: Task<Void, Never>?
    package var suggestionVisible: Bool { suggestion != nil }

    package init(showDelay: Duration = .zero) { self.showDelay = showDelay }

    package func refreshCandidates(_ candidates: [String], highlight: Int) {
        refreshCount += 1
        self.candidates = candidates
        self.highlight = highlight
        guard !candidates.isEmpty else { hideCandidates(); return }
        showCount += 1
        guard !candidatesVisible, showTask == nil else { return }
        if showDelay == .zero { candidatesVisible = true; return }
        showTask = Task { [weak self, showDelay] in
            do { try await Task.sleep(for: showDelay) } catch { return }
            guard let self, !self.candidates.isEmpty else { return }
            self.candidatesVisible = true
            self.showTask = nil
        }
    }

    package func hideCandidates() {
        hideCount += 1
        showTask?.cancel(); showTask = nil
        candidatesVisible = false
        hideSuggestion()
    }

    package func presentSuggestion(_ text: String) -> Bool {
        guard candidatesVisible, !candidates.isEmpty else { return false }
        suggestion = text
        return true
    }

    package func hideSuggestion() { suggestion = nil }
}

package struct AIHeadlessCase: Sendable {
    package let name: String
    package let pinyin: String
    package let stub: String
    package let required: [String]

    package static let effects: [Self] = [
        .init(name: "short", pinyin: "nihao", stub: "你好", required: ["你好"]),
        .init(name: "long", pinyin: "wozhengzaiceshishurufadezhinengyucegongneng",
              stub: "我正在测试输入法的智能预测功能", required: ["测试", "输入法", "智能", "预测"]),
        .init(name: "mixed", pinyin: "wozhengzaiyongswiftkaifashurufa",
              stub: "我正在用 Swift 开发输入法", required: ["swift", "开发", "输入法"]),
        .init(name: "long-typo", pinyin: "wozhegnzaiceshishurufadezhinengyucegongneng",
              stub: "我正在测试输入法的智能预测功能", required: ["测试", "输入法", "智能", "预测"])
    ]
}

/// Observation wraps the actual service; live mode never substitutes a stub result.
package actor AIHeadlessService: AISuggestionServing {
    package struct Call: Sendable {
        package let input: AISuggestionInput
        package let started: ContinuousClock.Instant
    }
    private let live: Bool
    private let response: String
    private let client = AIChatCompletionsClient()
    private var calls: [Call] = []

    package init(live: Bool = false, response: String = "你好") { self.live = live; self.response = response }

    package func suggest(input: AISuggestionInput, configuration: AISuggestionConfiguration) async throws -> String {
        calls.append(Call(input: input, started: .now))
        if live { return try await client.suggest(input: input, configuration: configuration) }
        return response
    }

    package func captured() -> [Call] { calls }
}

/// Physical ANSI key codes, real modifiers and monotonic event timestamps. Events
/// are delivered to handle(_:client:), never to IFEngine.key or a coordinator hook.
@MainActor
package enum AIHeadlessKeyboard {
    static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
    ]

    package static func event(_ code: UInt16, _ text: String = "", flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: text, charactersIgnoringModifiers: text.lowercased(), isARepeat: repeated, keyCode: code)!
    }

    package static func type(_ text: String, into controller: InkFlowInputController, client: RecordingClient) async -> ContinuousClock.Instant {
        var lastKey = ContinuousClock.now
        for character in text {
            let lower = Character(String(character).lowercased())
            guard let code = letters[lower] else { check(false, "Fixture lacks a physical key mapping"); return .now }
            let flags: NSEvent.ModifierFlags = character == lower ? [] : [.shift]
            check(controller.handle(event(code, String(character), flags: flags), client: client), "Production controller handles fixture letter")
            lastKey = .now
            // A pause below the debounce threshold between every physical key.
            try? await Task.sleep(for: .milliseconds(12))
        }
        return lastKey
    }
}

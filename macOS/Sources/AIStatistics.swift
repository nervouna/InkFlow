import Foundation
import CoreFoundation

/// Statistics have their own scope; standalone service calls cannot open a production store.
enum AIStatisticsScope {
    @TaskLocal static var attempt: AIStatisticsHandle?
}

struct AIStatisticsStamp: Sendable {
    let utc: Date
    let monotonic: TimeInterval
    static var now: Self { .init(utc: Date(), monotonic: ProcessInfo.processInfo.systemUptime) }
}

struct AIStatisticsAssociation: Sendable {
    var compositionID: String? = nil
    var appBundleID: String? = nil
    var lastEditAt: Date? = nil
    var lastEditMonotonic: TimeInterval? = nil
    var observedVisibleAfterEdit: TimeInterval? = nil
    var candidates: [String] = []
    var candidatePage: Int? = nil
}

/// Constructed explicitly from safe request properties, never from a credential-bearing object.
struct AIConfigurationSnapshot: Codable, Sendable {
    let strategyVersion: String
    let promptVersion: String
    let promptTemplate: String
    let provider: String
    let requestedModel: String
    let maxTokens: Int
    let stream: Bool
    let thinkingDisabled: Bool

    static func identifier(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-:/".unicodeScalars.contains($0) }) else { return "unknown" }
        return value
    }
}

enum AIUsageState: String, Codable, Sendable { case valid, missing, partial, invalid }
struct AIUsage: Codable, Sendable {
    var state: AIUsageState = .missing
    var prompt: Int?
    var completion: Int?
    var cached: Int?
    var reasoning: Int?
    var total: Int?

    static func parse(_ object: Any?) -> Self {
        guard let object else { return Self() }
        guard let values = object as? [String: Any] else { return Self(state: .invalid) }
        var invalid = false
        func number(_ source: [String: Any], _ key: String) -> Int? {
            guard let value = source[key] else { return nil }
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0,
                  value.doubleValue <= 1_000_000_000, value.doubleValue.rounded(.towardZero) == value.doubleValue else {
                invalid = true; return nil
            }
            return value.intValue
        }
        func details(_ key: String) -> [String: Any] {
            guard let value = values[key] else { return [:] }
            guard let dictionary = value as? [String: Any] else { invalid = true; return [:] }
            return dictionary
        }
        let prompt = number(values, "prompt_tokens"), completion = number(values, "completion_tokens")
        let total = number(values, "total_tokens")
        let detailCache = number(details("prompt_tokens_details"), "cached_tokens")
        let hitCache = number(values, "prompt_cache_hit_tokens")
        let missCache = number(values, "prompt_cache_miss_tokens")
        let cached = detailCache ?? hitCache
        let reasoning = number(details("completion_tokens_details"), "reasoning_tokens")
        if let detailCache, let hitCache, detailCache != hitCache { invalid = true }
        if let cached, let prompt, cached > prompt { invalid = true }
        if let reasoning, let completion, reasoning > completion { invalid = true }
        if let total, let prompt, let completion, total != prompt + completion { invalid = true }
        if let missCache, let prompt, missCache > prompt { invalid = true }
        if let cached, let missCache, let prompt, cached + missCache != prompt { invalid = true }
        return Self(state: invalid ? .invalid : (prompt == nil || completion == nil ? .partial : .valid),
                    prompt: prompt, completion: completion, cached: cached, reasoning: reasoning, total: total)
    }
}

struct AIResponseMetadata: Sendable {
    var usage = AIUsage()
    var returnedModel: String?
    var text: String?
    var textTruncated = false
    var responseOversized = false

    static func boundedText(_ text: String) -> (text: String, truncated: Bool) {
        var bounded = "", bytes = 0
        for character in text.prefix(4096) {
            let count = String(character).utf8.count
            guard bytes + count <= 16_384 else { break }
            bounded.append(character); bytes += count
        }
        return (bounded, bounded != text)
    }

    /// Only selected response fields survive. Never retain headers, raw bodies or error objects.
    static func parse(_ data: Data) -> Self {
        guard data.count <= 128 * 1024 else { return Self(responseOversized: true) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Self() }
        let content = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        let text = (content?["content"] as? String).map(boundedText)
        return Self(usage: .parse(root["usage"]),
                    returnedModel: (root["model"] as? String).map(AIConfigurationSnapshot.identifier),
                    text: text?.text, textTruncated: text?.truncated ?? false)
    }
}

struct AIPriceRule: Codable, Sendable {
    let id: String
    let provider: String
    let model: String
    let currency: String
    let inputPerMillion: Decimal
    let cachedInputPerMillion: Decimal?
    let outputPerMillion: Decimal
    var effectiveFrom: Date? = nil
    var effectiveUntil: Date? = nil

    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && provider.utf8.count <= 256 && model.utf8.count <= 256 &&
        currency.count == 3 && currency.utf8.allSatisfy { (65...90).contains($0) } &&
        [inputPerMillion, outputPerMillion].allSatisfy { !$0.isNaN && $0 >= 0 && $0 <= 1_000_000_000 } &&
        (cachedInputPerMillion.map { !$0.isNaN && $0 >= 0 && $0 <= 1_000_000_000 } ?? true) &&
        (effectiveFrom == nil || effectiveUntil == nil || effectiveFrom! < effectiveUntil!)
    }

    func estimate(_ usage: AIUsage) -> Decimal? {
        guard isValid, usage.state == .valid, let input = usage.prompt, let output = usage.completion else { return nil }
        let inputCost: Decimal
        if let cachedRate = cachedInputPerMillion, cachedRate != inputPerMillion {
            guard let cached = usage.cached else { return nil }
            inputCost = Decimal(input - cached) * inputPerMillion + Decimal(cached) * cachedRate
        } else if let cached = usage.cached, cached > 0, cachedInputPerMillion == nil {
            return nil
        } else {
            // A missing cache count is safe only when the rule explicitly prices all input equally.
            guard usage.cached != nil || cachedInputPerMillion == inputPerMillion else { return nil }
            inputCost = Decimal(input) * inputPerMillion
        }
        return (inputCost + Decimal(output) * outputPerMillion) / 1_000_000
    }
}

struct AIPricingConfiguration: Codable, Sendable {
    let version: Int
    let rules: [AIPriceRule]
    func rule(provider: String, model: String, at: Date) -> AIPriceRule? {
        guard version == 1, rules.count <= 256 else { return nil }
        let matches = rules.filter { $0.isValid && $0.provider == provider && $0.model == model &&
            ($0.effectiveFrom.map { $0 <= at } ?? true) && ($0.effectiveUntil.map { at < $0 } ?? true) }
        return matches.count == 1 ? matches.first : nil
    }
}

struct AIStatisticsInputSample: Sendable {
    let preceding: String
    let following: String
    let pinyin: String
    let selectedPrefix: String
    var precedingAvailable: Bool? = nil
    var followingAvailable: Bool? = nil
}

enum AIStatisticsEventKind: String, Sendable {
    case scheduled, dispatched, transportStarted, responseObserved, transportEnded
    case serviceReturned, serviceFailed, shown, adoptionRequested, insertionIssued, insertionReturned, uiEnded
}

struct AIStatisticsEvent: Sendable {
    let kind: AIStatisticsEventKind
    let stamp: AIStatisticsStamp
    var reason: String? = nil
    var httpStatus: Int? = nil
    var response: AIResponseMetadata? = nil
    var input: AIStatisticsInputSample? = nil
    var association: AIStatisticsAssociation? = nil
}

struct AIStatisticsHandle: Sendable {
    let id: String
    let started: AIStatisticsStamp
    private let store: AIStatisticsStore
    init(id: String, started: AIStatisticsStamp, store: AIStatisticsStore) {
        self.id = id; self.started = started; self.store = store
    }
    func record(_ kind: AIStatisticsEventKind, at: AIStatisticsStamp = .now, reason: String? = nil) {
        store.submit(id: id, started: started, event: .init(kind: kind, stamp: at, reason: reason))
    }
    func dispatch(_ input: AIStatisticsInputSample, association: AIStatisticsAssociation, at: AIStatisticsStamp) {
        store.submit(id: id, started: started, event: .init(kind: .dispatched, stamp: at, input: input, association: association))
    }
    func response(_ metadata: AIResponseMetadata, status: Int?, at: AIStatisticsStamp = .now) {
        store.submit(id: id, started: started, event: .init(kind: .responseObserved, stamp: at, httpStatus: status, response: metadata))
    }
    func returned(_ text: String, at: AIStatisticsStamp = .now) {
        let bounded = AIResponseMetadata.boundedText(text)
        store.submit(id: id, started: started, event: .init(kind: .serviceReturned, stamp: at,
            response: .init(text: bounded.text, textTruncated: bounded.truncated)))
    }
}

import Foundation

actor DelayedAIService: AISuggestionServing {
    private var inputs: [AISuggestionInput] = []
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]
    func suggest(input: AISuggestionInput, configuration: AISuggestionConfiguration) async throws -> String {
        let index = inputs.count
        inputs.append(input)
        // Deliberately ignores cancellation: the coordinator must reject late results itself.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func count() -> Int { inputs.count }
    func input(_ index: Int) -> AISuggestionInput { inputs[index] }
    func resolve(_ index: Int, _ result: Result<String, any Error> = .success("你好")) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}

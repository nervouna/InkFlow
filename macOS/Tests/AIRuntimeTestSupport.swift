import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

package actor DelayedAIService: AISuggestionServing {
    private var inputs: [AISuggestionInput] = []
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]
    package init() {}
    package func suggest(input: AISuggestionInput, configuration: AISuggestionConfiguration) async throws -> String {
        let index = inputs.count
        inputs.append(input)
        // Deliberately ignores cancellation: the coordinator must reject late results itself.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    package func count() -> Int { inputs.count }
    package func input(_ index: Int) -> AISuggestionInput { inputs[index] }
    package func resolve(_ index: Int, _ result: Result<String, any Error> = .success("你好")) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}

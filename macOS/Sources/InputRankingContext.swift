@preconcurrency import InputMethodKit

/// Offline context-ranking glue kept separate from AI controller behavior for build identity auditing.
@MainActor
enum IFInputRankingContext {
    static func refresh(_ engine: IFEngine?, client: IMKTextInput?, ownsMarkedText: Bool) {
        guard let engine else { return }
        let preceding = engine.snapshot().preedit.isEmpty ? "" :
            IFPrecedingText.read(from: client, ownsMarkedText: ownsMarkedText)
        engine.setPrecedingText(preceding)
    }

    /// Capture client context only at composition start. Later selection and flush events retain shown order.
    static func prepareForKey(_ engine: IFEngine, client: IMKTextInput?, ownsMarkedText: Bool) {
        guard engine.snapshot().preedit.isEmpty else { return }
        engine.setPrecedingText(IFPrecedingText.read(from: client, ownsMarkedText: ownsMarkedText))
    }
}

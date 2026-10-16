import InkFlowRime
@preconcurrency import InputMethodKit

/// Offline context-ranking glue kept separate from AI controller behavior for build identity auditing.
@MainActor
enum IFInputRankingContext {
    /// Capture client context only at composition start. Later keys, selection and flush events retain shown order;
    /// the engine drops the context when the composition ends.
    static func prepareForKey(_ engine: IFEngine, client: IMKTextInput?, ownsMarkedText: Bool,
                              secureInput: () -> Bool = IsSecureEventInputEnabled) {
        guard engine.snapshot().preedit.isEmpty else { return }
        engine.setPrecedingText(IFPrecedingText.read(from: client, ownsMarkedText: ownsMarkedText,
                                                     secureInput: secureInput))
    }
}

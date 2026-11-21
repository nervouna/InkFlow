import InkFlowRime
@preconcurrency import InputMethodKit

@MainActor
enum IFInputRankingContext {
    static func prepareForKey(_ engine: IFEngine, client: IMKTextInput?, ownsMarkedText: Bool,
                              secureInput: () -> Bool = IsSecureEventInputEnabled) {
        guard engine.snapshot().preedit.isEmpty else { return }
        engine.setPrecedingText(IFPrecedingText.read(from: client, ownsMarkedText: ownsMarkedText,
                                                     secureInput: secureInput))
    }
}

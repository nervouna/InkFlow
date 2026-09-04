import AppKit
import InkFlowAppleEngine
@preconcurrency import InputMethodKit

// InputMethodKit's Objective-C callbacks are nonisolated in the SDK even though
// the framework invokes input controllers on the main thread. Every callback
// below checks that contract before crossing into MainActor state.
private struct IMKMainThreadValue<Value>: @unchecked Sendable {
    let value: Value
}

@objc(InkFlowInputController)
@MainActor
final class InkFlowInputController: IMKInputController, @unchecked Sendable {
    private var engineSession: EngineSession?
    private var latestUpdate: EngineUpdate?

    nonisolated override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        dispatchPrecondition(condition: .onQueue(.main))
        super.init(server: server, delegate: delegate, client: inputClient)
        MainActor.assumeIsolated {
            engineSession = try? MacEngineHost.shared.makeSession()
        }
    }

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let event = IMKMainThreadValue(value: event)
        let sender = IMKMainThreadValue(value: sender)
        return MainActor.assumeIsolated {
            handleOnMain(event.value, client: sender.value)
        }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        dispatchPrecondition(condition: .onQueue(.main))
        let sender = IMKMainThreadValue(value: sender)
        MainActor.assumeIsolated {
            commitCompositionOnMain(sender.value)
        }
    }

    nonisolated override func composedString(_ sender: Any!) -> Any! {
        dispatchPrecondition(condition: .onQueue(.main))
        let value: String = MainActor.assumeIsolated {
            latestUpdate?.preedit ?? ""
        }
        return value
    }

    nonisolated override func selectionRange() -> NSRange {
        dispatchPrecondition(condition: .onQueue(.main))
        return MainActor.assumeIsolated {
            NSRange(location: latestUpdate?.cursorUTF16Offset ?? 0, length: 0)
        }
    }

    nonisolated override func candidateSelected(_ candidateString: NSAttributedString!) {
        dispatchPrecondition(condition: .onQueue(.main))
        let candidateString = IMKMainThreadValue(value: candidateString)
        MainActor.assumeIsolated {
            candidateSelectedOnMain(candidateString.value)
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        dispatchPrecondition(condition: .onQueue(.main))
        let sender = IMKMainThreadValue(value: sender)
        MainActor.assumeIsolated {
            deactivateServerOnMain(sender.value)
        }
    }

    nonisolated override func inputControllerWillClose() {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            MacEngineHost.shared.hideCandidates()
            engineSession?.close()
            engineSession = nil
            super.inputControllerWillClose()
        }
    }

    private func handleOnMain(_ event: NSEvent?, client sender: Any?) -> Bool {
        guard let event,
              let nativeEvent = MacKeyMapper.map(event),
              let engineSession else {
            return false
        }
        do {
            let update = try engineSession.process(nativeEvent)
            apply(update, client: sender)
            return update.handled || update.commitText != nil
        } catch {
            reset(client: sender)
            return false
        }
    }

    private func commitCompositionOnMain(_ sender: Any?) {
        guard let engineSession else { return }
        do {
            apply(try engineSession.commit(), client: sender)
        } catch {
            reset(client: sender)
        }
    }

    private func candidateSelectedOnMain(_ candidateString: NSAttributedString?) {
        guard let candidateString,
              let index = MacEngineHost.shared.index(of: candidateString),
              let engineSession else {
            return
        }
        do {
            apply(try engineSession.selectCandidate(at: index), client: client())
        } catch {
            reset(client: client())
        }
    }

    private func deactivateServerOnMain(_ sender: Any?) {
        if let engineSession {
            do {
                apply(try engineSession.commit(), client: sender)
            } catch {
                reset(client: sender)
            }
        }
        super.deactivateServer(sender)
    }

    private func apply(_ update: EngineUpdate, client sender: Any?) {
        latestUpdate = update
        guard let textClient = sender as? (any IMKTextInput) else { return }
        let replacement = NSRange(location: NSNotFound, length: NSNotFound)
        if let commit = update.commitText, !commit.isEmpty {
            textClient.insertText(commit, replacementRange: replacement)
        }
        if update.preedit.isEmpty {
            if update.commitText == nil {
                textClient.setMarkedText(
                    "",
                    selectionRange: NSRange(location: 0, length: 0),
                    replacementRange: replacement
                )
            }
        } else {
            textClient.setMarkedText(
                update.preedit,
                selectionRange: NSRange(
                    location: update.cursorUTF16Offset,
                    length: 0
                ),
                replacementRange: replacement
            )
        }
        MacEngineHost.shared.presentCandidates(update.candidates.map(\.text))
    }

    private func reset(client sender: Any?) {
        if let update = try? engineSession?.reset() {
            apply(update, client: sender)
        }
        latestUpdate = nil
        MacEngineHost.shared.hideCandidates()
    }
}

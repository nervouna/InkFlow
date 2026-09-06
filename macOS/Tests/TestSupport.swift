import AppKit

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard condition() else {
        print("FAIL \(file):\(line) \(message)")
        exit(1)
    }
}

@MainActor
func keyEvent(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: code)!
}

@MainActor
func type(_ engine: IFEngine, _ text: String) {
    for code in text.utf16 { engine.key(Int32(code)) }
}

@MainActor
final class IsolatedSettings {
    let suite = "inkflow.test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: IFSettings
    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = IFSettings(defaults: defaults)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
func drainEvents(seconds: TimeInterval = 0.15) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while deadline.timeIntervalSinceNow > 0 {
        if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}

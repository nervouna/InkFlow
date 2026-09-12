import AppKit
import InputMethodKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

@MainActor
package func check(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard condition() else {
        print("FAIL \(file):\(line) \(message)")
        exit(1)
    }
}

@MainActor
package func keyEvent(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = [],
                      repeated: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: repeated, keyCode: code)!
}

@MainActor
package func modifierEvent(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code)!
}

@MainActor
package func type(_ engine: IFEngine, _ text: String) {
    for code in text.utf16 { engine.key(Int32(code)) }
}

@MainActor
package final class IsolatedSettings {
    package let suite = "inkflow.test.\(UUID().uuidString)"
    package let defaults: UserDefaults
    package let settings: IFSettings
    package init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = IFSettings(defaults: defaults)
    }
    package func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
package func drainEvents(seconds: TimeInterval = 0.15) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while deadline.timeIntervalSinceNow > 0 {
        if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}


@MainActor
package final class RecordingClient: NSObject, @preconcurrency IMKTextInput {
    package var mutations: [String] = []
    package var insertions: [(replacementRange: NSRange, markedRange: NSRange)] = []
    package var insertionCallback: (() -> Void)?
    package var onMutation: (() -> Void)?
    package var testBundleID: String? = "inkflow.recording-client"
    package var testClientID: String? = "inkflow.recording-client"
    package var testIdentifierProvider: (() -> String?)?
    package var document: String?
    package var selection = NSRange(location: NSNotFound, length: 0)
    package var reportedSelection: NSRange?
    package var mark = NSRange(location: NSNotFound, length: 0)
    package var contextAvailable = true
    package var updatesActualRange = true
    package var requests: [NSRange] = []
    package var substringResponse: ((NSRange) -> (String?, NSRange))?
    package var lengthReads = 0
    package var reportedLength: Int?
    package var caretRect = NSRect.zero
    package var attributeIndexes: [Int] = []
    package var allowsExplicitMarkedReplacement = false
    package var onAttributes: (() -> Void)?

    package init(document: String? = nil) {
        self.document = document
        if let document { selection = NSRange(location: document.utf16.count, length: 0) }
    }

    private func replace(_ text: String, marked: Bool, cursor: NSRange? = nil, requested: NSRange? = nil) {
        guard let document else { return }
        let range = requested.flatMap { $0.location != NSNotFound ? $0 : nil } ?? (mark.location != NSNotFound ? mark : selection)
        check(range.location != NSNotFound && NSMaxRange(range) <= document.utf16.count)
        self.document = (document as NSString).replacingCharacters(in: range, with: text)
        selection = NSRange(location: range.location + (cursor?.location ?? text.utf16.count), length: cursor?.length ?? 0)
        mark = marked && !text.isEmpty ? NSRange(location: range.location, length: text.utf16.count) : NSRange(location: NSNotFound, length: 0)
    }
    package func insertText(_ string: Any!, replacementRange: NSRange) {
        insertions.append((replacementRange, mark))
        mutations.append("insert:\(string as! String)")
        onMutation?()
        replace(string as! String, marked: false, requested: replacementRange)
        insertionCallback?()
    }
    package func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        check(allowsExplicitMarkedReplacement || replacementRange == NSRange(location: NSNotFound, length: 0))
        let text = string as! String
        check(selectionRange.location <= text.utf16.count)
        mutations.append("mark:\(text)")
        onMutation?()
        replace(text, marked: true, cursor: selectionRange, requested: replacementRange)
    }
    package func selectedRange() -> NSRange { reportedSelection ?? selection }
    package func markedRange() -> NSRange { mark }
    package func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
    package func length() -> Int { lengthReads += 1; return reportedLength ?? document?.utf16.count ?? NSNotFound }
    package func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    package func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        attributeIndexes.append(index)
        onAttributes?()
        lineRect?.pointee = caretRect
        return [:]
    }
    package func validAttributesForMarkedText() -> [Any]! { [] }
    package func overrideKeyboard(withKeyboardNamed name: String!) {}
    package func selectMode(_ identifier: String!) {}
    package func supportsUnicode() -> Bool { true }
    package func bundleIdentifier() -> String! { testBundleID }
    package func windowLevel() -> CGWindowLevel { 0 }
    package func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    package func uniqueClientIdentifierString() -> String! {
        if let testIdentifierProvider { return testIdentifierProvider() }
        return testClientID
    }
    package func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        requests.append(range)
        guard contextAvailable else { return nil }
        if let substringResponse {
            let (text, actual) = substringResponse(range)
            actualRange?.pointee = actual
            return text
        }
        guard let document, NSMaxRange(range) <= document.utf16.count else { return nil }
        if updatesActualRange { actualRange?.pointee = range }
        return (document as NSString).substring(with: range)
    }
    package func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

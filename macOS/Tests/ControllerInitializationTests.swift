import InputMethodKit
import Carbon
import ObjectiveC
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowNativeTestSupport
import InkFlowTestSupport
#endif

@main
struct ControllerInitializationTests {
    @MainActor static func main() throws {
        check(CommandLine.arguments.count == 3)
        // The exact production initializer uses the shared settings object. Override only
        // this process's argument domain, never the user's persisted defaults.
        UserDefaults.standard.setVolatileDomain(["candidateCount": 5, "fontSize": 14, "vertical": false,
            "IFIsolatedAICredentials": true, "aiEnabled": false, "aiBaseURL": "", "aiModel": ""], forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
        try IFEngine.start(shared: CommandLine.arguments[1], user: CommandLine.arguments[2])
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "macOS/Info.plist")), format: nil) as! [String: Any]
        let className = info["InputMethodServerControllerClass"] as! String
        check(NSClassFromString(className) === InkFlowInputController.self, "IMK runtime class lookup")
        let name = "io.damao.inkflow.initialization-test.\(UUID().uuidString)"
        let server = IMKServer(name: name, bundleIdentifier: name)!
        var candidateLifetime: NativeCandidateLifetime? = NativeCandidateLifetime(server: server)
        weak let releasedLifetime = candidateLifetime
        weak var releasedController: InkFlowInputController?
        weak var retainedPanel: IMKCandidates?
        autoreleasepool {
            // Exercise the exact production initializer and real panel, without stubs.
            var controller: InkFlowInputController?
            autoreleasepool { controller = InkFlowInputController(server: server, delegate: nil, client: nil) }
            check(controller != nil)
            releasedController = controller
            var panel = controller?.panel
            check(panel != nil)
            retainedPanel = panel
            let layout = panel!.selectionKeysKeylayout()!.takeUnretainedValue()
            let identifier = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(layout, kTISPropertyInputSourceID)).takeUnretainedValue() as String
            check(identifier == "com.apple.keylayout.US")
            check(panel!.selectionKeys() as? [Int] == [18, 19, 20, 21, 23])
            panel!.setSelectionKeys([18, 19, 20, 21, 23])
            let candidates = ["微笑", "😊", "❤️", "🇨🇳", "👨‍⚕️"]
            panel!.setCandidateData(candidates)
            for (index, candidate) in candidates.enumerated() {
                check(panel!.candidateIdentifier(atLineNumber: index) == panel!.candidateStringIdentifier(candidate))
            }
            panel!.hide()
            let engine = controller!.engine!
            type(engine, "nihao"); controller!.refresh(nil)
            check((controller!.candidates(nil) as! [String]).contains("👋"))
            controller!.candidateSelected(NSAttributedString(string: "👋"))
            check(engine.snapshot().preedit.isEmpty && controller!.candidates(nil).isEmpty)
            print("PASS native emoji: candidate identifiers preserve Unicode sequences, emoji selection callback clears composition")
            panel!.setCandidateData(["session teardown fixture"])
            check(panel!.candidateIdentifier(atLineNumber: 0) != NSNotFound)
            panel = nil; controller = nil
        }
        check(releasedController == nil)
        autoreleasepool {
            check(retainedPanel != nil, "Server candidate must survive controller release")
            check(!retainedPanel!.isVisible(), "Released session leaves no visible candidate window")
        }
        // Diagnostic-only private dispatch, matching the crash before controller callbacks.
        // Fail explicitly if a future OS removes these inspection entry points.
        let deactivate = NSSelectorFromString("deactivateServer_CommonWithClientWrapper:controller:")
        check(server.responds(to: deactivate), "Native deactivation diagnostic is supported")
        let invoke = unsafeBitCast(server.method(for: deactivate),
            to: (@convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void).self)
        let storageIvar = class_getInstanceVariable(IMKServer.self, "_private")
        check(storageIvar != nil, "Native candidate storage diagnostic is supported")
        let storage = object_getIvar(server, storageIvar!)! as AnyObject
        let getter = NSSelectorFromString("_candidates")
        check(storage.responds(to: getter), "Native candidate reference diagnostic is supported")
        let getCandidates = unsafeBitCast(storage.method(for: getter),
            to: (@convention(c) (AnyObject, Selector) -> UnsafeRawPointer?).self)
        for _ in 0..<4 {
            weak var replacedPanel: IMKCandidates?
            // Native accessors can autorelease their return values. Drain the whole
            // inspection, deactivation and replacement before checking deallocation.
            autoreleasepool {
                check(retainedPanel != nil)
                let layout = retainedPanel!.selectionKeysKeylayout()!.takeUnretainedValue()
                let identifier = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(layout, kTISPropertyInputSourceID)).takeUnretainedValue() as String
                check(identifier == "com.apple.keylayout.US", "Borrowed layout survives controller release")
                check(retainedPanel!.selectionKeys() as? [Int] == [18, 19, 20, 21, 23])
                invoke(server, deactivate, nil, nil)
                replacedPanel = retainedPanel
                var controller: InkFlowInputController? = InkFlowInputController(server: server, delegate: nil, client: nil)
                releasedController = controller
                retainedPanel = controller?.panel
                controller = nil
            }
            check(releasedController == nil, "Lifetime must not retain controllers")
            check(replacedPanel == nil, "Only the latest retired panel remains retained")
        }
        // Refreshing and restyling an older session must not replace the server reference.
        weak var olderPanel: IMKCandidates?
        autoreleasepool {
            var older: InkFlowInputController? = InkFlowInputController(server: server, delegate: nil, client: nil)
            olderPanel = older?.panel
            var newer: InkFlowInputController? = InkFlowInputController(server: server, delegate: nil, client: nil)
            retainedPanel = newer?.panel
            let expected = UnsafeRawPointer(Unmanaged.passUnretained(newer!.panel!).toOpaque())
            check(getCandidates(storage, getter) == expected, "Server registers the newest panel")
            older?.panel?.update()
            older?.panel?.show(kIMKLocateCandidatesBelowHint)
            older?.panel?.hide()
            older?.panel?.setPanelType(kIMKSingleColumnScrollingCandidatePanel)
            check(getCandidates(storage, getter) == expected, "Older panel operations preserve server reference")
            older = nil
            newer = nil
        }
        check(olderPanel == nil && retainedPanel != nil, "Older session refresh preserves bounded latest panel ownership")
        autoreleasepool { invoke(server, deactivate, nil, nil) }
        autoreleasepool { candidateLifetime = nil }
        check(releasedLifetime == nil && retainedPanel == nil, "Application lifetime releases panels without a server cycle")
        IFEngine.stop()
        print("PASS lifetime: post-release native deactivation, bounded replacement, borrowed layout and owner teardown")

        print("PASS initialization: exact runtime class, real controller, selection-key configuration, layout reuse and teardown")
    }
}

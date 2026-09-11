import InputMethodKit
import Carbon
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
        weak var releasedController: InkFlowInputController?
        autoreleasepool {
            // Exercise the exact production initializer and real panel, without stubs.
            var controller: InkFlowInputController?
            autoreleasepool { controller = InkFlowInputController(server: server, delegate: nil, client: nil) }
            check(controller != nil)
            releasedController = controller
            var panel = controller?.panel
            check(panel != nil)
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
            panel = nil; controller = nil
        }
        check(releasedController == nil)
        IFEngine.stop()
        print("PASS initialization: exact runtime class, real controller, selection-key configuration, layout reuse and teardown")
    }
}

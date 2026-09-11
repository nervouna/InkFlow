import AppKit
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@main
struct MetadataTests {
    @MainActor static func main() throws {
        check(CommandLine.arguments.count == 2)
        guard let bundle = Bundle(path: CommandLine.arguments[1]), let info = bundle.infoDictionary else { check(false); return }
        let modeID = "io.damao.inputmethod.inkflow.Hans"
        let group = info["ComponentInputModeDict"] as! [String: Any]
        let modes = group["tsInputModeListKey"] as! [String: Any]
        check(modes.count == 1)
        let mode = modes[modeID] as! [String: Any]
        check(group["tsVisibleInputModeOrderedArrayKey"] as? [String] == [modeID])
        check(mode["TISInputSourceID"] as? String == modeID)
        check(mode["TISIntendedLanguage"] as? String == "zh-Hans")
        check(info["TISIconIsTemplate"] as? Bool == true)
        for key in ["TISIconIsTemplate", "tsInputModeIsVisibleKey", "tsInputModeDefaultStateKey", "tsInputModePrimaryInScriptKey"] {
            check(mode[key] as? Bool == true)
        }
        check(mode["tsInputModeScriptKey"] as? String == "smUnicodeScript")
        check(info["LSMinimumSystemVersion"] as? String == "26.0")
        check(NSClassFromString(info["InputMethodServerControllerClass"] as! String) === InkFlowInputController.self)
        for key in ["tsInputModeMenuIconFileKey", "tsInputModeAlternateMenuIconFileKey", "tsInputModePaletteIconFileKey"] {
            let file = mode[key] as! String
            check(!file.isEmpty && FileManager.default.isReadableFile(atPath: bundle.resourceURL!.appendingPathComponent(file).path))
        }
        for language in ["en", "zh-Hans"] {
            let url = bundle.resourceURL!.appendingPathComponent("\(language).lproj/InfoPlist.strings")
            let names = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
            let productName = language == "zh-Hans" ? "墨流拼音" : "InkFlow"
            let modeName = language == "zh-Hans" ? "墨流拼音" : "InkFlow Pinyin"
            check(names[modeID] == modeName && names["CFBundleName"] == productName && names["CFBundleDisplayName"] == productName)
        }
        check(mode["tsInputModeMenuIconFileKey"] as? String == "MenuIconTemplate.tiff")
        check(mode["tsInputModeAlternateMenuIconFileKey"] as? String == mode["tsInputModeMenuIconFileKey"] as? String)
        let menuIcon = bundle.image(forResource: "MenuIconTemplate")!
        check(menuIcon.isTemplate && menuIcon.size == NSSize(width: 22, height: 16))
        check(menuIcon.representations.count == 2)
        var widths: Set<Int> = []
        for representation in menuIcon.representations {
            guard let rep = representation as? NSBitmapImageRep else { check(false); return }
            check(rep.hasAlpha && rep.pixelsHigh * 22 == rep.pixelsWide * 16)
            check(rep.size == NSSize(width: 22, height: 16))
            widths.insert(rep.pixelsWide)
            check(rep.colorAt(x: 0, y: 0)!.alphaComponent < 0.1)
            var clearInterior = 0, solidInterior = 0
            for y in (rep.pixelsHigh / 4)..<(rep.pixelsHigh * 3 / 4) {
                for x in (rep.pixelsWide / 3)..<(rep.pixelsWide * 2 / 3) {
                    if rep.colorAt(x: x, y: y)!.alphaComponent < 0.5 { clearInterior += 1 }
                    else { solidInterior += 1 }
                }
            }
            check(clearInterior > 0 && solidInterior > 0)
        }
        check(widths == [22, 44])
        print("PASS metadata: one named visible/default Chinese mode, runtime controller class, macOS 26, packaged icons/localizations")
    }
}

import InkFlowRime
import Foundation

extension IFDictionaryRuntime {
    static func bundled(helper: URL) -> Self {
        let contents = helper.deletingLastPathComponent().deletingLastPathComponent()
        return .init(resources: contents.appendingPathComponent("Resources/Rime"), helper: helper,
                     libraries: [contents.appendingPathComponent("Frameworks/librime.1.dylib"),
                                 contents.appendingPathComponent("Frameworks/rime-plugins/librime-lua.dylib")])
    }
}

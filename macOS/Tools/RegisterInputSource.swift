import Foundation
#if SWIFT_PACKAGE
import InkFlowInputSources
#endif

@main struct RegisterInputSource {
    @MainActor static func main() async {
        await IFRegisterInputSourceBootstrap.run(arguments: CommandLine.arguments)
    }
}

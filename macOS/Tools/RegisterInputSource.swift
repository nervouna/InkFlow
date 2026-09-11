import Foundation
#if SWIFT_PACKAGE
import InkFlowInputSources
#endif

@main struct RegisterInputSource {
    @MainActor static func main() {
        IFRegisterInputSourceBootstrap.run(arguments: CommandLine.arguments)
    }
}

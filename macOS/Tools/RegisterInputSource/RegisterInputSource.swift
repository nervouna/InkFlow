import Foundation
import InkFlowInputSources

@main struct RegisterInputSource {
    @MainActor static func main() async {
        await IFRegisterInputSourceBootstrap.run(arguments: CommandLine.arguments)
    }
}

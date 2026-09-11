import AppKit
#if SWIFT_PACKAGE
import InkFlowInstallerCore
#endif

@main struct IFInstallerMain {
    @MainActor static func main() {
        IFInstallerBootstrap.run(arguments: CommandLine.arguments)
    }
}

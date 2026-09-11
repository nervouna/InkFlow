import Foundation
#if SWIFT_PACKAGE
import InkFlowCore
import InkFlowRimeWorker
#endif

@main struct PackagedCacheTool {
    static func main() throws {
        try IFPackagedCacheToolBootstrap.run(arguments: CommandLine.arguments,
            compile: { IFDictionaryCompile($0, $1, $2) },
            probe: { IFDictionaryProbe($0, $1, $2) })
    }
}

import InkFlowDomain
import Foundation
#if SWIFT_PACKAGE
import InkFlowRime
#endif

@main struct PackagedCacheTool {
    static func main() throws {
        try IFPackagedCacheToolBootstrap.run(arguments: CommandLine.arguments,
            compile: { IFPortableResources.compile($0, $1, $2) },
            probe: { IFPortableResources.probe($0, $1, $2) })
    }
}

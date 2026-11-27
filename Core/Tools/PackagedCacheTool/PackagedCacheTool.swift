import Foundation
import InkFlowRime

@main struct PackagedCacheTool {
    static func main() throws {
        try IFPackagedCacheToolBootstrap.run(arguments: CommandLine.arguments)
    }
}

import Foundation
#if SWIFT_PACKAGE
import InkFlowCore
#endif

// The online preparation worker calls the same IFDictionaryGenerator API.
do {
    try IFDictionaryToolBootstrap.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("dictionary-generator: \(error.localizedDescription)\n".utf8))
    exit(1)
}

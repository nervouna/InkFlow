import Foundation
import Darwin
#if SWIFT_PACKAGE
import InkFlowCore
import InkFlowRime
#endif

if CommandLine.arguments.dropFirst().first == "--personal-data" {
    exit(IFPersonalDataWorkerBootstrap.run(arguments: CommandLine.arguments))
}
exit(IFDictionaryWorkerBootstrap.run(arguments: CommandLine.arguments,
    executablePath: CommandLine.arguments[0],
    compile: { IFPortableResources.compile($0, $1, $2) },
    probe: { IFPortableResources.probe($0, $1, $2) }))

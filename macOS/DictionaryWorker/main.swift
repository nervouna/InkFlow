import Foundation
import Darwin
#if SWIFT_PACKAGE
import InkFlowCore
import InkFlowRimeWorker
#endif

exit(IFDictionaryWorkerBootstrap.run(arguments: CommandLine.arguments,
    executablePath: CommandLine.arguments[0],
    compile: { IFDictionaryCompile($0, $1, $2) },
    probe: { IFDictionaryProbe($0, $1, $2) }))

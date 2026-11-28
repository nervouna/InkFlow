import Foundation
import Darwin
import InkFlowCore

if CommandLine.arguments.dropFirst().first == "--personal-data" {
    exit(IFPersonalDataWorkerBootstrap.run(arguments: CommandLine.arguments))
}
exit(IFDictionaryWorkerBootstrap.run(arguments: CommandLine.arguments, executablePath: CommandLine.arguments[0]))

import Foundation

@main
struct QualityExportFixture {
    static func main() {
        do {
            let args = CommandLine.arguments
            let result = try QualityExport.write(database: URL(fileURLWithPath: args[1]),
                destination: URL(fileURLWithPath: args[2]))
            print(result)
        } catch {
            FileHandle.standardError.write(Data(error.localizedDescription.utf8))
            exit(2)
        }
    }
}

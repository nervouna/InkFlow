import Foundation

/// `DATABASE DESTINATION` writes the manual export. `auto DATABASE FOLDER LAST NOW` runs one check of the weekly
/// export with `LAST` (seconds since 1970, or `none`) and `NOW`, printing `skipped` when it is not due.
@main
struct QualityExportFixture {
    static func main() {
        do {
            let args = CommandLine.arguments
            if args[1] == "auto" {
                let last = Double(args[4]).map { Date(timeIntervalSince1970: $0) }
                let now = Date(timeIntervalSince1970: Double(args[5])!)
                guard QualityAutoExport.isDue(enabled: true, folder: args[3], lastSuccess: last, now: now) else {
                    print("skipped")
                    return
                }
                print(try QualityAutoExport.run(database: URL(fileURLWithPath: args[2]),
                    folder: URL(fileURLWithPath: args[3]), lastSuccess: last, now: now))
                return
            }
            let result = try QualityExport.write(database: URL(fileURLWithPath: args[1]),
                destination: URL(fileURLWithPath: args[2]))
            print(result)
        } catch {
            FileHandle.standardError.write(Data(error.localizedDescription.utf8))
            exit(2)
        }
    }
}

import Foundation
import InputMethodKit

guard let connectionName = Bundle.main.object(
    forInfoDictionaryKey: "InputMethodConnectionName"
) as? String, let bundleIdentifier = Bundle.main.bundleIdentifier else {
    fatalError("Input method connection metadata is missing")
}

guard let server = IMKServer(
    name: connectionName,
    bundleIdentifier: bundleIdentifier
) else {
    fatalError("Input method server could not be created")
}
MacEngineHost.shared.configure(server: server)
RunLoop.current.run()

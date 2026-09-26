import Foundation
import InkFlowRime

@MainActor
package func check(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard condition() else { print("FAIL \(file):\(line) \(message)"); exit(1) }
}

@MainActor
package func type(_ engine: IFEngine, _ text: String) {
    for code in text.utf16 { engine.key(Int32(code)) }
}

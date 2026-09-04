import Foundation
@testable import InkFlowAppleEngine
import XCTest

final class EngineTranscriptTests: XCTestCase {
    func testNihaoTranscriptCommitsExpectedCandidate() throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        var update: EngineUpdate?
        for scalar in "nihao".unicodeScalars {
            update = try session.process(EngineKeyEvent(key: scalar.value))
        }
        let composed = try XCTUnwrap(update)
        XCTAssertEqual(composed.preedit, "nihao")
        let index = try XCTUnwrap(
            composed.candidates.firstIndex(where: { $0.text == "你好" })
        )
        let committed = try session.selectCandidate(at: index)
        XCTAssertEqual(committed.commitText, "你好")
        XCTAssertTrue(committed.preedit.isEmpty)
    }
}

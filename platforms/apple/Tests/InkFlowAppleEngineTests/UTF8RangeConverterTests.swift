import Foundation
@testable import InkFlowAppleEngine
import XCTest

final class UTF8RangeConverterTests: XCTestCase {
    func testConvertsScalarBoundariesToUTF16Offsets() {
        let text = "a你🙂b"
        XCTAssertEqual(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 0), 0)
        XCTAssertEqual(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 1), 1)
        XCTAssertEqual(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 4), 2)
        XCTAssertEqual(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 8), 4)
        XCTAssertEqual(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 9), 5)
        XCTAssertEqual(
            UTF8RangeConverter.utf16Range(in: text, utf8Start: 1, utf8End: 8),
            NSRange(location: 1, length: 3)
        )
    }

    func testRejectsOffsetsInsideScalarsAndInvalidRanges() {
        let text = "你🙂"
        XCTAssertNil(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 1))
        XCTAssertNil(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 5))
        XCTAssertNil(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: -1))
        XCTAssertNil(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 8))
        XCTAssertNil(UTF8RangeConverter.utf16Range(in: text, utf8Start: 3, utf8End: 0))
    }

    func testAcceptsScalarBoundaryInsideGraphemeCluster() {
        let text = "e\u{301}"
        XCTAssertEqual(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 1), 1)
        XCTAssertNil(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 2))
        XCTAssertEqual(UTF8RangeConverter.utf16Offset(in: text, utf8ByteOffset: 3), 2)
    }
}

import Foundation

public enum UTF8RangeConverter {
    public static func utf16Offset(in text: String, utf8ByteOffset: Int) -> Int? {
        guard utf8ByteOffset >= 0, utf8ByteOffset <= text.utf8.count else {
            return nil
        }
        let utf8Index = text.utf8.index(
            text.utf8.startIndex,
            offsetBy: utf8ByteOffset
        )
        guard let utf16Index = utf8Index.samePosition(in: text.utf16) else {
            return nil
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
    }

    public static func utf16Range(
        in text: String,
        utf8Start: Int,
        utf8End: Int
    ) -> NSRange? {
        guard utf8Start <= utf8End,
              let start = utf16Offset(in: text, utf8ByteOffset: utf8Start),
              let end = utf16Offset(in: text, utf8ByteOffset: utf8End) else {
            return nil
        }
        return NSRange(location: start, length: end - start)
    }
}

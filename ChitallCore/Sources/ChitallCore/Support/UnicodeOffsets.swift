/// Conversions between Unicode scalar offsets (the unit of locators, as in W3C
/// TextPositionSelector) and UTF-16 offsets (the unit of NSString/NSRange/UITextView).
public enum UnicodeOffsets {
    /// UTF-16 offset of the scalar at `scalarOffset`. Offsets past the end clamp to the end.
    public static func utf16Offset(in text: String, scalarOffset: Int) -> Int {
        guard scalarOffset > 0 else { return 0 }
        var utf16 = 0
        var scalars = 0
        for scalar in text.unicodeScalars {
            if scalars == scalarOffset { break }
            utf16 += scalar.utf16Width
            scalars += 1
        }
        return utf16
    }

    /// Scalar offset for a UTF-16 offset. A UTF-16 offset that falls between the two halves
    /// of a surrogate pair rounds down to the start of that scalar.
    public static func scalarOffset(in text: String, utf16Offset: Int) -> Int {
        guard utf16Offset > 0 else { return 0 }
        var utf16 = 0
        var scalars = 0
        for scalar in text.unicodeScalars {
            let next = utf16 + scalar.utf16Width
            if next > utf16Offset { break }
            utf16 = next
            scalars += 1
        }
        return scalars
    }

    public static func scalarCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// Substring by scalar offsets, clamped to the text.
    public static func substring(_ text: String, scalarRange: Range<Int>) -> String {
        let scalars = text.unicodeScalars
        let lower = max(0, min(scalarRange.lowerBound, scalars.count))
        let upper = max(lower, min(scalarRange.upperBound, scalars.count))
        let start = scalars.index(scalars.startIndex, offsetBy: lower)
        let end = scalars.index(start, offsetBy: upper - lower)
        return String(scalars[start..<end])
    }
}

extension Unicode.Scalar {
    var utf16Width: Int { value > 0xFFFF ? 2 : 1 }
}

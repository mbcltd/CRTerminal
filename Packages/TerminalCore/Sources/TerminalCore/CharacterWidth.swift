/// Display-column width of scalars (wcwidth-style): 0 for combining/format
/// characters, 2 for East Asian Wide/Fullwidth and emoji-presentation
/// blocks, 1 otherwise. Multi-scalar grapheme clusters (ZWJ sequences,
/// skin tones) arrive as their parts in Phase 2; the side table is Phase 3.
public enum CharacterWidth {
    public static func width(of scalar: Unicode.Scalar) -> Int {
        if scalar.value < 0x1100 {
            return isZeroWidth(scalar) ? 0 : 1
        }
        if isZeroWidth(scalar) { return 0 }
        return isWide(scalar.value) ? 2 : 1
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x200D { return true } // ZWJ
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return true
        default:
            return false
        }
    }

    /// East Asian W/F ranges (Unicode 15 EastAsianWidth.txt, condensed) plus
    /// emoji-presentation blocks.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, // Hangul Jamo
        0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0...0x23F0,
        0x23F3...0x23F3, 0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653,
        0x267F...0x267F, 0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB,
        0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE...0x26CE, 0x26D4...0x26D4,
        0x26EA...0x26EA, 0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA,
        0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728,
        0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757,
        0x2795...0x2797, 0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C,
        0x2B50...0x2B50, 0x2B55...0x2B55,
        0x2E80...0x303E, // CJK Radicals … CJK Symbols and Punctuation
        0x3041...0x33FF, // Hiragana … CJK Compatibility
        0x3400...0x4DBF, // CJK Extension A
        0x4E00...0x9FFF, // CJK Unified Ideographs
        0xA000...0xA4CF, // Yi
        0xA960...0xA97F, // Hangul Jamo Extended-A
        0xAC00...0xD7A3, // Hangul Syllables
        0xF900...0xFAFF, // CJK Compatibility Ideographs
        0xFE10...0xFE19, // Vertical Forms
        0xFE30...0xFE6F, // CJK Compatibility Forms, Small Form Variants
        0xFF00...0xFF60, // Fullwidth Forms
        0xFFE0...0xFFE6,
        0x16FE0...0x16FE4, 0x17000...0x187F7, // Tangut
        0x18800...0x18CD5, 0x1B000...0x1B2FB, // Kana supplements
        0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E,
        0x1F191...0x1F19A, 0x1F200...0x1F320, // Enclosed Ideographic, emoji
        0x1F32D...0x1F335, 0x1F337...0x1F37C, 0x1F37E...0x1F393,
        0x1F3A0...0x1F3CA, 0x1F3CF...0x1F3D3, 0x1F3E0...0x1F3F0,
        0x1F3F4...0x1F3F4, 0x1F3F8...0x1F43E, 0x1F440...0x1F440,
        0x1F442...0x1F4FC, 0x1F4FF...0x1F53D, 0x1F54B...0x1F54E,
        0x1F550...0x1F567, 0x1F57A...0x1F57A, 0x1F595...0x1F596,
        0x1F5A4...0x1F5A4, 0x1F5FB...0x1F64F, 0x1F680...0x1F6C5,
        0x1F6CC...0x1F6CC, 0x1F6D0...0x1F6D2, 0x1F6D5...0x1F6D7,
        0x1F6DC...0x1F6DF, 0x1F6EB...0x1F6EC, 0x1F6F4...0x1F6FC,
        0x1F7E0...0x1F7EB, 0x1F7F0...0x1F7F0, 0x1F90C...0x1F93A,
        0x1F93C...0x1F945, 0x1F947...0x1F9FF, // Supplemental symbols, emoji
        0x1FA70...0x1FAFF,
        0x20000...0x2FFFD, // CJK Extension B+
        0x30000...0x3FFFD,
    ]

    private static func isWide(_ value: UInt32) -> Bool {
        // Binary search over the sorted range table.
        var low = 0
        var high = wideRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = wideRanges[mid]
            if value < range.lowerBound {
                high = mid - 1
            } else if value > range.upperBound {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}

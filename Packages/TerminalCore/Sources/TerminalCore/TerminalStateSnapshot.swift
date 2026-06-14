import Foundation

/// A versioned, platform-independent capture of a `TerminalState`'s visible
/// contents, for session restoration (ARCHITECTURE.md "session restoration").
///
/// The heavy fields — the active grid and scrollback — are stored as packed
/// byte blobs (`Data`) rather than verbose `[[Cell]]`, because scrollback
/// dominates size (a 10k-line buffer is megabytes). Each cell packs into 16
/// little-endian bytes; wrap flags bit-pack one bit per row. Everything else
/// (cursor, pending SGR, link table, prompt marks, cwd hint) is small and
/// stored plainly, so the whole struct is `Codable` and round-trips through
/// any encoder (the app uses a binary container).
public struct TerminalStateSnapshot: Codable, Sendable, Equatable {
    /// Bumped on any incompatible layout change so stale files are rejected.
    public static let currentVersion = 1

    public var version: Int
    public var columns: Int
    public var rows: Int

    /// Active grid: `rows × columns` cells, packed 16 bytes each, row-major.
    public var cells: Data
    /// Wrap flags for the active grid, bit-packed (`rows` bits).
    public var wrapped: Data

    public var scrollbackCount: Int
    /// Scrollback: `scrollbackCount × columns` packed cells, oldest first.
    public var scrollbackCells: Data
    /// Wrap flags for scrollback, bit-packed (`scrollbackCount` bits).
    public var scrollbackWrapped: Data
    /// Absolute index of `scrollback[0]`; keeps `promptMarks` rows consistent.
    public var evictedLineCount: Int

    public var cursorX: Int
    public var cursorY: Int
    /// 0 = block, 1 = underline, 2 = bar.
    public var cursorStyle: Int

    /// Pending SGR brush, so output resumes with the right attributes.
    public var brushForeground: UInt32
    public var brushBackground: UInt32
    public var brushAttributes: UInt16

    public var linkTable: [String]
    public var promptMarks: [PromptMark]

    /// Working directory captured at save time (proc query, or OSC 7 later),
    /// so the restored shell can be spawned in the same place.
    public var workingDirectoryHint: String?
}

// MARK: - Packing helpers

extension TerminalStateSnapshot {
    static let cellStride = 16

    /// Pack rows into a flat little-endian blob, normalising every row to
    /// exactly `columns` cells (short rows pad with blanks, long ones clip —
    /// matching resize semantics; in practice rows are already `columns` wide).
    static func packCells(_ rows: [[Cell]], columns: Int) -> Data {
        var data = Data(capacity: rows.count * columns * cellStride)
        for row in rows {
            for x in 0..<columns {
                appendCell(x < row.count ? row[x] : .blank, to: &data)
            }
        }
        return data
    }

    /// Inverse of `packCells`; tolerant of a short blob (missing cells read
    /// as blanks) so a truncated file degrades to a clean grid, not a crash.
    static func unpackCells(_ bytes: [UInt8], rowCount: Int, columns: Int) -> [[Cell]] {
        var rows: [[Cell]] = []
        rows.reserveCapacity(rowCount)
        var offset = 0
        for _ in 0..<rowCount {
            var row: [Cell] = []
            row.reserveCapacity(columns)
            for _ in 0..<columns {
                row.append(readCell(bytes, at: &offset))
            }
            rows.append(row)
        }
        return rows
    }

    static func packBits(_ flags: [Bool]) -> Data {
        var data = Data(count: (flags.count + 7) / 8)
        for (i, flag) in flags.enumerated() where flag {
            data[i / 8] |= UInt8(1 << (i % 8))
        }
        return data
    }

    static func unpackBits(_ bytes: [UInt8], count: Int) -> [Bool] {
        (0..<count).map { i in
            let byte = i / 8
            return byte < bytes.count && (bytes[byte] & UInt8(1 << (i % 8))) != 0
        }
    }

    private static func appendCell(_ cell: Cell, to data: inout Data) {
        appendUInt32(cell.glyph, to: &data)
        appendUInt32(cell.foreground.rawValue, to: &data)
        appendUInt32(cell.background.rawValue, to: &data)
        appendUInt16(cell.attributes.rawValue, to: &data)
        appendUInt16(cell.link, to: &data)
    }

    private static func readCell(_ bytes: [UInt8], at offset: inout Int) -> Cell {
        let glyph = readUInt32(bytes, at: &offset)
        let foreground = PackedColor(rawValue: readUInt32(bytes, at: &offset))
        let background = PackedColor(rawValue: readUInt32(bytes, at: &offset))
        let attributes = CellAttributes(rawValue: readUInt16(bytes, at: &offset))
        let link = readUInt16(bytes, at: &offset)
        return Cell(
            glyph: glyph, foreground: foreground, background: background,
            attributes: attributes, link: link)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: inout Int) -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, through: 24, by: 8) {
            if offset < bytes.count {
                value |= UInt32(bytes[offset]) << shift
                offset += 1
            }
        }
        return value
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: inout Int) -> UInt16 {
        var value: UInt16 = 0
        for shift in stride(from: 0, through: 8, by: 8) {
            if offset < bytes.count {
                value |= UInt16(bytes[offset]) << shift
                offset += 1
            }
        }
        return value
    }
}

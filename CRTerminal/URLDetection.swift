import Foundation
import TerminalCore

/// ⌘-click target resolution: URLs and filesystem paths in row text.
enum URLDetection {
    /// Schemed URL from an OSC 8 target (or any explicit string).
    static func url(from string: String) -> URL? {
        guard let url = URL(string: string), url.scheme != nil else { return nil }
        return url
    }

    /// Finds a URL or local path under `column` in a row of cells.
    static func detect(in line: [Cell], atColumn column: Int) -> URL? {
        locate(in: line, atColumn: column)?.url
    }

    /// Resolves the URL/path under `column` together with the cell-column span
    /// it occupies. `detect` (⌘-click) and the ⌘-hover underline share this.
    static func locate(
        in line: [Cell], atColumn column: Int
    ) -> (url: URL, columns: Range<Int>)? {
        // Build row text plus a scalar→column map (wide spacers collapse).
        var scalars = String.UnicodeScalarView()
        var columnOf: [Int] = []
        for (x, cell) in line.enumerated() where !cell.attributes.contains(.wideSpacer) {
            scalars.append(Unicode.Scalar(cell.glyph) ?? " ")
            columnOf.append(x)
        }
        let text = String(scalars)
        guard let scalarIndex = columnOf.lastIndex(where: { $0 <= column }) else { return nil }

        for token in candidates(in: text) {
            let range = token.range
            let start = text.unicodeScalars.distance(
                from: text.unicodeScalars.startIndex, to: range.lowerBound)
            let end = start + text.unicodeScalars.distance(
                from: range.lowerBound, to: range.upperBound)
            guard scalarIndex >= start, scalarIndex < end else { continue }
            // Map the scalar span back to cells (end-1 is the last scalar).
            return (token.url, columnOf[start]..<(columnOf[end - 1] + 1))
        }
        return nil
    }

    private struct Candidate {
        var range: Range<String.UnicodeScalarIndex>
        var url: URL
    }

    private static let urlPattern = try? NSRegularExpression(
        pattern: #"(?:https?|file|ftp)://[^\s<>"'\)\]]+"#)
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(?:~|\.{0,2})/[\w.@%+=:,\-/~]+"#)

    private static func candidates(in text: String) -> [Candidate] {
        var out: [Candidate] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in urlPattern?.matches(in: text, range: full) ?? [] {
            guard let range = Range(match.range, in: text) else { continue }
            // Strip trailing punctuation that's usually sentence syntax.
            var candidate = String(text[range])
            while let last = candidate.last, ".,;:!?".contains(last) {
                candidate.removeLast()
            }
            if let url = URL(string: candidate), url.scheme != nil {
                out.append(Candidate(
                    range: range.lowerBound..<range.upperBound, url: url))
            }
        }
        for match in pathPattern?.matches(in: text, range: full) ?? [] {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range])
            let expanded = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            out.append(Candidate(
                range: range.lowerBound..<range.upperBound,
                url: URL(fileURLWithPath: expanded)))
        }
        return out
    }
}

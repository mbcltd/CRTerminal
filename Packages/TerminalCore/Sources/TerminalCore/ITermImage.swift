import Foundation

/// iTerm2 inline images: `OSC 1337 ; File=<args> : <base64> ST`. The args are
/// `key=value;…` and include the display size (`width`/`height` in cells,
/// `Npx` pixels, `N%` of the terminal, or `auto`) and `inline=1` to render
/// rather than download. Other OSC 1337 verbs (SetUserVar, CurrentDir, …) are
/// ignored here.
extension TerminalState {
    mutating func handleITerm1337(_ body: ArraySlice<UInt8>) {
        let prefix = Array("File=".utf8)
        guard body.count > prefix.count,
              Array(body.prefix(prefix.count)) == prefix else { return }
        let rest = body.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: UInt8(ascii: ":")) else { return }
        let argString = String(decoding: rest[..<colon], as: UTF8.self)
        let base64 = rest[(colon + 1)...]

        var args: [String: String] = [:]
        for pair in argString.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { args[kv[0].lowercased()] = String(kv[1]) }
        }
        // inline defaults to 0 (download); only inline=1 renders.
        guard args["inline"] == "1" else { return }

        guard let data = Data(base64Encoded: Data(base64), options: .ignoreUnknownCharacters),
              !data.isEmpty else { return }
        let bytes = [UInt8](data)
        guard bytes.count <= Self.maxImageBytes else { return }
        let dims = ImageHeader.dimensions(of: bytes)
        let pixelW = dims?.width ?? 0
        let pixelH = dims?.height ?? 0

        var columns = resolveITermExtent(
            args["width"], cellPixels: cellPixelWidth, gridCells: self.columns)
        var rows = resolveITermExtent(
            args["height"], cellPixels: cellPixelHeight, gridCells: self.rows)

        // preserveAspectRatio (default true): if only one extent is pinned,
        // derive the other from the image's aspect in cells.
        let preserve = args["preserveaspectratio"] != "0"
        if preserve, pixelW > 0, pixelH > 0 {
            let aspectRows = Double(pixelH) / Double(cellPixelHeight)
            let aspectCols = Double(pixelW) / Double(cellPixelWidth)
            if let c = columns, rows == nil, aspectCols > 0 {
                rows = max(1, Int((Double(c) * aspectRows / aspectCols).rounded()))
            } else if let r = rows, columns == nil, aspectRows > 0 {
                columns = max(1, Int((Double(r) * aspectCols / aspectRows).rounded()))
            }
        }

        let serial = storeImage(
            format: .encoded,
            pixelWidth: pixelW > 0 ? pixelW : cellPixelWidth,
            pixelHeight: pixelH > 0 ? pixelH : cellPixelHeight,
            bytes: bytes)
        displayImage(serial: serial, columns: columns, rows: rows)
    }

    /// Parse one iTerm2 size token into a cell count, or nil for auto/absent.
    private func resolveITermExtent(
        _ token: String?, cellPixels: Int, gridCells: Int
    ) -> Int? {
        guard let token, !token.isEmpty, token != "auto" else { return nil }
        if token.hasSuffix("px") {
            let px = Int(token.dropLast(2)) ?? 0
            return px > 0 ? max(1, (px + cellPixels - 1) / cellPixels) : nil
        }
        if token.hasSuffix("%") {
            let pct = Double(token.dropLast()) ?? 0
            return pct > 0 ? max(1, Int((pct / 100 * Double(gridCells)).rounded())) : nil
        }
        return Int(token).map { max(1, $0) } // bare number = cells
    }
}

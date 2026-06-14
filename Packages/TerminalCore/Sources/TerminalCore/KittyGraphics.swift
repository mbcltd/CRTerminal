import Foundation
#if canImport(Compression)
import Compression
#endif

/// The kitty graphics protocol (https://sw.kovidgoyal.net/kitty/graphics-protocol/).
/// Commands arrive as APC strings `ESC _ G <key=value,...> ; <base64 payload> ESC \`.
///
/// Implemented: transmit (direct & file/temp-file media), formats RGBA/RGB/PNG,
/// chunked transmission (m=), zlib (o=z), display/put with source crop, cell
/// extent, z-index and placement ids, delete, and query — with APC responses.
/// Not implemented: animation frames (a=f/a=c/a=a) and shared-memory media,
/// which are ignored.

/// Parsed kitty control keys (the part before the `;`).
struct KittyControl: Sendable, Equatable {
    var action: UInt8 = UInt8(ascii: "t")       // a=
    var medium: UInt8 = UInt8(ascii: "d")       // t=
    var format = 32                              // f=
    var compression: UInt8 = 0                   // o= ('z' or 0)
    var more = 0                                 // m=
    var width = 0                                // s= (pixels)
    var height = 0                               // v= (pixels)
    var dataSize = 0                             // S=
    var dataOffset = 0                           // O=
    var imageID: UInt32 = 0                      // i=
    var imageNumber: UInt32 = 0                  // I=
    var placementID: UInt32 = 0                  // p=
    var cropX = 0                                // x=
    var cropY = 0                                // y=
    var cropW = 0                                // w=
    var cropH = 0                                // h=
    var columns = 0                              // c=
    var rows = 0                                 // r=
    var zIndex: Int32 = 0                        // z=
    var cursorMovement = 0                       // C=
    var quiet = 0                                // q=
    var deleteTarget: UInt8 = UInt8(ascii: "a")  // d=

    init(parsing bytes: [UInt8]) {
        for pair in bytes.split(separator: UInt8(ascii: ",")) {
            // Keys are single letters: "a=T", "f=32", …
            guard let eq = pair.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = pair[pair.startIndex]
            let valueBytes = pair[pair.index(after: eq)...]
            let value = String(decoding: valueBytes, as: UTF8.self)
            let int = Int(value)
            switch key {
            case UInt8(ascii: "a"): action = valueBytes.first ?? action
            case UInt8(ascii: "t"): medium = valueBytes.first ?? medium
            case UInt8(ascii: "f"): format = int ?? format
            case UInt8(ascii: "o"): compression = valueBytes.first ?? 0
            case UInt8(ascii: "m"): more = int ?? more
            case UInt8(ascii: "s"): width = int ?? width
            case UInt8(ascii: "v"): height = int ?? height
            case UInt8(ascii: "S"): dataSize = int ?? dataSize
            case UInt8(ascii: "O"): dataOffset = int ?? dataOffset
            case UInt8(ascii: "i"): imageID = int.map { UInt32(clamping: $0) } ?? imageID
            case UInt8(ascii: "I"): imageNumber = int.map { UInt32(clamping: $0) } ?? imageNumber
            case UInt8(ascii: "p"): placementID = int.map { UInt32(clamping: $0) } ?? placementID
            case UInt8(ascii: "x"): cropX = int ?? cropX
            case UInt8(ascii: "y"): cropY = int ?? cropY
            case UInt8(ascii: "w"): cropW = int ?? cropW
            case UInt8(ascii: "h"): cropH = int ?? cropH
            case UInt8(ascii: "c"): columns = int ?? columns
            case UInt8(ascii: "r"): rows = int ?? rows
            case UInt8(ascii: "z"): zIndex = int.map { Int32(clamping: $0) } ?? zIndex
            case UInt8(ascii: "C"): cursorMovement = int ?? cursorMovement
            case UInt8(ascii: "q"): quiet = int ?? quiet
            case UInt8(ascii: "d"): deleteTarget = valueBytes.first ?? deleteTarget
            default: break
            }
        }
    }
}

/// Accumulated chunked transmission (m=1). kitty allows one at a time; the
/// control keys ride on the first chunk.
struct KittyTransfer: Sendable, Equatable {
    var control: KittyControl
    var payload: [UInt8]
}

extension TerminalState {
    public mutating func apcDispatch(_ payload: [UInt8]) {
        guard payload.first == UInt8(ascii: "G") else { return } // graphics only
        let body = Array(payload.dropFirst())
        let sep = body.firstIndex(of: UInt8(ascii: ";"))
        let controlBytes = sep.map { Array(body[..<$0]) } ?? body
        let dataBytes = sep.map { Array(body[($0 + 1)...]) } ?? []
        let control = KittyControl(parsing: controlBytes)

        // Chunked transmission: stitch payloads, control rides the first chunk.
        if kittyTransfer != nil {
            kittyTransfer!.payload.append(contentsOf: dataBytes)
            if kittyTransfer!.payload.count > Self.maxImageBytes { kittyTransfer = nil; return }
            if control.more != 1 {
                let transfer = kittyTransfer!
                kittyTransfer = nil
                finishKitty(control: transfer.control, base64: transfer.payload)
            }
            return
        }
        if control.more == 1 {
            kittyTransfer = KittyTransfer(control: control, payload: dataBytes)
            return
        }
        finishKitty(control: control, base64: dataBytes)
    }

    private mutating func finishKitty(control: KittyControl, base64: [UInt8]) {
        switch control.action {
        case UInt8(ascii: "q"): // query: validate format, don't store
            respondKitty(control, "OK")
        case UInt8(ascii: "d"):
            deleteKitty(control)
        case UInt8(ascii: "p"): // put: display an already-transmitted image
            if let serial = serial(for: control) {
                displayKitty(serial: serial, control: control)
                respondKitty(control, "OK")
            } else {
                respondKitty(control, "ENOENT:image not found")
            }
        default: // t / T (and frame/compose, which we treat as transmit)
            transmitKitty(control: control, base64: base64)
        }
    }

    private mutating func transmitKitty(control: KittyControl, base64: [UInt8]) {
        guard let raw = Self.decodeKittyData(control: control, base64: base64) else {
            respondKitty(control, "EBADF:could not read image data")
            return
        }
        let format: ImageFormat
        var width = control.width
        var height = control.height
        switch control.format {
        case 100: // PNG container
            format = .encoded
            if let dims = ImageHeader.dimensions(of: raw) { width = dims.width; height = dims.height }
        case 24:
            format = .rgb
        default: // 32
            format = .rgba
        }
        guard width > 0, height > 0 else {
            respondKitty(control, "EINVAL:missing image dimensions")
            return
        }
        // Sanity-check raw sizes for uncompressed pixel data.
        if format == .rgb, raw.count < width * height * 3 {
            respondKitty(control, "EINVAL:RGB data too small"); return
        }
        if format == .rgba, raw.count < width * height * 4 {
            respondKitty(control, "EINVAL:RGBA data too small"); return
        }

        let serial = storeImage(
            format: format, pixelWidth: width, pixelHeight: height, bytes: raw)
        if control.imageID != 0 { kittyImageSerials[control.imageID] = serial }
        if control.imageNumber != 0 { kittyImageNumbers[control.imageNumber] = serial }

        if control.action == UInt8(ascii: "T") {
            displayKitty(serial: serial, control: control)
        }
        respondKitty(control, "OK")
    }

    private mutating func displayKitty(serial: UInt32, control: KittyControl) {
        displayImage(
            serial: serial,
            placementID: control.placementID,
            columns: control.columns > 0 ? control.columns : nil,
            rows: control.rows > 0 ? control.rows : nil,
            sourceX: control.cropX, sourceY: control.cropY,
            sourceWidth: control.cropW, sourceHeight: control.cropH,
            zIndex: control.zIndex,
            moveCursor: control.cursorMovement != 1)
    }

    private mutating func deleteKitty(_ control: KittyControl) {
        let target = control.deleteTarget
        let freeData = target.isUppercaseLetter
        let lower = target | 0x20 // ASCII fold
        switch lower {
        case UInt8(ascii: "i"): // by image id (+ placement id if given)
            if let serial = kittyImageSerials[control.imageID] {
                if control.placementID != 0 {
                    imagePlacements.removeAll {
                        $0.imageID == serial && $0.placementID == control.placementID
                    }
                } else {
                    imagePlacements.removeAll { $0.imageID == serial }
                }
                if freeData { dropImage(serial) }
            }
        case UInt8(ascii: "n"): // by image number
            if let serial = kittyImageNumbers[control.imageNumber] {
                imagePlacements.removeAll { $0.imageID == serial }
                if freeData { dropImage(serial) }
            }
        default: // 'a' and everything else: all visible placements
            imagePlacements.removeAll()
            if freeData { clearAllImages() }
        }
        markImagesChanged()
    }

    /// Resolve an already-transmitted image for an `a=p` put.
    private func serial(for control: KittyControl) -> UInt32? {
        if control.imageID != 0, let s = kittyImageSerials[control.imageID] { return s }
        if control.imageNumber != 0, let s = kittyImageNumbers[control.imageNumber] { return s }
        return nil
    }

    /// Send `ESC _ G <ids> ; <message> ESC \`. kitty only replies when the
    /// client named the image (i=/I=) and `q` permits it.
    private mutating func respondKitty(_ control: KittyControl, _ message: String) {
        let isError = message != "OK"
        if control.quiet >= 2 { return }
        if control.quiet >= 1 && !isError { return }
        guard control.imageID != 0 || control.imageNumber != 0 else { return }
        var keys: [String] = []
        if control.imageID != 0 { keys.append("i=\(control.imageID)") }
        if control.imageNumber != 0 { keys.append("I=\(control.imageNumber)") }
        if control.placementID != 0 { keys.append("p=\(control.placementID)") }
        let header = keys.joined(separator: ",")
        appendResponse(Array("\u{1B}_G\(header);\(message)\u{1B}\\".utf8))
        markImagesChanged()
    }

    // MARK: Decoding

    private static func decodeKittyData(control: KittyControl, base64: [UInt8]) -> [UInt8]? {
        guard let decoded = base64Decode(base64) else { return nil }
        var raw: [UInt8]
        switch control.medium {
        case UInt8(ascii: "f"), UInt8(ascii: "t"): // file / temp file
            let path = String(decoding: decoded, as: UTF8.self)
            guard let bytes = readFileBytes(
                path: path, offset: control.dataOffset, size: control.dataSize) else { return nil }
            raw = bytes
            if control.medium == UInt8(ascii: "t") { try? FileManager.default.removeItem(atPath: path) }
        default: // direct
            raw = decoded
        }
        if control.compression == UInt8(ascii: "z") {
            guard let inflated = zlibInflate(raw) else { return nil }
            raw = inflated
        }
        return raw
    }

    private static func base64Decode(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        let data = Data(bytes)
        guard let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters)
        else { return nil }
        return [UInt8](decoded)
    }

    private static func readFileBytes(path: String, offset: Int, size: Int) -> [UInt8]? {
        guard !path.isEmpty,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        let cap = min(size > 0 ? size : maxImageBytes, maxImageBytes)
        guard let data = try? handle.read(upToCount: cap), !data.isEmpty else { return nil }
        return [UInt8](data)
    }
}

private extension UInt8 {
    var isUppercaseLetter: Bool { self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z") }
}

/// Inflate kitty's zlib (RFC1950) payload. Apple's COMPRESSION_ZLIB consumes
/// raw DEFLATE, so strip the 2-byte zlib header and 4-byte adler trailer.
func zlibInflate(_ input: [UInt8]) -> [UInt8]? {
#if canImport(Compression)
    guard input.count > 6 else { return nil }
    var src = input
    if src[0] & 0x0F == 0x08, ((UInt16(src[0]) << 8 | UInt16(src[1])) % 31) == 0 {
        src.removeFirst(2)
        src.removeLast(4)
    }
    guard !src.isEmpty else { return nil }
    var output: [UInt8] = []
    let bufferSize = 256 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    var stream = compression_stream(
        dst_ptr: buffer, dst_size: bufferSize, src_ptr: buffer, src_size: 0, state: nil)
    guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { return nil }
    defer { compression_stream_destroy(&stream) }

    let result: [UInt8]? = src.withUnsafeBufferPointer { srcBuf -> [UInt8]? in
        stream.src_ptr = srcBuf.baseAddress!
        stream.src_size = srcBuf.count
        while true {
            stream.dst_ptr = buffer
            stream.dst_size = bufferSize
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: bufferSize - stream.dst_size))
                if status == COMPRESSION_STATUS_END { return output }
                if output.count > TerminalState.maxImageBytes { return nil }
            default:
                return nil
            }
        }
    }
    return result
#else
    return nil
#endif
}

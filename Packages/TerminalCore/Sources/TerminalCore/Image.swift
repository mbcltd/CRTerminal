/// Inline-image support shared by the kitty graphics protocol, sixel, and
/// iTerm2's OSC 1337. The core stores image bytes plus where each is shown;
/// `CRTRendering` decodes them to GPU textures and composites them into the
/// cell pass (so they pass through the CRT effect chain like everything else).

/// How an image's bytes are encoded in `TerminalImage.bytes`.
public enum ImageFormat: Sendable, Equatable {
    /// Raw 8-bit RGBA, `pixelWidth * pixelHeight * 4` bytes (kitty f=32,
    /// decoded sixel).
    case rgba
    /// Raw 8-bit RGB, `pixelWidth * pixelHeight * 3` bytes (kitty f=24).
    case rgb
    /// A container the renderer decodes via ImageIO — PNG (kitty f=100),
    /// or whatever iTerm2 handed us (PNG/JPEG/GIF/…).
    case encoded
}

/// One transmitted image, kept by internal serial. The serial is the
/// renderer's texture-cache key, so re-transmitting a kitty image (which
/// reuses its client id) gets a fresh serial and busts the stale texture.
public struct TerminalImage: Sendable, Equatable {
    public var id: UInt32
    public var format: ImageFormat
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var bytes: [UInt8]

    public init(id: UInt32, format: ImageFormat, pixelWidth: Int, pixelHeight: Int, bytes: [UInt8]) {
        self.id = id
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytes = bytes
    }
}

/// Where an image is shown on the grid. Anchored to an absolute row so it
/// scrolls with the text and is evicted with the scrollback (like
/// `PromptMark`). Display extent is in cells; the source crop is in pixels.
public struct ImagePlacement: Sendable, Equatable {
    /// Internal serial of the image (`TerminalImage.id`).
    public var imageID: UInt32
    /// kitty placement id (p=); 0 when unset. Lets a client replace/delete a
    /// specific placement of an image that has several.
    public var placementID: UInt32
    /// Absolute row of the top-left cell (scrollback-stable).
    public var row: Int
    /// Column of the top-left cell.
    public var column: Int
    /// Display size in cells.
    public var rows: Int
    public var columns: Int
    /// Source crop in image pixels; width/height 0 means "to the edge".
    public var sourceX: Int
    public var sourceY: Int
    public var sourceWidth: Int
    public var sourceHeight: Int
    /// kitty z-index (z=). Negative draws under the text, ≥0 over it.
    public var zIndex: Int32
    /// Placements live in primary- or alternate-screen coordinate space and
    /// are only drawn while that screen is active.
    public var onAlternateScreen: Bool

    public init(
        imageID: UInt32, placementID: UInt32 = 0, row: Int, column: Int,
        rows: Int, columns: Int, sourceX: Int = 0, sourceY: Int = 0,
        sourceWidth: Int = 0, sourceHeight: Int = 0, zIndex: Int32 = 0,
        onAlternateScreen: Bool = false
    ) {
        self.imageID = imageID
        self.placementID = placementID
        self.row = row
        self.column = column
        self.rows = rows
        self.columns = columns
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.zIndex = zIndex
        self.onAlternateScreen = onAlternateScreen
    }
}

/// Reads pixel dimensions straight from a container's header, so the core can
/// map an encoded image (PNG/JPEG/GIF/BMP) onto a cell grid without a full
/// decode (that happens later, in the renderer). Returns nil for formats it
/// doesn't recognise.
enum ImageHeader {
    static func dimensions(of bytes: [UInt8]) -> (width: Int, height: Int)? {
        png(bytes) ?? gif(bytes) ?? bmp(bytes) ?? jpeg(bytes)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
    private static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }
    private static func le16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8
    }

    private static func png(_ b: [UInt8]) -> (Int, Int)? {
        // 8-byte signature, then an IHDR chunk whose data starts at offset 16.
        guard b.count >= 24,
              b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 else { return nil }
        return (be32(b, 16), be32(b, 20))
    }

    private static func gif(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count >= 10, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 else { return nil }
        return (le16(b, 6), le16(b, 8))
    }

    private static func bmp(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count >= 26, b[0] == 0x42, b[1] == 0x4D else { return nil }
        return (le32(b, 18), abs(le32(b, 22)))
    }

    private static func jpeg(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            // Standalone markers without a length field.
            if marker == 0xD8 || marker == 0xD9 || (0xD0...0xD7).contains(marker) {
                i += 2
                continue
            }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            // SOF0..SOF15 carry the frame dimensions (skip DHT/DAC/SOFx pad).
            if (0xC0...0xCF).contains(marker),
               marker != 0xC4, marker != 0xC8, marker != 0xCC,
               i + 9 < b.count {
                let height = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let width = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return (width, height)
            }
            if length < 2 { return nil }
            i += 2 + length
        }
        return nil
    }
}

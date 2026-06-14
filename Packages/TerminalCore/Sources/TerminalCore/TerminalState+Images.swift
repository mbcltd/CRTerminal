/// Image store management shared by all three graphics protocols: registering
/// transmitted images under an internal serial, placing them on the grid, and
/// evicting them when they scroll away or memory caps are hit. Cursor and
/// scroll mutations go through the internal helpers in `TerminalState.swift`.
extension TerminalState {
    /// Set by the app from the renderer's cell metrics (points × backing
    /// scale). Pixel→cell math and CSI 14/16 t depend on it.
    public mutating func setCellPixelSize(width: Int, height: Int) {
        let w = max(1, width), h = max(1, height)
        guard w != cellPixelWidth || h != cellPixelHeight else { return }
        cellPixelWidth = w
        cellPixelHeight = h
    }

    /// Register a transmitted image; returns its internal serial (the
    /// renderer's texture-cache key). Enforces the memory caps.
    mutating func storeImage(
        format: ImageFormat, pixelWidth: Int, pixelHeight: Int, bytes: [UInt8]
    ) -> UInt32 {
        let serial = nextImageSerial
        nextImageSerial &+= 1
        images[serial] = TerminalImage(
            id: serial, format: format,
            pixelWidth: max(1, pixelWidth), pixelHeight: max(1, pixelHeight),
            bytes: bytes)
        totalImageBytes += bytes.count
        evictImagesIfNeeded(keeping: serial)
        return serial
    }

    /// Drop an image and everything referencing it.
    mutating func dropImage(_ serial: UInt32) {
        if let image = images.removeValue(forKey: serial) {
            totalImageBytes -= image.bytes.count
        }
        imagePlacements.removeAll { $0.imageID == serial }
        kittyImageSerials = kittyImageSerials.filter { $0.value != serial }
        kittyImageNumbers = kittyImageNumbers.filter { $0.value != serial }
    }

    mutating func clearAllImages() {
        images.removeAll()
        imagePlacements.removeAll()
        kittyImageSerials.removeAll()
        kittyImageNumbers.removeAll()
        kittyTransfer = nil
        totalImageBytes = 0
    }

    /// Evict the oldest images (lowest serial) until back under the caps,
    /// never the one just stored.
    private mutating func evictImagesIfNeeded(keeping keep: UInt32) {
        while images.count > Self.maxImages || totalImageBytes > Self.maxImageBytes {
            guard let victim = images.keys.filter({ $0 != keep }).min() else { break }
            dropImage(victim)
        }
    }

    /// Drop placements whose every row has fallen out of scrollback.
    mutating func pruneEvictedImagePlacements() {
        let cutoff = evictedLineCount
        imagePlacements.removeAll { $0.row + $0.rows <= cutoff }
    }

    private func cells(_ pixels: Int, per cellPixels: Int) -> Int {
        max(1, (max(0, pixels) + cellPixels - 1) / cellPixels)
    }

    /// Place a stored image at the cursor and (optionally) advance below it.
    /// `columns`/`rows` override the cell extent; otherwise it's derived from
    /// the source crop and the cell pixel size. The source rect is in image
    /// pixels (0 width/height means "to the edge").
    mutating func displayImage(
        serial: UInt32, placementID: UInt32 = 0,
        columns: Int? = nil, rows: Int? = nil,
        sourceX: Int = 0, sourceY: Int = 0,
        sourceWidth: Int = 0, sourceHeight: Int = 0,
        zIndex: Int32 = 0, moveCursor: Bool = true
    ) {
        guard let image = images[serial] else { return }
        let srcX = min(max(0, sourceX), image.pixelWidth)
        let srcY = min(max(0, sourceY), image.pixelHeight)
        let srcW = sourceWidth > 0
            ? min(sourceWidth, image.pixelWidth - srcX) : image.pixelWidth - srcX
        let srcH = sourceHeight > 0
            ? min(sourceHeight, image.pixelHeight - srcY) : image.pixelHeight - srcY
        guard srcW > 0, srcH > 0 else { return }

        let cols = min(max(1, columns ?? cells(srcW, per: cellPixelWidth)), self.columns)
        let rws = max(1, rows ?? cells(srcH, per: cellPixelHeight))
        let startColumn = cursor.x

        let placement = ImagePlacement(
            imageID: serial, placementID: placementID,
            row: imageAnchorRow, column: startColumn,
            rows: rws, columns: cols,
            sourceX: srcX, sourceY: srcY, sourceWidth: srcW, sourceHeight: srcH,
            zIndex: zIndex, onAlternateScreen: isAlternateScreen)

        // A specific placement id replaces its previous incarnation.
        if placementID != 0 {
            imagePlacements.removeAll {
                $0.imageID == serial && $0.placementID == placementID
            }
        }
        imagePlacements.append(placement)
        if imagePlacements.count > Self.maxPlacements {
            imagePlacements.removeFirst(imagePlacements.count - Self.maxPlacements)
        }

        if moveCursor {
            advanceCursorBelowImage(rows: rws, startColumn: startColumn)
        } else {
            markImagesChanged()
        }
    }

    static var maxPlacements: Int { 4096 }
}

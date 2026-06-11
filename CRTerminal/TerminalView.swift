import AppKit
import CRTRendering
import QuartzCore
import TerminalCore

/// The terminal surface: hosts the CAMetalLayer, owns the renderer, and
/// translates AppKit input into PTY bytes. Implements NSTextInputClient from
/// day one so IME isn't a retrofit (ARCHITECTURE.md risks).
final class TerminalView: NSView, NSTextInputClient {
    private(set) var renderer: TerminalRenderer?
    var session: TerminalSession? {
        didSet { wireSession() }
    }

    private var lastDrawnGeneration: UInt64?
    private var lastBellCount: UInt64 = 0
    private var markedText: String?
    /// Frames actually drawn; reported by the typist probe.
    private(set) var drawCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Without this, AppKit never calls updateLayer for custom backing
        // layers (the default policy is .never).
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalView is created in code")
    }

    // MARK: Layer / drawing

    override var acceptsFirstResponder: Bool { true }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    /// Renders the current snapshot into the layer. Driven directly by
    /// session updates and geometry changes — a CAMetalLayer presents its own
    /// drawables, so AppKit's contents-update cycle is not involved. Phase 3
    /// moves this onto a CAMetalDisplayLink render thread.
    private func renderFrame() {
        guard let session else { return }
        setUpRendererIfNeeded()
        guard let renderer, let metalLayer else { return }

        let state = session.snapshot
        if state.bellCount != lastBellCount {
            lastBellCount = state.bellCount
            NSSound.beep()
        }
        if let title = state.title, window?.title != title {
            window?.title = title
        }
        guard state.generation != lastDrawnGeneration else { return }
        lastDrawnGeneration = state.generation

        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0 else { return }
        metalLayer.drawableSize = size
        renderer.draw(state, into: metalLayer)
        drawCount += 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setUpRendererIfNeeded()
        window?.makeFirstResponder(self)
        forceRedraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
        forceRedraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        forceRedraw()
    }

    private func setUpRendererIfNeeded() {
        guard renderer == nil, window != nil else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        renderer = TerminalRenderer(
            font: font, scale: window?.backingScaleFactor ?? 2)
        updateGridSize()
    }

    private func forceRedraw() {
        lastDrawnGeneration = nil
        renderFrame()
    }

    private func wireSession() {
        session?.onUpdate = { [weak self] in
            self?.renderFrame()
        }
        forceRedraw()
    }

    private func updateGridSize() {
        guard let renderer, let session else { return }
        let columns = max(2, Int(bounds.width / renderer.cellSize.width))
        let rows = max(2, Int(bounds.height / renderer.cellSize.height))
        session.resize(columns: columns, rows: rows)
    }

    /// Points for a cols×rows grid; the window sizes itself with this.
    func sizeForGrid(columns: Int, rows: Int) -> NSSize {
        guard let renderer else { return NSSize(width: 800, height: 540) }
        return NSSize(
            width: CGFloat(columns) * renderer.cellSize.width,
            height: CGFloat(rows) * renderer.cellSize.height)
    }

    // MARK: Input

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        renderer?.markInput()
        session?.send(bytes)
    }

    override func keyDown(with event: NSEvent) {
        // Control combinations bypass the input context (^C must not reach
        // an IME). NSEvent already maps ctrl+letter to the control character.
        if event.modifierFlags.contains(.control),
           let characters = event.characters, !characters.isEmpty,
           let scalar = characters.unicodeScalars.first, scalar.value < 0x20 {
            send([UInt8(scalar.value)])
            return
        }
        inputContext?.handleEvent(event)
    }

    override func doCommand(by selector: Selector) {
        let modes = session?.snapshot.modes
        let application = modes?.applicationCursorKeys ?? false

        func key(_ key: TerminalKey, _ modifiers: KeyModifiers = []) {
            send(KeyEncoder.encode(key, modifiers: modifiers, applicationCursorKeys: application))
        }

        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)):
            key(.enter)
        case #selector(deleteBackward(_:)):
            key(.backspace)
        case #selector(deleteForward(_:)):
            key(.deleteForward)
        case #selector(insertTab(_:)):
            key(.tab)
        case #selector(insertBacktab(_:)):
            key(.tab, [.shift])
        case #selector(cancelOperation(_:)):
            key(.escape)
        case #selector(moveUp(_:)): key(.up)
        case #selector(moveDown(_:)): key(.down)
        case #selector(moveLeft(_:)): key(.left)
        case #selector(moveRight(_:)): key(.right)
        case #selector(moveUpAndModifySelection(_:)): key(.up, [.shift])
        case #selector(moveDownAndModifySelection(_:)): key(.down, [.shift])
        case #selector(moveLeftAndModifySelection(_:)): key(.left, [.shift])
        case #selector(moveRightAndModifySelection(_:)): key(.right, [.shift])
        case #selector(moveWordLeft(_:)): send([0x1B, UInt8(ascii: "b")])
        case #selector(moveWordRight(_:)): send([0x1B, UInt8(ascii: "f")])
        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)): key(.pageUp)
        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)): key(.pageDown)
        case #selector(scrollToBeginningOfDocument(_:)),
             #selector(moveToBeginningOfDocument(_:)),
             #selector(moveToBeginningOfLine(_:)):
            key(.home)
        case #selector(scrollToEndOfDocument(_:)),
             #selector(moveToEndOfDocument(_:)),
             #selector(moveToEndOfLine(_:)):
            key(.end)
        default:
            break // swallow silently; a terminal shouldn't beep on unknowns
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let bracketed = session?.snapshot.modes.bracketedPaste ?? false
        send(KeyEncoder.encodePaste(text, bracketed: bracketed))
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = nil
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        send(Array(text.utf8))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Stored but not yet drawn in-grid; composed text arrives via
        // insertText. Visual marked-text rendering lands in Phase 5.
        markedText = (string as? NSAttributedString)?.string ?? (string as? String)
    }

    func unmarkText() {
        markedText = nil
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard let markedText, !markedText.isEmpty else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool {
        markedText != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // IME candidate window anchors at the cursor cell.
        guard let renderer, let session, let window else { return .zero }
        let cursor = session.snapshot.cursor
        let cell = renderer.cellSize
        let local = NSRect(
            x: CGFloat(cursor.x) * cell.width,
            y: bounds.height - CGFloat(cursor.y + 1) * cell.height,
            width: cell.width,
            height: cell.height)
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }
}

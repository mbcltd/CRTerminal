import AppKit
import CRTRendering
import QuartzCore
import TerminalCore

/// The terminal surface: hosts the CAMetalLayer, owns the renderer, and
/// translates AppKit input into PTY bytes. Implements NSTextInputClient from
/// day one so IME isn't a retrofit (ARCHITECTURE.md risks).
final class TerminalView: NSView, NSTextInputClient {
    private(set) var renderer: TerminalRenderer?
    private(set) var renderLoop: RenderLoop?
    var session: TerminalSession? {
        didSet { wireSession() }
    }

    private var lastBellCount: UInt64 = 0
    private var markedText: String?
    /// Frames actually drawn (on the render thread); probe-reported.
    var drawCount: Int { renderLoop?.drawCount ?? 0 }

    /// Lines scrolled back from live (0 = following output).
    private var scrollOffset = 0
    private var wheelAccumulator: CGFloat = 0
    private var selection: Selection?
    private var selectionAnchor: SelectionPoint?
    private var lastReportedDragCell: (x: Int, y: Int)?
    private var keyWindowObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalView is created in code")
    }

    deinit {
        for observer in keyWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Layer / drawing

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    /// Main-thread reaction to session updates: side effects (bell, title,
    /// offset clamping) plus waking the render thread. Drawing itself happens
    /// on the RenderLoop's CAMetalDisplayLink thread.
    private func sessionDidUpdate() {
        guard let session else { return }
        let state = session.snapshot
        if state.bellCount != lastBellCount {
            lastBellCount = state.bellCount
            NSSound.beep()
        }
        if let title = state.title, window?.title != title {
            window?.title = title
        }
        let clamped = min(scrollOffset, state.scrollback.count)
        if clamped != scrollOffset {
            scrollOffset = clamped
            pushViewStateToRenderLoop()
        }
        renderLoop?.poke()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setUpRendererIfNeeded()
        window?.makeFirstResponder(self)
        observeKeyWindow()
        updateLayerGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if selection != nil {
            selection = nil
            pushViewStateToRenderLoop()
        }
        updateGridSize()
        updateLayerGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerGeometry()
    }

    private func setUpRendererIfNeeded() {
        guard renderer == nil, window != nil, let metalLayer, let session else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        guard let renderer = TerminalRenderer(
            font: font, scale: window?.backingScaleFactor ?? 2) else { return }
        self.renderer = renderer
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        updateGridSize()
        updateLayerGeometry()
        renderLoop = RenderLoop(layer: metalLayer, renderer: renderer, session: session)
    }

    /// Geometry is owned by the main thread; the render thread just consumes
    /// drawables at whatever size the layer currently has.
    private func updateLayerGeometry() {
        guard let metalLayer else { return }
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        let size = convertToBacking(bounds).size
        if size.width > 0, size.height > 0 {
            metalLayer.drawableSize = size
        }
        renderLoop?.poke(force: true)
    }

    private func pushViewStateToRenderLoop() {
        renderLoop?.setViewState(scrollOffset: scrollOffset, selection: selection)
    }

    private func wireSession() {
        session?.onUpdate = { [weak self] in
            self?.sessionDidUpdate()
        }
        setUpRendererIfNeeded()
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

    private func observeKeyWindow() {
        for observer in keyWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        keyWindowObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        keyWindowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendFocusReport(focused: true) }
        })
        keyWindowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendFocusReport(focused: false) }
        })
    }

    private func sendFocusReport(focused: Bool) {
        guard session?.snapshot.modes.focusReporting == true else { return }
        send(Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8))
    }

    // MARK: Sending

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        renderer?.markInput()
        session?.send(bytes)
    }

    /// Keyboard input snaps the viewport back to live and drops selection.
    private func sendKeyboard(_ bytes: [UInt8]) {
        if scrollOffset != 0 {
            scrollOffset = 0
            pushViewStateToRenderLoop()
        }
        if selection != nil {
            selection = nil
            pushViewStateToRenderLoop()
        }
        send(bytes)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Control combinations bypass the input context (^C must not reach
        // an IME). NSEvent already maps ctrl+letter to the control character.
        if event.modifierFlags.contains(.control),
           let characters = event.characters, !characters.isEmpty,
           let scalar = characters.unicodeScalars.first, scalar.value < 0x20 {
            sendKeyboard([UInt8(scalar.value)])
            return
        }
        inputContext?.handleEvent(event)
    }

    override func doCommand(by selector: Selector) {
        let modes = session?.snapshot.modes
        let application = modes?.applicationCursorKeys ?? false

        func key(_ key: TerminalKey, _ modifiers: KeyModifiers = []) {
            sendKeyboard(KeyEncoder.encode(
                key, modifiers: modifiers, applicationCursorKeys: application))
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
        case #selector(moveWordLeft(_:)): sendKeyboard([0x1B, UInt8(ascii: "b")])
        case #selector(moveWordRight(_:)): sendKeyboard([0x1B, UInt8(ascii: "f")])
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

    // MARK: Clipboard

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let bracketed = session?.snapshot.modes.bracketedPaste ?? false
        sendKeyboard(KeyEncoder.encodePaste(text, bracketed: bracketed))
    }

    @objc func copy(_ sender: Any?) {
        guard let selection, let state = session?.snapshot else { return }
        let text = state.text(in: selection)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return selection != nil && !(selection?.isEmpty ?? true)
        }
        return true
    }

    // MARK: Mouse

    private func cellPosition(of event: NSEvent) -> (x: Int, y: Int) {
        guard let renderer else { return (0, 0) }
        let point = convert(event.locationInWindow, from: nil)
        let x = min(max(0, Int(point.x / renderer.cellSize.width)),
                    (session?.snapshot.columns ?? 1) - 1)
        let y = min(max(0, Int(point.y / renderer.cellSize.height)),
                    (session?.snapshot.rows ?? 1) - 1)
        return (x, y)
    }

    private func absolutePoint(of event: NSEvent) -> SelectionPoint {
        let cell = cellPosition(of: event)
        let state = session?.snapshot
        let top = (state?.absoluteScreenTop ?? 0) - scrollOffset
        return SelectionPoint(row: top + cell.y, column: cell.x)
    }

    private func keyModifiers(of event: NSEvent) -> KeyModifiers {
        var modifiers = KeyModifiers()
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// True when the application has claimed this mouse event (shift
    /// overrides reporting so local selection stays reachable).
    private func reportMouse(
        _ kind: MouseEventKind, button: MouseButton, event: NSEvent
    ) -> Bool {
        guard let modes = session?.snapshot.modes,
              modes.mouseMode != .off,
              !event.modifierFlags.contains(.shift)
        else { return false }
        // Reporting consumes the event even when this kind isn't forwarded,
        // so local selection doesn't fight the application.
        let shouldSend: Bool
        switch modes.mouseMode {
        case .off:
            return false
        case .x10:
            shouldSend = kind == .press && button.rawValue <= 2
        case .normal:
            shouldSend = kind == .press || kind == .release
        case .buttonEvent:
            shouldSend = kind != .motion
        case .anyEvent:
            shouldSend = true
        }
        guard shouldSend else { return true }
        let cell = cellPosition(of: event)
        if kind == .drag {
            if lastReportedDragCell?.x == cell.x && lastReportedDragCell?.y == cell.y {
                return true
            }
            lastReportedDragCell = cell
        }
        send(MouseEncoder.encode(
            kind, button: button, x: cell.x, y: cell.y,
            modifiers: keyModifiers(of: event),
            encoding: modes.mouseEncoding))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if reportMouse(.press, button: .left, event: event) { return }
        let point = absolutePoint(of: event)
        switch event.clickCount {
        case 2:
            if let state = session?.snapshot {
                selection = state.wordSelection(row: point.row, column: point.column)
            }
        case 3:
            selection = Selection(anchor: point, head: point, granularity: .line)
        default:
            selection = nil
            selectionAnchor = point
        }
        pushViewStateToRenderLoop()
    }

    override func mouseDragged(with event: NSEvent) {
        if reportMouse(.drag, button: .left, event: event) { return }
        let point = absolutePoint(of: event)
        if var current = selection, current.granularity != .character {
            current.head = point
            selection = current
        } else if let anchor = selectionAnchor {
            selection = Selection(anchor: anchor, head: point)
        }
        pushViewStateToRenderLoop()
    }

    override func mouseUp(with event: NSEvent) {
        lastReportedDragCell = nil
        if reportMouse(.release, button: .left, event: event) { return }
        if let selection, selection.isEmpty {
            self.selection = nil
            pushViewStateToRenderLoop()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        _ = reportMouse(.press, button: .right, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        _ = reportMouse(.release, button: .right, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        _ = reportMouse(.press, button: .middle, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        _ = reportMouse(.release, button: .middle, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer, let state = session?.snapshot else { return }

        var lines: Int
        if event.hasPreciseScrollingDeltas {
            wheelAccumulator += event.scrollingDeltaY
            lines = Int(wheelAccumulator / renderer.cellSize.height)
            wheelAccumulator -= CGFloat(lines) * renderer.cellSize.height
        } else {
            lines = Int(event.scrollingDeltaY.rounded(.towardZero))
        }
        guard lines != 0 else { return }

        // Reported wheel events go to the application.
        if state.modes.mouseMode != .off && !event.modifierFlags.contains(.shift) {
            let button: MouseButton = lines > 0 ? .wheelUp : .wheelDown
            let cell = cellPosition(of: event)
            for _ in 0..<min(abs(lines), 30) {
                send(MouseEncoder.encode(
                    .press, button: button, x: cell.x, y: cell.y,
                    modifiers: keyModifiers(of: event),
                    encoding: state.modes.mouseEncoding))
            }
            return
        }
        // Full-screen apps get arrow keys (alternate scroll).
        if state.isAlternateScreen && state.modes.alternateScroll {
            let key: TerminalKey = lines > 0 ? .up : .down
            let bytes = KeyEncoder.encode(
                key, applicationCursorKeys: state.modes.applicationCursorKeys)
            for _ in 0..<min(abs(lines), 30) {
                send(bytes)
            }
            return
        }
        // Otherwise scroll the viewport through scrollback.
        let target = scrollOffset + lines
        scrollOffset = min(max(0, target), state.scrollback.count)
        pushViewStateToRenderLoop()
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = nil
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        sendKeyboard(Array(text.utf8))
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
            y: CGFloat(cursor.y) * cell.height,
            width: cell.width,
            height: cell.height)
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }
}

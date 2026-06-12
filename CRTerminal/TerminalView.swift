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
    /// Supplies the window's shared renderer (one atlas per window, panes
    /// share it); set by the window controller before the view lands in
    /// the window.
    var rendererProvider: (() -> TerminalRenderer?)?
    var session: TerminalSession? {
        didSet { wireSession() }
    }

    /// Search state (⌘F bar drives this).
    private var searchQuery: String?
    private(set) var currentMatch: Selection?

    private var lastBellCount: UInt64 = 0
    private var markedText: String?
    /// Frames actually drawn (on the render thread); probe-reported.
    var drawCount: Int { renderLoop?.drawCount ?? 0 }

    private let degaussSound = DegaussSound()

    /// The CRT preset for this pane; per-pane because sidebar sessions
    /// theme independently while sharing the window's renderer. Presets
    /// with a bezel shrink the cell grid (the bezel is part of the view).
    var preset: CRTPreset = .museumOff {
        didSet {
            renderLoop?.setPreset(preset)
            updateGridSize()
        }
    }

    /// Points reserved around the grid: the preset's bezel, or a small
    /// margin when effects are off.
    private var contentInset: CGFloat {
        CGFloat(preset.contentInsetPt)
    }

    /// Menu/titlebar-button entry point (nil-target action).
    @objc func degauss(_ sender: Any?) {
        degauss()
    }

    /// The degauss button does what it says on the tin — but only as hard
    /// as the tube has magnetized since the last firing: a freshly
    /// degaussed tube gives a quiet, barely-there wobble (or nothing at
    /// all within the first 30 seconds).
    func degauss() {
        guard preset.effects, let amplitude = renderer?.degauss(),
              amplitude > 0 else { return }
        degaussSound.play(volume: amplitude)
        renderLoop?.poke(force: true)
    }

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
        // Only the focused pane drives the window/tab title.
        if let title = state.title, window?.title != title,
           window?.firstResponder === self {
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
        guard renderer == nil, window != nil, let metalLayer, let session,
              let renderer = rendererProvider?() ?? Self.makeFallbackRenderer(for: window)
        else { return }
        self.renderer = renderer
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        updateGridSize()
        updateLayerGeometry()
        renderLoop = RenderLoop(layer: metalLayer, renderer: renderer, session: session)
        renderLoop?.setPreset(preset)
    }

    /// Standalone views (no controller) still render.
    private static func makeFallbackRenderer(for window: NSWindow?) -> TerminalRenderer? {
        TerminalRenderer(
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            scale: window?.backingScaleFactor ?? 2)
    }

    /// Hidden tabs must not produce frames; revealing redraws whatever
    /// arrived while occluded.
    func setOccluded(_ occluded: Bool) {
        renderLoop?.setOccluded(occluded)
    }

    /// Profile font changed: drop the renderer and pick up the new shared
    /// one from the provider.
    func resetRenderer() {
        renderLoop?.invalidate()
        renderLoop = nil
        renderer = nil
        setUpRendererIfNeeded()
        renderLoop?.poke(force: true)
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
        renderLoop?.setViewState(
            scrollOffset: scrollOffset, selection: selection, markedText: markedText)
    }

    private func wireSession() {
        session?.onUpdate = { [weak self] in
            self?.sessionDidUpdate()
        }
        setUpRendererIfNeeded()
    }

    private func updateGridSize() {
        guard let renderer, let session else { return }
        let inset = contentInset * 2
        let columns = max(2, Int((bounds.width - inset) / renderer.cellSize.width))
        let rows = max(2, Int((bounds.height - inset) / renderer.cellSize.height))
        session.resize(columns: columns, rows: rows)
    }

    /// Points for a cols×rows grid (plus bezel); the window sizes itself
    /// with this.
    func sizeForGrid(columns: Int, rows: Int) -> NSSize {
        guard let renderer else { return NSSize(width: 800, height: 540) }
        return NSSize(
            width: CGFloat(columns) * renderer.cellSize.width + contentInset * 2,
            height: CGFloat(rows) * renderer.cellSize.height + contentInset * 2)
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
        // an IME). NSEvent already maps ctrl+letter to the control character;
        // ctrl+space stays a plain space (0x20) and must become NUL by hand.
        if event.modifierFlags.contains(.control),
           let characters = event.characters, !characters.isEmpty,
           let scalar = characters.unicodeScalars.first, scalar.value <= 0x20 {
            // Under the kitty protocol, modified keys get CSI u encodings
            // so applications can tell ^I from Tab, ^[ from Esc, etc.
            let kittyFlags = session?.snapshot.modes.kittyKeyboardFlags ?? []
            if let plain = event.charactersIgnoringModifiers?.unicodeScalars.first,
               let encoded = KeyEncoder.encodeCharacter(
                plain, modifiers: keyModifiers(of: event), kittyFlags: kittyFlags) {
                sendKeyboard(encoded)
                return
            }
            sendKeyboard([scalar.value == 0x20 ? 0x00 : UInt8(scalar.value)])
            return
        }
        inputContext?.handleEvent(event)
    }

    override func doCommand(by selector: Selector) {
        let modes = session?.snapshot.modes
        let application = modes?.applicationCursorKeys ?? false
        let kittyFlags = modes?.kittyKeyboardFlags ?? []

        func key(_ key: TerminalKey, _ modifiers: KeyModifiers = []) {
            sendKeyboard(KeyEncoder.encode(
                key, modifiers: modifiers, applicationCursorKeys: application,
                kittyFlags: kittyFlags))
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
        let inset = contentInset
        let x = min(max(0, Int((point.x - inset) / renderer.cellSize.width)),
                    (session?.snapshot.columns ?? 1) - 1)
        let y = min(max(0, Int((point.y - inset) / renderer.cellSize.height)),
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
        // ⌘-click opens hyperlinks (OSC 8) or detected URLs/paths.
        if event.modifierFlags.contains(.command) {
            openLink(at: event)
            return
        }
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

    // MARK: Links

    private func openLink(at event: NSEvent) {
        guard let state = session?.snapshot else { return }
        let point = absolutePoint(of: event)
        guard let line = state.absoluteLine(point.row),
              point.column < line.count else { return }
        // OSC 8 hyperlink on the cell wins; otherwise scan the row's text.
        if line[point.column].link != 0,
           let target = state.linkURL(line[point.column].link),
           let url = URLDetection.url(from: target) {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = URLDetection.detect(in: line, atColumn: point.column) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Prompt jumping (OSC 133 shell integration)

    @objc func jumpToPreviousPrompt(_ sender: Any?) {
        guard let state = session?.snapshot else { return }
        let currentTop = state.absoluteScreenTop - scrollOffset
        guard let mark = state.promptMarks.last(where: { $0.row < currentTop })
        else { return }
        scrollTo(absoluteRow: mark.row, in: state)
    }

    @objc func jumpToNextPrompt(_ sender: Any?) {
        guard let state = session?.snapshot else { return }
        let currentTop = state.absoluteScreenTop - scrollOffset
        if let mark = state.promptMarks.first(where: { $0.row > currentTop }) {
            scrollTo(absoluteRow: mark.row, in: state)
        } else {
            scrollOffset = 0 // past the last prompt: back to live
            pushViewStateToRenderLoop()
        }
    }

    private func scrollTo(absoluteRow row: Int, in state: TerminalState) {
        scrollOffset = min(max(0, state.absoluteScreenTop - row), state.scrollback.count)
        pushViewStateToRenderLoop()
    }

    // MARK: Search (the window's ⌘F bar drives this)

    /// Finds and reveals the next match; returns false when there is none.
    @discardableResult
    func find(_ query: String, backward: Bool = true) -> Bool {
        guard let state = session?.snapshot, !query.isEmpty else { return false }
        let from = query == searchQuery ? currentMatch?.anchor : nil
        searchQuery = query
        var match = state.search(for: query, from: from, backward: backward)
        if match == nil, from != nil { // wrap around
            match = state.search(for: query, from: nil, backward: backward)
        }
        guard let match else {
            NSSound.beep()
            return false
        }
        currentMatch = match
        selection = match
        let top = state.absoluteScreenTop - scrollOffset
        if match.anchor.row < top || match.anchor.row >= top + state.rows {
            scrollTo(absoluteRow: match.anchor.row, in: state)
        } else {
            pushViewStateToRenderLoop()
        }
        return true
    }

    func endSearch() {
        searchQuery = nil
        currentMatch = nil
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityLabel() -> String? { "Terminal" }

    override func accessibilityValue() -> Any? {
        guard let state = session?.snapshot else { return "" }
        return (0..<state.rows).map { state.lineText($0) }
            .joined(separator: "\n")
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        let value = (accessibilityValue() as? String) ?? ""
        return NSRange(location: 0, length: value.utf16.count)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        if markedText != nil {
            markedText = nil
            pushViewStateToRenderLoop()
        }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        sendKeyboard(Array(text.utf8))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Composition in progress: drawn at the cursor by the renderer's
        // decorations pass; the composed text arrives via insertText.
        markedText = (string as? NSAttributedString)?.string ?? (string as? String)
        pushViewStateToRenderLoop()
    }

    func unmarkText() {
        markedText = nil
        pushViewStateToRenderLoop()
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
            x: CGFloat(cursor.x) * cell.width + contentInset,
            y: CGFloat(cursor.y) * cell.height + contentInset,
            width: cell.width,
            height: cell.height)
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }
}

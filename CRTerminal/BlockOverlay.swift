import AppKit
import TerminalCore

/// Draws command-block chrome — a hairline divider plus a status gutter marker
/// at the top of each block — as plain CALayers above the Metal surface, the
/// same pattern as the bell flash and bottom warning bar (`TerminalView`), so it
/// composites over every preset including effects-off and never touches the hot
/// render path. Coordinates are the view's flipped, y-down space (row `i`'s top
/// is `i * cellHeight + contentInset`), matching the cursor rect and bottom bar.
final class BlockOverlayController {
    /// Colours for the chrome, supplied by the view from the active preset.
    struct Palette {
        var divider: CGColor
        var neutral: CGColor   // prompt / still-running
        var success: CGColor   // exit 0
        var failure: CGColor   // non-zero exit
    }

    /// One thing to draw: a block boundary at on-screen point `y`.
    struct Boundary {
        var y: CGFloat
        var status: Block.Status
    }

    private let container = CALayer()
    /// Reused across refreshes so streaming output doesn't churn allocations;
    /// surplus layers are hidden rather than removed.
    private var dividers: [CALayer] = []
    private var gutters: [CALayer] = []
    private var lastSignature = 0
    private var attached = false

    private let gutterWidth: CGFloat = 3

    init() {
        container.masksToBounds = true
        container.zPosition = 1  // above the metal contents, below an on-demand bell flash
    }

    /// Rebuild the chrome. `host` is the view's backing layer; `width` its point
    /// width; `cellHeight`/`contentInset` the grid metrics. Pass an empty
    /// `boundaries` (no marks, or alternate screen) to clear the overlay.
    func update(host: CALayer, width: CGFloat, height: CGFloat,
                cellHeight: CGFloat, contentInset: CGFloat,
                boundaries: [Boundary], palette: Palette) {
        if !attached {
            host.addSublayer(container)
            attached = true
        }
        // Cheap signature so frequent session updates that don't move a boundary
        // skip the rebuild entirely.
        var sig = Hasher()
        sig.combine(width); sig.combine(cellHeight); sig.combine(contentInset)
        for b in boundaries { sig.combine(b.y); sig.combine(b.status) }
        let signature = sig.finalize()
        guard signature != lastSignature else { return }
        lastSignature = signature

        CATransaction.begin()
        CATransaction.setDisableActions(true)  // no implicit fade/slide as content scrolls
        container.frame = CGRect(x: 0, y: 0, width: width, height: height)

        ensure(&dividers, count: boundaries.count, on: container)
        ensure(&gutters, count: boundaries.count, on: container)

        let markerHeight = min(cellHeight * 0.8, 16)
        for (i, b) in boundaries.enumerated() {
            let divider = dividers[i]
            divider.isHidden = false
            divider.backgroundColor = palette.divider
            divider.frame = CGRect(x: contentInset, y: b.y,
                                   width: max(0, width - contentInset * 2), height: 1)

            let gutter = gutters[i]
            gutter.isHidden = false
            gutter.backgroundColor = color(for: b.status, in: palette)
            gutter.cornerRadius = gutterWidth / 2
            gutter.frame = CGRect(x: 0, y: b.y + (cellHeight - markerHeight) / 2,
                                  width: gutterWidth, height: markerHeight)
        }
        for j in boundaries.count..<dividers.count { dividers[j].isHidden = true }
        for j in boundaries.count..<gutters.count { gutters[j].isHidden = true }
        CATransaction.commit()
    }

    /// Detach and reset (e.g. the renderer/preset is being swapped).
    func clear() {
        lastSignature = 0
        for layer in dividers { layer.isHidden = true }
        for layer in gutters { layer.isHidden = true }
    }

    private func color(for status: Block.Status, in palette: Palette) -> CGColor {
        switch status {
        case .prompt, .running: return palette.neutral
        case .finished(let code): return code == 0 ? palette.success : palette.failure
        }
    }

    private func ensure(_ pool: inout [CALayer], count: Int, on parent: CALayer) {
        while pool.count < count {
            let layer = CALayer()
            parent.addSublayer(layer)
            pool.append(layer)
        }
    }
}

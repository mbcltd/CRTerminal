import Metal
import QuartzCore

/// Per-pane render state: the offscreen effect textures plus the phosphor
/// clocks. Owned by a pane's render loop and touched only on that thread,
/// which lets one `TerminalRenderer` (one glyph atlas, one set of
/// pipelines) serve every pane in a window.
public final class SurfaceContext {
    var surfaces: EffectSurfaces?
    var lastDrawTime: CFTimeInterval?
    var lastContentChange: CFTimeInterval = 0
    /// Presets are per-pane (sidebar sessions can each wear their own);
    /// nil forces a persistence reset on the first frame.
    var lastPreset: CRTPreset?
    /// Inline-image GPU textures for this pane's session, keyed by image
    /// serial. Lazily created so panes without graphics pay nothing.
    var imageCache: ImageTextureCache?

    public init() {}
}

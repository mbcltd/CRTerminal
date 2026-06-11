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
    var lastPresetGeneration: UInt64 = .max // forces a persistence reset first frame

    public init() {}
}

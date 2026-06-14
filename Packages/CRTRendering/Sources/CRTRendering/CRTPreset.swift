import Foundation

/// A declarative CRT monitor description. Parameters are physical-ish —
/// phosphor color and decay time, mask pitch in millimetres, scan line
/// counts — so presets read like the spec sheet of a real monitor rather
/// than a bag of shader magic numbers (see ARCHITECTURE.md).
public struct CRTPreset: Codable, Equatable, Sendable {
    // MARK: Identity

    public var name: String
    public var year: Int?
    public var blurb: String?
    /// Master switch: false = "museum off", the whole effect chain is
    /// bypassed and the terminal texture goes straight to the drawable.
    public var effects: Bool

    /// Whether the terminal renders with the dark or the light color
    /// scheme (the historic CRT presets are all dark; the plain "standard"
    /// presets offer both). The renderer maps this to a `ColorScheme`.
    public enum Appearance: String, Codable, Sendable {
        case dark, light
    }
    public var appearance: Appearance

    // MARK: Sections

    public struct Phosphor: Codable, Equatable, Sendable {
        /// Phosphor chromaticity. When `monochrome` is true the image is
        /// reduced to luminance and re-emitted in this color.
        public var color: HexColor
        /// Persistence time constant in milliseconds: the time for an
        /// excited phosphor to decay to ~37%. P39 green is hundreds of ms;
        /// modern fast phosphors are a few ms (0 disables persistence).
        public var decayMs: Double
        public var monochrome: Bool

        public init(color: HexColor = HexColor(0xFF, 0xFF, 0xFF),
                    decayMs: Double = 0, monochrome: Bool = false) {
            self.color = color
            self.decayMs = decayMs
            self.monochrome = monochrome
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Phosphor()
            color = try c.decodeIfPresent(HexColor.self, forKey: .color) ?? d.color
            decayMs = try c.decodeIfPresent(Double.self, forKey: .decayMs) ?? d.decayMs
            monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome) ?? d.monochrome
        }
    }

    public struct Geometry: Codable, Equatable, Sendable {
        /// Barrel distortion amount; 0 = flat glass, ~0.1 = a curvy 80s tube.
        public var curvature: Double
        /// Corner rounding as a fraction of the screen's short edge.
        public var cornerRadius: Double
        /// Edge darkening, 0...1.
        public var vignette: Double

        public init(curvature: Double = 0, cornerRadius: Double = 0, vignette: Double = 0) {
            self.curvature = curvature
            self.cornerRadius = cornerRadius
            self.vignette = vignette
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Geometry()
            curvature = try c.decodeIfPresent(Double.self, forKey: .curvature) ?? d.curvature
            cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
            vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? d.vignette
        }
    }

    public enum MaskType: String, Codable, Sendable {
        case none, aperture, slot, shadow
    }

    public struct Mask: Codable, Equatable, Sendable {
        public var type: MaskType
        /// Triad/stripe pitch in millimetres (e.g. 0.64 for a consumer
        /// composite monitor, 0.25 for a late fine-pitch tube).
        public var pitchMM: Double
        /// How visible the mask is, 0...1.
        public var strength: Double

        public init(type: MaskType = .none, pitchMM: Double = 0.6, strength: Double = 0) {
            self.type = type
            self.pitchMM = pitchMM
            self.strength = strength
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Mask()
            type = try c.decodeIfPresent(MaskType.self, forKey: .type) ?? d.type
            pitchMM = try c.decodeIfPresent(Double.self, forKey: .pitchMM) ?? d.pitchMM
            strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
        }
    }

    public struct Scanlines: Codable, Equatable, Sendable {
        /// Visible scan lines on the emulated tube (350 for MDA, 240 for a
        /// VT220 field, ~240 visible for NTSC composite).
        public var lines: Int
        /// Beam darkening between lines, 0...1.
        public var strength: Double
        /// Beam spot size relative to line pitch: 1 = lines just touch,
        /// smaller = harder gaps between lines.
        public var beamWidth: Double

        public init(lines: Int = 0, strength: Double = 0, beamWidth: Double = 0.8) {
            self.lines = lines
            self.strength = strength
            self.beamWidth = beamWidth
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Scanlines()
            lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? d.lines
            strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
            beamWidth = try c.decodeIfPresent(Double.self, forKey: .beamWidth) ?? d.beamWidth
        }
    }

    public struct Bloom: Codable, Equatable, Sendable {
        /// Luminance above which the phosphor blooms, 0...1.
        public var threshold: Double
        /// Halation intensity, 0 disables the bloom passes entirely.
        public var strength: Double
        /// Glow radius in millimetres of faceplate glass.
        public var radiusMM: Double

        public init(threshold: Double = 0.6, strength: Double = 0, radiusMM: Double = 0.4) {
            self.threshold = threshold
            self.strength = strength
            self.radiusMM = radiusMM
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Bloom()
            threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
            strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
            radiusMM = try c.decodeIfPresent(Double.self, forKey: .radiusMM) ?? d.radiusMM
        }
    }

    public struct Artifacts: Codable, Equatable, Sendable {
        /// Video noise grain, 0...1. Animated: forces continuous redraw.
        public var noise: Double
        /// Mains hum bar drifting up the screen, 0...1. Animated.
        public var humBar: Double
        /// Interlace-style line jitter in fractions of a scan line. Animated.
        public var jitter: Double
        /// Beam convergence error in millimetres (R/B fringes on everything).
        public var convergenceMM: Double
        /// Additional radial chromatic aberration toward the corners, 0...1.
        public var aberration: Double

        public init(noise: Double = 0, humBar: Double = 0, jitter: Double = 0,
                    convergenceMM: Double = 0, aberration: Double = 0) {
            self.noise = noise
            self.humBar = humBar
            self.jitter = jitter
            self.convergenceMM = convergenceMM
            self.aberration = aberration
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Artifacts()
            noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? d.noise
            humBar = try c.decodeIfPresent(Double.self, forKey: .humBar) ?? d.humBar
            jitter = try c.decodeIfPresent(Double.self, forKey: .jitter) ?? d.jitter
            convergenceMM = try c.decodeIfPresent(Double.self, forKey: .convergenceMM) ?? d.convergenceMM
            aberration = try c.decodeIfPresent(Double.self, forKey: .aberration) ?? d.aberration
        }

        public var isAnimated: Bool {
            noise > 0 || humBar > 0 || jitter > 0
        }
    }

    public struct Bezel: Codable, Equatable, Sendable {
        /// Bezel width in points around the screen; 0 = no bezel.
        public var widthPt: Double
        public var color: HexColor

        public init(widthPt: Double = 0, color: HexColor = HexColor(0x2E, 0x2C, 0x28)) {
            self.widthPt = widthPt
            self.color = color
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Bezel()
            widthPt = try c.decodeIfPresent(Double.self, forKey: .widthPt) ?? d.widthPt
            color = try c.decodeIfPresent(HexColor.self, forKey: .color) ?? d.color
        }
    }

    public var phosphor: Phosphor
    public var geometry: Geometry
    public var mask: Mask
    public var scanlines: Scanlines
    public var bloom: Bloom
    public var artifacts: Artifacts
    public var bezel: Bezel
    /// Whether the monitor sports a manual degauss button. Sets without
    /// one (the Commodore 1702 degaussed itself at power-on) hide the
    /// titlebar button; the menu command still works.
    public var degaussButton: Bool

    /// Points reserved between the window edge and the cell grid: the
    /// bezel when effects are on, a small breathing margin for the plain
    /// screen so text doesn't sit flush against the edge.
    public var contentInsetPt: Double {
        effects ? bezel.widthPt : Self.plainInsetPt
    }

    /// The grid margin when effects are off (museum off).
    public static let plainInsetPt: Double = 8

    public init(
        name: String, year: Int? = nil, blurb: String? = nil, effects: Bool = true,
        appearance: Appearance = .dark,
        phosphor: Phosphor = Phosphor(), geometry: Geometry = Geometry(),
        mask: Mask = Mask(), scanlines: Scanlines = Scanlines(),
        bloom: Bloom = Bloom(), artifacts: Artifacts = Artifacts(), bezel: Bezel = Bezel(),
        degaussButton: Bool = true
    ) {
        self.name = name
        self.year = year
        self.blurb = blurb
        self.effects = effects
        self.appearance = appearance
        self.phosphor = phosphor
        self.geometry = geometry
        self.mask = mask
        self.scanlines = scanlines
        self.bloom = bloom
        self.artifacts = artifacts
        self.bezel = bezel
        self.degaussButton = degaussButton
    }

    /// Sections may be omitted in JSON; they default to "off".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        blurb = try container.decodeIfPresent(String.self, forKey: .blurb)
        effects = try container.decodeIfPresent(Bool.self, forKey: .effects) ?? true
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .dark
        phosphor = try container.decodeIfPresent(Phosphor.self, forKey: .phosphor) ?? Phosphor()
        geometry = try container.decodeIfPresent(Geometry.self, forKey: .geometry) ?? Geometry()
        mask = try container.decodeIfPresent(Mask.self, forKey: .mask) ?? Mask()
        scanlines = try container.decodeIfPresent(Scanlines.self, forKey: .scanlines) ?? Scanlines()
        bloom = try container.decodeIfPresent(Bloom.self, forKey: .bloom) ?? Bloom()
        artifacts = try container.decodeIfPresent(Artifacts.self, forKey: .artifacts) ?? Artifacts()
        bezel = try container.decodeIfPresent(Bezel.self, forKey: .bezel) ?? Bezel()
        degaussButton = try container.decodeIfPresent(Bool.self, forKey: .degaussButton) ?? true
    }

    /// Everything off — the lean modern terminal, dark scheme.
    public static let darkStandard = CRTPreset(
        name: "Dark", blurb: "All effects disabled; the modern terminal.",
        effects: false)

    /// Everything off — the lean modern terminal, light scheme.
    public static let lightStandard = CRTPreset(
        name: "Light", blurb: "All effects disabled; a light scheme.",
        effects: false, appearance: .light)
}

/// An sRGB color encoded as "#RRGGBB" in JSON.
public struct HexColor: Codable, Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(string: String) {
        var hex = string
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(UInt8(value >> 16), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    public var string: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public var simd: SIMD3<Float> {
        SIMD3(Float(red), Float(green), Float(blue)) / 255
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let color = HexColor(string: raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected \"#RRGGBB\", got \"\(raw)\""))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

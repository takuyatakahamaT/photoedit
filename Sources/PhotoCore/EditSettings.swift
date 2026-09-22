import Foundation

public struct CurvePoint: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum ToneCurveChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case rgb
    case red
    case green
    case blue
}

public struct ToneCurve: Codable, Equatable, Hashable, Sendable {
    public let channel: ToneCurveChannel
    public let points: [CurvePoint]

    public init(channel: ToneCurveChannel, points: [CurvePoint]) {
        self.channel = channel
        // Preserve authored order so ToneCurveModel can resolve duplicate x
        // positions deterministically as last-authored-wins before evaluation.
        // The evaluator owns sorting because decoded JSON/XMP must follow the
        // same policy as values created through this initializer.
        self.points = points
    }
}

public extension ToneCurve {
    /// True when this curve is a no-op in `ToneCurveModel`'s normalized
    /// (sorted, deduplicated, 0...1-clamped) sense -- every point lies on the
    /// identity diagonal. Exposed so UI code in a different module (the point
    /// curve editor) can drop a curve that a user edit brought back onto the
    /// diagonal from `EditSettings.toneCurves`, keeping `settings ==
    /// EditSettings.neutral` the same way `EditSettings.hasActiveColorEdits`
    /// already treats such a curve as inert.
    var isIdentity: Bool {
        ToneCurveModel.isIdentity([self])
    }
}

public enum HSLBand: String, Codable, CaseIterable, Hashable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
}

public struct HSLAdjustment: Codable, Equatable, Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }
}

/// Phase2 C2's Camera Calibration panel (`.photobench/phase2/color/model.md`
/// §3): the Red/Green/Blue Hue/Saturation sliders, applied by
/// `ColorOps.calibrationMatrix` as a fixed 3x3 matrix on linear ProPhoto,
/// plus `shadowTint`, which is retained only for round-tripping -- the
/// measured reference found it has zero effect (§3.3) and `ColorOps` treats
/// it as a no-op.
public struct CalibrationSettings: Codable, Equatable, Hashable, Sendable {
    public var shadowTint: Double
    public var redHue: Double
    public var redSaturation: Double
    public var greenHue: Double
    public var greenSaturation: Double
    public var blueHue: Double
    public var blueSaturation: Double

    public init(
        shadowTint: Double = 0,
        redHue: Double = 0,
        redSaturation: Double = 0,
        greenHue: Double = 0,
        greenSaturation: Double = 0,
        blueHue: Double = 0,
        blueSaturation: Double = 0
    ) {
        self.shadowTint = shadowTint
        self.redHue = redHue
        self.redSaturation = redSaturation
        self.greenHue = greenHue
        self.greenSaturation = greenSaturation
        self.blueHue = blueHue
        self.blueSaturation = blueSaturation
    }

    public static let neutral = CalibrationSettings()
}

/// One Color Grading band's Hue/Saturation/Luminance (`ColorGradeShadowHue`
/// etc). `hue` is 0...359 (a wheel angle), `saturation` 0...100, `luminance`
/// -100...100 -- matching Adobe's own XMP ranges, not `HSLAdjustment`'s
/// -100...100-for-everything convention.
public struct ColorGradeBand: Codable, Equatable, Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }
}

/// Phase2 C2's Color Grading panel (`.photobench/phase2/color/model.md` §4),
/// applied by `ColorOps.colorGrading`. The legacy Split Toning XMP tags
/// (`SplitToningShadowHue/Saturation`, `SplitToningHighlightHue/Saturation`,
/// `SplitToningBalance`) are parsed into the same `shadow`/`highlight`/
/// `balance` slots by `XMPPresetParser` -- there is no separate storage for
/// "split toning mode".
///
/// `midtone.luminance` and `global.luminance` are retained for round-tripping
/// only: `color_model.apply_color_grading` (the measured reference
/// `ColorOps.colorGrading` faithfully ports) has no fitted curve for those
/// two sliders -- only `ColorGradeShadowLum`/`ColorGradeHighlightLum` were
/// measured (`model.md` §4.1) -- so they are never applied to rendering.
public struct ColorGradingSettings: Codable, Equatable, Hashable, Sendable {
    public var shadow: ColorGradeBand
    public var midtone: ColorGradeBand
    public var highlight: ColorGradeBand
    public var global: ColorGradeBand
    /// `ColorGradeBlending` (0...100, Adobe default 50; absent-tag default is
    /// 100 here, matching `color_model.apply_color_grading`'s own default --
    /// see that function's doc comment for why).
    public var blending: Double
    /// `ColorGradeBalance`/legacy `SplitToningBalance` (-100...100).
    public var balance: Double

    public init(
        shadow: ColorGradeBand = ColorGradeBand(),
        midtone: ColorGradeBand = ColorGradeBand(),
        highlight: ColorGradeBand = ColorGradeBand(),
        global: ColorGradeBand = ColorGradeBand(),
        blending: Double = 100,
        balance: Double = 0
    ) {
        self.shadow = shadow
        self.midtone = midtone
        self.highlight = highlight
        self.global = global
        self.blending = blending
        self.balance = balance
    }

    public static let neutral = ColorGradingSettings()
}

public enum WhiteBalanceMode: String, Codable, Equatable, Hashable, Sendable {
    case asShot
    case custom
    case unknown
}

public struct WhiteBalanceSettings: Codable, Equatable, Hashable, Sendable {
    public var mode: WhiteBalanceMode
    public var temperature: Double?
    public var tint: Double?
    public var incrementalTemperature: Double?
    public var incrementalTint: Double?

    public init(
        mode: WhiteBalanceMode = .asShot,
        temperature: Double? = nil,
        tint: Double? = nil,
        incrementalTemperature: Double? = nil,
        incrementalTint: Double? = nil
    ) {
        self.mode = mode
        self.temperature = temperature
        self.tint = tint
        self.incrementalTemperature = incrementalTemperature
        self.incrementalTint = incrementalTint
    }

    public static let asShot = WhiteBalanceSettings()
}

public struct EditSettings: Codable, Equatable, Hashable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var vibrance: Double
    public var saturation: Double
    /// Relative shift around the decoded capture white point. This is kept
    /// separate from Adobe's absolute/incremental white-balance metadata.
    public var relativeTemperature: Double {
        didSet { relativeTemperature = RelativeColorAdjustment.sanitizedValue(relativeTemperature) }
    }
    public var relativeTint: Double {
        didSet { relativeTint = RelativeColorAdjustment.sanitizedValue(relativeTint) }
    }
    public var whiteBalance: WhiteBalanceSettings
    public var toneCurves: [ToneCurve]
    public var hsl: [HSLBand: HSLAdjustment]
    /// Phase2 C2's Camera Calibration panel. Applied last (`ColorOps.
    /// calibrationMatrix`, a `CIColorMatrix` kept separate from cube Q so a
    /// calibration-only slider change never invalidates cube Q's cache --
    /// `docs/PHASE2_C2_C3.md`'s C2 item 3).
    public var calibration: CalibrationSettings
    /// Phase2 C2's Color Grading panel (and legacy Split Toning). Applied at
    /// the end of cube Q (`ColorOps.applyColorOps`'s Vibrance -> Saturation ->
    /// HSL -> Color Grading order).
    public var colorGrading: ColorGradingSettings
    /// Phase2 C1 `Parametric{Shadows,Darks,Lights,Highlights}` (-100...100)
    /// and their split points (0...100, Adobe defaults 25/50/75). Applied by
    /// `ToneOps.parametric` at Stage P (`docs/PHASE2_DEVELOP_PIPELINE.md`).
    public var parametricShadows: Double
    public var parametricDarks: Double
    public var parametricLights: Double
    public var parametricHighlights: Double
    public var parametricShadowSplit: Double
    public var parametricMidtoneSplit: Double
    public var parametricHighlightSplit: Double
    /// `CurveRefineSaturation` (0...100, Adobe default 100). Only the default
    /// (100, DNGSpline + RGBTone hue-preserving point curve) is modeled; a
    /// non-100 value is retained but rendered as if it were 100
    /// (`.photobench/phase2/tone/model.md`'s Q3 "未解決" note).
    public var curveRefineSaturation: Double
    /// `Texture`/`Clarity2012`/`Dehaze` (-100...100). Retained only -- no
    /// rendering operation reads these yet (phase3, per
    /// `docs/PHASE2_DEVELOP_PIPELINE.md`'s "範囲外").
    public var texture: Double
    public var clarity: Double
    public var dehaze: Double

    public init(
        exposure: Double = 0,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        vibrance: Double = 0,
        saturation: Double = 0,
        whiteBalance: WhiteBalanceSettings = .asShot,
        toneCurves: [ToneCurve] = [],
        hsl: [HSLBand: HSLAdjustment] = [:],
        calibration: CalibrationSettings = .neutral,
        colorGrading: ColorGradingSettings = .neutral,
        relativeTemperature: Double = 0,
        relativeTint: Double = 0,
        parametricShadows: Double = 0,
        parametricDarks: Double = 0,
        parametricLights: Double = 0,
        parametricHighlights: Double = 0,
        parametricShadowSplit: Double = 25,
        parametricMidtoneSplit: Double = 50,
        parametricHighlightSplit: Double = 75,
        curveRefineSaturation: Double = 100,
        texture: Double = 0,
        clarity: Double = 0,
        dehaze: Double = 0
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.vibrance = vibrance
        self.saturation = saturation
        self.relativeTemperature = RelativeColorAdjustment.sanitizedValue(relativeTemperature)
        self.relativeTint = RelativeColorAdjustment.sanitizedValue(relativeTint)
        self.whiteBalance = whiteBalance
        self.toneCurves = toneCurves
        self.hsl = hsl
        self.calibration = calibration
        self.colorGrading = colorGrading
        self.parametricShadows = parametricShadows
        self.parametricDarks = parametricDarks
        self.parametricLights = parametricLights
        self.parametricHighlights = parametricHighlights
        self.parametricShadowSplit = parametricShadowSplit
        self.parametricMidtoneSplit = parametricMidtoneSplit
        self.parametricHighlightSplit = parametricHighlightSplit
        self.curveRefineSaturation = curveRefineSaturation
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
    }

    private enum CodingKeys: String, CodingKey {
        case exposure
        case contrast
        case highlights
        case shadows
        case whites
        case blacks
        case vibrance
        case saturation
        case relativeTemperature
        case relativeTint
        case whiteBalance
        case toneCurves
        case hsl
        case calibration
        case colorGrading
        case parametricShadows
        case parametricDarks
        case parametricLights
        case parametricHighlights
        case parametricShadowSplit
        case parametricMidtoneSplit
        case parametricHighlightSplit
        case curveRefineSaturation
        case texture
        case clarity
        case dehaze
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        whites = try container.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try container.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        relativeTemperature = RelativeColorAdjustment.sanitizedValue(
            try container.decodeIfPresent(Double.self, forKey: .relativeTemperature) ?? 0
        )
        relativeTint = RelativeColorAdjustment.sanitizedValue(
            try container.decodeIfPresent(Double.self, forKey: .relativeTint) ?? 0
        )
        whiteBalance = try container.decodeIfPresent(WhiteBalanceSettings.self, forKey: .whiteBalance) ?? .asShot
        toneCurves = try container.decodeIfPresent([ToneCurve].self, forKey: .toneCurves) ?? []
        hsl = try container.decodeIfPresent([HSLBand: HSLAdjustment].self, forKey: .hsl) ?? [:]
        calibration = try container.decodeIfPresent(CalibrationSettings.self, forKey: .calibration) ?? .neutral
        colorGrading = try container.decodeIfPresent(ColorGradingSettings.self, forKey: .colorGrading) ?? .neutral
        parametricShadows = try container.decodeIfPresent(Double.self, forKey: .parametricShadows) ?? 0
        parametricDarks = try container.decodeIfPresent(Double.self, forKey: .parametricDarks) ?? 0
        parametricLights = try container.decodeIfPresent(Double.self, forKey: .parametricLights) ?? 0
        parametricHighlights = try container.decodeIfPresent(Double.self, forKey: .parametricHighlights) ?? 0
        parametricShadowSplit = try container.decodeIfPresent(Double.self, forKey: .parametricShadowSplit) ?? 25
        parametricMidtoneSplit = try container.decodeIfPresent(Double.self, forKey: .parametricMidtoneSplit) ?? 50
        parametricHighlightSplit = try container.decodeIfPresent(Double.self, forKey: .parametricHighlightSplit) ?? 75
        curveRefineSaturation = try container.decodeIfPresent(Double.self, forKey: .curveRefineSaturation) ?? 100
        texture = try container.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        dehaze = try container.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(whites, forKey: .whites)
        try container.encode(blacks, forKey: .blacks)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(RelativeColorAdjustment.sanitizedValue(relativeTemperature), forKey: .relativeTemperature)
        try container.encode(RelativeColorAdjustment.sanitizedValue(relativeTint), forKey: .relativeTint)
        try container.encode(whiteBalance, forKey: .whiteBalance)
        try container.encode(toneCurves, forKey: .toneCurves)
        try container.encode(hsl, forKey: .hsl)
        try container.encode(calibration, forKey: .calibration)
        try container.encode(colorGrading, forKey: .colorGrading)
        try container.encode(parametricShadows, forKey: .parametricShadows)
        try container.encode(parametricDarks, forKey: .parametricDarks)
        try container.encode(parametricLights, forKey: .parametricLights)
        try container.encode(parametricHighlights, forKey: .parametricHighlights)
        try container.encode(parametricShadowSplit, forKey: .parametricShadowSplit)
        try container.encode(parametricMidtoneSplit, forKey: .parametricMidtoneSplit)
        try container.encode(parametricHighlightSplit, forKey: .parametricHighlightSplit)
        try container.encode(curveRefineSaturation, forKey: .curveRefineSaturation)
        try container.encode(texture, forKey: .texture)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(dehaze, forKey: .dehaze)
    }

    public static let neutral = EditSettings()

    /// Drives the final SDR output transform for operations the renderer
    /// actually applies. A tiny tolerance avoids turning on a nonlinear output
    /// stage because of serialization noise around zero. Unsupported white
    /// balance metadata and mathematically identity curves remain true no-ops.
    func hasActiveColorEdits(tolerance: Double = 1e-9) -> Bool {
        let scalarControls = [
            exposure,
            contrast,
            highlights,
            shadows,
            whites,
            blacks,
            vibrance,
            saturation,
            relativeTemperature,
            relativeTint,
            parametricShadows,
            parametricDarks,
            parametricLights,
            parametricHighlights
        ]
        let calibrationControls = [
            calibration.redHue, calibration.redSaturation,
            calibration.greenHue, calibration.greenSaturation,
            calibration.blueHue, calibration.blueSaturation
            // shadowTint excluded: measured zero-effect (color/model.md §3.3).
        ]
        let colorGradingControls = [
            colorGrading.shadow.hue, colorGrading.shadow.saturation, colorGrading.shadow.luminance,
            colorGrading.midtone.hue, colorGrading.midtone.saturation,
            colorGrading.highlight.hue, colorGrading.highlight.saturation, colorGrading.highlight.luminance,
            colorGrading.global.hue, colorGrading.global.saturation
            // midtone/global luminance excluded: never applied (see
            // `ColorGradingSettings`'s doc comment); blending/balance alone
            // (with every band's saturation/luminance at 0) are no-ops too.
        ]
        return scalarControls.contains { abs($0) > tolerance }
            || calibrationControls.contains { abs($0) > tolerance }
            || colorGradingControls.contains { abs($0) > tolerance }
            || !ToneCurveModel.isIdentity(toneCurves, tolerance: tolerance)
            || hsl.values.contains {
                abs($0.hue) > tolerance || abs($0.saturation) > tolerance || abs($0.luminance) > tolerance
            }
    }
}

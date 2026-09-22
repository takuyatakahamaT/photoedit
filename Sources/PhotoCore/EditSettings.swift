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

public enum HSLBand: String, Codable, CaseIterable, Hashable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var centerHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 280
        case .magenta: 320
        }
    }
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
        relativeTemperature: Double = 0,
        relativeTint: Double = 0
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
            relativeTint
        ]
        return scalarControls.contains { abs($0) > tolerance }
            || !ToneCurveModel.isIdentity(toneCurves, tolerance: tolerance)
            || PerceptualColorMixer.isActive(hsl, tolerance: tolerance)
    }
}

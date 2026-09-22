import Foundation

/// Stable identifiers for the processing semantics covered by calibration.
/// Keeping these in PhotoCore prevents calibration tools from duplicating
/// version strings that could silently drift away from the implementation.
public struct PhotoCoreProcessingFingerprint: Codable, Equatable, Sendable {
    public static let legacyRawDecodeIdentifier = "legacy-unversioned-full-resolution-raw-decode-v1"

    public let rawDecode: String
    public let basicTone: String
    public let toneCurve: String
    public let colorMixer: String
    public let outputTransform: String
    public let renderPipeline: String

    public init(
        rawDecode: String,
        basicTone: String,
        toneCurve: String,
        colorMixer: String,
        outputTransform: String,
        renderPipeline: String
    ) {
        self.rawDecode = rawDecode
        self.basicTone = basicTone
        self.toneCurve = toneCurve
        self.colorMixer = colorMixer
        self.outputTransform = outputTransform
        self.renderPipeline = renderPipeline
    }

    private enum CodingKeys: String, CodingKey {
        case rawDecode
        case basicTone
        case toneCurve
        case colorMixer
        case outputTransform
        case renderPipeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawDecode = try container.decodeIfPresent(String.self, forKey: .rawDecode)
            ?? Self.legacyRawDecodeIdentifier
        basicTone = try container.decode(String.self, forKey: .basicTone)
        toneCurve = try container.decode(String.self, forKey: .toneCurve)
        colorMixer = try container.decode(String.self, forKey: .colorMixer)
        outputTransform = try container.decode(String.self, forKey: .outputTransform)
        renderPipeline = try container.decodeIfPresent(
            String.self,
            forKey: .renderPipeline
        ) ?? RenderEngine.legacyProcessingIdentifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawDecode, forKey: .rawDecode)
        try container.encode(basicTone, forKey: .basicTone)
        try container.encode(toneCurve, forKey: .toneCurve)
        try container.encode(colorMixer, forKey: .colorMixer)
        try container.encode(outputTransform, forKey: .outputTransform)
        try container.encode(renderPipeline, forKey: .renderPipeline)
    }

    // `colorMixer` keeps its field name (a `Codable` contract other JSON
    // consumers rely on) even though the deleted `PerceptualColorMixer`'s
    // OKLCh approximation is gone; it now identifies phase2 C2's measured
    // `ColorOps` cube Q instead. `basicTone` keeps its field name the same
    // way: phase2 C3 deleted `BasicToneModel` (Highlights/Shadows' clean-room
    // approximation) in favor of `SpatialToneOps`'s measured local-Laplacian
    // model, but the JSON field itself is an existing `Codable` contract.
    public static let current = PhotoCoreProcessingFingerprint(
        rawDecode: CoreImageDecoder.processingIdentifier,
        basicTone: SpatialToneOps.identifier,
        toneCurve: ToneCurveModel.identifier,
        colorMixer: ColorOps.identifier,
        outputTransform: SRGBOutputTransform.identifier,
        renderPipeline: RenderEngine.processingIdentifier
    )

    public static let legacyCurrentRawDecode = PhotoCoreProcessingFingerprint(
        rawDecode: CoreImageDecoder.processingIdentifier,
        basicTone: SpatialToneOps.identifier,
        toneCurve: ToneCurveModel.identifier,
        colorMixer: ColorOps.identifier,
        outputTransform: SRGBOutputTransform.identifier,
        renderPipeline: RenderEngine.legacyProcessingIdentifier
    )
}

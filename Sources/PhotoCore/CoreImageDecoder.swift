import CoreImage
import Foundation
import ImageIO

public enum ImageDecodeIntent: Equatable, Sendable {
    /// Decode only as many RAW pixels as the interactive preview can display.
    /// Raster inputs intentionally keep their existing ImageIO decode path in
    /// this slice; thumbnail decoding is a separate, independently gated change.
    case interactivePreview(maxDimension: Int)
    case fullResolution

    public var identifier: String {
        switch self {
        case .interactivePreview:
            "interactive-preview"
        case .fullResolution:
            "full-resolution"
        }
    }

    public var requestedMaximumDimension: Int? {
        switch self {
        case let .interactivePreview(maxDimension):
            maxDimension
        case .fullResolution:
            nil
        }
    }
}

public struct DecodeInfo: Equatable, Sendable {
    public let backend: String
    public let width: Int
    public let height: Int
    public let durationMilliseconds: Double
    public let isRAW: Bool
    public let isBoundedSRGBRaster: Bool
    public let cameraMake: String?
    public let cameraModel: String?
    public let calibrationID: String?
    public let calibrationLabel: String?
    public let intent: ImageDecodeIntent
    public let requestedMaximumDimension: Int?
    public let nativeWidth: Int
    public let nativeHeight: Int
    /// The scale applied by CIRAWFilter. Raster inputs use nil because this
    /// slice deliberately does not change their ImageIO decode behavior.
    public let appliedScaleFactor: Float?
    /// The RAW's as-shot white point, in the same camera-neutral-derived xy
    /// this project's `ColorSpec`/`DNGTemperature` already work in. Only
    /// `LibRawDecoder`'s Adobe-DCP path populates this (it already computes
    /// `AdobeBaseAssets.whiteXY` for its own base rendering); every other
    /// decode path -- non-RAW, and `CoreImageDecoder`'s own RAW fallback --
    /// leaves it nil, since the UI's absolute-white-balance controls
    /// (`ColorSpec.temperatureAndTint(fromXY:)`) are gated on this being
    /// non-nil rather than on `isRAW` alone.
    public let asShotWhiteXY: ChromaticityXY?
    /// Human-readable label for an in-body lens correction baked into the
    /// output pixels (currently just `LibRawDecoder`'s Panasonic RW2
    /// `DistortionInfo` radial-distortion correction,
    /// `.photobench/phase4/lens/model.md`), or `nil` when none was applied
    /// -- not a RAW, not an RW2, the file's `DistortionCorrection` flag was
    /// off, or the decode path doesn't support it (`CoreImageDecoder`'s own
    /// RAW path always leaves this `nil`; Apple's own RAW decoder applies
    /// its own, separate lens corrections that this project does not model
    /// or report).
    public let lensCorrection: String?

    public init(
        backend: String,
        width: Int,
        height: Int,
        durationMilliseconds: Double,
        isRAW: Bool,
        isBoundedSRGBRaster: Bool = false,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        calibrationID: String? = nil,
        calibrationLabel: String? = nil,
        intent: ImageDecodeIntent = .fullResolution,
        requestedMaximumDimension: Int? = nil,
        nativeWidth: Int? = nil,
        nativeHeight: Int? = nil,
        appliedScaleFactor: Float? = nil,
        asShotWhiteXY: ChromaticityXY? = nil,
        lensCorrection: String? = nil
    ) {
        self.backend = backend
        self.width = width
        self.height = height
        self.durationMilliseconds = durationMilliseconds
        self.isRAW = isRAW
        self.isBoundedSRGBRaster = isBoundedSRGBRaster
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.calibrationID = calibrationID
        self.calibrationLabel = calibrationLabel
        self.intent = intent
        self.requestedMaximumDimension = requestedMaximumDimension
        self.nativeWidth = nativeWidth ?? width
        self.nativeHeight = nativeHeight ?? height
        self.appliedScaleFactor = appliedScaleFactor
        self.asShotWhiteXY = asShotWhiteXY
        self.lensCorrection = lensCorrection
    }
}

public struct DecodedPhoto: @unchecked Sendable {
    public let sourceURL: URL
    public let image: CIImage
    public let metadata: [String: Any]
    public let info: DecodeInfo
    /// Stage-M (camera RGB -> linear ProPhoto) image and profile assets for
    /// RAW photos decoded through `LibRawDecoder`; `nil` for every other
    /// decode path. Unused in phase1 (see `docs/PHASE1_BASE_RENDERING.md`
    /// B2); phase2/3 insert user edits between `AdobeBaseRenderer`'s stages
    /// via this handle instead of only after the finished baseline image.
    public let adobeBase: AdobeBaseRenderer.Handle?

    public init(
        sourceURL: URL,
        image: CIImage,
        metadata: [String: Any],
        info: DecodeInfo,
        adobeBase: AdobeBaseRenderer.Handle? = nil
    ) {
        self.sourceURL = sourceURL
        self.image = image
        self.metadata = metadata
        self.info = info
        self.adobeBase = adobeBase
    }
}

public protocol ImageDecoding: Sendable {
    func decode(url: URL, intent: ImageDecodeIntent) throws -> DecodedPhoto
}

public extension ImageDecoding {
    func decode(url: URL) throws -> DecodedPhoto {
        try decode(url: url, intent: .fullResolution)
    }
}

public struct RAWDecodeConfiguration: Equatable, Sendable {
    public var exposure: Float
    public var shadowBias: Float
    public var boostAmount: Float
    public var boostShadowAmount: Float
    public var extendedDynamicRangeAmount: Float

    public init(
        exposure: Float = 0,
        shadowBias: Float = 0,
        boostAmount: Float = 0,
        boostShadowAmount: Float = 1,
        extendedDynamicRangeAmount: Float = 0
    ) {
        self.exposure = exposure
        self.shadowBias = shadowBias
        self.boostAmount = boostAmount
        self.boostShadowAmount = boostShadowAmount
        self.extendedDynamicRangeAmount = extendedDynamicRangeAmount
    }

    /// 固定OS既定値に依存せず、Lightroom基準TIFFとの比較を始めるための平坦な基準。
    public static let calibrationBaseline = RAWDecodeConfiguration()

    /// DC-S5限定の暫定値。boost 0.9は2組のLightroom基準との色差試験値、
    /// EDR 1はAppleのdefault EDRで、EDR 2の約94〜96%の拡張画素を保ちながら
    /// 最大値だけが過度に伸びるのを避けた。追加sceneでの再校正は必要。
    public static let lumixDCS5LightroomBaseline = RAWDecodeConfiguration(
        boostAmount: 0.9,
        extendedDynamicRangeAmount: 1
    )
}

/// A measured RAW baseline is only valid for the camera that produced its
/// reference files. Keeping selection separate from the decoder prevents a
/// Panasonic calibration from silently changing Sony, Canon, Nikon, or Fuji
/// RAW files that Core Image can also open.
public struct RAWCalibrationProfile: Equatable, Sendable {
    public let id: String
    public let label: String
    public let configuration: RAWDecodeConfiguration

    public init(id: String, label: String, configuration: RAWDecodeConfiguration) {
        self.id = id
        self.label = label
        self.configuration = configuration
    }

    public static let generic = RAWCalibrationProfile(
        id: "core-image-raw8-generic-v1",
        label: "未校正RAW基準",
        configuration: .calibrationBaseline
    )

    public static let panasonicDCS5Lightroom93 = RAWCalibrationProfile(
        id: "panasonic-dc-s5-lightroom-9.3-edr1-v2",
        label: "DC-S5 EDR1暫定校正（2シーン）",
        configuration: .lumixDCS5LightroomBaseline
    )

    public static func matching(make: String?, model: String?) -> RAWCalibrationProfile {
        let normalizedMake = normalizeMake(make)
        let normalizedModel = normalizeModel(model)
        if normalizedMake.contains("panasonic"),
           normalizedModel == "dc-s5" || normalizedModel == "lumix dc-s5" {
            return .panasonicDCS5Lightroom93
        }
        return .generic
    }

    private static func normalizedText(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            ?? ""
    }

    private static func normalizeMake(_ value: String?) -> String {
        normalizedText(value)
    }

    private static func normalizeModel(_ value: String?) -> String {
        let normalized = normalizedText(value)
        return normalized.hasPrefix("panasonic ")
            ? String(normalized.dropFirst("panasonic ".count))
            : normalized
    }
}

public enum ImageDecoderError: LocalizedError {
    case unsupported(URL)
    case rawDecodeFailed(URL)
    case invalidPreviewMaximumDimension(Int)
    case invalidNativeDimensions(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let url): "画像を読み込めません: \(url.lastPathComponent)"
        case .rawDecodeFailed(let url): "RAWを現像できません: \(url.lastPathComponent)"
        case .invalidPreviewMaximumDimension(let value):
            "プレビューの最大辺は1以上で指定してください: \(value)"
        case .invalidNativeDimensions(let url):
            "画像の原寸サイズを確認できません: \(url.lastPathComponent)"
        }
    }
}

public struct CoreImageDecoder: ImageDecoding {
    public static let processingIdentifier = "core-image-raw8-intent-v2"

    private let rawConfigurationOverride: RAWDecodeConfiguration?

    /// Passing an explicit configuration is reserved for the calibration CLI.
    /// Normal app decoding selects a measured profile from camera metadata.
    public init(rawConfiguration: RAWDecodeConfiguration? = nil) {
        self.rawConfigurationOverride = rawConfiguration
    }

    public func decode(
        url: URL,
        intent: ImageDecodeIntent = .fullResolution
    ) throws -> DecodedPhoto {
        if let requestedMaximumDimension = intent.requestedMaximumDimension,
           requestedMaximumDimension < 1 {
            throw ImageDecoderError.invalidPreviewMaximumDimension(requestedMaximumDimension)
        }
        let started = ContinuousClock.now
        let metadata = Self.readMetadata(url: url)
        let isRAW = PhotoKind.detect(url: url) == .raw
        let camera = Self.cameraIdentity(metadata: metadata)
        let image: CIImage
        let backend: String
        var calibrationID: String?
        var calibrationLabel: String?
        var isBoundedSRGBRaster = false
        var nativeWidth = 0
        var nativeHeight = 0
        var appliedScaleFactor: Float?

        if isRAW {
            guard let filter = CIRAWFilter(imageURL: url) else {
                throw ImageDecoderError.rawDecodeFailed(url)
            }
            let supportsValidatedDecoder = filter.supportedDecoderVersions.contains(.version8)
            if supportsValidatedDecoder {
                filter.decoderVersion = .version8
            }
            let nativeSize = filter.nativeSize
            guard let validatedNativeWidth = Self.validatedPixelDimension(nativeSize.width),
                  let validatedNativeHeight = Self.validatedPixelDimension(nativeSize.height)
            else {
                throw ImageDecoderError.invalidNativeDimensions(url)
            }
            nativeWidth = validatedNativeWidth
            nativeHeight = validatedNativeHeight

            let profile: RAWCalibrationProfile
            if let rawConfigurationOverride {
                profile = RAWCalibrationProfile(
                    id: "manual-calibration-override",
                    label: "校正ツール指定値",
                    configuration: rawConfigurationOverride
                )
            } else if supportsValidatedDecoder {
                profile = RAWCalibrationProfile.matching(make: camera.make, model: camera.model)
            } else {
                // The measured DC-S5 coefficients are valid only with RAW 8.
                // Falling back to a newer decoder must never retain a green
                // "calibrated" label or silently reuse those coefficients.
                profile = .generic
            }
            let rawConfiguration = profile.configuration
            calibrationID = profile.id
            calibrationLabel = profile.label
            // RAW 9以降は処理内容が変わるため、検証したRAW 8を利用可能な限り固定する。
            // これによりmacOS更新後も同じ写真が突然別の発色になるのを防ぐ。
            // Core Image's default global tone boost is intentionally disabled.
            // This creates a stable, scene-referred baseline for the Lightroom
            // comparison gate instead of silently depending on an OS default.
            filter.exposure = rawConfiguration.exposure
            filter.shadowBias = rawConfiguration.shadowBias
            filter.boostAmount = rawConfiguration.boostAmount
            filter.boostShadowAmount = rawConfiguration.boostShadowAmount
            filter.extendedDynamicRangeAmount = rawConfiguration.extendedDynamicRangeAmount
            let rawScaleFactor: Float
            switch intent {
            case let .interactivePreview(maxDimension):
                let nativeLongest = max(nativeSize.width, nativeSize.height)
                rawScaleFactor = min(1, Float(CGFloat(maxDimension) / nativeLongest))
            case .fullResolution:
                rawScaleFactor = 1
            }
            // This must be set before outputImage is first requested. Apple
            // documents scaleFactor as a RAW decode-time performance control,
            // not as a post-decode resize operation.
            filter.scaleFactor = rawScaleFactor
            appliedScaleFactor = rawScaleFactor
            // Make the upstream policy explicit. RAW values are still kept in
            // extended-linear sRGB after decode; Core Image only maps the
            // camera-native gamut into that working space here.
            filter.isGamutMappingEnabled = true
            guard let calibratedOutput = filter.outputImage else {
                throw ImageDecoderError.rawDecodeFailed(url)
            }
            image = calibratedOutput
            backend = "Core Image RAW \(filter.decoderVersion.rawValue)"
        } else {
            guard let loaded = CIImage(
                contentsOf: url,
                options: [.applyOrientationProperty: true, .cacheImmediately: false]
            ) else {
                throw ImageDecoderError.unsupported(url)
            }
            image = loaded
            backend = "ImageIO"
            isBoundedSRGBRaster = loaded.colorSpace?.name == CGColorSpace.sRGB
            guard let validatedNativeWidth = Self.validatedPixelDimension(loaded.extent.width),
                  let validatedNativeHeight = Self.validatedPixelDimension(loaded.extent.height)
            else {
                throw ImageDecoderError.invalidNativeDimensions(url)
            }
            nativeWidth = validatedNativeWidth
            nativeHeight = validatedNativeHeight
        }

        let duration = started.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return DecodedPhoto(
            sourceURL: url,
            image: image,
            metadata: metadata,
            info: DecodeInfo(
                backend: backend,
                width: Int(image.extent.width.rounded()),
                height: Int(image.extent.height.rounded()),
                durationMilliseconds: milliseconds,
                isRAW: isRAW,
                isBoundedSRGBRaster: isBoundedSRGBRaster,
                cameraMake: camera.make,
                cameraModel: camera.model,
                calibrationID: calibrationID,
                calibrationLabel: calibrationLabel,
                intent: intent,
                requestedMaximumDimension: intent.requestedMaximumDimension,
                nativeWidth: nativeWidth,
                nativeHeight: nativeHeight,
                appliedScaleFactor: appliedScaleFactor
            )
        )
    }

    /// Converts framework-provided dimensions without allowing NaN, infinity,
    /// zero, negative, or out-of-range values to reach an Int conversion or an
    /// export provenance record.
    static func validatedPixelDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard let dimension = Int(exactly: rounded), dimension > 0 else { return nil }
        return dimension
    }

    private static func cameraIdentity(metadata: [String: Any]) -> (make: String?, model: String?) {
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake as String] as? String)
            ?? metadata[kCGImagePropertyTIFFMake as String] as? String
        let model = (tiff?[kCGImagePropertyTIFFModel as String] as? String)
            ?? metadata[kCGImagePropertyTIFFModel as String] as? String
        return (make, model)
    }

    /// Internal (not `private`) so `LibRawDecoder` can reuse the same EXIF/TIFF
    /// read for RAW photos it decodes without going through `CIRAWFilter`.
    static func readMetadata(url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }
        return properties
    }
}

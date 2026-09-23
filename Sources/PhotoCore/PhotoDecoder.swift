import CoreImage
import Foundation

/// `ImageDecoding` facade: RAW extensions try `LibRawDecoder` (Adobe DCP +
/// Adobe Color base rendering) first and fall back to the existing
/// `CoreImageDecoder` RAW path when LibRaw can't decode the file or the
/// Adobe profile assets are not installed; every other extension (JPEG,
/// HEIC, PNG, TIFF) goes straight to `CoreImageDecoder`, unchanged
/// (`docs/PHASE1_BASE_RENDERING.md` B2).
public struct PhotoDecoder: ImageDecoding {
    /// Setting this to `coreImageEngineValue` ("coreimage") always uses
    /// `CoreImageDecoder`, even for RAW, bypassing `LibRawDecoder` entirely.
    public static let rawEngineEnvironmentVariable = "PHOTO_BENCH_RAW_ENGINE"
    public static let coreImageEngineValue = "coreimage"

    private let libRawDecoder: LibRawDecoder
    private let coreImageDecoder: CoreImageDecoder
    private let forceCoreImageEngine: Bool

    /// Passing an explicit `rawConfiguration` is reserved for the
    /// calibration CLI, exactly as `CoreImageDecoder.init` documents; it only
    /// affects the Core Image fallback path (LibRaw's Adobe-DCP pipeline has
    /// no equivalent per-camera boost knobs).
    public init(
        rawConfiguration: RAWDecodeConfiguration? = nil,
        profileLocator: AdobeProfileLocator = AdobeProfileLocator(),
        toneCurveVariant: ToneCurveVariant = .b,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        libRawDecoder = LibRawDecoder(profileLocator: profileLocator, toneCurveVariant: toneCurveVariant)
        coreImageDecoder = CoreImageDecoder(rawConfiguration: rawConfiguration)
        forceCoreImageEngine = environment[Self.rawEngineEnvironmentVariable] == Self.coreImageEngineValue
    }

    public func decode(url: URL, intent: ImageDecodeIntent = .fullResolution) throws -> DecodedPhoto {
        guard PhotoKind.detect(url: url) == .raw, !forceCoreImageEngine else {
            return try coreImageDecoder.decode(url: url, intent: intent)
        }
        do {
            return try libRawDecoder.decode(url: url, intent: intent)
        } catch {
            let fallback = try coreImageDecoder.decode(url: url, intent: intent)
            return Self.annotatingFallback(fallback, reason: error)
        }
    }

    /// Keeps `CoreImageDecoder`'s own `calibrationLabel`/`calibrationID`
    /// (its per-camera boost calibration is a separate, unrelated concept
    /// from the Adobe DCP pipeline) but records the fallback in `backend` so
    /// it is visible in logs/UI/exported-JPEG provenance, per
    /// `docs/PHASE1_BASE_RENDERING.md`'s "DecodeInfo.backend にその旨を残す".
    private static func annotatingFallback(_ decoded: DecodedPhoto, reason: Error) -> DecodedPhoto {
        let info = decoded.info
        let annotatedInfo = DecodeInfo(
            backend: "\(info.backend) [LibRawフォールバック: \(shortReason(reason))]",
            width: info.width,
            height: info.height,
            durationMilliseconds: info.durationMilliseconds,
            isRAW: info.isRAW,
            isBoundedSRGBRaster: info.isBoundedSRGBRaster,
            cameraMake: info.cameraMake,
            cameraModel: info.cameraModel,
            calibrationID: info.calibrationID,
            calibrationLabel: info.calibrationLabel,
            intent: info.intent,
            requestedMaximumDimension: info.requestedMaximumDimension,
            nativeWidth: info.nativeWidth,
            nativeHeight: info.nativeHeight,
            appliedScaleFactor: info.appliedScaleFactor,
            asShotWhiteXY: info.asShotWhiteXY,
            lensCorrection: info.lensCorrection
        )
        return DecodedPhoto(
            sourceURL: decoded.sourceURL,
            image: decoded.image,
            metadata: decoded.metadata,
            info: annotatedInfo,
            adobeBase: decoded.adobeBase
        )
    }

    private static func shortReason(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

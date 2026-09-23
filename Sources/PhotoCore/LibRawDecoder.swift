import Accelerate
import CLibRawShim
import CoreImage
import Foundation

public enum LibRawDecoderError: LocalizedError, Sendable {
    case decodeFailed(url: URL, code: Int32, message: String)
    case unexpectedChannelCount(url: URL, colors: Int32)
    case invalidPixelBuffer(URL)
    case invalidWhiteBalance(url: URL)
    case pixelConversionFailed(URL)
    case profileNotFound(url: URL, uniqueCameraModel: String)

    public var errorDescription: String? {
        switch self {
        case let .decodeFailed(url, code, message):
            "LibRawのデコードに失敗しました(\(code)): \(url.lastPathComponent) — \(message)"
        case let .unexpectedChannelCount(url, colors):
            "LibRawの出力チャンネル数が想定外です(\(colors)): \(url.lastPathComponent)"
        case let .invalidPixelBuffer(url):
            "LibRawが空のピクセルバッファを返しました: \(url.lastPathComponent)"
        case let .invalidWhiteBalance(url):
            "LibRawのカメラ内WB係数(cam_mul)が不正です: \(url.lastPathComponent)"
        case let .pixelConversionFailed(url):
            "RAWピクセルのRGB16→RGBA16変換に失敗しました: \(url.lastPathComponent)"
        case let .profileNotFound(url, uniqueCameraModel):
            "Adobe DCP/Adobe Colorプロファイルが見つかりません(\(uniqueCameraModel)): \(url.lastPathComponent)"
        }
    }
}

/// `ImageDecoding` backed by LibRaw 0.21.4 + the Adobe DCP / "Adobe Color"
/// base-rendering pipeline (`docs/PHASE1_BASE_RENDERING.md` B2). Throws
/// whenever LibRaw cannot decode the file, its pixel data cannot be turned
/// into a `CIImage`, or (most commonly) the Adobe profile assets are not
/// installed on this machine; `PhotoDecoder` catches every case and falls
/// back to `CoreImageDecoder` rather than failing the photo entirely.
public struct LibRawDecoder: ImageDecoding {
    public static let backendLabel = "LibRaw 0.21.4 + Adobe DCP"
    /// `ImageDecodeIntent.interactivePreview` requests at or under this
    /// longest-edge size decode at LibRaw's `half_size=1` (2x2-box-averaged,
    /// no full AHD demosaic) for interactive speed; anything larger, and
    /// every `.fullResolution` request, decodes at native size.
    public static let halfSizeMaximumDimension = 3_000
    /// `DecodeInfo.lensCorrection` label used whenever a Panasonic RW2's
    /// embedded `DistortionInfo` is applied (`.photobench/phase4/lens/model.md`).
    static let panasonicLensCorrectionLabel = "内蔵歪曲補正（Panasonic DistortionInfo）"

    private let profileLocator: AdobeProfileLocator
    private let toneCurveVariant: ToneCurveVariant

    public init(
        profileLocator: AdobeProfileLocator = AdobeProfileLocator(),
        toneCurveVariant: ToneCurveVariant = .production
    ) {
        self.profileLocator = profileLocator
        self.toneCurveVariant = toneCurveVariant
    }

    public func decode(url: URL, intent: ImageDecodeIntent = .fullResolution) throws -> DecodedPhoto {
        if let requestedMaximumDimension = intent.requestedMaximumDimension,
           requestedMaximumDimension < 1 {
            throw ImageDecoderError.invalidPreviewMaximumDimension(requestedMaximumDimension)
        }
        let started = ContinuousClock.now
        let wantsHalfSize = Self.wantsHalfSize(intent: intent)

        var shimResult = CLibRawShimResult()
        let decodeStatus = url.path.withCString { path in
            clibraw_shim_decode(path, wantsHalfSize ? 1 : 0, &shimResult)
        }
        guard decodeStatus == 0 else {
            let message = String(cString: clibraw_shim_strerror(decodeStatus))
            throw LibRawDecoderError.decodeFailed(url: url, code: decodeStatus, message: message)
        }
        defer { clibraw_shim_free(&shimResult) }

        guard shimResult.colors == 3 else {
            throw LibRawDecoderError.unexpectedChannelCount(url: url, colors: shimResult.colors)
        }
        let width = Int(shimResult.width)
        let height = Int(shimResult.height)
        guard width > 0, height > 0, let pixelPointer = shimResult.pixels else {
            throw LibRawDecoderError.invalidPixelBuffer(url)
        }
        // Read early: the lens-distortion block below (right before
        // `AdobeBaseRenderer.makeHandle`) needs `appliedHalfSize` to size
        // its corrected canvas, and `nativeWidth`/`nativeHeight` feed that
        // same block's no-correction fallback.
        let appliedHalfSize = shimResult.appliedHalfSize != 0
        let nativeWidth = Int(shimResult.nativeWidth)
        let nativeHeight = Int(shimResult.nativeHeight)

        let rawCameraImage = try Self.makeCameraImage(
            pixels: pixelPointer, width: width, height: height, url: url
        )

        let camMul = Self.array4(shimResult.camMul)
        guard camMul[0].isFinite, camMul[1].isFinite, camMul[2].isFinite,
              camMul[0] > 0, camMul[1] > 0, camMul[2] > 0
        else {
            throw LibRawDecoderError.invalidWhiteBalance(url: url)
        }
        // `(G/R, 1, G/B)`: the as-shot neutral, G=1-normalized (see
        // `docs/PHASE1_BASE_RENDERING.md` B2 note on `neutralG1` and
        // `AdobeBaseAssets.init`'s `neutralG1` parameter doc for why this is
        // the reciprocal-and-renormalized form of `cam_mul`, not `cam_mul`
        // or `1/cam_mul` directly).
        let neutralG1 = SIMD3(
            Double(camMul[1] / camMul[0]), 1.0, Double(camMul[1] / camMul[2])
        )

        let make = Self.cString(from: shimResult.make)
        let model = Self.cString(from: shimResult.model)
        let normalizedMake = Self.cString(from: shimResult.normalizedMake)
        let normalizedModel = Self.cString(from: shimResult.normalizedModel)
        let effectiveMake = normalizedMake.isEmpty ? make : normalizedMake
        let effectiveModel = normalizedModel.isEmpty ? model : normalizedModel
        let uniqueCameraModel = "\(effectiveMake) \(effectiveModel)"
            .trimmingCharacters(in: .whitespaces)

        guard let locatedDCP = profileLocator.locateDCP(uniqueCameraModel: uniqueCameraModel),
              let lookURL = profileLocator.locateAdobeColorLookXMP(),
              let look = try? AdobeLookXMP(contentsOf: lookURL)
        else {
            throw LibRawDecoderError.profileNotFound(url: url, uniqueCameraModel: uniqueCameraModel)
        }

        let assets = try AdobeBaseAssets(dcp: locatedDCP.profile, look: look, neutralG1: neutralG1)
        let cacheKey = AdobeBaseRenderer.CacheKey(
            dcpIdentity: locatedDCP.url.path,
            lookIdentity: lookURL.path,
            whiteXY: assets.whiteXY,
            exposureEV: assets.baselineEV,
            variant: toneCurveVariant
        )

        // Lumix RW2s the camera itself declares a `DistortionInfo` for
        // (`.photobench/phase4/lens/model.md`) get their in-body radial
        // distortion correction applied here, to `rawCameraImage` --
        // camera RGB, linear light, before Stage M / any color processing
        // -- exactly like Lightroom's own always-on handling of the same
        // embedded correction. Everything else (no RW2 tag, or the file's
        // own `DistortionCorrection` flag off) decodes exactly as before.
        let scaleFactor: Double = appliedHalfSize ? 0.5 : 1.0
        let distortionInfo = PanasonicRW2Metadata.readDistortionInfo(url: url)
        var cameraImage: CIImage
        var correctedWidth: Int
        var correctedHeight: Int
        var correctedNativeWidth: Int
        var correctedNativeHeight: Int
        let lensCorrection: String?
        if let distortionInfo, distortionInfo.correctionEnabled {
            cameraImage = LensDistortion.apply(to: rawCameraImage, info: distortionInfo, scaleFactor: scaleFactor)
            correctedWidth = Int((Double(distortionInfo.cropWidth) * scaleFactor).rounded())
            correctedHeight = Int((Double(distortionInfo.cropHeight) * scaleFactor).rounded())
            correctedNativeWidth = distortionInfo.cropWidth
            correctedNativeHeight = distortionInfo.cropHeight
            lensCorrection = Self.panasonicLensCorrectionLabel
        } else {
            cameraImage = rawCameraImage
            correctedWidth = width
            correctedHeight = height
            correctedNativeWidth = nativeWidth > 0 ? nativeWidth : width
            correctedNativeHeight = nativeHeight > 0 ? nativeHeight : height
            lensCorrection = nil
        }

        // EXIF/camera-sensor orientation (`raw->sizes.flip` via the shim):
        // independent of, and applied after, the lens-distortion warp above
        // (that warp is symmetric about the geometric center, so the two
        // operations commute; rotating last -- still before `makeHandle`,
        // so `Handle`'s own cached images and everything `RenderEngine`
        // later builds from `decoded.adobeBase` see the final, correctly
        // oriented canvas too -- means this code never has to reason about
        // a rotated center/crop rect). A portrait RW2 (`flip` 5 or 6) swaps
        // width/height here to match.
        let orientation = Self.orientation(forFlip: shimResult.flip)
        if orientation != .up {
            cameraImage = cameraImage.oriented(orientation)
            if orientation == .left || orientation == .right {
                swap(&correctedWidth, &correctedHeight)
                swap(&correctedNativeWidth, &correctedNativeHeight)
            }
        }

        let handle = AdobeBaseRenderer.makeHandle(
            cameraImage: cameraImage, assets: assets, cacheKey: cacheKey, variant: toneCurveVariant
        )
        let renderedImage = handle.image(userExposureEV: 0)

        let metadata = CoreImageDecoder.readMetadata(url: url)

        let duration = started.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000

        return DecodedPhoto(
            sourceURL: url,
            image: renderedImage,
            metadata: metadata,
            info: DecodeInfo(
                backend: Self.backendLabel,
                width: correctedWidth,
                height: correctedHeight,
                durationMilliseconds: milliseconds,
                isRAW: true,
                isBoundedSRGBRaster: false,
                cameraMake: effectiveMake.isEmpty ? nil : effectiveMake,
                cameraModel: effectiveModel.isEmpty ? nil : effectiveModel,
                calibrationID: "adobe-dcp-v1",
                calibrationLabel: Self.calibrationLabel(
                    profileName: locatedDCP.profile.profileName, baselineEV: assets.baselineEV
                ),
                intent: intent,
                requestedMaximumDimension: intent.requestedMaximumDimension,
                nativeWidth: correctedNativeWidth,
                nativeHeight: correctedNativeHeight,
                appliedScaleFactor: Float(scaleFactor),
                asShotWhiteXY: assets.whiteXY,
                lensCorrection: lensCorrection
            ),
            adobeBase: handle
        )
    }

    /// Maps `CLibRawShimResult.flip` (LibRaw/dcraw's `sizes.flip`: 0 = none,
    /// 3 = 180 deg, 5 = 90 deg CCW, 6 = 90 deg CW -- see that field's doc
    /// comment) to the `CGImagePropertyOrientation` describing the same
    /// correction, verified against a real portrait RW2
    /// (`exports/lr-measure/round2/extra-raw/P1581356.RW2`: shim
    /// `flip == 5`, `exiftool -Orientation` reports EXIF orientation 8 /
    /// "Rotate 270 CW", which is exactly `CGImagePropertyOrientation.left`)
    /// and empirically against `CIImage.oriented(_:)`'s actual pixel
    /// movement (an asymmetric single-pixel marker confirms `.left`/`.right`
    /// rotate the content 90 deg CCW/CW respectively, matching
    /// `CGImageProperties.h`'s own "- 90 deg CCW"/"- 90 deg CW" comments on
    /// those cases). Any other raw value (never observed; LibRaw does not
    /// formally restrict the field to just these four) falls back to `.up`
    /// (no rotation) rather than guessing.
    static func orientation(forFlip flip: Int32) -> CGImagePropertyOrientation {
        // LibRaw's `sizes.flip` mirrors the EXIF orientation dcraw would apply
        // to make the image upright: 3 = 180°, 5 = EXIF 8 (rotate 270° CW, i.e.
        // 90° CCW to correct), 6 = EXIF 6 (rotate 90° CW to correct). Mapping
        // to the matching `CGImagePropertyOrientation` (.left = 8, .right = 6)
        // lets `CIImage.oriented` undo it. Verified against the camera's own
        // `CameraOrientation: Rotate CCW` tag on P1581356 (flip 5 -> .left).
        // NOTE: Lightroom's exports of the two portrait RW2s in round2
        // (P1581356 / P1581368) match none of the 8 orientations of our
        // render (mean ΔE00 >= 20 for every one), so they are not usable as
        // geometry references; the app follows EXIF here.
        // `PHOTO_BENCH_ORIENTATION_OVERRIDE=<1-8>` forces an orientation for
        // experiments only.
        if let raw = ProcessInfo.processInfo.environment["PHOTO_BENCH_ORIENTATION_OVERRIDE"],
           let value = UInt32(raw), let forced = CGImagePropertyOrientation(rawValue: value) {
            return forced
        }
        switch flip {
        case 3: return .down
        case 5: return .left
        case 6: return .right
        default: return .up
        }
    }

    private static func wantsHalfSize(intent: ImageDecodeIntent) -> Bool {
        guard let requestedMaximumDimension = intent.requestedMaximumDimension else { return false }
        return requestedMaximumDimension <= halfSizeMaximumDimension
    }

    /// e.g. "Adobe Standard + Adobe Color（LibRaw）/ baselineEV +0.057".
    private static func calibrationLabel(profileName: String, baselineEV: Double) -> String {
        let name = profileName.isEmpty ? "Adobe Standard" : profileName
        let sign = baselineEV >= 0 ? "+" : ""
        let ev = String(format: "%.3f", baselineEV)
        return "\(name) + Adobe Color（LibRaw）/ baselineEV \(sign)\(ev)"
    }

    private static func array4(_ tuple: (Float, Float, Float, Float)) -> [Float] {
        [tuple.0, tuple.1, tuple.2, tuple.3]
    }

    /// Reinterprets a fixed-size C `char[N]` field (imported as an N-tuple of
    /// `CChar`) as a NUL-terminated C string. Safe because
    /// `Sources/CLibRawShim/shim.c`'s `copyCString` always NUL-terminates.
    private static func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }

    /// RGB16 (3-channel, from LibRaw) -> RGBA16 (4-channel, alpha = opaque)
    /// via vImage, then wraps the result as a `colorSpace: nil` `CIImage` --
    /// i.e. the numbers are handed to Core Image as-is, camera-native RGB
    /// with white == 1.0, not run through any color management
    /// (`docs/PHASE1_BASE_RENDERING.md` B2's decoder note).
    private static func makeCameraImage(
        pixels: UnsafeMutablePointer<UInt16>, width: Int, height: Int, url: URL
    ) throws -> CIImage {
        let sourceRowBytes = width * 3 * MemoryLayout<UInt16>.size
        let destinationRowBytes = width * 4 * MemoryLayout<UInt16>.size
        let destinationByteCount = destinationRowBytes * height
        guard let destination = malloc(destinationByteCount) else {
            throw LibRawDecoderError.pixelConversionFailed(url)
        }

        var sourceBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(pixels),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: sourceRowBytes
        )
        var destinationBuffer = vImage_Buffer(
            data: destination,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: destinationRowBytes
        )
        // `aSrc: nil` uses the constant `alpha` (fully opaque) for every
        // pixel instead of reading a second planar alpha source.
        let conversionError = vImageConvert_RGB16UtoRGBA16U(
            &sourceBuffer, nil, 65_535, &destinationBuffer, false, vImage_Flags(kvImageNoFlags)
        )
        guard conversionError == kvImageNoError else {
            free(destination)
            throw LibRawDecoderError.pixelConversionFailed(url)
        }

        let data = Data(bytesNoCopy: destination, count: destinationByteCount, deallocator: .free)
        return CIImage(
            bitmapData: data,
            bytesPerRow: destinationRowBytes,
            size: CGSize(width: width, height: height),
            format: .RGBA16,
            colorSpace: nil
        )
    }
}

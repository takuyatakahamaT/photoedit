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

    private let profileLocator: AdobeProfileLocator
    private let toneCurveVariant: ToneCurveVariant

    public init(
        profileLocator: AdobeProfileLocator = AdobeProfileLocator(),
        toneCurveVariant: ToneCurveVariant = .b
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

        let cameraImage = try Self.makeCameraImage(
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
        let handle = AdobeBaseRenderer.makeHandle(
            cameraImage: cameraImage, assets: assets, cacheKey: cacheKey, variant: toneCurveVariant
        )
        let renderedImage = handle.image(userExposureEV: 0)

        let appliedHalfSize = shimResult.appliedHalfSize != 0
        let nativeWidth = Int(shimResult.nativeWidth)
        let nativeHeight = Int(shimResult.nativeHeight)
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
                width: width,
                height: height,
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
                nativeWidth: nativeWidth > 0 ? nativeWidth : width,
                nativeHeight: nativeHeight > 0 ? nativeHeight : height,
                appliedScaleFactor: appliedHalfSize ? 0.5 : 1.0
            ),
            adobeBase: handle
        )
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

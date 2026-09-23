import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import PhotoBenchCalibrationSupport
import PhotoCore
import Testing

/// Regression guard for the 2026-09-24 missing-tile defect
/// (`CALIBRATION.md`「非決定的な描画欠損」). A large CPU-backed raster (an
/// ImageIO TIFF, lazily decoded) run through the spatial pass occasionally
/// came back with its later 1024-px input tiles as transparent black, which
/// the export then carried as missing 256-px tiles at 1,500 px.
///
/// The trigger needed both a raster larger than Core Image renders in one
/// pass (6000x4000 reproduced; 3072x2048 never did) and the calibration
/// runner's stage sequence with cold per-settings caches: replaying it on a
/// synthetic TIFF lost 8 of 16 renders before the fix and none after, while
/// rendering one fixed setting repeatedly never reproduced. So this test
/// replays that sequence instead of looping one call.
///
/// The replay holds several GB of GPU memory at 24 MP, so it only runs on a
/// machine with at least 32 GB (the calibration Mac Studio); the 16 GB Mac
/// mini has reset under comparable load.
@Suite("Raster input tile integrity", .serialized)
struct RasterInputTileIntegrityTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static let hasHeadroom = MTLCreateSystemDefaultDevice() != nil
        && ProcessInfo.processInfo.physicalMemory >= 32 * 1_073_741_824

    /// `calibration/manifest-v4.json`'s legacy candidates, then its stage
    /// matrix, in the order `PhotoBenchCalibration` renders them.
    static let calibrationSequence = [
        "exposure-only", "tone-base", "basic-legacy", "full-current",
        "tone-base", "tone-plus-vibrance", "tone-plus-global-saturation",
        "tone-plus-global-curve", "tone-plus-rgb-curves", "tone-plus-all-curves",
        "tone-plus-mixer-hue", "tone-plus-mixer-saturation", "tone-plus-mixer-luminance",
        "tone-plus-all-mixer", "tone-plus-curves-mixer", "full-current"
    ]

    @Test(.enabled(if: hasHeadroom))
    func largeRasterKeepsEveryTileThroughTheCalibrationStageSequence() throws {
        let preset = try XMPPresetParser.parse(
            url: projectRoot.appendingPathComponent("niho-priset_colorful.xmp")
        )
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("RasterInputTileIntegrityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let raster = sandbox.appendingPathComponent("raster.tif")
        try Self.writeSyntheticTIFF(width: 6_000, height: 4_000, to: raster)
        let decoded = try CoreImageDecoder().decode(url: raster)
        let renderer = RenderEngine()

        var damaged: [String: Double] = [:]
        for (index, candidateID) in Self.calibrationSequence.enumerated() {
            try autoreleasepool {
                let settings = try CalibrationStageFactory.settings(for: candidateID, preset: preset)
                let destination = sandbox.appendingPathComponent("\(index)-\(candidateID).tif")
                _ = try renderer.exportTIFF(
                    decoded: decoded,
                    settings: settings,
                    destination: destination,
                    maxDimension: 1_500,
                    outputTransformPlacement: .afterDownsampling
                )
                let transparent = try Self.transparentFraction(destination)
                if transparent > 0 {
                    damaged["\(index)-\(candidateID)"] = transparent
                }
            }
        }
        #expect(damaged.isEmpty, "transparent pixels by render: \(damaged)")
    }

    /// A smooth, opaque 16-bit RGB gradient with a little noise, stored
    /// uncompressed like the Lightroom-exported calibration inputs.
    private static func writeSyntheticTIFF(width: Int, height: Int, to url: URL) throws {
        var pixels = [UInt16](repeating: 0, count: width * height * 3)
        var seed: UInt32 = 12_345
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Double(seed >> 16) / 65_535 * 0.05
                let base = (y * width + x) * 3
                let gx = Double(x) / Double(width)
                let gy = Double(y) / Double(height)
                pixels[base] = UInt16(min(1, 0.15 + 0.7 * gx + noise) * 65_535)
                pixels[base + 1] = UInt16(min(1, 0.1 + 0.6 * gy + noise) * 65_535)
                pixels[base + 2] = UInt16(min(1, 0.2 + 0.5 * (1 - gx) * gy + noise) * 65_535)
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            ),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Fraction of pixels whose alpha is exactly zero in an exported TIFF.
    /// Core Image writes a fully opaque render without an alpha channel, and
    /// such a file has no transparent pixel by construction.
    private static func transparentFraction(_ url: URL) throws -> Double {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerComponent = image.bitsPerComponent / 8
        let alphaOffset: Int
        switch image.alphaInfo {
        case .first, .premultipliedFirst:
            alphaOffset = 0
        case .last, .premultipliedLast:
            alphaOffset = bytesPerPixel - bytesPerComponent
        default:
            return 0
        }
        let data = try #require(image.dataProvider?.data) as Data
        var zero = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<image.height {
                let row = y * image.bytesPerRow
                for x in 0..<image.width {
                    let offset = row + x * bytesPerPixel + alphaOffset
                    var isZero = true
                    for byte in 0..<bytesPerComponent where bytes[offset + byte] != 0 {
                        isZero = false
                    }
                    if isZero { zero += 1 }
                }
            }
        }
        return Double(zero) / Double(image.width * image.height)
    }
}

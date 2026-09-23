import CLibRawShim
import CoreGraphics
import Foundation
import Testing
@testable import PhotoCore

/// Cross-checks `Sources/CLibRawShim/shim.c`'s LibRaw wiring against the
/// Python prototype's independent `dcraw_emu -4 -o 0 -w -W -H 0 -h -g 1 1`
/// invocation (`docs/PHASE1_BASE_RENDERING.md` B2's "Python試作との整合確認"):
/// same library, same settings, half-size (so demosaic-algorithm choice --
/// `user_qual`, which half-size bypasses entirely -- cannot explain any
/// mismatch), so the two should agree closely. This only exercises the C
/// shim directly (not `AdobeBaseRenderer`/`AdobeProfileLocator`), so it never
/// needs the Adobe DCP/"Adobe Color" assets and does not skip when they are
/// absent -- only when the large binary RAW/PPM fixtures themselves are
/// missing from this checkout.
struct LibRawDecoderTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LibRawDecoderTests.swift -> PhotoCoreTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> repo root
    }

    @Test func halfSizeDecodeMatchesPythonPrototypePPMCentralPatch() throws {
        let rawURL = projectRoot.appendingPathComponent(
            "exports/editing-mvp-20260922/lightroom-reference/P1013558.RW2"
        )
        let ppmURL = projectRoot.appendingPathComponent(
            ".photobench/engine-research-20260922/dcp-base-prototype/rawwork/P1013558.RW2.ppm"
        )
        guard FileManager.default.fileExists(atPath: rawURL.path),
              FileManager.default.fileExists(atPath: ppmURL.path)
        else {
            print("SKIP: P1013558.RW2 / 試作のPPM fixtureがこの環境に無いため、この環境ではスキップします。")
            return
        }

        let ppm = try Self.readP6PPM16(url: ppmURL)
        defer { ppm.samples.deallocate() }

        var shimResult = CLibRawShimResult()
        let status = rawURL.path.withCString { clibraw_shim_decode($0, 1, &shimResult) }
        #expect(status == 0, "clibraw_shim_decode failed: \(String(cString: clibraw_shim_strerror(status)))")
        guard status == 0 else { return }
        defer { clibraw_shim_free(&shimResult) }

        #expect(shimResult.colors == 3)
        #expect(Int(shimResult.width) == ppm.width)
        #expect(Int(shimResult.height) == ppm.height)
        guard let pixels = shimResult.pixels, shimResult.colors == 3,
              Int(shimResult.width) == ppm.width, Int(shimResult.height) == ppm.height
        else { return }

        let shimMean = Self.centralPatchMean(
            pixels: pixels, width: Int(shimResult.width), height: Int(shimResult.height), patch: 100
        )
        let ppmMean = Self.centralPatchMean(
            pixels: ppm.samples, width: ppm.width, height: ppm.height, patch: 100
        )

        for channel in 0..<3 {
            let a = shimMean[channel]
            let b = ppmMean[channel]
            let relDiff = abs(a - b) / max(1.0, abs(b))
            #expect(relDiff <= 1e-3, "channel \(channel): shim=\(a) prototype=\(b) relDiff=\(relDiff)")
        }
    }

    // MARK: - Phase4 lens correction: `LibRawDecoder.decode` end-to-end wiring
    //
    // Unlike the shim-only test above, `LibRawDecoder.decode` needs the
    // Adobe DCP/"Adobe Color" assets (`AdobeBaseRendererTests.swift`'s own
    // convention), so these skip on both that *and* the RW2 fixture being
    // absent.

    /// Full-resolution decode of a DC-S5 RW2 with an embedded, enabled
    /// `DistortionInfo` must report -- and actually produce -- the
    /// camera-declared active-area canvas (6000x4000), not LibRaw's own
    /// wider 6024x4016 active-area guess (`.photobench/phase4/lens/model.md`
    /// §2), with `lensCorrection` set.
    @Test func decodesP1013558WithLensCorrectionAtFullResolution() throws {
        let url = projectRoot.appendingPathComponent(
            "exports/editing-mvp-20260922/lightroom-reference/P1013558.RW2"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: P1013558.RW2 がこの環境に無いため、この環境ではスキップします。")
            return
        }
        guard AdobeProfileLocator().locateDCP(uniqueCameraModel: "Panasonic DC-S5") != nil,
              AdobeProfileLocator().locateAdobeColorLookXMP() != nil
        else {
            print("SKIP: Panasonic DC-S5のAdobe DCP/Adobe Color.xmpが見つからないため、この環境ではスキップします。")
            return
        }

        let decoded = try LibRawDecoder().decode(url: url)
        #expect(decoded.info.width == 6_000)
        #expect(decoded.info.height == 4_000)
        #expect(decoded.info.nativeWidth == 6_000)
        #expect(decoded.info.nativeHeight == 4_000)
        #expect(decoded.info.appliedScaleFactor == 1)
        #expect(decoded.info.lensCorrection == LibRawDecoder.panasonicLensCorrectionLabel)
        #expect(decoded.image.extent == CGRect(x: 0, y: 0, width: 6_000, height: 4_000))
    }

    /// Same file, half-size (`interactivePreview(maxDimension: 3000)`)
    /// decode: the corrected canvas halves too (3000x2000), while
    /// `nativeWidth/Height` keep reporting the full corrected size --
    /// exactly the existing `CoreImageDecoder` preview-vs-native convention
    /// (`PhotoCoreTests.decodesInteractiveLumixRAWAtTheRequestedPreviewDimension`),
    /// just applied to the corrected numbers instead of LibRaw's raw ones.
    @Test func decodesP1013558WithLensCorrectionAtHalfSize() throws {
        let url = projectRoot.appendingPathComponent(
            "exports/editing-mvp-20260922/lightroom-reference/P1013558.RW2"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: P1013558.RW2 がこの環境に無いため、この環境ではスキップします。")
            return
        }
        guard AdobeProfileLocator().locateDCP(uniqueCameraModel: "Panasonic DC-S5") != nil,
              AdobeProfileLocator().locateAdobeColorLookXMP() != nil
        else {
            print("SKIP: Panasonic DC-S5のAdobe DCP/Adobe Color.xmpが見つからないため、この環境ではスキップします。")
            return
        }

        let decoded = try LibRawDecoder().decode(url: url, intent: .interactivePreview(maxDimension: 3_000))
        #expect(decoded.info.width == 3_000)
        #expect(decoded.info.height == 2_000)
        #expect(decoded.info.nativeWidth == 6_000)
        #expect(decoded.info.nativeHeight == 4_000)
        #expect(decoded.info.appliedScaleFactor == 0.5)
        #expect(decoded.info.lensCorrection == LibRawDecoder.panasonicLensCorrectionLabel)
        #expect(decoded.image.extent == CGRect(x: 0, y: 0, width: 3_000, height: 2_000))
    }

    // MARK: - RAW orientation (EXIF/sensor `flip`)

    /// `LibRawDecoder.orientation(forFlip:)`'s own mapping (LibRaw's
    /// `sizes.flip` -> `CGImagePropertyOrientation`), independent of any
    /// fixture: 0/3/5/6 are the only values LibRaw/dcraw ever produce, and
    /// anything else must fall back to `.up` rather than guessing.
    @Test func mapsLibRawFlipValuesToTheMatchingOrientation() {
        #expect(LibRawDecoder.orientation(forFlip: 0) == .up)
        #expect(LibRawDecoder.orientation(forFlip: 3) == .down)
        #expect(LibRawDecoder.orientation(forFlip: 5) == .left)
        #expect(LibRawDecoder.orientation(forFlip: 6) == .right)
        #expect(LibRawDecoder.orientation(forFlip: 1) == .up)
        #expect(LibRawDecoder.orientation(forFlip: -1) == .up)
    }

    /// A real portrait RW2 (`exiftool -Orientation` reports EXIF 8 /
    /// "Rotate 270 CW"; `raw-identify -v` reports `Image flip: 5`): decoding
    /// must produce the same 4000x6000 canvas Lightroom exports, not
    /// LibRaw's native sensor-orientation 6000x4000 (the bug being fixed
    /// here). Personal fixture, so this skips like the others when absent.
    @Test func decodesPortraitP1581356WithOrientationApplied() throws {
        let url = projectRoot.appendingPathComponent("exports/lr-measure/round2/extra-raw/P1581356.RW2")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: P1581356.RW2 がこの環境に無いため、この環境ではスキップします。")
            return
        }
        guard AdobeProfileLocator().locateDCP(uniqueCameraModel: "Panasonic DC-S5") != nil,
              AdobeProfileLocator().locateAdobeColorLookXMP() != nil
        else {
            print("SKIP: Panasonic DC-S5のAdobe DCP/Adobe Color.xmpが見つからないため、この環境ではスキップします。")
            return
        }

        let decoded = try LibRawDecoder().decode(url: url)
        #expect(decoded.info.width == 4_000)
        #expect(decoded.info.height == 6_000)
        #expect(decoded.info.nativeWidth == 4_000)
        #expect(decoded.info.nativeHeight == 6_000)
        #expect(decoded.info.appliedScaleFactor == 1)
        #expect(decoded.info.lensCorrection == LibRawDecoder.panasonicLensCorrectionLabel)
        #expect(decoded.image.extent == CGRect(x: 0, y: 0, width: 4_000, height: 6_000))
    }

    // MARK: - Helpers

    private struct PPM16 {
        let width: Int
        let height: Int
        let samples: UnsafeMutablePointer<UInt16>
    }

    /// Reads a binary P6 PPM with a 16-bit (big-endian, per the Netpbm spec)
    /// maxval, mirroring `raw_io.py`'s `read_ppm16`. Skips `#`-comment lines
    /// wherever whitespace-separated header tokens may appear.
    private static func readP6PPM16(url: URL) throws -> PPM16 {
        let data = try Data(contentsOf: url)
        var cursor = data.startIndex

        func skipCommentsAndWhitespace() {
            while cursor < data.endIndex {
                if data[cursor] == UInt8(ascii: "#") {
                    while cursor < data.endIndex, data[cursor] != UInt8(ascii: "\n") { cursor += 1 }
                } else if data[cursor].isPPMWhitespace {
                    cursor += 1
                } else {
                    break
                }
            }
        }

        func readToken() -> String {
            skipCommentsAndWhitespace()
            var bytes: [UInt8] = []
            while cursor < data.endIndex, !data[cursor].isPPMWhitespace {
                bytes.append(data[cursor])
                cursor += 1
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        let magic = readToken()
        precondition(magic == "P6", "not a P6 PPM: \(magic)")
        let width = Int(readToken())!
        let height = Int(readToken())!
        let maxval = Int(readToken())!
        precondition(maxval > 255 && maxval <= 65_535, "expected a 16-bit PPM, got maxval=\(maxval)")
        // Exactly one whitespace byte separates the header from binary data.
        cursor = data.index(after: cursor)

        let sampleCount = width * height * 3
        let samples = UnsafeMutablePointer<UInt16>.allocate(capacity: sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: data.distance(from: data.startIndex, to: cursor))
            for index in 0..<sampleCount {
                let hi = UInt16(base.load(fromByteOffset: index * 2, as: UInt8.self))
                let lo = UInt16(base.load(fromByteOffset: index * 2 + 1, as: UInt8.self))
                samples[index] = (hi << 8) | lo // big-endian, per the Netpbm spec
            }
        }
        return PPM16(width: width, height: height, samples: samples)
    }

    /// Mean of each of the 3 interleaved channels over a `patch`x`patch`
    /// square centered in a `width`x`height` image.
    private static func centralPatchMean(
        pixels: UnsafeMutablePointer<UInt16>, width: Int, height: Int, patch: Int
    ) -> SIMD3<Double> {
        let x0 = max(0, (width - patch) / 2)
        let y0 = max(0, (height - patch) / 2)
        let x1 = min(width, x0 + patch)
        let y1 = min(height, y0 + patch)
        var sum = SIMD3<Double>(0, 0, 0)
        var count = 0
        for y in y0..<y1 {
            let rowBase = y * width * 3
            for x in x0..<x1 {
                let base = rowBase + x * 3
                sum += SIMD3(Double(pixels[base]), Double(pixels[base + 1]), Double(pixels[base + 2]))
                count += 1
            }
        }
        return sum / Double(max(count, 1))
    }
}

private extension UInt8 {
    var isPPMWhitespace: Bool {
        self == UInt8(ascii: " ") || self == UInt8(ascii: "\n")
            || self == UInt8(ascii: "\t") || self == UInt8(ascii: "\r")
    }
}

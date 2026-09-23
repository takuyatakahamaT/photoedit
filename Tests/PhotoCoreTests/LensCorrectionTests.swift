import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import PhotoCore

/// Phase4 lens correction: `PanasonicRW2Metadata` (RW2 IFD0 `DistortionInfo`
/// parsing) and `LensDistortion` (the inverse radial map, both as pure Swift
/// and as the `CIWarpKernel` `LibRawDecoder` actually applies).
/// `.photobench/phase4/lens/model.md` is the model's source of truth.
struct LensCorrectionTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LensCorrectionTests.swift -> PhotoCoreTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> repo root
    }

    // MARK: - Fixture cross-check against the independent Python/exiftool oracle

    private struct FixtureSample: Decodable {
        let name: String
        let outputX: Double
        let outputY: Double
        let expectedSourceX: Double
        let expectedSourceY: Double
    }

    private struct FixtureScene: Decodable {
        let scene: String
        let scale: Double
        let a: Double
        let b: Double
        let c: Double
        let r0: Double
        let cropWidth: Double
        let cropHeight: Double
        let inputCenterX: Double
        let inputCenterY: Double
        let outputCenterX: Double
        let outputCenterY: Double
        let samples: [FixtureSample]
    }

    private struct Fixture: Decodable {
        let scenes: [FixtureScene]
    }

    /// `.photobench/phase4/lens/make_fixture.py` computes, for representative
    /// output-canvas points (center/corners/edge-midpoints/25-50-75%-radius)
    /// of each of the 3 real DC-S5 scenes, the exact input sample position
    /// its own (independent, plain-Python) Newton-iteration inverse gives.
    /// `LensDistortion.sourcePosition(forOutput:)` must agree to <=1e-3px.
    @Test func sourcePositionMatchesPythonOracleFixture() throws {
        let url = projectRoot.appendingPathComponent("Tests/Fixtures/phase4/lens-distortion.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.scenes.count == 3)

        for scene in fixture.scenes {
            let parameters = LensDistortion.Parameters(
                scale: scene.scale, a: scene.a, b: scene.b, c: scene.c, r0: scene.r0,
                outputCenter: CGPoint(x: scene.outputCenterX, y: scene.outputCenterY),
                inputCenter: CGPoint(x: scene.inputCenterX, y: scene.inputCenterY)
            )
            #expect(scene.samples.count == 12, "\(scene.scene): 期待する代表点数と一致しません。")
            for sample in scene.samples {
                let result = LensDistortion.sourcePosition(
                    forOutput: CGPoint(x: sample.outputX, y: sample.outputY), parameters: parameters
                )
                #expect(
                    abs(result.x - sample.expectedSourceX) < 1e-3,
                    "\(scene.scene)/\(sample.name): x \(result.x) vs oracle \(sample.expectedSourceX)"
                )
                #expect(
                    abs(result.y - sample.expectedSourceY) < 1e-3,
                    "\(scene.scene)/\(sample.name): y \(result.y) vs oracle \(sample.expectedSourceY)"
                )
            }
        }
    }

    // MARK: - Metadata extraction against real RW2 fixtures (skips if absent)

    /// `exiftool -u -s3 -DistortionScale -DistortionParam08 -DistortionParam04
    /// -DistortionParam11 -DistortionN -CropLeft -CropTop -CropRight
    /// -CropBottom exports/.../P1013558.RW2` (recorded in
    /// `.photobench/phase4/lens/model.md` §1.2/§1.4).
    @Test func readsP1013558DistortionInfoMatchingExiftool() throws {
        let url = projectRoot.appendingPathComponent(
            "exports/editing-mvp-20260922/lightroom-reference/P1013558.RW2"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: P1013558.RW2 がこの環境に無いため、この環境ではスキップします。")
            return
        }
        let info = try #require(PanasonicRW2Metadata.readDistortionInfo(url: url))
        #expect(Self.relativelyClose(info.scale, 1.033_756_072_938_36))
        #expect(Self.relativelyClose(info.a, -0.034_088_134_765_625))
        #expect(Self.relativelyClose(info.b, 0.003_387_451_171_875))
        #expect(Self.relativelyClose(info.c, -0.001_495_361_328_125))
        #expect(Self.relativelyClose(info.r0, 3_605))
        #expect(info.correctionEnabled)
        #expect(info.cropRect == .init(left: 12, top: 8, right: 6_012, bottom: 4_008))
        #expect(info.cropWidth == 6_000)
        #expect(info.cropHeight == 4_000)
    }

    /// All three gate scenes (two different lenses on the same DC-S5 body)
    /// declare the correction on and share the body-constant `DistortionN`
    /// and active-area size, even though `scale/a/b/c` differ per lens
    /// (`model.md` §1.4).
    @Test func readsAllThreeReferenceScenesWithCorrectionOn() throws {
        for scene in ["P1013558", "P1013207", "P1012822"] {
            let url = projectRoot.appendingPathComponent(
                "exports/editing-mvp-20260922/lightroom-reference/\(scene).RW2"
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("SKIP: \(scene).RW2 がこの環境に無いため、この環境ではスキップします。")
                continue
            }
            let info = try #require(PanasonicRW2Metadata.readDistortionInfo(url: url))
            #expect(info.correctionEnabled)
            #expect(info.r0 == 3_605)
            #expect(info.cropWidth == 6_000)
            #expect(info.cropHeight == 4_000)
        }
    }

    @Test func returnsNilForNonRW2Files() throws {
        let url = projectRoot.appendingPathComponent("DSC02072.JPG")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: DSC02072.JPG がこの環境に無いため、この環境ではスキップします。")
            return
        }
        #expect(PanasonicRW2Metadata.readDistortionInfo(url: url) == nil)
    }

    // MARK: - Synthetic RW2 byte-layout tests (environment-independent)

    /// Hand-crafted minimal RW2-shaped TIFF: verifies the parser's byte
    /// layout/formula understanding (`data[5]/[8]/[4]/[11]/[12]` and the
    /// `data[7] & 0x0F` `DistortionCorrection` mask) directly, without
    /// depending on any real camera fixture being present.
    @Test func parsesSyntheticRW2DistortionInfoBytes() throws {
        // The exact `data[4]/[5]/[8]/[11]/[12]` bytes verified by hand
        // against `P1013558.RW2` above (`exiftool -H -u -s -DistortionInfo`),
        // reused here so the expected `scale/a/b/c/r0` are exact (no
        // rounding uncertainty from re-encoding arbitrary doubles into
        // `/32768` fixed point) and cross-check the same known-good numbers
        // through a second, file-I/O-independent path.
        let data16 = Self.encodeDistortionInfo(data5: -1_070, data8: -1_117, data4: 111, data11: -49, data12: 3_605, correctionEnabled: true)
        let bytes = Self.makeSyntheticRW2(
            distortionData16: data16, cropLeft: 12, cropTop: 8, cropRight: 6_012, cropBottom: 4_008
        )
        let url = try Self.writeTemporaryFile(bytes, name: "synthetic-on.rw2")
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try #require(PanasonicRW2Metadata.readDistortionInfo(url: url))
        #expect(Self.relativelyClose(info.scale, 1.033_756_072_938_36))
        #expect(Self.relativelyClose(info.a, -0.034_088_134_765_625))
        #expect(Self.relativelyClose(info.b, 0.003_387_451_171_875))
        #expect(Self.relativelyClose(info.c, -0.001_495_361_328_125))
        #expect(Self.relativelyClose(info.r0, 3_605))
        #expect(info.correctionEnabled)
        #expect(info.cropRect == .init(left: 12, top: 8, right: 6_012, bottom: 4_008))
    }

    /// `DistortionCorrection` (the `data[7] & 0x0F` mask) reading `0` --
    /// this must disable correction entirely (`model.md`: "Offのときは補正
    /// しない"), even though `scale/a/b/c` are otherwise present and
    /// well-formed.
    @Test func parsesSyntheticRW2WithDistortionCorrectionOff() throws {
        let data16 = Self.encodeDistortionInfo(
            data5: -1_070, data8: -1_117, data4: 111, data11: -49, data12: 3_605, correctionEnabled: false
        )
        let bytes = Self.makeSyntheticRW2(
            distortionData16: data16, cropLeft: 12, cropTop: 8, cropRight: 6_012, cropBottom: 4_008
        )
        let url = try Self.writeTemporaryFile(bytes, name: "synthetic-off.rw2")
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try #require(PanasonicRW2Metadata.readDistortionInfo(url: url))
        #expect(!info.correctionEnabled)
    }

    /// Some bodies set the upper nibble of `data[7]` too (`PanasonicRaw.pm`'s
    /// own comment: "have seen the upper 4 bits set for GF5 and GX1, giving
    /// a value of -4095"); the `& 0x0F` mask must still read "On".
    @Test func upperNibbleOfDistortionCorrectionByteIsIgnored() throws {
        var data16 = Self.encodeDistortionInfo(
            data5: -1_070, data8: -1_117, data4: 111, data11: -49, data12: 3_605, correctionEnabled: true
        )
        // Set the upper nibble (bits 4-15) while keeping the low nibble at 1,
        // mirroring the exact `-4095` bit pattern `PanasonicRaw.pm` documents
        // (0xF001 as a signed int16).
        data16[7] = Int16(bitPattern: 0xF001)
        let bytes = Self.makeSyntheticRW2(
            distortionData16: data16, cropLeft: 12, cropTop: 8, cropRight: 6_012, cropBottom: 4_008
        )
        let url = try Self.writeTemporaryFile(bytes, name: "synthetic-upper-nibble.rw2")
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try #require(PanasonicRW2Metadata.readDistortionInfo(url: url))
        #expect(info.correctionEnabled)
    }

    @Test func returnsNilWhenCropTagsAreMissing() throws {
        let data16 = Self.encodeDistortionInfo(
            data5: -1_070, data8: -1_117, data4: 111, data11: -49, data12: 3_605, correctionEnabled: true
        )
        let bytes = Self.makeSyntheticRW2(
            distortionData16: data16, cropLeft: nil, cropTop: 8, cropRight: 6_012, cropBottom: 4_008
        )
        let url = try Self.writeTemporaryFile(bytes, name: "synthetic-missing-crop.rw2")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PanasonicRW2Metadata.readDistortionInfo(url: url) == nil)
    }

    @Test func returnsNilWhenMagicNumberIsNotRW2() throws {
        let data16 = Self.encodeDistortionInfo(
            data5: -1_070, data8: -1_117, data4: 111, data11: -49, data12: 3_605, correctionEnabled: true
        )
        var bytes = Self.makeSyntheticRW2(
            distortionData16: data16, cropLeft: 12, cropTop: 8, cropRight: 6_012, cropBottom: 4_008
        )
        // Flip the magic number to the standard TIFF value (0x002A) that
        // every non-Panasonic TIFF-based RAW (DNG/NEF/ARW/CR2) also uses.
        bytes[2] = 0x2A
        bytes[3] = 0x00
        let url = try Self.writeTemporaryFile(bytes, name: "synthetic-standard-tiff.rw2")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PanasonicRW2Metadata.readDistortionInfo(url: url) == nil)
    }

    // MARK: - Synthetic marker round-trip: Swift math vs. the CIWarpKernel

    /// `LensDistortion.apply(to:info:scaleFactor:)` (the `CIWarpKernel` --
    /// hand-transcribed into CIKL) must move pixels exactly where
    /// `sourcePosition(forOutput:)` (the pure-Swift Newton solve, already
    /// checked against the Python oracle above) says they should go. Places
    /// small Gaussian markers in the *input* image at
    /// `sourcePosition(forOutput: targetOutputPoint)` for several
    /// `targetOutputPoint`s spanning a range of radii/angles, warps, and
    /// checks each marker's output-image intensity centroid lands back on
    /// its `targetOutputPoint` within +-0.5px -- i.e. the two independent
    /// implementations of the same formula agree, not just each against the
    /// Python oracle individually.
    @Test func warpMovesKnownMarkersToPredictedOutputPositions() throws {
        let outputWidth = 400
        let outputHeight = 300
        let inputWidth = 500
        let inputHeight = 400
        let parameters = LensDistortion.Parameters(
            scale: 1.05, a: -0.03, b: 0, c: 0, r0: 250,
            outputCenter: CGPoint(x: Double(outputWidth) / 2, y: Double(outputHeight) / 2),
            inputCenter: CGPoint(x: Double(inputWidth) / 2, y: Double(inputHeight) / 2)
        )
        let targetOutputPoints: [(name: String, point: CGPoint)] = [
            ("center", CGPoint(x: 200, y: 150)),
            ("top_mid", CGPoint(x: 200, y: 40)),
            ("right_mid", CGPoint(x: 380, y: 150)),
            ("lower_left", CGPoint(x: 60, y: 260)),
            ("corner_ish", CGPoint(x: 350, y: 270)),
            ("left_mid", CGPoint(x: 30, y: 150)),
            ("bottom_mid", CGPoint(x: 200, y: 280)),
        ]
        let markers = targetOutputPoints.map {
            LensDistortion.sourcePosition(forOutput: $0.point, parameters: parameters)
        }

        let inputImage = Self.makeMarkerImage(width: inputWidth, height: inputHeight, markers: markers, sigma: 2.5)
        let info = PanasonicDistortionInfo(
            scale: parameters.scale, a: parameters.a, b: parameters.b, c: parameters.c, r0: parameters.r0,
            correctionEnabled: true,
            cropRect: .init(left: 0, top: 0, right: outputWidth, bottom: outputHeight)
        )
        let warped = LensDistortion.apply(to: inputImage, info: info, scaleFactor: 1.0)
        #expect(warped.extent == CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        var rendered = [Float](repeating: 0, count: outputWidth * outputHeight * 4)
        // No `workingColorSpace`/`outputColorSpace` needed: both the input
        // marker image and this `render` call use `colorSpace: nil`, so
        // Core Image never has a source/destination space to convert
        // to/from and the numbers pass through unmanaged end-to-end, same
        // as `LibRawDecoder`'s own camera-RGB pipeline.
        let context = CIContext()
        context.render(
            warped, toBitmap: &rendered, rowBytes: outputWidth * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight), format: .RGBAf, colorSpace: nil
        )

        for (name, target) in targetOutputPoints {
            let centroid = try #require(
                Self.centroid(
                    in: rendered, width: outputWidth, height: outputHeight, near: target, windowRadius: 20
                ),
                "\(name): 出力側にマーカーの輝度が見つかりませんでした。"
            )
            let distance = (centroid.x - target.x, centroid.y - target.y)
            let error = (distance.0 * distance.0 + distance.1 * distance.1).squareRoot()
            #expect(error <= 0.5, "\(name): centroid=\(centroid) target=\(target) error=\(error)px")
        }
    }

    // MARK: - Helpers

    private static func relativelyClose(_ value: Double, _ expected: Double, tolerance: Double = 1e-6) -> Bool {
        abs(value - expected) <= tolerance * max(1, abs(expected))
    }

    /// Places the given raw `int16s` values at their documented
    /// `DistortionInfo` indices (4/5/8/11/12 -> `b`/`scale`/`a`/`c`/`r0`;
    /// `PanasonicRW2Metadata`'s doc comment), everything else `0`, index 7
    /// set from `correctionEnabled`. Taking the raw pre-`ValueConv` integers
    /// (rather than the physical `scale/a/b/c/r0` doubles) keeps this exact
    /// -- no `/32768` rounding uncertainty -- so callers can assert an exact
    /// expected `scale/a/b/c/r0` back out.
    private static func encodeDistortionInfo(
        data5: Int16, data8: Int16, data4: Int16, data11: Int16, data12: Int16, correctionEnabled: Bool
    ) -> [Int16] {
        var data = [Int16](repeating: 0, count: 16)
        data[5] = data5
        data[8] = data8
        data[4] = data4
        data[11] = data11
        data[12] = data12
        data[7] = correctionEnabled ? 1 : 0
        return data
    }

    /// Minimal RW2-shaped TIFF ("II" + magic 0x0055, IFD0 at byte 8) with
    /// just the tags `PanasonicRW2Metadata` reads: 0x0119 (`DistortionInfo`,
    /// pointed at an offset past the IFD) and the four `Crop*` tags (inline
    /// SHORTs). `cropLeft: nil` omits that one tag, for the
    /// missing-tag-returns-nil test.
    private static func makeSyntheticRW2(
        distortionData16: [Int16], cropLeft: Int?, cropTop: Int?, cropRight: Int?, cropBottom: Int?
    ) -> [UInt8] {
        struct Entry { let tag: UInt16; let type: UInt16; let count: UInt32; let value: [UInt8] }

        func inlineShort(_ value: Int) -> [UInt8] {
            let v = UInt16(value)
            return [UInt8(v & 0xFF), UInt8(v >> 8), 0, 0]
        }

        var entries: [Entry] = []
        if let cropTop { entries.append(.init(tag: 0x002F, type: 3, count: 1, value: inlineShort(cropTop))) }
        if let cropLeft { entries.append(.init(tag: 0x0030, type: 3, count: 1, value: inlineShort(cropLeft))) }
        if let cropBottom { entries.append(.init(tag: 0x0031, type: 3, count: 1, value: inlineShort(cropBottom))) }
        if let cropRight { entries.append(.init(tag: 0x0032, type: 3, count: 1, value: inlineShort(cropRight))) }
        entries.sort { $0.tag < $1.tag }
        // 0x0119 always goes last, its "value" is a placeholder 4-byte
        // offset patched in below once the true payload offset is known.
        let distortionEntryIndex = entries.count
        entries.append(.init(tag: 0x0119, type: 7, count: 32, value: [0, 0, 0, 0]))

        let ifdStart = 8
        let entryCount = entries.count
        let payloadOffset = ifdStart + 2 + entryCount * 12 + 4

        var bytes: [UInt8] = []
        bytes.append(contentsOf: [UInt8(ascii: "I"), UInt8(ascii: "I")]) // byte order
        bytes.append(contentsOf: [0x55, 0x00]) // RW2 magic 0x0055, little-endian
        bytes.append(contentsOf: Self.uint32LE(UInt32(ifdStart))) // IFD0 offset
        precondition(bytes.count == ifdStart)

        bytes.append(contentsOf: Self.uint16LE(UInt16(entryCount)))
        for (index, entry) in entries.enumerated() {
            bytes.append(contentsOf: Self.uint16LE(entry.tag))
            bytes.append(contentsOf: Self.uint16LE(entry.type))
            bytes.append(contentsOf: Self.uint32LE(entry.count))
            if index == distortionEntryIndex {
                bytes.append(contentsOf: Self.uint32LE(UInt32(payloadOffset)))
            } else {
                bytes.append(contentsOf: entry.value)
            }
        }
        bytes.append(contentsOf: Self.uint32LE(0)) // next IFD offset (none)
        precondition(bytes.count == payloadOffset)

        for value in distortionData16 {
            let bitPattern = UInt16(bitPattern: value)
            bytes.append(contentsOf: Self.uint16LE(bitPattern))
        }
        return bytes
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
        ]
    }

    private static func writeTemporaryFile(_ bytes: [UInt8], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(bytes).write(to: url)
        return url
    }

    /// A black `width`x`height` `CIImage` (colorSpace `nil`, matching
    /// `LibRawDecoder.makeCameraImage`'s "no color management" camera-RGB
    /// convention) with a small Gaussian intensity marker centered at each
    /// of `markers` -- smooth/sub-pixel-placeable, unlike a hard-edged
    /// rasterized disc, so its post-warp centroid is a clean, unbiased
    /// estimate of where that point actually landed.
    private static func makeMarkerImage(width: Int, height: Int, markers: [CGPoint], sigma: Double) -> CIImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let radius = Int((sigma * 6).rounded(.up))
        for marker in markers {
            let cx = Int(marker.x.rounded())
            let cy = Int(marker.y.rounded())
            let xRange = max(0, cx - radius)..<min(width, cx + radius + 1)
            let yRange = max(0, cy - radius)..<min(height, cy + radius + 1)
            for y in yRange {
                for x in xRange {
                    let dx = (Double(x) + 0.5) - marker.x
                    let dy = (Double(y) + 0.5) - marker.y
                    let intensity = exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                    let base = (y * width + x) * 4
                    pixels[base] = max(pixels[base], Float(intensity))
                    pixels[base + 1] = pixels[base]
                    pixels[base + 2] = pixels[base]
                    pixels[base + 3] = 1
                }
            }
        }
        return CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) },
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )
    }

    /// Intensity-weighted centroid of the red channel within
    /// `windowRadius` pixels of `point`, or `nil` if nothing above zero was
    /// found there (a real bug that moved a marker further than the window
    /// covers should show up as "no marker found" rather than a
    /// silently-wrong centroid from some *other* marker).
    private static func centroid(
        in buffer: [Float], width: Int, height: Int, near point: CGPoint, windowRadius: Int
    ) -> CGPoint? {
        let cx = Int(point.x.rounded())
        let cy = Int(point.y.rounded())
        let xRange = max(0, cx - windowRadius)..<min(width, cx + windowRadius + 1)
        let yRange = max(0, cy - windowRadius)..<min(height, cy + windowRadius + 1)
        var sumWeight = 0.0
        var sumX = 0.0
        var sumY = 0.0
        for y in yRange {
            for x in xRange {
                let weight = Double(buffer[(y * width + x) * 4])
                guard weight > 0 else { continue }
                sumWeight += weight
                sumX += weight * (Double(x) + 0.5)
                sumY += weight * (Double(y) + 0.5)
            }
        }
        guard sumWeight > 0 else { return nil }
        return CGPoint(x: sumX / sumWeight, y: sumY / sumWeight)
    }
}

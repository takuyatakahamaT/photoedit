import CoreImage
import Foundation
import Testing
@testable import PhotoCore

/// Phase2 C1 (`docs/PHASE2_DEVELOP_PIPELINE.md`) gates for `ToneOps` and the
/// absolute-white-balance chromaticity helper it depends on
/// (`ColorSpec.swift`'s `DNGTemperature.xy(fromTemperature:tint:)`):
///
///  - `toneOpsMatchesPythonReferenceFixture`: every `ToneOps` function against
///    `Tests/Fixtures/phase2/tone-ops.json`, generated from
///    `.photobench/phase2/tone/tone_model.py` (the measured reference), at
///    1e-4 relative tolerance.
///  - `xyFromTemperatureRoundTripsAndMatchesKnownIlluminantsApproximately`:
///    `DNGTemperature.xy(fromTemperature:tint:)` (`LegacyGetXY`) round-trips
///    through the already-tested `xyToTemperature` (`LegacySetXY`), lands
///    near (not exactly -- see the test's own comment) the named illuminants
///    at 5000K/6500K, and tint's sign moves `v` monotonically.
///  - `postOpsCubeMatchesCPUReferenceWithinDeltaE`: the GPU `CIColorCube`
///    baked by `AdobeBaseRenderer.postOpsCube` against the CPU
///    `ToneOps.applyPostOps` reference, same ~0.15 ΔE (OKLab-distance) budget
///    `AdobeBaseRendererTests.gpuGraphMatchesCPUReferenceWithinDeltaE` uses
///    for the phase1 cubes.
struct ToneOpsTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ToneOpsTests.swift -> PhotoCoreTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> repo root
    }

    // MARK: - Fixture model

    private struct Fixture: Decodable {
        let inputs: [[Double]]
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let op: String
        let params: Params
        let outputs: [[Double]]

        struct Params: Decodable {
            let ev: Double?
            let amount: Double?
            let contrast: Double?
            let whites: Double?
            let blacks: Double?
            let shadows: Double?
            let darks: Double?
            let lights: Double?
            let highlights: Double?
            let shadowSplit: Double?
            let midtoneSplit: Double?
            let highlightSplit: Double?
            let parametricShadows: Double?
            let parametricDarks: Double?
            let parametricLights: Double?
            let parametricHighlights: Double?
            let parametricShadowSplit: Double?
            let parametricMidtoneSplit: Double?
            let parametricHighlightSplit: Double?
            let points: [[Double]]?
        }
    }

    private func loadFixture() throws -> Fixture {
        let url = projectRoot.appendingPathComponent("Tests/Fixtures/phase2/tone-ops.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// `points` are 0...255 (the fixture's authoring convention, matching
    /// real XMP ToneCurvePV2012 points); `ToneCurve.points` are always
    /// 0...1-normalized in this codebase (`XMPPresetParser`'s own convention).
    private func curve(from points255: [[Double]], channel: ToneCurveChannel = .rgb) -> ToneCurve {
        ToneCurve(
            channel: channel,
            points: points255.map { CurvePoint(x: $0[0] / 255.0, y: $0[1] / 255.0) }
        )
    }

    private func actual(_ testCase: Case, input: SIMD3<Double>) throws -> SIMD3<Double> {
        let p = testCase.params
        switch testCase.op {
        case "exposureNonRaw":
            return ToneOps.exposureNonRaw(input, ev: try #require(p.ev))
        case "contrast":
            return ToneOps.contrast(input, amount: try #require(p.amount))
        case "whites":
            return ToneOps.whites(input, amount: try #require(p.amount))
        case "blacks":
            return ToneOps.blacks(input, amount: try #require(p.amount))
        case "parametric":
            return ToneOps.parametric(
                input,
                shadows: try #require(p.shadows), darks: try #require(p.darks),
                lights: try #require(p.lights), highlights: try #require(p.highlights),
                shadowSplit: try #require(p.shadowSplit), midtoneSplit: try #require(p.midtoneSplit),
                highlightSplit: try #require(p.highlightSplit)
            )
        case "pointCurve":
            return ToneOps.pointCurve(input, curves: [curve(from: try #require(p.points))])
        case "applyPostOps":
            var settings = EditSettings()
            settings.contrast = try #require(p.contrast)
            settings.whites = try #require(p.whites)
            settings.blacks = try #require(p.blacks)
            settings.parametricShadows = try #require(p.parametricShadows)
            settings.parametricDarks = try #require(p.parametricDarks)
            settings.parametricLights = try #require(p.parametricLights)
            settings.parametricHighlights = try #require(p.parametricHighlights)
            settings.parametricShadowSplit = try #require(p.parametricShadowSplit)
            settings.parametricMidtoneSplit = try #require(p.parametricMidtoneSplit)
            settings.parametricHighlightSplit = try #require(p.parametricHighlightSplit)
            settings.toneCurves = [curve(from: try #require(p.points))]
            return ToneOps.applyPostOps(input, settings: settings)
        default:
            Issue.record("Unknown fixture op: \(testCase.op)")
            return input
        }
    }

    @Test func toneOpsMatchesPythonReferenceFixture() throws {
        let fixture = try loadFixture()
        let inputs = fixture.inputs.map { SIMD3($0[0], $0[1], $0[2]) }
        #expect(inputs.count == 64)

        for testCase in fixture.cases {
            #expect(testCase.outputs.count == inputs.count, "\(testCase.name) output count")
            for (index, input) in inputs.enumerated() {
                let expected = testCase.outputs[index]
                let output = try actual(testCase, input: input)
                for (component, (got, want)) in zip([output.x, output.y, output.z], expected).enumerated() {
                    let tolerance = max(1e-4 * abs(want), 1e-7)
                    #expect(
                        abs(got - want) <= tolerance,
                        "\(testCase.name)[\(index)].\(component): \(got) vs \(want)"
                    )
                }
            }
        }
    }

    // MARK: - Phase2 C4: ToneOps.dehaze

    private struct DehazeFixture: Decodable {
        let input: [[Double]]
        let dehazeCases: [DehazeCase]
    }

    private struct DehazeCase: Decodable {
        let name: String
        let amount: Double
        let output: [[Double]]
    }

    /// `ToneOps.dehaze` against `.photobench/phase2/detail/detail_model.py`'s
    /// `apply_dehaze`, sharing `Tests/Fixtures/phase2/detail-ops.json` with
    /// `SpatialToneOpsTests` (generated by `.photobench/phase2/detail/
    /// make_fixture.py`) -- pointwise, so unlike Texture/Clarity there is no
    /// `scalePx` to vary.
    @Test func dehazeMatchesPythonReferenceFixture() throws {
        let url = projectRoot.appendingPathComponent("Tests/Fixtures/phase2/detail-ops.json")
        let fixture = try JSONDecoder().decode(DehazeFixture.self, from: Data(contentsOf: url))
        let rgb = fixture.input.map { SIMD3($0[0], $0[1], $0[2]) }
        var worst = 0.0
        for testCase in fixture.dehazeCases {
            for (index, expectedArray) in testCase.output.enumerated() {
                let expected = SIMD3(expectedArray[0], expectedArray[1], expectedArray[2])
                let actual = ToneOps.dehaze(rgb[index], amount: testCase.amount)
                for component in 0..<3 {
                    let absoluteDifference = abs(actual[component] - expected[component])
                    guard absoluteDifference > 1e-6 else { continue }
                    let relativeError = absoluteDifference / max(abs(expected[component]), 1e-6)
                    worst = max(worst, relativeError)
                    #expect(
                        relativeError <= 1e-4,
                        "\(testCase.name) pixel \(index) channel \(component): actual=\(actual[component]) expected=\(expected[component])"
                    )
                }
            }
        }
        print("ToneOpsTests: dehaze worst relative error = \(worst)")
    }

    @Test func dehazeIsIdentityAtZeroAndFiniteAtExtremes() {
        let samples: [SIMD3<Double>] = [
            SIMD3(0.001, 0.02, 0.5), SIMD3(0.8, 0.4, 0.2), SIMD3(1.5, 0.9, 1.9)
        ]
        for sample in samples {
            #expect(ToneOps.dehaze(sample, amount: 0) == sample)
            for amount in [-100.0, -40.0, 40.0, 100.0] {
                let output = ToneOps.dehaze(sample, amount: amount)
                #expect(output.x.isFinite && output.y.isFinite && output.z.isFinite)
                #expect(output.x >= 0 && output.y >= 0 && output.z >= 0)
            }
        }
    }

    // MARK: - ColorSpec.xy(fromTemperature:tint:)

    @Test func xyFromTemperatureRoundTripsAndMatchesKnownIlluminantsApproximately() {
        // Round-trips through the already-validated inverse (LegacySetXY /
        // `xyToTemperature`) to within the table's own linear-interpolation
        // noise.
        for temperature in [2_000.0, 4_000.0, 5_000.0, 6_500.0, 7_500.0, 20_000.0] {
            let xy = DNGTemperature.xy(fromTemperature: temperature, tint: 0)
            let roundTripped = DNGTemperature.xyToTemperature(xy)
            #expect(abs(roundTripped - temperature) < 0.05, "roundtrip \(temperature)K -> \(roundTripped)K")
        }

        // T < 2000 clamps to 2000 (docs/PHASE2_DEVELOP_PIPELINE.md's explicit
        // instruction; the legacy table's own domain does not extend lower).
        #expect(
            DNGTemperature.xy(fromTemperature: 500, tint: 0)
                == DNGTemperature.xy(fromTemperature: 2_000, tint: 0)
        )

        // Near (not exactly -- the Robertson isotherm locus this table
        // implements sits a few tint-units off the named illuminants'
        // official xy, which is the whole reason a separate Tint slider
        // exists) the D50/D65 chromaticities at 5000K/6500K, tint 0.
        let near5000 = DNGTemperature.xy(fromTemperature: 5_000, tint: 0)
        #expect(abs(near5000.x - 0.3457) < 0.01, "5000K x")
        #expect(abs(near5000.y - 0.3585) < 0.01, "5000K y")
        let near6500 = DNGTemperature.xy(fromTemperature: 6_500, tint: 0)
        #expect(abs(near6500.x - 0.3127) < 0.01, "6500K x")
        #expect(abs(near6500.y - 0.3290) < 0.01, "6500K y")

        // Tint's sign moves v (the y-numerator in the uv->xy conversion)
        // monotonically; magnitude grows with |tint|.
        let base = DNGTemperature.xy(fromTemperature: 6_500, tint: 0)
        let warm = DNGTemperature.xy(fromTemperature: 6_500, tint: 30)
        let cool = DNGTemperature.xy(fromTemperature: 6_500, tint: -30)
        #expect(warm.y > base.y)
        #expect(cool.y < base.y)
        let warmer = DNGTemperature.xy(fromTemperature: 6_500, tint: 60)
        #expect(warmer.y > warm.y)
    }

    // MARK: - Cube P vs CPU

    /// 64 samples spread over [0,1]^3 via golden-ratio-offset channels,
    /// avoiding exact `CIColorCube` grid-node alignment (a node-exact sample
    /// would not exercise the cube's own trilinear interpolation error) --
    /// same technique as `AdobeBaseRendererTests.sampleCameraRGBs`.
    private static func spreadSamples(count: Int) -> [SIMD3<Double>] {
        let goldenConjugate = 0.618_034
        return (0..<count).map { index in
            let t = Double(index) / Double(max(count - 1, 1))
            func channel(_ offset: Double) -> Double {
                var value = (t + offset).truncatingRemainder(dividingBy: 1.0)
                if value < 0 { value += 1 }
                return 0.05 + 0.9 * value
            }
            return SIMD3(channel(0), channel(goldenConjugate), channel(2 * goldenConjugate))
        }
    }

    private static func makeImage(samples: [SIMD3<Double>], colorSpace: CGColorSpace) -> CIImage {
        var floats = [Float](repeating: 0, count: samples.count * 4)
        for (index, sample) in samples.enumerated() {
            floats[index * 4] = Float(sample.x)
            floats[index * 4 + 1] = Float(sample.y)
            floats[index * 4 + 2] = Float(sample.z)
            floats[index * 4 + 3] = 1
        }
        return CIImage(
            bitmapData: floats.withUnsafeBytes { Data($0) },
            bytesPerRow: samples.count * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: samples.count, height: 1),
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }

    private static func render(_ image: CIImage, sampleCount: Int, colorSpace: CGColorSpace) -> [Float] {
        var rendered = [Float](repeating: 0, count: sampleCount * 4)
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: true
        ])
        context.render(
            image, toBitmap: &rendered, rowBytes: sampleCount * 4 * MemoryLayout<Float>.size,
            bounds: image.extent, format: .RGBAf, colorSpace: colorSpace
        )
        return rendered
    }

    /// Euclidean OKLab distance, this project's established ΔE00 stand-in
    /// (`AdobeBaseRendererTests.deltaE`'s own doc comment explains why).
    /// Inputs are linear ProPhoto (cube P's own domain); both are converted
    /// to linear sRGB via `DNGColorSpace.proPhotoToSRGBLinear` first since
    /// `OKLabColor.from(linearSRGB:)` assumes that space.
    private static func deltaE(_ proPhotoA: SIMD3<Double>, _ proPhotoB: SIMD3<Double>) -> Double {
        let a = OKLabColor.from(linearSRGB: DNGColorSpace.proPhotoToSRGBLinear * proPhotoA)
        let b = OKLabColor.from(linearSRGB: DNGColorSpace.proPhotoToSRGBLinear * proPhotoB)
        return (
            (a.lightness - b.lightness) * (a.lightness - b.lightness)
                + (a.a - b.a) * (a.a - b.a)
                + (a.b - b.b) * (a.b - b.b)
        ).squareRoot()
    }

    @Test func postOpsCubeMatchesCPUReferenceWithinDeltaE() throws {
        var settings = EditSettings()
        settings.contrast = 50
        settings.whites = 50
        settings.blacks = -50
        settings.parametricShadows = 60
        settings.parametricHighlights = -60
        settings.toneCurves = [
            ToneCurve(channel: .rgb, points: [
                CurvePoint(x: 0, y: 0), CurvePoint(x: 64.0 / 255, y: 40.0 / 255),
                CurvePoint(x: 128.0 / 255, y: 128.0 / 255), CurvePoint(x: 192.0 / 255, y: 215.0 / 255),
                CurvePoint(x: 1, y: 1)
            ])
        ]
        #expect(ToneOps.needsPostOps(settings))

        let samples = Self.spreadSamples(count: 64)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let inputImage = Self.makeImage(samples: samples, colorSpace: colorSpace)
        let cubeData = AdobeBaseRenderer.postOpsCube(exposureNonRaw: 0, settings: settings)
        let outputImage = AdobeBaseRenderer.applyCube(cubeData, to: inputImage)
        let rendered = Self.render(outputImage, sampleCount: samples.count, colorSpace: colorSpace)

        var maxDeltaE = 0.0
        var maxTag = ""
        for (index, sample) in samples.enumerated() {
            let expected = ToneOps.applyPostOps(sample, settings: settings)
            let actual = SIMD3(
                Double(rendered[index * 4]), Double(rendered[index * 4 + 1]), Double(rendered[index * 4 + 2])
            )
            let delta = Self.deltaE(expected, actual)
            if delta > maxDeltaE {
                maxDeltaE = delta
                maxTag = "sample[\(index)]=\(sample) cpu=\(expected) gpu=\(actual)"
            }
        }
        #expect(maxDeltaE <= 0.15, "cube P / CPU ΔE exceeded 0.15: \(maxTag) (ΔE=\(maxDeltaE))")
    }
}

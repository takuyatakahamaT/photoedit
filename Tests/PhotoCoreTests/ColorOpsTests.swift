import CoreImage
import Foundation
import Testing
@testable import PhotoCore

/// Phase2 C2 (`docs/PHASE2_C2_C3.md`) gates for `ColorOps`:
///
///  - `colorOpsMatchesPythonReferenceFixture`: every `ColorOps` function
///    against `Tests/Fixtures/phase2/color-ops.json`, generated from
///    `.photobench/phase2/color/color_model.py` and `.photobench/phase2/hsl/
///    hsl_model.py` (the measured references), at relative 1e-4 (floored at
///    absolute 1e-6 for near-zero expected values, matching the C2 gate's
///    stated tolerance).
///  - `postColorCubeMatchesCPUReferenceWithinDeltaE`: the GPU `CIColorCube`
///    baked by `AdobeBaseRenderer.postColorCube` against the CPU
///    `ColorOps.applyColorOps` reference, the same ~0.15 ΔE (OKLab-distance)
///    budget `ToneOpsTests.postOpsCubeMatchesCPUReferenceWithinDeltaE` uses
///    for cube P.
struct ColorOpsTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorOpsTests.swift -> PhotoCoreTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> repo root
    }

    // MARK: - Fixture model

    private struct Fixture: Decodable {
        let inputs: [[Double]]
        let cases: [Case]
    }

    private struct HSLEntry: Decodable {
        let band: String
        let hue: Double
        let saturation: Double
        let luminance: Double
    }

    private struct Case: Decodable {
        let name: String
        let op: String
        let params: Params
        let outputs: [[Double]]

        struct Params: Decodable {
            let amount: Double?
            let hslBand: String?
            let hslHue: Double?
            let hslSaturation: Double?
            let hslLuminance: Double?
            let hslAdjustments: [HSLEntry]?
            let redHue: Double?
            let redSaturation: Double?
            let greenHue: Double?
            let greenSaturation: Double?
            let blueHue: Double?
            let blueSaturation: Double?
            let shadowHue: Double?
            let shadowSat: Double?
            let shadowLum: Double?
            let midtoneHue: Double?
            let midtoneSat: Double?
            let midtoneLum: Double?
            let highlightHue: Double?
            let highlightSat: Double?
            let highlightLum: Double?
            let globalHue: Double?
            let globalSat: Double?
            let globalLum: Double?
            let blending: Double?
            let balance: Double?
            let vibrance: Double?
            let saturation: Double?
        }
    }

    private func loadFixture() throws -> Fixture {
        let url = projectRoot.appendingPathComponent("Tests/Fixtures/phase2/color-ops.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Fixture band names ("Orange", "Blue", ...) are Lightroom's own
    /// capitalization; `HSLBand`'s raw values are lowercase.
    private func hslBand(named name: String) throws -> HSLBand {
        try #require(HSLBand(rawValue: name.lowercased()), "Unknown HSL band in fixture: \(name)")
    }

    private func colorGradingSettings(from p: Case.Params) throws -> ColorGradingSettings {
        ColorGradingSettings(
            shadow: ColorGradeBand(
                hue: try #require(p.shadowHue), saturation: try #require(p.shadowSat),
                luminance: try #require(p.shadowLum)
            ),
            midtone: ColorGradeBand(
                hue: try #require(p.midtoneHue), saturation: try #require(p.midtoneSat),
                luminance: try #require(p.midtoneLum)
            ),
            highlight: ColorGradeBand(
                hue: try #require(p.highlightHue), saturation: try #require(p.highlightSat),
                luminance: try #require(p.highlightLum)
            ),
            global: ColorGradeBand(
                hue: try #require(p.globalHue), saturation: try #require(p.globalSat),
                luminance: try #require(p.globalLum)
            ),
            blending: try #require(p.blending), balance: try #require(p.balance)
        )
    }

    private func actual(_ testCase: Case, input: SIMD3<Double>) throws -> SIMD3<Double> {
        let p = testCase.params
        switch testCase.op {
        case "saturation":
            return ColorOps.saturation(input, amount: try #require(p.amount))
        case "vibrance":
            return ColorOps.vibrance(input, amount: try #require(p.amount))
        case "hsl":
            let band = try hslBand(named: try #require(p.hslBand))
            let adjustment = HSLAdjustment(
                hue: try #require(p.hslHue),
                saturation: try #require(p.hslSaturation),
                luminance: try #require(p.hslLuminance)
            )
            return ColorOps.hsl(input, adjustments: [band: adjustment])
        case "calibration":
            let settings = CalibrationSettings(
                redHue: try #require(p.redHue), redSaturation: try #require(p.redSaturation),
                greenHue: try #require(p.greenHue), greenSaturation: try #require(p.greenSaturation),
                blueHue: try #require(p.blueHue), blueSaturation: try #require(p.blueSaturation)
            )
            return ColorOps.calibration(input, settings: settings)
        case "colorGrading":
            return ColorOps.colorGrading(input, settings: try colorGradingSettings(from: p))
        case "applyColorOps":
            var settings = EditSettings()
            settings.vibrance = try #require(p.vibrance)
            settings.saturation = try #require(p.saturation)
            for entry in try #require(p.hslAdjustments) {
                settings.hsl[try hslBand(named: entry.band)] = HSLAdjustment(
                    hue: entry.hue, saturation: entry.saturation, luminance: entry.luminance
                )
            }
            settings.colorGrading = try colorGradingSettings(from: p)
            return ColorOps.applyColorOps(input, settings: settings)
        default:
            Issue.record("Unknown fixture op: \(testCase.op)")
            return input
        }
    }

    @Test func colorOpsMatchesPythonReferenceFixture() throws {
        let fixture = try loadFixture()
        let inputs = fixture.inputs.map { SIMD3($0[0], $0[1], $0[2]) }
        #expect(inputs.count == 64)

        for testCase in fixture.cases {
            #expect(testCase.outputs.count == inputs.count, "\(testCase.name) output count")
            for (index, input) in inputs.enumerated() {
                let expected = testCase.outputs[index]
                let output = try actual(testCase, input: input)
                for (component, (got, want)) in zip([output.x, output.y, output.z], expected).enumerated() {
                    let tolerance = max(1e-4 * abs(want), 1e-6)
                    #expect(
                        abs(got - want) <= tolerance,
                        "\(testCase.name)[\(index)].\(component): \(got) vs \(want)"
                    )
                }
            }
        }
    }

    // MARK: - Cube Q vs CPU

    /// Same golden-ratio-offset spread as `ToneOpsTests.spreadSamples` /
    /// `AdobeBaseRendererTests.sampleCameraRGBs`, redefined here per this
    /// codebase's existing per-test-file convention (see those files).
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

    /// Euclidean OKLab distance, this project's established ΔE00 stand-in.
    private static func deltaE(_ proPhotoA: SIMD3<Double>, _ proPhotoB: SIMD3<Double>) -> Double {
        let a = OKLabColor.from(linearSRGB: DNGColorSpace.proPhotoToSRGBLinear * proPhotoA)
        let b = OKLabColor.from(linearSRGB: DNGColorSpace.proPhotoToSRGBLinear * proPhotoB)
        return (
            (a.lightness - b.lightness) * (a.lightness - b.lightness)
                + (a.a - b.a) * (a.a - b.a)
                + (a.b - b.b) * (a.b - b.b)
        ).squareRoot()
    }

    @Test func postColorCubeMatchesCPUReferenceWithinDeltaE() throws {
        var settings = EditSettings()
        settings.vibrance = 40
        settings.saturation = -30
        settings.hsl[.orange] = HSLAdjustment(hue: 20, saturation: 50, luminance: -10)
        settings.hsl[.blue] = HSLAdjustment(hue: -15, saturation: 30, luminance: 25)
        settings.colorGrading = ColorGradingSettings(
            shadow: ColorGradeBand(hue: 220, saturation: 25, luminance: 10),
            highlight: ColorGradeBand(hue: 50, saturation: 20, luminance: -5),
            blending: 80,
            balance: -20
        )
        #expect(ColorOps.needsColorOps(settings))

        let samples = Self.spreadSamples(count: 64)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let inputImage = Self.makeImage(samples: samples, colorSpace: colorSpace)
        let cubeData = AdobeBaseRenderer.postColorCube(settings: settings)
        let outputImage = AdobeBaseRenderer.applyCube(cubeData, to: inputImage)
        let rendered = Self.render(outputImage, sampleCount: samples.count, colorSpace: colorSpace)

        var maxDeltaE = 0.0
        var maxTag = ""
        for (index, sample) in samples.enumerated() {
            let expected = ColorOps.applyColorOps(sample, settings: settings)
            let actual = SIMD3(
                Double(rendered[index * 4]), Double(rendered[index * 4 + 1]), Double(rendered[index * 4 + 2])
            )
            let delta = Self.deltaE(expected, actual)
            if delta > maxDeltaE {
                maxDeltaE = delta
                maxTag = "sample[\(index)]=\(sample) cpu=\(expected) gpu=\(actual)"
            }
        }
        #expect(maxDeltaE <= 0.15, "cube Q / CPU ΔE exceeded 0.15: \(maxTag) (ΔE=\(maxDeltaE))")
    }
}

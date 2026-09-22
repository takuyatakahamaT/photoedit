import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import PhotoCore

struct RelativeColorAdjustmentTests {
    @Test func zeroIsAnExactBypassAndKeepsTheExistingPipelineFingerprint() throws {
        let source = neutralGrayImage()
        let output = RenderEngine().apply(settings: .neutral, to: source)

        #expect(try renderPixel(output) == renderPixel(source))
        #expect(RelativeColorAdjustment.identifier == "relative-temperature-and-tint-ci-v1")
        #expect(RenderEngine.processingIdentifier == "extended-linear-srgb-edits-resize-before-final-srgb-v1")
        #expect(!EditSettings.neutral.hasActiveColorEdits())
    }

    @Test func slidersMoveNeutralGrayTowardWarmCoolGreenAndMagenta() throws {
        let source = neutralGrayImage()
        let renderer = RenderEngine()

        let warm = try renderPixel(renderer.apply(
            settings: EditSettings(relativeTemperature: 50),
            to: source
        ))
        let cool = try renderPixel(renderer.apply(
            settings: EditSettings(relativeTemperature: -50),
            to: source
        ))
        let magenta = try renderPixel(renderer.apply(
            settings: EditSettings(relativeTint: 50),
            to: source
        ))
        let green = try renderPixel(renderer.apply(
            settings: EditSettings(relativeTint: -50),
            to: source
        ))

        #expect(warm.x > warm.z)
        #expect(cool.z > cool.x)
        #expect(magenta.x > magenta.y && magenta.z > magenta.y)
        #expect(green.y > green.x && green.y > green.z)
    }

    @Test func valuesAreFiniteClampedAndPartOfTheOutputActivityGate() throws {
        #expect(RelativeColorAdjustment.sanitizedValue(180) == 100)
        #expect(RelativeColorAdjustment.sanitizedValue(-180) == -100)
        #expect(RelativeColorAdjustment.sanitizedValue(.nan) == 0)
        #expect(RelativeColorAdjustment.sanitizedValue(.infinity) == 0)

        var settings = EditSettings(relativeTemperature: 180, relativeTint: -180)
        #expect(settings.relativeTemperature == 100)
        #expect(settings.relativeTint == -100)
        settings.relativeTemperature = .infinity
        settings.relativeTint = .nan
        #expect(settings.relativeTemperature == 0)
        #expect(settings.relativeTint == 0)
        #expect(EditSettings(relativeTemperature: 0.01).hasActiveColorEdits())
        #expect(EditSettings(relativeTint: -0.01).hasActiveColorEdits())

        let source = neutralGrayImage()
        let renderer = RenderEngine()
        let aboveRange = try renderPixel(renderer.apply(
            settings: EditSettings(relativeTemperature: 140),
            to: source
        ))
        let clamped = try renderPixel(renderer.apply(
            settings: EditSettings(relativeTemperature: 100),
            to: source
        ))
        let invalid = try renderPixel(renderer.apply(
            settings: EditSettings(relativeTint: .nan),
            to: source
        ))
        let zero = try renderPixel(source)
        #expect(aboveRange == clamped)
        #expect(invalid == zero)
    }

    @Test func legacyAndRoundTripJSONKeepRelativeValuesAndXMPWhiteBalanceSeparate() throws {
        let legacy = Data(
            #"{"exposure":0.25,"whiteBalance":{"mode":"asShot"},"toneCurves":[],"hsl":[]}"#.utf8
        )
        let oldSettings = try JSONDecoder().decode(EditSettings.self, from: legacy)
        #expect(oldSettings.relativeTemperature == 0)
        #expect(oldSettings.relativeTint == 0)

        let original = EditSettings(
            whiteBalance: WhiteBalanceSettings(mode: .custom, temperature: 5_400, tint: 4),
            relativeTemperature: 37,
            relativeTint: -24
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EditSettings.self, from: encoded)
        #expect(decoded == original)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let night = try XMPPresetParser.parse(
            url: root.appendingPathComponent("niho-preset night.xmp")
        )
        let applied = night.applying(to: original)
        #expect(applied.relativeTemperature == original.relativeTemperature)
        #expect(applied.relativeTint == original.relativeTint)
        #expect(applied.whiteBalance.temperature == 6_214)
        #expect(applied.whiteBalance.tint == 13)
    }

    private func neutralGrayImage() -> CIImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let pixels = [SIMD4<Float>(0.18, 0.18, 0.18, 1)]
        return CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) },
            bytesPerRow: MemoryLayout<SIMD4<Float>>.stride,
            size: CGSize(width: 1, height: 1),
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }

    private func renderPixel(_ image: CIImage) throws -> SIMD4<Float> {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var rendered = [SIMD4<Float>](repeating: .zero, count: 1)
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: true
        ])
        context.render(
            image,
            toBitmap: &rendered,
            rowBytes: MemoryLayout<SIMD4<Float>>.stride,
            bounds: image.extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )
        return try #require(rendered.first)
    }
}

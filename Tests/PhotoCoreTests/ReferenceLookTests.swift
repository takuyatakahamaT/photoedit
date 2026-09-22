import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import PhotoCore

struct ReferenceLookTests {
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let referenceLooks: [ReferenceLook] = [
        .bluesky2September2026,
        .bluesky2September2026V3
    ]

    private struct FitProfile: Decodable {
        let knots: [Double]
        let coefficients: [[Double]]
    }

    private struct FitProfiles: Decodable {
        let raw: FitProfile
        let jpeg: FitProfile
    }

    @Test func editSettingsDecodeLegacyAndRoundTripReferenceLook() throws {
        let legacy = try JSONDecoder().decode(EditSettings.self, from: Data("{}".utf8))
        #expect(legacy.referenceLook == nil)

        let original = EditSettings(
            relativeTemperature: 12,
            relativeTint: -5,
            referenceLook: .bluesky2September2026
        )
        #expect(original.hasActiveColorEdits())
        let encoded = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["referenceLook"] as? String == ReferenceLook.bluesky2September2026.rawValue)
        #expect(try JSONDecoder().decode(EditSettings.self, from: encoded) == original)

        let current = EditSettings(referenceLook: .currentBluesky2)
        let currentEncoded = try JSONEncoder().encode(current)
        let currentObject = try #require(JSONSerialization.jsonObject(with: currentEncoded) as? [String: Any])
        #expect(currentObject["referenceLook"] as? String == "niho-bluesky2-reference-20260922-v3")
        #expect(try JSONDecoder().decode(EditSettings.self, from: currentEncoded) == current)

        let unknown = Data(#"{"referenceLook":"unrecognized-look-v99"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditSettings.self, from: unknown)
        }
    }

    @Test func absentReferenceLookIsANoOpEvenWithSupportedDecodeInfo() throws {
        let source = makeImage(colors: [(SIMD3(0.3, 0.2, 0.1), 1)])
        let output = RenderEngine().apply(
            settings: .neutral,
            to: source,
            decodeInfo: rasterInfo()
        )

        #expect(try renderPixels(output) == renderPixels(source))
        #expect(!EditSettings.neutral.hasActiveColorEdits())
    }

    @Test func referenceLookWithoutDecodeInfoKeepsTheLegacyApplyPath() throws {
        let source = makeImage(colors: [(SIMD3(0.3, 0.2, 0.1), 1)])
        let output = RenderEngine().apply(
            settings: EditSettings(referenceLook: .bluesky2September2026),
            to: source
        )

        #expect(try renderPixels(output) == renderPixels(source))
    }

    @Test func supportSelectionNormalizesCameraNamesAndSeparatesRasterFromRaw() {
        #expect(BlueskyReferenceLook.identifier == "niho-bluesky2-reference-20260922-v3")
        #expect(ReferenceLook.bluesky2September2026.rawValue == "niho-bluesky2-reference-20260922-v2")
        #expect(ReferenceLook.currentBluesky2 == .bluesky2September2026V3)
        #expect(BlueskyReferenceLook.supports(info: rasterInfo()))
        #expect(BlueskyReferenceLook.supports(info: rawInfo(make: "  pAnAsOnIc ", model: "dc s5")))
        #expect(!BlueskyReferenceLook.supports(info: rawInfo(make: "Canon", model: "DC-S5")))
        #expect(!BlueskyReferenceLook.supports(info: rawInfo(make: "Panasonic", model: "DC-S6")))

        let raw = SIMD3(0.8, 0.35, 0.12)
        #expect(BlueskyReferenceLook.map(linearRGB: raw, isRAW: true)
            != BlueskyReferenceLook.map(linearRGB: raw, isRAW: false))
    }

    @Test func embeddedProfilesMatchTheV2FitJSONExactly() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let profileURL = repoRoot
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("bluesky2-reference-v2.json")
        let fitted = try JSONDecoder().decode(FitProfiles.self, from: Data(contentsOf: profileURL))

        for (isRAW, expected) in [(true, fitted.raw), (false, fitted.jpeg)] {
            let embedded = BlueskyReferenceLook.profile(isRAW: isRAW)
            #expect(embedded.knots == expected.knots)
            #expect(embedded.coefficients.map { [$0.x, $0.y, $0.z] } == expected.coefficients)
        }
    }

    @Test func explicitVersionTwoRetainsItsSavedCPUOutput() {
        let sample = SIMD3(0.9, 0.38, 0.08)
        let raw = BlueskyReferenceLook.map(
            linearRGB: sample,
            isRAW: true,
            look: .bluesky2September2026
        )
        let jpeg = BlueskyReferenceLook.map(
            linearRGB: sample,
            isRAW: false,
            look: .bluesky2September2026
        )

        #expect(maxComponentDifference(raw, SIMD3(0.9391823585902196, 0.5319225160971678, 0.16834739986983666)) < 1e-9)
        #expect(maxComponentDifference(jpeg, SIMD3(0.8979240842366504, 0.5960690326385901, 0.20250736765195465)) < 1e-9)
    }

    @Test func versionThreeAddsTheExistingOrangeMixerAfterVersionTwo() {
        let samples = [
            SIMD3(0.9, 0.38, 0.08),
            SIMD3(0.62, 0.27, 0.09),
            SIMD3(1.4, 0.72, 0.21)
        ]
        let orangeAdjustment: [HSLBand: HSLAdjustment] = [
            .orange: HSLAdjustment(hue: 0, saturation: 10, luminance: -12)
        ]
        var orangeStageChangesAtLeastOneSample = false

        for isRAW in [false, true] {
            for sample in samples {
                let versionTwo = BlueskyReferenceLook.map(
                    linearRGB: sample,
                    isRAW: isRAW,
                    look: .bluesky2September2026
                )
                let expectedVersionThree = PerceptualColorMixer.apply(
                    to: versionTwo,
                    adjustments: orangeAdjustment
                )
                let actualVersionThree = BlueskyReferenceLook.map(
                    linearRGB: sample,
                    isRAW: isRAW,
                    look: .currentBluesky2
                )

                #expect(maxComponentDifference(actualVersionThree, expectedVersionThree) < 1e-12)
                orangeStageChangesAtLeastOneSample = orangeStageChangesAtLeastOneSample
                    || maxComponentDifference(actualVersionThree, versionTwo) > 1e-5
            }
        }
        #expect(orangeStageChangesAtLeastOneSample)
    }

    @Test func unsupportedRawCameraReturnsTheOriginalImage() throws {
        let source = makeImage(colors: [(SIMD3(0.23, 0.41, 0.62), 0.65)])
        for look in referenceLooks {
            let output = BlueskyReferenceLook.apply(
                to: source,
                info: rawInfo(make: "Canon", model: "DC-S5"),
                look: look
            )

            #expect(try renderPixels(output) == renderPixels(source))
        }
    }

    @Test func rawAndJpegColorKernelsMatchTheCPUMapForFloatPixelsAndAlpha() throws {
        let colors: [(SIMD3<Double>, Double)] = [
            (SIMD3(0.18, 0.18, 0.18), 1),
            (SIMD3(0.025, 0.12, 0.55), 1),
            (SIMD3(0.9, 0.38, 0.08), 0.72),
            (SIMD3(1.4, 0.72, 0.21), 0.4),
            (SIMD3(1, 0, 0), 1),
            (SIMD3(0, 1, 0), 0.8),
            (SIMD3(0, 0, 1), 1),
            (SIMD3(1, 0, 1), 0.65),
            (linearRGBWithLuminance(0.4, radius: 0.65 - 0.0001), 1),
            (linearRGBWithLuminance(0.4, radius: 0.65), 1),
            (linearRGBWithLuminance(0.4, radius: 0.65 + 0.0001), 1),
            (linearRGBWithLuminance(0.4, radius: 1.1 - 0.0001), 1),
            (linearRGBWithLuminance(0.4, radius: 1.1), 1),
            (linearRGBWithLuminance(0.4, radius: 1.1 + 0.0001), 1),
            (SIMD3(16, 8, 3), 0.2),
            (SIMD3(0, 0, 0), 0)
        ]
        let source = makeImage(colors: colors)

        for look in referenceLooks {
            for isRAW in [false, true] {
                let info = isRAW ? rawInfo(make: "Panasonic", model: "DC-S5") : rasterInfo()
                let output = BlueskyReferenceLook.apply(to: source, info: info, look: look)
                let rendered = try renderPixels(output)
                #expect(rendered.count == colors.count)
                #expect(rendered.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })

                for index in colors.indices {
                    let (rgb, alpha) = colors[index]
                    let expected = BlueskyReferenceLook.map(linearRGB: rgb, isRAW: isRAW, look: look)
                    #expect(abs(Double(rendered[index].x) - expected.x * alpha) < 0.004)
                    #expect(abs(Double(rendered[index].y) - expected.y * alpha) < 0.004)
                    #expect(abs(Double(rendered[index].z) - expected.z * alpha) < 0.004)
                    #expect(abs(Double(rendered[index].w) - alpha) < 0.000_01)
                }
            }
        }
    }

    @Test func versionThreeCIStageMatchesTheExistingMixerKernel() throws {
        let source = makeImage(colors: [(SIMD3(0.9, 0.38, 0.08), 0.45)])
        let adjustments: [HSLBand: HSLAdjustment] = [
            .orange: HSLAdjustment(hue: 0, saturation: 10, luminance: -12)
        ]
        let mixer = try #require(PerceptualColorMixer.makeKernel(adjustments: adjustments))

        for isRAW in [false, true] {
            let info = isRAW ? rawInfo(make: "Panasonic", model: "DC-S5") : rasterInfo()
            let versionTwo = BlueskyReferenceLook.apply(
                to: source,
                info: info,
                look: .bluesky2September2026
            )
            let expected = try #require(mixer.apply(extent: versionTwo.extent, arguments: [versionTwo]))
            let actual = BlueskyReferenceLook.apply(
                to: source,
                info: info,
                look: .bluesky2September2026V3
            )
            let expectedPixels = try renderPixels(expected)
            let actualPixels = try renderPixels(actual)
            #expect(expectedPixels.count == actualPixels.count)
            for (expectedPixel, actualPixel) in zip(expectedPixels, actualPixels) {
                #expect(abs(expectedPixel.x - actualPixel.x) < 0.000_01)
                #expect(abs(expectedPixel.y - actualPixel.y) < 0.000_01)
                #expect(abs(expectedPixel.z - actualPixel.z) < 0.000_01)
                #expect(abs(expectedPixel.w - actualPixel.w) < 0.000_01)
            }
        }
    }

    @Test func saturatedColorsKeepTheirDominantChannels() {
        let cases: [(SIMD3<Double>, [Int])] = [
            (SIMD3(1, 0, 0), [0]),
            (SIMD3(0, 1, 0), [1]),
            (SIMD3(0, 0, 1), [2]),
            (SIMD3(1, 0, 1), [0, 2])
        ]

        for look in referenceLooks {
            for isRAW in [false, true] {
                for (source, dominantChannels) in cases {
                    let mapped = BlueskyReferenceLook.map(linearRGB: source, isRAW: isRAW, look: look)
                    let channels = [mapped.x, mapped.y, mapped.z]
                    #expect(channels[0].isFinite && channels[1].isFinite && channels[2].isFinite)
                    let nondominantChannels = channels.indices.filter { !dominantChannels.contains($0) }
                    for dominantChannel in dominantChannels {
                        for nondominantChannel in nondominantChannels {
                            #expect(channels[dominantChannel] > channels[nondominantChannel])
                        }
                    }
                }
            }
        }
    }

    @Test func chromaGuardIsContinuousAtBothRadiusBoundaries() {
        for look in referenceLooks {
            for isRAW in [false, true] {
                for boundary in [0.65, 1.1] {
                    let epsilon = 0.00001
                    let mapped = [boundary - epsilon, boundary, boundary + epsilon].map { radius in
                        BlueskyReferenceLook.map(
                            linearRGB: linearRGBWithLuminance(0.4, radius: radius),
                            isRAW: isRAW,
                            look: look
                        )
                    }

                    #expect(maxComponentDifference(mapped[0], mapped[1]) < 0.001)
                    #expect(maxComponentDifference(mapped[1], mapped[2]) < 0.001)
                }
            }
        }
    }

    @Test func grayscaleAxisStaysMonotoneAndHDRResultsStayFinite() {
        let grayValues = [-0.01, 0, 0.0001, 0.002, 0.01, 0.03, 0.1, 0.35, 0.8, 1.5, 4, 16]

        for look in referenceLooks {
            for isRAW in [false, true] {
                var previous = SIMD3<Double>(-.infinity, -.infinity, -.infinity)
                for value in grayValues {
                    let mapped = BlueskyReferenceLook.map(
                        linearRGB: SIMD3(value, value, value),
                        isRAW: isRAW,
                        look: look
                    )
                    #expect(mapped.x.isFinite && mapped.y.isFinite && mapped.z.isFinite)
                    #expect(mapped.x >= previous.x - 1e-9)
                    #expect(mapped.y >= previous.y - 1e-9)
                    #expect(mapped.z >= previous.z - 1e-9)
                    previous = mapped
                }

                let hdr = BlueskyReferenceLook.map(
                    linearRGB: SIMD3(12, 5.5, 2.75),
                    isRAW: isRAW,
                    look: look
                )
                #expect(hdr.x.isFinite && hdr.y.isFinite && hdr.z.isFinite)
            }
        }

        let hostile = BlueskyReferenceLook.map(
            linearRGB: SIMD3(.nan, .infinity, -.infinity),
            isRAW: false
        )
        #expect(hostile.x.isFinite && hostile.y.isFinite && hostile.z.isFinite)
    }

    @Test func brightnessAndColorAdjustmentsRemainAvailableAfterTheReferenceLook() throws {
        let source = makeImage(colors: [(SIMD3(0.26, 0.12, 0.045), 1)])
        let info = rasterInfo()
        let renderer = RenderEngine()
        let baselineSettings = EditSettings(referenceLook: .bluesky2September2026)
        let baseline = try renderPixels(renderer.apply(
            settings: baselineSettings,
            to: source,
            decodeInfo: info
        ))[0]
        let brighter = try renderPixels(renderer.apply(
            settings: EditSettings(exposure: 0.75, referenceLook: .bluesky2September2026),
            to: source,
            decodeInfo: info
        ))[0]
        let warmer = try renderPixels(renderer.apply(
            settings: EditSettings(relativeTemperature: 35, referenceLook: .bluesky2September2026),
            to: source,
            decodeInfo: info
        ))[0]

        #expect(brighter.x > baseline.x || brighter.y > baseline.y || brighter.z > baseline.z)
        #expect(warmer != baseline)
    }

    @Test func previewAndOutputGraphsUseTheDecodedCameraBranch() throws {
        let source = makeImage(colors: [(SIMD3(0.35, 0.2, 0.09), 1)])
        let info = rawInfo(make: "Panasonic", model: "DC-S5")
        let decoded = DecodedPhoto(
            sourceURL: URL(fileURLWithPath: "/tmp/reference-look-fixture.raw"),
            image: source,
            metadata: [:],
            info: info
        )
        let renderer = RenderEngine()
        for look in referenceLooks {
            let settings = EditSettings(referenceLook: look)
            let output = renderer.applyForOutput(decoded: decoded, settings: settings)
            let graph = try renderer.makeOutputGraph(
                decoded: decoded,
                settings: settings,
                maxDimension: nil,
                downsamplingFilter: .affineTransform,
                outputTransformPlacement: .afterDownsampling
            )

            #expect(try renderPixels(output) == renderPixels(graph.image))
        }
    }

    private func rasterInfo() -> DecodeInfo {
        DecodeInfo(backend: "test-raster", width: 6, height: 1, durationMilliseconds: 0, isRAW: false)
    }

    private func rawInfo(make: String, model: String) -> DecodeInfo {
        DecodeInfo(
            backend: "test-raw",
            width: 6,
            height: 1,
            durationMilliseconds: 0,
            isRAW: true,
            cameraMake: make,
            cameraModel: model
        )
    }

    private func makeImage(colors: [(SIMD3<Double>, Double)]) -> CIImage {
        let pixels = colors.map { color, alpha in
            SIMD4<Float>(
                Float(color.x * alpha),
                Float(color.y * alpha),
                Float(color.z * alpha),
                Float(alpha)
            )
        }
        return CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) },
            bytesPerRow: MemoryLayout<SIMD4<Float>>.stride * pixels.count,
            size: CGSize(width: pixels.count, height: 1),
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }

    private func renderPixels(_ image: CIImage) throws -> [SIMD4<Float>] {
        let width = try #require(Int(exactly: image.extent.width))
        let height = try #require(Int(exactly: image.extent.height))
        var rendered = [SIMD4<Float>](repeating: .zero, count: width * height)
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: true
        ])
        context.render(
            image,
            toBitmap: &rendered,
            rowBytes: MemoryLayout<SIMD4<Float>>.stride * width,
            bounds: image.extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )
        return rendered
    }

    private func linearRGBWithLuminance(_ luminance: Double, radius: Double) -> SIMD3<Double> {
        let denominator = 0.1 + luminance
        let redChroma = radius * denominator
        let blueChroma = 0.0
        let greenChroma = -(0.2126 * redChroma + 0.0722 * blueChroma) / 0.7152
        return SIMD3(
            encodedToLinear(luminance + redChroma),
            encodedToLinear(luminance + greenChroma),
            encodedToLinear(luminance + blueChroma)
        )
    }

    private func encodedToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func maxComponentDifference(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        max(max(abs(lhs.x - rhs.x), abs(lhs.y - rhs.y)), abs(lhs.z - rhs.z))
    }
}

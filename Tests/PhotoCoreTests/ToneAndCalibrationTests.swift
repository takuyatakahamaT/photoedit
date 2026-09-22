import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing
@testable import PhotoCore

struct ToneAndCalibrationTests {
    @Test func selectsMeasuredRAWCalibrationOnlyForPanasonicDCS5() {
        let measured = RAWCalibrationProfile.matching(make: "Panasonic", model: "DC-S5")
        let corporation = RAWCalibrationProfile.matching(make: "Panasonic Corporation", model: "DC-S5")
        let prefixed = RAWCalibrationProfile.matching(make: "Panasonic", model: "Panasonic DC-S5")
        let sony = RAWCalibrationProfile.matching(make: "SONY", model: "ILCE-7M2")
        let unknown = RAWCalibrationProfile.matching(make: nil, model: nil)

        #expect(measured == .panasonicDCS5Lightroom93)
        #expect(corporation == .panasonicDCS5Lightroom93)
        #expect(prefixed == .panasonicDCS5Lightroom93)
        #expect(sony == .generic)
        #expect(unknown == .generic)
    }

    @Test func analyticToneIsIdentityAtNeutralSettings() {
        for luminance in [0.0, 0.0001, 0.01, 0.18, 0.5, 1, 4] {
            let output = BasicToneModel.outputLuminance(luminance, settings: .neutral)
            #expect(output == luminance)
        }
    }

    @Test func analyticToneKeepsExtremeControlsFiniteAndMonotonicWithoutHiddenScaling() {
        let cases = [
            EditSettings(contrast: -100),
            EditSettings(contrast: 100),
            EditSettings(highlights: -100),
            EditSettings(highlights: 100),
            EditSettings(shadows: -100),
            EditSettings(shadows: 100),
            EditSettings(whites: -100),
            EditSettings(whites: 100),
            EditSettings(blacks: -100),
            EditSettings(blacks: 100),
            EditSettings(
                contrast: -100,
                highlights: -100,
                shadows: 100,
                whites: -100,
                blacks: 100
            )
        ]

        for settings in cases {
            var previous = -Double.infinity
            for index in 0...16_384 {
                let luminance = Double(index) * 4 / 16_384
                let output = BasicToneModel.outputLuminance(luminance, settings: settings)
                #expect(output.isFinite)
                #expect(output + 1e-12 >= previous)
                previous = output
            }
        }
    }

    @Test func coreImageToneKernelMatchesCPUAndRemainsMonotonic() throws {
        // Phase2 C1 moved Contrast/Whites/Blacks to `ToneOps`; `BasicToneModel`
        // (and its kernel) now only reads Highlights/Shadows.
        let settings = EditSettings(
            highlights: -88,
            shadows: 37
        )
        let sampleCount = 4_097
        var input = [Float](repeating: 0, count: sampleCount * 4)
        for index in 0..<sampleCount {
            let luminance = Float(index) * 4 / Float(sampleCount - 1)
            input[index * 4] = luminance
            input[index * 4 + 1] = luminance
            input[index * 4 + 2] = luminance
            input[index * 4 + 3] = 1
        }

        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let inputData = input.withUnsafeBytes { Data($0) }
        let image = CIImage(
            bitmapData: inputData,
            bytesPerRow: sampleCount * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: sampleCount, height: 1),
            format: .RGBAf,
            colorSpace: colorSpace
        )
        let output = try #require(BasicToneModel.kernel.apply(extent: image.extent, arguments: [
            image,
            Float(settings.highlights),
            Float(settings.shadows)
        ]))
        let softwareContext = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: true
        ])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let metalContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])

        func render(using context: CIContext) -> [Float] {
            var rendered = [Float](repeating: 0, count: input.count)
            context.render(
                output,
                toBitmap: &rendered,
                rowBytes: sampleCount * 4 * MemoryLayout<Float>.size,
                bounds: image.extent,
                format: .RGBAf,
                colorSpace: colorSpace
            )
            return rendered
        }

        let softwareRendered = render(using: softwareContext)
        let metalRendered = render(using: metalContext)

        var previous = -Float.infinity
        for index in 0..<sampleCount {
            let inputLuminance = Double(input[index * 4])
            let software = softwareRendered[index * 4]
            let actual = metalRendered[index * 4]
            let expected = Float(BasicToneModel.outputLuminance(inputLuminance, settings: settings))
            #expect(actual.isFinite)
            #expect(abs(actual - expected) < 0.000_02)
            #expect(abs(software - expected) < 0.000_02)
            #expect(abs(actual - software) < 0.000_02)
            #expect(actual + 0.000_001 >= previous)
            previous = actual
        }
    }

    @Test func colorMixerLeavesNeutralRampNeutral() throws {
        let sampleCount = 257
        var input = [Float](repeating: 0, count: sampleCount * 4)
        for index in 0..<sampleCount {
            let value = Float(index) / Float(sampleCount - 1)
            input[index * 4] = value
            input[index * 4 + 1] = value
            input[index * 4 + 2] = value
            input[index * 4 + 3] = 1
        }
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = CIImage(
            bitmapData: input.withUnsafeBytes { Data($0) },
            bytesPerRow: sampleCount * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: sampleCount, height: 1),
            format: .RGBAf,
            colorSpace: colorSpace
        )
        var hsl: [HSLBand: HSLAdjustment] = [:]
        for band in HSLBand.allCases {
            hsl[band] = HSLAdjustment(hue: 100, saturation: 100, luminance: 100)
        }
        let settings = EditSettings(hsl: hsl)

        // CPU reference (`ColorOps.applyColorOps`, no cube) first: phase2 C2's
        // measured model keeps the achromatic axis invariant not by a
        // designed-in protection (unlike the deleted `PerceptualColorMixer`'s
        // explicit OKLCh chroma-gate) but because it falls out of the math --
        // `ColorOps.hsl`'s HSV saturation/luminance deltas are exactly
        // proportional to the input's own HSV `S`, which is exactly 0 for
        // R==G==B -- matching `hsl_model.py`'s own measured finding that the
        // achromatic axis is invariant to noise floor across all 48 variants.
        for index in 0..<sampleCount {
            let value = Double(index) / Double(sampleCount - 1)
            let cpuOutput = ColorOps.applyColorOps(SIMD3(repeating: value), settings: settings)
            #expect(maximumAbsoluteDifference(cpuOutput, SIMD3(repeating: value)) < 1e-12)
        }

        let output = RenderEngine().apply(
            settings: settings,
            to: image
        )
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
        var rendered = [Float](repeating: 0, count: input.count)
        context.render(
            output,
            toBitmap: &rendered,
            rowBytes: sampleCount * 4 * MemoryLayout<Float>.size,
            bounds: image.extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )

        var maximumChannelDelta: Float = 0
        for index in 0..<sampleCount {
            let red = rendered[index * 4]
            let green = rendered[index * 4 + 1]
            let blue = rendered[index * 4 + 2]
            maximumChannelDelta = max(
                maximumChannelDelta,
                abs(red - green),
                abs(green - blue),
                abs(red - blue)
            )
        }
        // GPU cube Q: a 64-point `CIColorCube` cannot represent the CPU
        // function's hue-discontinuity-at-zero-chroma exactly, so trilinear
        // interpolation leaks a little of an adjacent, non-neutral grid
        // node's full-strength adjustment into an exactly-neutral query.
        // Measured worst case with every band maxed simultaneously (the most
        // adversarial input this test can construct): 0.0265 of an 8-bit
        // step. This is ordinary `CIColorCube` quantization error, not an
        // OKLab float error (the OKLCh `PerceptualColorMixer` this test's
        // comment used to describe is gone) -- budgeted the same way cube
        // Q's other ΔE tests are (`ColorOpsTests.
        // postColorCubeMatchesCPUReferenceWithinDeltaE`).
        #expect(maximumChannelDelta < 0.03)
    }

    @Test func oklabRoundTripsExtendedLinearValuesAndKeepsExposureHomogeneous() {
        let samples = [
            SIMD3(0.0, 0.0, 0.0),
            SIMD3(0.18, 0.18, 0.18),
            SIMD3(1.7, 0.2, 0.05),
            SIMD3(-0.02, 0.3, 1.4)
        ]
        for sample in samples {
            let lab = OKLabColor.from(linearSRGB: sample)
            let roundTrip = lab.linearSRGB()
            #expect(maximumAbsoluteDifference(roundTrip, sample) < 0.000_000_2)

            let gain = exp2(100.0 / 300.0)
            let scaledLab = OKLabColor(
                lightness: lab.lightness * gain,
                a: lab.a * gain,
                b: lab.b * gain
            )
            #expect(maximumAbsoluteDifference(scaledLab.linearSRGB(), sample * 2) < 0.000_001)
        }
    }

    @Test func pointCurvesExtrapolateHDRAndMatchTheRenderedKernel() throws {
        let curves = [
            ToneCurve(channel: .rgb, points: [
                CurvePoint(x: 0, y: 0),
                CurvePoint(x: 0.4, y: 0.36),
                CurvePoint(x: 0.8, y: 0.88),
                CurvePoint(x: 1, y: 1)
            ]),
            ToneCurve(channel: .red, points: [
                CurvePoint(x: 0, y: 0),
                CurvePoint(x: 0.5, y: 0.45),
                CurvePoint(x: 1, y: 1)
            ])
        ]
        let samples = [
            SIMD3(-0.01, 0.02, 0.2),
            SIMD3(0.18, 0.5, 0.9),
            SIMD3(1.0, 1.3, 2.0),
            SIMD3(4.0, 0.1, 1.7)
        ]
        let kernel = try #require(ToneCurveModel.makeKernel(curves: curves))
        let rendered = try render(
            try #require(kernel.apply(
                extent: image(from: samples).extent,
                arguments: [image(from: samples)]
            ))
        )
        for (index, sample) in samples.enumerated() {
            let expected = ToneCurveModel.apply(to: sample, curves: curves)
            #expect(maximumAbsoluteDifference(rendered[index], expected) < 0.000_2)
        }
        #expect(rendered[2].z > 1)
        #expect(rendered[3].x > rendered[2].x)

        var previous = -Double.infinity
        for index in 0...4_096 {
            let value = Double(index) * 4 / 4_096
            let output = ToneCurveModel.apply(
                to: SIMD3(repeating: value),
                curves: curves
            ).y
            #expect(output + 0.000_000_001 >= previous)
            previous = output
        }
    }

    @Test func toneCurveModelAppliesEncodedSpaceFixtureAndResolvesDuplicateXPoints() {
        let sCurve = ToneCurve(channel: .rgb, points: [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.25, y: 0.18),
            CurvePoint(x: 0.5, y: 0.5),
            CurvePoint(x: 0.75, y: 0.82),
            CurvePoint(x: 1, y: 1)
        ])
        let encodedCurveFixture = [
            (0.125, 0.09),
            (0.25, 0.18),
            (0.375, 0.34),
            (0.5, 0.5),
            (0.625, 0.66),
            (0.75, 0.82),
            (0.875, 0.91),
            (1.25, 1.18)
        ]
        for (encodedInput, encodedExpected) in encodedCurveFixture {
            let output = ToneCurveModel.apply(
                to: SIMD3(repeating: encodedInput.sRGBToLinear),
                curves: [sCurve]
            )
            #expect(abs(output.x.linearToSRGB - encodedExpected) < 0.000_000_01)
            #expect(abs(output.y.linearToSRGB - encodedExpected) < 0.000_000_01)
            #expect(abs(output.z.linearToSRGB - encodedExpected) < 0.000_000_01)
        }

        let duplicateXCurve = ToneCurve(channel: .rgb, points: [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.5, y: 0.4),
            CurvePoint(x: 0.5, y: 0.6),
            CurvePoint(x: 1, y: 1)
        ])
        let duplicateOutput = ToneCurveModel.apply(
            to: SIMD3(repeating: 0.5.sRGBToLinear),
            curves: [duplicateXCurve]
        )
        #expect(abs(duplicateOutput.x.linearToSRGB - 0.6) < 0.000_000_01)
    }

    @Test func sRGBOutputTransformIsBoundedMonotonicAndDoesNotCreateAHighlightPlateau() {
        let knee = SRGBOutputTransform.highlightKnee
        let epsilon = 0.000_001
        let atKnee = SRGBOutputTransform.highlightShoulder(SIMD3(repeating: knee)).x
        let immediatelyAbove = SRGBOutputTransform.highlightShoulder(
            SIMD3(repeating: knee + epsilon)
        ).x
        let rightSlope = (immediatelyAbove - atKnee) / epsilon
        #expect(abs(atKnee - knee) < 0.000_000_000_1)
        #expect(abs(rightSlope - 1) < 0.001)

        let rays = [
            SIMD3(1.0, 1.0, 1.0),
            SIMD3(1.0, 0.05, 0.05),
            SIMD3(0.05, 1.0, 0.1),
            SIMD3(0.05, 0.1, 1.0),
            SIMD3(1.0, 0.2, 0.8)
        ]
        let scales = stride(from: 0.05, through: 8.0, by: 0.05).map { $0 }
        for ray in rays {
            var previousLightness = -Double.infinity
            var quantizedShoulderPeaks = Set<Int>()
            for scale in scales {
                let input = ray * scale
                let shouldered = SRGBOutputTransform.highlightShoulder(input)
                let output = SRGBOutputTransform.map(input)
                #expect(output.x.isFinite && output.y.isFinite && output.z.isFinite)
                #expect(OKLabColor.isInSRGBGamut(output, tolerance: 0.000_000_1))
                let maximum = max(output.x, max(output.y, output.z))
                #expect(maximum <= SRGBOutputTransform.highlightCeiling + 0.000_001)

                let beforeLab = OKLabColor.from(linearSRGB: shouldered)
                let afterLab = OKLabColor.from(linearSRGB: output)
                #expect(abs(afterLab.lightness - beforeLab.lightness) < 0.000_02)
                #expect(afterLab.lightness + 0.000_001 >= previousLightness)
                previousLightness = afterLab.lightness
                if scale >= 1 {
                    #expect(maximum < 1)
                    let shoulderPeak = max(shouldered.x, max(shouldered.y, shouldered.z))
                    quantizedShoulderPeaks.insert(Int((shoulderPeak * 65_535).rounded()))
                }

                if beforeLab.chroma > 0.001, afterLab.chroma > 0.001 {
                    #expect(circularHueDifference(beforeLab.hueDegrees, afterLab.hueDegrees) < 0.02)
                }
            }
            // Even samples far into the asymptotic tail must not collapse to
            // one 16-bit code. C1 continuity and the real-image plateau gate
            // cover the more important region immediately around the knee.
            #expect(quantizedShoulderPeaks.count > 12)
        }

        let saturatedHighlight = SRGBOutputTransform.map(SIMD3(2.0, 0.1, 0.1))
        #expect(saturatedHighlight.x < 1)
        #expect(saturatedHighlight.x > saturatedHighlight.y)
        #expect(saturatedHighlight.x > saturatedHighlight.z)
    }

    @Test func gamutCompressionKeepsFixedLightnessHueAndMonotonicChroma() {
        for lightness in [0.25, 0.5, 0.75] {
            for hue in stride(from: 0.0, to: 360.0, by: 15.0) {
                var previousChroma = -Double.infinity
                for chroma in stride(from: 0.0, through: 0.8, by: 0.002) {
                    let inputLab = OKLabColor(lightness: lightness, a: 0, b: 0)
                        .replacing(chroma: chroma, hueDegrees: hue)
                    let output = SRGBOutputTransform.gamutCompress(inputLab.linearSRGB())
                    let outputLab = OKLabColor.from(linearSRGB: output)
                    #expect(OKLabColor.isInSRGBGamut(output, tolerance: 0.000_000_1))
                    #expect(abs(outputLab.lightness - lightness) < 0.000_02)
                    #expect(outputLab.chroma + 0.000_001 >= previousChroma)
                    previousChroma = outputLab.chroma
                    if outputLab.chroma > 0.001 {
                        #expect(circularHueDifference(outputLab.hueDegrees, hue) < 0.02)
                    }
                }
            }
        }
    }

    @Test func renderedGamutKernelStaysPerceptuallyStableAcrossOperationalAndStressGamut() throws {
        struct Sample {
            let rgb: SIMD3<Double>
            let ratio: Double
            let ray: Int
        }

        let lightnesses = [0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95]
        let hues = stride(from: 0.0, to: 360.0, by: 15.0)
        var samples: [Sample] = []
        var ray = 0
        for lightness in lightnesses {
            for hue in hues {
                let boundary = SRGBOutputTransform.maximumChroma(
                    lightness: lightness,
                    hueDegrees: hue
                )
                for ratioIndex in 0...400 {
                    let ratio = Double(ratioIndex) / 100
                    let rgb = OKLabColor(lightness: lightness, a: 0, b: 0)
                        .replacing(chroma: boundary * ratio, hueDegrees: hue)
                        .linearSRGB()
                    samples.append(Sample(rgb: rgb, ratio: ratio, ray: ray))
                }
                ray += 1
            }
        }

        let source = gridImage(from: samples.map(\.rgb))
        let rendered = try render(try #require(
            SRGBOutputTransform.gamutKernel.apply(
                extent: source.extent,
                arguments: [source]
            )
        ))

        var operationalNonFiniteOrUnbounded = 0
        var stressNonFiniteOrUnbounded = 0
        var operationalMaximumDeltaOK = 0.0
        var stressMaximumDeltaOK = 0.0
        var operationalMaximumLightnessDrift = 0.0
        var stressMaximumLightnessDrift = 0.0
        var operationalMaximumHueDrift = 0.0
        var stressMaximumHueDrift = 0.0
        var operationalMaximumChromaDrop = 0.0
        var stressMaximumChromaDrop = 0.0
        var previousOperationalChroma: Double?
        var previousStressChroma: Double?
        var previousRay = -1

        for (index, sample) in samples.enumerated() {
            if sample.ray != previousRay {
                previousOperationalChroma = nil
                previousStressChroma = nil
                previousRay = sample.ray
            }

            // Core Image receives RGBAf. Both the CPU reference and the fixed
            // L/h comparison therefore start from exactly that Float input,
            // not from the nominal Double OKLCh ray used to generate it.
            let quantizedInput = SIMD3(
                Double(Float(sample.rgb.x)),
                Double(Float(sample.rgb.y)),
                Double(Float(sample.rgb.z))
            )
            let inputLab = OKLabColor.from(linearSRGB: quantizedInput)
            let expectedLab = OKLabColor.from(
                linearSRGB: SRGBOutputTransform.gamutCompress(quantizedInput)
            )
            let actual = rendered[index]
            let actualLab = OKLabColor.from(linearSRGB: actual)
            let deltaOK = sqrt(
                pow(actualLab.lightness - expectedLab.lightness, 2)
                    + pow(actualLab.a - expectedLab.a, 2)
                    + pow(actualLab.b - expectedLab.b, 2)
            )
            let lightnessDrift = abs(actualLab.lightness - inputLab.lightness)
            let hueDrift = inputLab.chroma > 0.001 && actualLab.chroma > 0.001
                ? circularHueDifference(actualLab.hueDegrees, inputLab.hueDegrees)
                : 0
            let finiteAndBounded = actual.x.isFinite && actual.y.isFinite && actual.z.isFinite
                && OKLabColor.isInSRGBGamut(actual, tolerance: 0.000_001)

            // A +100 mixer adjustment reaches 2x chroma. The 4x tier covers
            // the worst combination with the separate +100 global saturation
            // control. CIKL float math is evaluated perceptually here because
            // LMS cube roots are ill-conditioned exactly on a cone plane.
            if sample.ratio <= 2 {
                if !finiteAndBounded { operationalNonFiniteOrUnbounded += 1 }
                operationalMaximumDeltaOK = max(operationalMaximumDeltaOK, deltaOK)
                operationalMaximumLightnessDrift = max(
                    operationalMaximumLightnessDrift,
                    lightnessDrift
                )
                operationalMaximumHueDrift = max(operationalMaximumHueDrift, hueDrift)
                if let previousOperationalChroma {
                    operationalMaximumChromaDrop = max(
                        operationalMaximumChromaDrop,
                        previousOperationalChroma - actualLab.chroma
                    )
                }
                previousOperationalChroma = actualLab.chroma
            }

            if !finiteAndBounded { stressNonFiniteOrUnbounded += 1 }
            stressMaximumDeltaOK = max(stressMaximumDeltaOK, deltaOK)
            stressMaximumLightnessDrift = max(stressMaximumLightnessDrift, lightnessDrift)
            stressMaximumHueDrift = max(stressMaximumHueDrift, hueDrift)
            if let previousStressChroma {
                stressMaximumChromaDrop = max(
                    stressMaximumChromaDrop,
                    previousStressChroma - actualLab.chroma
                )
            }
            previousStressChroma = actualLab.chroma
        }

        #expect(operationalNonFiniteOrUnbounded == 0)
        #expect(operationalMaximumDeltaOK < 0.001)
        #expect(operationalMaximumLightnessDrift < 0.000_01)
        #expect(operationalMaximumHueDrift < 0.05)
        #expect(operationalMaximumChromaDrop < 0.000_2)
        #expect(stressNonFiniteOrUnbounded == 0)
        #expect(stressMaximumDeltaOK < 0.005)
        #expect(stressMaximumLightnessDrift < 0.000_1)
        #expect(stressMaximumHueDrift < 1)
        #expect(stressMaximumChromaDrop < 0.003)
    }

    @Test func basicTonePreservesStraightColorAcrossPremultipliedAlpha() throws {
        let straight = SIMD3<Double>(0.8, 0.4, 0.2)
        let alphas: [Double] = [1, 0.5, 0.1]
        let source = image(from: alphas.map { alpha in
            SIMD4<Float>(
                Float(straight.x * alpha),
                Float(straight.y * alpha),
                Float(straight.z * alpha),
                Float(alpha)
            )
        })
        let settings = EditSettings(
            contrast: -37,
            highlights: -88,
            shadows: 37,
            whites: -53,
            blacks: 95
        )
        let rendered = try renderRGBA(RenderEngine().apply(settings: settings, to: source))
        let expected = SIMD3(
            Double(rendered[0].x),
            Double(rendered[0].y),
            Double(rendered[0].z)
        )
        for (index, alpha) in alphas.enumerated() {
            let actual = SIMD3(
                Double(rendered[index].x) / alpha,
                Double(rendered[index].y) / alpha,
                Double(rendered[index].z) / alpha
            )
            #expect(maximumAbsoluteDifference(actual, expected) < 0.000_02)
            #expect(abs(Double(rendered[index].w) - alpha) < 0.000_001)
        }
    }

    @Test func sRGBOutputKernelsMatchCPUAndPreservePremultipliedAlpha() throws {
        let straightSamples: [(SIMD3<Double>, Double)] = [
            (SIMD3(0.2, 0.3, 0.4), 1),
            (SIMD3(2.0, 0.1, 0.1), 1),
            (SIMD3(-0.05, 0.5, 1.8), 1),
            (SIMD3(0.1, 2.2, 0.3), 0.5),
            (SIMD3(0.3, 0.1, 3.0), 0.25)
        ]
        let premultiplied = straightSamples.map { rgb, alpha in
            SIMD4<Float>(
                Float(rgb.x * alpha),
                Float(rgb.y * alpha),
                Float(rgb.z * alpha),
                Float(alpha)
            )
        }
        let source = image(from: premultiplied)
        let rendered = try renderRGBA(SRGBOutputTransform.apply(to: source))
        for (index, sample) in straightSamples.enumerated() {
            let expected = SRGBOutputTransform.map(sample.0) * sample.1
            let actual = SIMD3(
                Double(rendered[index].x),
                Double(rendered[index].y),
                Double(rendered[index].z)
            )
            #expect(maximumAbsoluteDifference(actual, expected) < 0.000_4)
            #expect(abs(Double(rendered[index].w) - sample.1) < 0.000_001)
        }
    }

    @Test func genericRawEDRZeroStillMapsSyntheticExtendedValues() throws {
        #expect(RAWCalibrationProfile.generic.configuration.extendedDynamicRangeAmount == 0)
        let rawBranchSentinel = DecodeInfo(
            backend: "synthetic-raw-branch-sentinel",
            width: 1,
            height: 1,
            durationMilliseconds: 0,
            isRAW: true,
            // Real RAW decode never sets this flag. True deliberately isolates
            // the isRAW disjunct from the separate unbounded-input disjunct.
            isBoundedSRGBRaster: true,
            calibrationID: RAWCalibrationProfile.generic.id,
            calibrationLabel: RAWCalibrationProfile.generic.label
        )
        let boundedRasterControl = DecodeInfo(
            backend: "synthetic-bounded-raster-control",
            width: 1,
            height: 1,
            durationMilliseconds: 0,
            isRAW: false,
            isBoundedSRGBRaster: true
        )
        #expect(RenderEngine.requiresOutputTransform(info: rawBranchSentinel, settings: .neutral))
        #expect(!RenderEngine.requiresOutputTransform(info: boundedRasterControl, settings: .neutral))

        let samples = [
            SIMD3<Double>(1.5, 1.5, 1.5),
            SIMD3<Double>(2.0, 0.3, 0.1),
            SIMD3<Double>(-0.05, 0.6, 1.8)
        ]
        #expect(samples.contains {
            0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z > 1
        })
        let decoded = DecodedPhoto(
            sourceURL: URL(fileURLWithPath: "/virtual/generic-edr0.raw"),
            image: image(from: samples),
            metadata: [:],
            info: DecodeInfo(
                backend: "synthetic-generic-raw",
                width: samples.count,
                height: 1,
                durationMilliseconds: 0,
                isRAW: true,
                isBoundedSRGBRaster: false,
                calibrationID: RAWCalibrationProfile.generic.id,
                calibrationLabel: RAWCalibrationProfile.generic.label
            )
        )

        let rendered = try render(
            RenderEngine().applyForOutput(decoded: decoded, settings: .neutral)
        )
        for (index, sample) in samples.enumerated() {
            let quantizedInput = SIMD3(
                Double(Float(sample.x)),
                Double(Float(sample.y)),
                Double(Float(sample.z))
            )
            let expected = SRGBOutputTransform.map(quantizedInput)
            #expect(maximumAbsoluteDifference(rendered[index], expected) < 0.000_5)
            #expect(OKLabColor.isInSRGBGamut(rendered[index], tolerance: 0.000_001))
            #expect(max(rendered[index].x, rendered[index].y, rendered[index].z)
                <= SRGBOutputTransform.highlightCeiling + 0.000_001)
        }
    }

    @Test func canonicalOutputGraphDownsamplesWorkingHDRBeforeTerminalTransform() throws {
        struct Fixture {
            let width: Int
            let height: Int
            let maxDimension: CGFloat
        }

        // Cover an exact 1/2 reduction, a non-integral landscape reduction,
        // and a non-integral portrait reduction with odd source dimensions.
        let fixtures = [
            Fixture(width: 40, height: 24, maxDimension: 20),
            Fixture(width: 37, height: 23, maxDimension: 19),
            Fixture(width: 23, height: 37, maxDimension: 19)
        ]
        let renderer = RenderEngine()
        let settings = EditSettings(exposure: 0.15, contrast: 7)
        var maximumLegacyOrderDifference: Float = 0

        for fixture in fixtures {
            let source = rectangularImage(width: fixture.width, height: fixture.height) { x, y in
                // Mixing values on opposite sides of the shoulder makes the
                // two graph orders observably different without depending on
                // a single Lanczos edge pixel.
                switch ((x / 2) + (y / 3)) % 3 {
                case 0:
                    SIMD4<Float>(4, 0.08, 0.03, 1)
                case 1:
                    SIMD4<Float>(0.03, 2.4, 0.12, 1)
                default:
                    SIMD4<Float>(0.08, 0.15, 3.2, 1)
                }
            }
            let decoded = syntheticDecodedPhoto(
                image: source,
                width: fixture.width,
                height: fixture.height,
                isRAW: true,
                isBoundedSRGBRaster: false
            )

            let current = try renderer.makeOutputGraph(
                decoded: decoded,
                settings: settings,
                maxDimension: fixture.maxDimension,
                downsamplingFilter: .lanczos,
                outputTransformPlacement: .afterDownsampling
            )
            let working = renderer.apply(settings: settings, to: source)
            let manualResize = lanczosDownsample(
                working,
                maxDimension: fixture.maxDimension
            )
            let manual = SRGBOutputTransform.apply(
                to: manualResize.image.cropped(to: manualResize.extent)
            ).cropped(to: manualResize.extent)

            #expect(current.extent == manualResize.extent)
            let expectedScale = fixture.maxDimension
                / CGFloat(max(fixture.width, fixture.height))
            let expectedExtent = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(fixture.width) * expectedScale,
                height: CGFloat(fixture.height) * expectedScale
            ).integral
            #expect(current.extent == expectedExtent)

            let actualPixels = try renderRGBA(current.image)
            let manualPixels = try renderRGBA(manual)
            #expect(actualPixels.count == manualPixels.count)
            #expect(maximumAbsoluteDifference(actualPixels, manualPixels) < 0.000_05)
            #expect(actualPixels.allSatisfy { pixel in
                return pixel.x.isFinite && pixel.y.isFinite
                    && pixel.z.isFinite && pixel.w.isFinite
                    && pixel.x >= -0.000_01 && pixel.x <= 1.000_01
                    && pixel.y >= -0.000_01 && pixel.y <= 1.000_01
                    && pixel.z >= -0.000_01 && pixel.z <= 1.000_01
            })
            let alphaMinimum = try #require(actualPixels.map(\.w).min())
            let alphaMaximum = try #require(actualPixels.map(\.w).max())
            // Core Image's Lanczos normalization can move opaque alpha by
            // about 5e-4 even with an infinitely extended opaque input. This
            // still rejects transparent padding and the prior >1.03 ringing.
            #expect(alphaMinimum >= 0.999)
            #expect(alphaMaximum <= 1.001)

            let legacy = try renderer.makeOutputGraph(
                decoded: decoded,
                settings: settings,
                maxDimension: fixture.maxDimension,
                downsamplingFilter: .lanczos,
                outputTransformPlacement: .legacyBeforeDownsampling
            )
            #expect(legacy.extent == current.extent)
            let legacyManualResize = legacyLanczosDownsample(
                SRGBOutputTransform.apply(to: working),
                maxDimension: fixture.maxDimension
            )
            #expect(
                maximumAbsoluteDifference(
                    try renderRGBA(legacy.image),
                    try renderRGBA(legacyManualResize.image)
                ) < 0.000_05
            )
            maximumLegacyOrderDifference = max(
                maximumLegacyOrderDifference,
                maximumAbsoluteDifference(actualPixels, try renderRGBA(legacy.image))
            )
        }

        #expect(maximumLegacyOrderDifference > 0.05)
    }

    @Test func canonicalLanczosKeepsOpaqueBoundaryPixelsOpaque() throws {
        let width = 17
        let height = 11
        let maxDimension: CGFloat = 7
        let opaquePixel = SIMD4<Float>(0.25, 0.5, 0.75, 1)
        let source = rectangularImage(width: width, height: height) { _, _ in opaquePixel }
        let decoded = syntheticDecodedPhoto(
            image: source,
            width: width,
            height: height,
            isRAW: false,
            isBoundedSRGBRaster: true
        )

        let production = try RenderEngine().makeOutputGraph(
            decoded: decoded,
            settings: .neutral,
            maxDimension: maxDimension,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        let productionPixels = try renderRGBA(production.image)
        let outputWidth = Int(production.extent.width)
        let outputHeight = Int(production.extent.height)
        let boundaryIndices = (0..<productionPixels.count).filter { index in
            let x = index % outputWidth
            let y = index / outputWidth
            return x == 0 || x == outputWidth - 1 || y == 0 || y == outputHeight - 1
        }
        func pixelDifference(_ left: SIMD4<Float>, _ right: SIMD4<Float>) -> Float {
            max(
                abs(left.x - right.x),
                abs(left.y - right.y),
                abs(left.z - right.z),
                abs(left.w - right.w)
            )
        }

        // This deliberately constructs the historical finite-extent Lanczos
        // graph inline rather than sharing production's resize helper. It is a
        // negative control: pixels outside `source.extent` are transparent
        // black and therefore contaminate at least one output boundary.
        let scale = maxDimension / CGFloat(max(width, height))
        let scaledExtent = source.extent.applying(
            CGAffineTransform(scaleX: scale, y: scale)
        ).integral
        let unclamped = source.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ]
        ).cropped(to: scaledExtent)
        let unclampedPixels = try renderRGBA(unclamped)

        #expect(production.extent == scaledExtent)
        #expect(productionPixels.count == unclampedPixels.count)
        #expect(!boundaryIndices.isEmpty)
        #expect(boundaryIndices.allSatisfy { index in
            pixelDifference(productionPixels[index], opaquePixel) < 0.001
                && productionPixels[index].w >= 0.999
                && productionPixels[index].w <= 1.001
        })

        // Pin an actual output corner rather than comparing against a helper
        // that repeats production's clamp implementation. With finite input,
        // the same pixel loses over 10% alpha to transparent-black sampling;
        // the canonical graph must retain the source's opaque edge value.
        let cornerIndex = 0
        #expect(boundaryIndices.contains(cornerIndex))
        #expect(productionPixels[cornerIndex].w >= 0.999)
        #expect(unclampedPixels[cornerIndex].w < 0.9)
        #expect(productionPixels[cornerIndex].w - unclampedPixels[cornerIndex].w > 0.1)
        #expect(pixelDifference(productionPixels[cornerIndex], unclampedPixels[cornerIndex]) > 0.1)
    }

    @Test func boundedNeutralRasterStillBypassesTerminalOutputTransform() throws {
        let width = 31
        let height = 17
        let maxDimension: CGFloat = 15
        let source = rectangularImage(width: width, height: height) { x, y in
            let palette: [SIMD4<Float>] = [
                SIMD4(1, 0, 0, 1),
                SIMD4(0, 1, 0, 1),
                SIMD4(0, 0, 1, 1),
                SIMD4(0.2, 0.4, 0.7, 1)
            ]
            return palette[((x / 4) + (y / 3)) % palette.count]
        }
        let decoded = syntheticDecodedPhoto(
            image: source,
            width: width,
            height: height,
            isRAW: false,
            isBoundedSRGBRaster: true
        )
        let renderer = RenderEngine()
        let manual = lanczosDownsample(source, maxDimension: maxDimension)
        let legacyManual = legacyLanczosDownsample(source, maxDimension: maxDimension)
        let current = try renderer.makeOutputGraph(
            decoded: decoded,
            settings: .neutral,
            maxDimension: maxDimension,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        let legacy = try renderer.makeOutputGraph(
            decoded: decoded,
            settings: .neutral,
            maxDimension: maxDimension,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .legacyBeforeDownsampling
        )

        let expectedPixels = try renderRGBA(manual.image.cropped(to: manual.extent))
        let legacyExpectedPixels = try renderRGBA(
            legacyManual.image.cropped(to: legacyManual.extent)
        )
        let currentPixels = try renderRGBA(current.image)
        let legacyPixels = try renderRGBA(legacy.image)
        #expect(current.extent == manual.extent)
        #expect(legacy.extent == legacyManual.extent)
        #expect(maximumAbsoluteDifference(currentPixels, expectedPixels) < 0.000_05)
        #expect(maximumAbsoluteDifference(legacyPixels, legacyExpectedPixels) < 0.000_05)

        // Pure primaries are changed by the gamut-compression kernel. This
        // control proves equality above is a real bypass, not an accidental
        // identity of the terminal transform for this fixture.
        let transformedPixels = try renderRGBA(
            SRGBOutputTransform.apply(to: manual.image.cropped(to: manual.extent))
        )
        #expect(maximumAbsoluteDifference(currentPixels, transformedPixels) > 0.001)
    }

    @Test func outputTransformPlacementDoesNotChangeFullSizeOutput() throws {
        let width = 17
        let height = 11
        let source = rectangularImage(width: width, height: height) { x, y in
            ((x + y) % 2 == 0)
                ? SIMD4<Float>(2.5, 0.1, 0.05, 1)
                : SIMD4<Float>(0.05, 0.2, 1.8, 1)
        }
        let decoded = syntheticDecodedPhoto(
            image: source,
            width: width,
            height: height,
            isRAW: true,
            isBoundedSRGBRaster: false
        )
        let renderer = RenderEngine()
        let settings = EditSettings(highlights: -23, shadows: 11)
        let current = try renderer.makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: nil,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        let legacy = try renderer.makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: nil,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .legacyBeforeDownsampling
        )
        let establishedFullSize = renderer.applyForOutput(decoded: decoded, settings: settings)

        #expect(current.extent == source.extent.integral)
        #expect(legacy.extent == current.extent)
        let currentPixels = try renderRGBA(current.image)
        #expect(maximumAbsoluteDifference(currentPixels, try renderRGBA(legacy.image)) < 0.000_05)
        #expect(maximumAbsoluteDifference(
            currentPixels,
            try renderRGBA(establishedFullSize.cropped(to: current.extent))
        ) < 0.000_05)
    }

    @Test func editActivityGateUsesToleranceAndStructuralEdits() {
        #expect(!EditSettings.neutral.hasActiveColorEdits())
        #expect(!EditSettings(exposure: 1e-12).hasActiveColorEdits())
        #expect(EditSettings(exposure: 0.01).hasActiveColorEdits())
        #expect(!EditSettings(toneCurves: [
            ToneCurve(channel: .rgb, points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)])
        ]).hasActiveColorEdits())
        #expect(!EditSettings(whiteBalance: WhiteBalanceSettings(mode: .custom)).hasActiveColorEdits())
        #expect(EditSettings(toneCurves: [
            ToneCurve(channel: .rgb, points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.9)])
        ]).hasActiveColorEdits())
        #expect(EditSettings(hsl: [.blue: HSLAdjustment(saturation: 0.01)]).hasActiveColorEdits())
    }

    private func image(from samples: [SIMD3<Double>]) -> CIImage {
        image(from: samples.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) })
    }

    private func image(from samples: [SIMD4<Float>]) -> CIImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIImage(
            bitmapData: samples.withUnsafeBytes { Data($0) },
            bytesPerRow: samples.count * MemoryLayout<SIMD4<Float>>.stride,
            size: CGSize(width: samples.count, height: 1),
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }

    private func gridImage(from samples: [SIMD3<Double>]) -> CIImage {
        let width = min(samples.count, 1_024)
        let height = (samples.count + width - 1) / width
        var pixels = samples.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
        pixels.append(contentsOf: repeatElement(.zero, count: width * height - pixels.count))
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) },
            bytesPerRow: width * MemoryLayout<SIMD4<Float>>.stride,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }

    private func rectangularImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> SIMD4<Float>
    ) -> CIImage {
        var pixels: [SIMD4<Float>] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(pixel(x, y))
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) },
            bytesPerRow: width * MemoryLayout<SIMD4<Float>>.stride,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: colorSpace
        )
    }

    private func syntheticDecodedPhoto(
        image: CIImage,
        width: Int,
        height: Int,
        isRAW: Bool,
        isBoundedSRGBRaster: Bool
    ) -> DecodedPhoto {
        DecodedPhoto(
            sourceURL: URL(fileURLWithPath: "/virtual/output-order-fixture"),
            image: image,
            metadata: [:],
            info: DecodeInfo(
                backend: "synthetic-output-order",
                width: width,
                height: height,
                durationMilliseconds: 0,
                isRAW: isRAW,
                isBoundedSRGBRaster: isBoundedSRGBRaster
            )
        )
    }

    private func lanczosDownsample(
        _ image: CIImage,
        maxDimension: CGFloat
    ) -> (image: CIImage, extent: CGRect) {
        let scale = maxDimension / max(image.extent.width, image.extent.height)
        let scaledExtent = image.extent.applying(
            CGAffineTransform(scaleX: scale, y: scale)
        ).integral
        let resized = image.clampedToExtent().applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ]
        ).cropped(to: scaledExtent)
        return (resized, scaledExtent)
    }

    private func legacyLanczosDownsample(
        _ image: CIImage,
        maxDimension: CGFloat
    ) -> (image: CIImage, extent: CGRect) {
        let scale = maxDimension / max(image.extent.width, image.extent.height)
        let resized = image.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ]
        )
        let extent = resized.extent.integral
        return (resized.cropped(to: extent), extent)
    }

    private func render(_ image: CIImage) throws -> [SIMD3<Double>] {
        try renderRGBA(image).map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }
    }

    private func renderRGBA(_ image: CIImage) throws -> [SIMD4<Float>] {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let width = Int(image.extent.width)
        let count = width * Int(image.extent.height)
        var rendered = [SIMD4<Float>](repeating: .zero, count: count)
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: true
        ])
        context.render(
            image,
            toBitmap: &rendered,
            rowBytes: width * MemoryLayout<SIMD4<Float>>.stride,
            bounds: image.extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )
        return rendered
    }

    private func maximumAbsoluteDifference(
        _ left: [SIMD4<Float>],
        _ right: [SIMD4<Float>]
    ) -> Float {
        guard left.count == right.count else { return .infinity }
        return zip(left, right).reduce(into: Float.zero) { maximum, pair in
            maximum = max(
                maximum,
                abs(pair.0.x - pair.1.x),
                abs(pair.0.y - pair.1.y),
                abs(pair.0.z - pair.1.z),
                abs(pair.0.w - pair.1.w)
            )
        }
    }

    private func maximumAbsoluteDifference(_ left: SIMD3<Double>, _ right: SIMD3<Double>) -> Double {
        max(abs(left.x - right.x), abs(left.y - right.y), abs(left.z - right.z))
    }

    private func circularHueDifference(_ left: Double, _ right: Double) -> Double {
        let raw = abs(left - right).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }
}

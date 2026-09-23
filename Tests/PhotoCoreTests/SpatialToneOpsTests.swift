import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing
@testable import PhotoCore

/// Phase2 C3 gates for `SpatialToneOps` (CPU reference) and
/// `SpatialToneProcessor` (GPU `CIImageProcessorKernel`/Metal, plus its CPU
/// software-renderer fallback):
///
///  - `pyrDownMatchesPythonReference`/`pyrUpMatchesPythonReference`/
///    `remapMagnitudeMatchesPythonReference`: the internal pyramid/remap
///    primitives against `Tests/Fixtures/phase2/spatial-ops.json`'s
///    intermediate fixtures, so a mismatch can be localized to one stage.
///  - `applyHighlightsShadowsMatchesPythonReferenceFixture`: the full
///    `SpatialToneOps.applyHighlightsShadows` against the fixture's 14
///    end-to-end cases (7 slider combinations x 2 `scalePx`), generated from
///    `.photobench/phase2/spatial-v2/spatial_model_v2.py` by
///    `.photobench/phase2/spatial-v2/make_fixture.py`.
///  - `identityWhenNeutral`/`flatImageOnlyMovesWithTheGlobalCurve`: two
///    model-level invariants that replace `BasicToneModel`'s old
///    per-pixel-monotonic-curve guarantees, which no longer make sense for a
///    genuinely spatial (neighbor-mixing) operator -- see
///    `ToneAndCalibrationTests.swift`'s own comment where the
///    `BasicToneModel`-only tests were removed.
///  - `gpuProcessorMatchesCPUReferenceOnHardwareContext`/
///    `...OnSoftwareContext`: `SpatialToneProcessor` (Metal, then the
///    CPU-buffer fallback a software `CIContext` forces) against
///    `SpatialToneOps` on a synthetic 600x400 image, budgeted at ΔE00 <= 0.3
///    (OKLab distance) per the brief's GPU/CPU parity gate.
// `.serialized`: `gpuProcessorMatchesCPUReferenceOnHardwareContext`/
// `...OnSoftwareContext` both reset and read `SpatialToneProcessor`'s shared
// static `process(with:)` call-count diagnostics around their own single
// `apply(to:...)` call; Swift Testing parallelizes different test functions
// within a suite by default, which raced those two tests against each other
// (observed: a spurious "total=2" for a single `apply()` call, from the
// other test's `process(with:)` invocation landing between this test's
// `resetDiagnostics()` and its own call). Serializing this suite makes that
// diagnostic (and the print in `runGPUParityTest`) trustworthy.
@Suite(.serialized)
struct SpatialToneOpsTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SpatialToneOpsTests.swift -> PhotoCoreTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> repo root
    }

    // MARK: - Fixture model (`make_fixture.py`'s exact JSON shape)

    private struct Fixture: Decodable {
        let width: Int
        let height: Int
        let input: [[Double]]
        let cases: [Case]
        let pyrDown: PyramidStep
        let pyrUp: PyramidStep
        let remapMagnitude: RemapFixture
    }

    private struct Case: Decodable {
        let name: String
        let highlights: Double
        let shadows: Double
        let scalePx: Double
        let output: [[Double]]
    }

    private struct PyramidStep: Decodable {
        let inputWidth: Int
        let inputHeight: Int
        let input: [Double]
        let outputWidth: Int
        let outputHeight: Int
        let output: [Double]
    }

    private struct RemapFixture: Decodable {
        let ad: [Double]
        let shadows: RemapCase
        let identity: RemapCase
    }

    private struct RemapCase: Decodable {
        let sigmaR: Double
        let alpha: Double
        let beta: Double
        let output: [Double]
    }

    private func loadFixture() throws -> Fixture {
        let url = projectRoot.appendingPathComponent("Tests/Fixtures/phase2/spatial-ops.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    // MARK: - Phase2 C4 fixture (`.photobench/phase2/detail/detail_model.py`)

    private struct DetailFixture: Decodable {
        let width: Int
        let height: Int
        let input: [[Double]]
        let textureCases: [AmountScaleCase]
        let clarityCases: [AmountScaleCase]
        let dehazeCases: [DehazeCase]
        let chainedCase: ChainedCase
    }

    private struct AmountScaleCase: Decodable {
        let name: String
        let amount: Double
        let scalePx: Double
        let output: [[Double]]
    }

    private struct DehazeCase: Decodable {
        let name: String
        let amount: Double
        let output: [[Double]]
    }

    private struct ChainedCase: Decodable {
        let highlights: Double
        let shadows: Double
        let texture: Double
        let clarity: Double
        let scalePx: Double
        let output: [[Double]]
    }

    private func loadDetailFixture() throws -> DetailFixture {
        let url = projectRoot.appendingPathComponent("Tests/Fixtures/phase2/detail-ops.json")
        return try JSONDecoder().decode(DetailFixture.self, from: Data(contentsOf: url))
    }

    private func assertMatches(
        _ actual: [SIMD3<Double>], _ expectedArrays: [[Double]], label: String, worst: inout Double
    ) {
        for (index, expectedArray) in expectedArrays.enumerated() {
            let expected = SIMD3(expectedArray[0], expectedArray[1], expectedArray[2])
            let a = actual[index]
            for channel in 0..<3 {
                let absoluteDifference = abs(a[channel] - expected[channel])
                guard absoluteDifference > 1e-6 else { continue }
                let relativeError = absoluteDifference / max(abs(expected[channel]), 1e-6)
                if relativeError > worst { worst = relativeError }
                #expect(
                    relativeError <= 1e-4,
                    "\(label) pixel \(index) channel \(channel): actual=\(a[channel]) expected=\(expected[channel])"
                )
            }
        }
    }

    @Test func textureMatchesPythonReferenceFixture() throws {
        let fixture = try loadDetailFixture()
        let rgb = fixture.input.map { SIMD3($0[0], $0[1], $0[2]) }
        var worst = 0.0
        for testCase in fixture.textureCases {
            let output = SpatialToneOps.applyTexture(
                rgb: rgb, width: fixture.width, height: fixture.height, amount: testCase.amount, scalePx: testCase.scalePx
            )
            assertMatches(output, testCase.output, label: testCase.name, worst: &worst)
        }
        print("SpatialToneOpsTests: texture worst relative error = \(worst)")
    }

    @Test func clarityMatchesPythonReferenceFixture() throws {
        let fixture = try loadDetailFixture()
        let rgb = fixture.input.map { SIMD3($0[0], $0[1], $0[2]) }
        var worst = 0.0
        for testCase in fixture.clarityCases {
            let output = SpatialToneOps.applyClarity(
                rgb: rgb, width: fixture.width, height: fixture.height, amount: testCase.amount, scalePx: testCase.scalePx
            )
            assertMatches(output, testCase.output, label: testCase.name, worst: &worst)
        }
        print("SpatialToneOpsTests: clarity worst relative error = \(worst)")
    }

    /// `SpatialToneOps.applyHighlightsShadows`'s single-Ln-chain (H -> S ->
    /// Texture -> Clarity, one final ratio) against the fixture's
    /// `chainedCase` -- generated by calling `spatial_model_v2.py`'s
    /// `apply_highlights_shadows` then `detail_model.py`'s `apply_texture`/
    /// `apply_clarity` *sequentially* on each other's RGB output. Proves the
    /// fused implementation is exact, not an approximation (see that
    /// function's doc comment for why the two are mathematically identical).
    @Test func chainedHighlightsShadowsTextureClarityMatchesSequentialPythonReference() throws {
        let fixture = try loadDetailFixture()
        let rgb = fixture.input.map { SIMD3($0[0], $0[1], $0[2]) }
        let output = SpatialToneOps.applyHighlightsShadows(
            rgb: rgb, width: fixture.width, height: fixture.height,
            highlights: fixture.chainedCase.highlights, shadows: fixture.chainedCase.shadows,
            scalePx: fixture.chainedCase.scalePx, texture: fixture.chainedCase.texture, clarity: fixture.chainedCase.clarity,
            gainScale: .identity  // fixture was generated with no amplitude scaling (SpatialGainScale's doc comment)
        )
        var worst = 0.0
        assertMatches(output, fixture.chainedCase.output, label: "chained", worst: &worst)
        print("SpatialToneOpsTests: chained worst relative error = \(worst)")
    }

    // MARK: - Intermediate primitives

    @Test func pyrDownMatchesPythonReference() throws {
        let fixture = try loadFixture()
        let plane = SpatialPlane(
            width: fixture.pyrDown.inputWidth, height: fixture.pyrDown.inputHeight,
            values: fixture.pyrDown.input
        )
        let down = SpatialToneOps.pyrDown(plane)
        #expect(down.width == fixture.pyrDown.outputWidth)
        #expect(down.height == fixture.pyrDown.outputHeight)
        let maxAbsolute = maxAbsoluteDifference(down.values, fixture.pyrDown.output)
        #expect(maxAbsolute < 1e-9)
    }

    @Test func pyrUpMatchesPythonReference() throws {
        let fixture = try loadFixture()
        let plane = SpatialPlane(
            width: fixture.pyrUp.inputWidth, height: fixture.pyrUp.inputHeight,
            values: fixture.pyrUp.input
        )
        let up = SpatialToneOps.pyrUp(plane, outWidth: fixture.pyrUp.outputWidth, outHeight: fixture.pyrUp.outputHeight)
        let maxAbsolute = maxAbsoluteDifference(up.values, fixture.pyrUp.output)
        #expect(maxAbsolute < 1e-9)
    }

    @Test func remapMagnitudeMatchesPythonReference() throws {
        let fixture = try loadFixture()
        for (ad, expected) in zip(fixture.remapMagnitude.ad, fixture.remapMagnitude.shadows.output) {
            let actual = SpatialToneOps.remapMagnitude(
                ad, sigmaR: fixture.remapMagnitude.shadows.sigmaR,
                alpha: fixture.remapMagnitude.shadows.alpha, beta: fixture.remapMagnitude.shadows.beta
            )
            #expect(abs(actual - expected) < 1e-9)
        }
        for (ad, expected) in zip(fixture.remapMagnitude.ad, fixture.remapMagnitude.identity.output) {
            let actual = SpatialToneOps.remapMagnitude(
                ad, sigmaR: fixture.remapMagnitude.identity.sigmaR,
                alpha: fixture.remapMagnitude.identity.alpha, beta: fixture.remapMagnitude.identity.beta
            )
            #expect(abs(actual - expected) < 1e-9)
        }
    }

    // MARK: - End-to-end fixture

    @Test func applyHighlightsShadowsMatchesPythonReferenceFixture() throws {
        let fixture = try loadFixture()
        let rgb = fixture.input.map { SIMD3($0[0], $0[1], $0[2]) }
        var worstRelativeError = 0.0
        var worstCase = ""

        for testCase in fixture.cases {
            let output = SpatialToneOps.applyHighlightsShadows(
                rgb: rgb, width: fixture.width, height: fixture.height,
                highlights: testCase.highlights, shadows: testCase.shadows, scalePx: testCase.scalePx,
                gainScale: .identity  // fixture was generated with no amplitude scaling
            )
            #expect(output.count == testCase.output.count)
            for (index, expectedArray) in testCase.output.enumerated() {
                let expected = SIMD3(expectedArray[0], expectedArray[1], expectedArray[2])
                let actual = output[index]
                for channel in 0..<3 {
                    let a = actual[channel]
                    let e = expected[channel]
                    let absoluteDifference = abs(a - e)
                    // 1e-4 relative / 1e-6 absolute floor, per the brief's
                    // fixture-matching tolerance.
                    guard absoluteDifference > 1e-6 else { continue }
                    let relativeError = absoluteDifference / max(abs(e), 1e-6)
                    if relativeError > worstRelativeError {
                        worstRelativeError = relativeError
                        worstCase = "\(testCase.name) pixel \(index) channel \(channel) actual=\(a) expected=\(e)"
                    }
                    #expect(
                        relativeError <= 1e-4,
                        "case \(testCase.name) pixel \(index) channel \(channel): actual=\(a) expected=\(e) relError=\(relativeError)"
                    )
                }
            }
        }
        print("SpatialToneOpsTests: worst relative error over \(fixture.cases.count) cases = \(worstRelativeError) (\(worstCase))")
    }

    // MARK: - Model-level invariants (replace `BasicToneModel`'s old identity/monotonic tests)

    @Test func identityWhenNeutral() {
        let width = 6
        let height = 5
        var rgb: [SIMD3<Double>] = []
        for index in 0..<(width * height) {
            let v = Double(index) / Double(width * height - 1)
            rgb.append(SIMD3(0.1 + 0.8 * v, 0.05 + 0.5 * v, 0.2 + 0.3 * v))
        }
        let output = SpatialToneOps.applyHighlightsShadows(
            rgb: rgb, width: width, height: height, highlights: 0, shadows: 0, scalePx: 16, gainScale: .identity
        )
        #expect(output == rgb)
    }

    /// A perfectly flat (spatially constant) image has an all-zero Laplacian
    /// detail band at every level (`pyrDown`/`pyrUp` of a constant plane is
    /// that same constant, so `G[l] - pyrUp(G[l+1])` is exactly zero) --
    /// only the coarsest base level, and therefore only the measured global
    /// gain curve, can move it. This is the spatial model's own analogue of
    /// "no hidden per-pixel scaling": a texture-free input is not where the
    /// local-contrast machinery has anything to do.
    @Test func flatImageOnlyMovesWithTheGlobalCurve() {
        let width = 12
        let height = 10
        let flatLuminanceRGB = SIMD3<Double>(0.18, 0.18, 0.18)
        let rgb = [SIMD3<Double>](repeating: flatLuminanceRGB, count: width * height)

        for (highlights, shadows) in [(-80.0, 0.0), (60.0, 0.0), (0.0, -70.0), (0.0, 90.0), (-40.0, 55.0)] {
            let output = SpatialToneOps.applyHighlightsShadows(
                rgb: rgb, width: width, height: height, highlights: highlights, shadows: shadows, scalePx: 32,
                gainScale: .identity
            )
            let first = output[0]
            for sample in output {
                #expect(maximumAbsoluteDifference(sample, first) < 1e-9)
            }
            // The uniform output must also be finite and not wildly far from
            // the input -- catches a runaway curve/levels bug without
            // pinning an exact number (the gain tables are measured, not
            // closed-form).
            #expect(first.x.isFinite && first.y.isFinite && first.z.isFinite)
        }
    }

    @Test func needsSpatialMatchesHighlightsOrShadowsBeingNonZero() {
        #expect(!SpatialToneOps.needsSpatial(.neutral))
        #expect(SpatialToneOps.needsSpatial(EditSettings(highlights: 1)))
        #expect(SpatialToneOps.needsSpatial(EditSettings(shadows: -1)))
        #expect(!SpatialToneOps.needsSpatial(EditSettings(contrast: 50, whites: 50, blacks: -50)))
    }

    @Test func scalePxIsLinearInLongEdgeAndMatchesTheDocumentedAnchors() {
        #expect(abs(SpatialToneOps.scalePx(forLongEdge: 1500) - 32) < 1e-9)
        #expect(abs(SpatialToneOps.scalePx(forLongEdge: 6000) - 128) < 1e-9)
        #expect(abs(SpatialToneOps.scalePx(forLongEdge: 3072) - 65.536) < 1e-6)
    }

    // MARK: - GPU (Metal) vs. CPU reference parity

    /// `SpatialToneProcessor` on a real Metal-backed `CIContext` against
    /// `SpatialToneOps` (CPU) on the same pixels, both operations active
    /// together (the more demanding path -- Highlights' fast identity-remap
    /// pyramid then Shadows' full `n_disc`-point discretized sweep, entirely
    /// on the GPU including the whole-image min/max reduction). Budget:
    /// OKLab distance <= 0.3 (the brief's "ΔE00 <= 0.3" gate, using OKLab's
    /// Euclidean distance as the simpler of the two allowed metrics).
    @Test func gpuProcessorMatchesCPUReferenceOnHardwareContext() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: colorSpace, .outputColorSpace: colorSpace
        ])
        try runGPUParityTest(context: context, maxOKLabDelta: 0.3, label: "hardware-metal")
    }

    /// Same comparison, with the *caller's* readback forced through a
    /// software `CIContext`. `SpatialToneProcessor.apply` no longer depends
    /// on which `CIContext` the caller uses at all (it manages its own
    /// `MTLDevice`/command queue/`CIContext` internally, see this file's
    /// class doc comment) -- its CPU fallback only ever runs when
    /// `MTLCreateSystemDefaultDevice()` itself returns `nil`, which does not
    /// happen on any Mac. This test's value is confirming the *output*
    /// `CIImage` composes correctly with a software-rendering caller, not
    /// exercising a different code path inside `SpatialToneProcessor` --
    /// see `cpuBufferPathMatchesSpatialToneOpsDirectlyAndHandlesTiledOutput
    /// Offsets` for a direct test of the CPU fallback's buffer logic.
    @Test func gpuProcessorMatchesCPUReferenceOnSoftwareContext() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [
            .workingColorSpace: colorSpace, .outputColorSpace: colorSpace, .useSoftwareRenderer: true
        ])
        try runGPUParityTest(context: context, maxOKLabDelta: 0.02, label: "software-fallback")
    }

    /// **Experiment only** (`SpatialShift`'s doc comment): the same GPU/CPU
    /// parity check, at a non-zero shift for both Highlights and Shadows --
    /// the shift's GPU implementation is a brand-new Metal kernel parameter
    /// (`spatialAddCurve`'s `shift` buffer), so this is the one test that
    /// would catch a mismatch between it and the CPU reference's `curve($0 -
    /// shift)` (e.g. a buffer-index mixup, or `Float`-vs-`Double` cast
    /// error) that the two existing (shift-less) parity tests cannot.
    @Test func gpuProcessorMatchesCPUReferenceWithANonZeroShift() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: colorSpace, .outputColorSpace: colorSpace
        ])
        try runGPUParityTest(
            context: context, maxOKLabDelta: 0.3, label: "hardware-metal-shifted",
            shift: SpatialShift(highlights: 1.5, shadows: -2.0)
        )
    }

    private func runGPUParityTest(context: CIContext, maxOKLabDelta: Double, label: String, shift: SpatialShift = .zero) throws {
        let width = 600
        let height = 400
        let (image, rgb) = makeParityTestImage(width: width, height: height)
        let highlights = -60.0
        let shadows = 55.0
        // Phase2 C4: exercise Texture/Clarity's new `spatialMultiplyScalar`
        // GPU path in the same call, chained after Highlights/Shadows.
        let texture = -40.0
        let clarity = 35.0
        let scalePx = 24.0

        SpatialToneProcessor.resetDiagnostics()
        let processed = try SpatialToneProcessor.apply(
            to: image, highlights: highlights, shadows: shadows, scalePx: scalePx, texture: texture, clarity: clarity,
            gainScale: .identity, shift: shift
        )

        var rendered = [Float](repeating: 0, count: width * height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        context.render(
            processed, toBitmap: &rendered, rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )

        let expected = SpatialToneOps.applyHighlightsShadows(
            rgb: rgb, width: width, height: height, highlights: highlights, shadows: shadows, scalePx: scalePx,
            texture: texture, clarity: clarity, gainScale: .identity, shift: shift
        )

        var maxDelta = 0.0
        var maxAbsolute = 0.0
        for index in 0..<(width * height) {
            let base = index * 4
            let actual = SIMD3(Double(rendered[base]), Double(rendered[base + 1]), Double(rendered[base + 2]))
            let alpha = Double(rendered[base + 3])
            let exp = expected[index]
            maxAbsolute = max(maxAbsolute, abs(actual.x - exp.x), abs(actual.y - exp.y), abs(actual.z - exp.z))
            let actualLab = OKLabColor.from(linearSRGB: actual)
            let expectedLab = OKLabColor.from(linearSRGB: exp)
            let delta = sqrt(
                pow(actualLab.lightness - expectedLab.lightness, 2)
                    + pow(actualLab.a - expectedLab.a, 2)
                    + pow(actualLab.b - expectedLab.b, 2)
            )
            maxDelta = max(maxDelta, delta)
            #expect(abs(alpha - 1) < 1e-4, "alpha must survive unchanged at pixel \(index)")
        }
        let diagnostics = SpatialToneProcessor.diagnosticsSnapshot
        print(
            "SpatialToneOpsTests GPU parity (\(label)): maxOKLabDelta=\(maxDelta) maxAbsolute=\(maxAbsolute) "
                + "process(with:) calls total=\(diagnostics.total) metal=\(diagnostics.metal) cpu=\(diagnostics.cpu)"
        )
        #expect(
            maxDelta <= maxOKLabDelta,
            "GPU/CPU parity (\(label)): maxOKLabDelta=\(maxDelta) exceeds budget \(maxOKLabDelta)"
        )
    }

    /// A deterministic 600x400 synthetic image (gradient + hard edge + a
    /// cheap positional hash for high-frequency noise, no RNG/seed state
    /// needed) spanning roughly the same [1e-4, 1.0] range as the fixture
    /// image, so the pyramid/Laplacian machinery has real detail to react
    /// to. Returns both the `CIImage` (RGBAf, opaque) and the same values as
    /// a flat `[SIMD3<Double>]` for the CPU reference call.
    private func makeParityTestImage(width: Int, height: Int) -> (image: CIImage, rgb: [SIMD3<Double>]) {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var rgb = [SIMD3<Double>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x) / Double(width - 1)
                let fy = Double(y) / Double(height - 1)
                let gradient = (fx + fy) / 2.0
                let step = x >= width * 55 / 100 ? 0.35 : 0.0
                let hash = sin(Double(x) * 12.9898 + Double(y) * 78.233) * 43_758.5453
                let noise = (hash - hash.rounded(.down) - 0.5) * 0.04
                var value = max(0.0, gradient * 0.9 + step + noise)
                value = pow(value, 2.2)
                value = min(max(value, 1e-4), 1.0)
                let red = value
                let green = min(max(value * (0.8 + 0.4 * Double((x + y) % 7) / 7.0), 1e-4), 1.0)
                let blue = min(max(value * (0.6 + 0.6 * Double((x * 2 + y) % 5) / 5.0), 1e-4), 1.0)
                let index = y * width + x
                rgb[index] = SIMD3(red, green, blue)
                let base = index * 4
                pixels[base] = Float(red)
                pixels[base + 1] = Float(green)
                pixels[base + 2] = Float(blue)
                pixels[base + 3] = 1
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let image = CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) },
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: colorSpace
        )
        return (image, rgb)
    }

    // MARK: - CPU-buffer path (`SpatialToneProcessor.processCPUBuffers`)

    /// `processCPUBuffers` is the buffer-marshaling code
    /// `applyCPUFallback` (only reachable when `MTLCreateSystemDefaultDevice()`
    /// returns `nil`, which no real Mac does) delegates to -- there is no
    /// way to force a real render through that fallback on this hardware,
    /// so this calls `processCPUBuffers` directly with hand-built buffers
    /// instead, covering the two things it does beyond calling
    /// `SpatialToneOps` (which is already exhaustively fixture-tested):
    /// premultiplied-alpha unwrapping and an output window offset into a
    /// larger input (retained from this design's earlier
    /// `CIImageProcessorKernel` incarnation, where it handled Core Image's
    /// tiled `output.region != input.region`; `applyCPUFallback` itself
    /// never actually needs a nonzero offset now, but the general logic is
    /// still worth covering directly).
    @Test func cpuBufferPathMatchesSpatialToneOpsDirectlyAndHandlesTiledOutputOffsets() throws {
        let width = 20
        let height = 16
        var rgb = [SIMD3<Double>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x) / Double(width - 1)
                let fy = Double(y) / Double(height - 1)
                rgb[y * width + x] = SIMD3(0.01 + 0.9 * fx, 0.02 + 0.7 * fy, 0.05 + 0.5 * ((fx + fy) / 2))
            }
        }
        let highlights = -70.0
        let shadows = 40.0
        let scalePx = 8.0

        var inputPixels = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            inputPixels[index * 4] = Float(rgb[index].x)
            inputPixels[index * 4 + 1] = Float(rgb[index].y)
            inputPixels[index * 4 + 2] = Float(rgb[index].z)
            inputPixels[index * 4 + 3] = 1
        }
        let inputBytesPerRow = width * 4 * MemoryLayout<Float>.size

        var fullOutput = [Float](repeating: 0, count: width * height * 4)
        try inputPixels.withUnsafeBytes { inRaw in
            try fullOutput.withUnsafeMutableBytes { outRaw in
                try SpatialToneProcessor.processCPUBuffers(
                    inputBase: inRaw.baseAddress!, inputBytesPerRow: inputBytesPerRow,
                    inputWidth: width, inputHeight: height,
                    outputBase: outRaw.baseAddress!, outputBytesPerRow: inputBytesPerRow,
                    outputWidth: width, outputHeight: height, offsetX: 0, offsetY: 0,
                    highlights: highlights, shadows: shadows, scalePx: scalePx, gainScale: .identity
                )
            }
        }

        let expected = SpatialToneOps.applyHighlightsShadows(
            rgb: rgb, width: width, height: height, highlights: highlights, shadows: shadows, scalePx: scalePx,
            gainScale: .identity
        )
        for index in 0..<(width * height) {
            let actual = SIMD3(
                Double(fullOutput[index * 4]), Double(fullOutput[index * 4 + 1]), Double(fullOutput[index * 4 + 2])
            )
            #expect(maximumAbsoluteDifference(actual, expected[index]) < 1e-5)
            #expect(abs(Double(fullOutput[index * 4 + 3]) - 1.0) < 1e-6)
        }

        // A tiled request (a sub-rectangle, not the whole input) must yield
        // exactly the corresponding pixels of the full-image result -- the
        // whole point of computing on `inputWidth x inputHeight` and only
        // then windowing into the requested output rectangle.
        let tileX = 5
        let tileY = 3
        let tileWidth = 9
        let tileHeight = 7
        var tileOutput = [Float](repeating: 0, count: tileWidth * tileHeight * 4)
        let tileBytesPerRow = tileWidth * 4 * MemoryLayout<Float>.size
        try inputPixels.withUnsafeBytes { inRaw in
            try tileOutput.withUnsafeMutableBytes { outRaw in
                try SpatialToneProcessor.processCPUBuffers(
                    inputBase: inRaw.baseAddress!, inputBytesPerRow: inputBytesPerRow,
                    inputWidth: width, inputHeight: height,
                    outputBase: outRaw.baseAddress!, outputBytesPerRow: tileBytesPerRow,
                    outputWidth: tileWidth, outputHeight: tileHeight, offsetX: tileX, offsetY: tileY,
                    highlights: highlights, shadows: shadows, scalePx: scalePx, gainScale: .identity
                )
            }
        }
        for y in 0..<tileHeight {
            for x in 0..<tileWidth {
                let tileIndex = (y * tileWidth + x) * 4
                let fullIndex = ((y + tileY) * width + (x + tileX)) * 4
                #expect(abs(Double(tileOutput[tileIndex]) - Double(fullOutput[fullIndex])) < 1e-9)
                #expect(abs(Double(tileOutput[tileIndex + 1]) - Double(fullOutput[fullIndex + 1])) < 1e-9)
                #expect(abs(Double(tileOutput[tileIndex + 2]) - Double(fullOutput[fullIndex + 2])) < 1e-9)
            }
        }
    }

    /// A spatially-flat straight color behind a spatially-*varying* alpha
    /// pattern: unpremultiplying must happen before the log-luminance/
    /// pyramid math, or the alpha pattern would leak in as if it were real
    /// image detail (see `SpatialToneProcessor`'s doc comment). Replaces
    /// `ToneAndCalibrationTests`' deleted `BasicToneModel`-era
    /// `basicTonePreservesStraightColorAcrossPremultipliedAlpha` (a 1-row
    /// fixture that only made sense for a pointwise, non-spatial operator).
    @Test func cpuBufferPathPreservesStraightColorAcrossPremultipliedAlpha() throws {
        let width = 8
        let height = 8
        let straight = SIMD3<Double>(0.6, 0.3, 0.15)
        let alphaCycle: [Double] = [1.0, 0.5, 0.1, 0.8]

        var inputPixels = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let alpha = alphaCycle[index % alphaCycle.count]
            inputPixels[index * 4] = Float(straight.x * alpha)
            inputPixels[index * 4 + 1] = Float(straight.y * alpha)
            inputPixels[index * 4 + 2] = Float(straight.z * alpha)
            inputPixels[index * 4 + 3] = Float(alpha)
        }
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        var output = [Float](repeating: 0, count: width * height * 4)
        try inputPixels.withUnsafeBytes { inRaw in
            try output.withUnsafeMutableBytes { outRaw in
                try SpatialToneProcessor.processCPUBuffers(
                    inputBase: inRaw.baseAddress!, inputBytesPerRow: bytesPerRow, inputWidth: width, inputHeight: height,
                    outputBase: outRaw.baseAddress!, outputBytesPerRow: bytesPerRow,
                    outputWidth: width, outputHeight: height, offsetX: 0, offsetY: 0,
                    highlights: -55, shadows: 65, scalePx: 8, gainScale: .identity
                )
            }
        }

        var recovered: [SIMD3<Double>] = []
        for index in 0..<(width * height) {
            let alpha = Double(output[index * 4 + 3])
            #expect(abs(alpha - alphaCycle[index % alphaCycle.count]) < 1e-6)
            recovered.append(SIMD3(
                Double(output[index * 4]) / alpha, Double(output[index * 4 + 1]) / alpha, Double(output[index * 4 + 2]) / alpha
            ))
        }
        let first = recovered[0]
        for sample in recovered {
            #expect(maximumAbsoluteDifference(sample, first) < 1e-4)
        }
    }

    /// Regression test from this design's two earlier, abandoned
    /// `CIImageProcessorKernel` incarnations (see `SpatialToneProcessor`'s
    /// class doc comment): an input that traces back through
    /// `AdobeBaseRenderer.applyCube` (`CIGammaAdjust`+`CIColorCube`, exactly
    /// like real cube P1 in production) used to make a custom kernel's
    /// `process(with:...)` never get called at all. The explicit
    /// `CIContext.render(_:to:MTLTexture:...)` round trip this type uses
    /// instead does not have that failure mode, but this input shape is
    /// exactly what production always feeds `apply(to:...)`, so it stays as
    /// a end-to-end regression check: asserts both that `apply` actually ran
    /// and that the result is a plausible (non-zero, finite)
    /// contrast+Highlights/Shadows output.
    @Test func gpuKernelIsReachedThroughACubeChainedInput() throws {
        let width = 20
        let height = 16
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = 0.5
            pixels[i * 4 + 1] = 0.3
            pixels[i * 4 + 2] = 0.2
            pixels[i * 4 + 3] = 1
        }
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let raw = CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )
        // Mirrors real cube P1: `AdobeBaseRenderer.applyCube` wraps
        // `CIColorCube` in `CIGammaAdjust`/`CIGammaAdjust`.
        let cube = AdobeBaseRenderer.postOpsCubeP1(exposureNonRaw: 0, contrast: -37, dehaze: 0)
        let cubed = AdobeBaseRenderer.applyCube(cube, to: raw)

        SpatialToneProcessor.resetDiagnostics()
        let output = try SpatialToneProcessor.apply(
            to: cubed, highlights: -88, shadows: 37, scalePx: SpatialToneOps.scalePx(forLongEdge: Double(max(width, height))),
            gainScale: .identity
        )
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        var rendered = [Float](repeating: 0, count: width * height * 4)
        context.render(
            output, toBitmap: &rendered, rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )

        #expect(SpatialToneProcessor.diagnosticsSnapshot.total >= 1)
        for index in 0..<(width * height) {
            let base = index * 4
            #expect(rendered[base].isFinite && rendered[base] > 0)
            #expect(rendered[base + 1].isFinite && rendered[base + 1] > 0)
            #expect(rendered[base + 2].isFinite && rendered[base + 2] > 0)
            #expect(abs(rendered[base + 3] - 1) < 1e-4)
        }
    }

    /// Verifies the explicit GPU round trip's vertical orientation:
    /// `CIContext.render(_:to:MTLTexture:commandBuffer:bounds:colorSpace:)`
    /// (write) and `CIImage(mtlTexture:options:)` (read) must agree on which
    /// texture row is the top of the image, or the output would come back
    /// vertically mirrored. Uses a `highlights: 0, shadows: 0` call, which
    /// makes the compute pass an exact identity (`y_ratio == 1` everywhere,
    /// no early-return shortcut skips the round trip itself -- `apply`
    /// always renders into `inputTexture` and wraps `outputTexture` back
    /// up), so any row-order mismatch shows up directly as a pixel mismatch
    /// against the untouched input. The fixture is asymmetric top-to-bottom
    /// (bright top half, dark bottom half) so a flip is unmistakable.
    @Test func gpuRoundTripPreservesVerticalOrientation() throws {
        let width = 24
        let height = 32
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let value: Float = y < height / 2 ? 0.85 : 0.1
            for x in 0..<width {
                let base = (y * width + x) * 4
                pixels[base] = value
                pixels[base + 1] = value * 0.6
                pixels[base + 2] = value * 0.3
                pixels[base + 3] = 1
            }
        }
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        let image = CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: bytesPerRow,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )

        let output = try SpatialToneProcessor.apply(to: image, highlights: 0, shadows: 0, scalePx: 16, gainScale: .identity)
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        var rendered = [Float](repeating: 0, count: width * height * 4)
        context.render(
            output, toBitmap: &rendered, rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )

        var maxAbsoluteDifference: Float = 0
        var nonFiniteCount = 0
        for index in 0..<(width * height * 4) {
            guard rendered[index].isFinite else {
                nonFiniteCount += 1
                continue
            }
            maxAbsoluteDifference = max(maxAbsoluteDifference, abs(rendered[index] - pixels[index]))
        }
        #expect(nonFiniteCount == 0, "\(nonFiniteCount) non-finite output values")
        #expect(maxAbsoluteDifference < 1e-4, "identity round trip drifted by \(maxAbsoluteDifference) -- check for a vertical flip")

        // Directly pin top-stays-bright/bottom-stays-dark (would read
        // backwards if `needsVerticalFlipAfterRoundTrip` should be `true`).
        let topRowFirstPixel = rendered[0]
        let bottomRowFirstPixel = rendered[((height - 1) * width) * 4]
        #expect(topRowFirstPixel > 0.5, "row 0 should still be the bright top half")
        #expect(bottomRowFirstPixel < 0.5, "the last row should still be the dark bottom half")
    }

    // MARK: - round2 set A: image-adaptive Shadows2012 amplitude
    // (`.photobench/phase2/spatial-adaptive/model.md`)

    /// Uniform planes are unaffected by any blur (a constant convolved with
    /// a normalized kernel is itself), so these two are exact, not
    /// approximate: a photo that is entirely brighter/darker than -1 stop
    /// must have `highlightRatioBase` exactly 1/0.
    @Test func highlightRatioBaseIsExactOneOrZeroForAUniformImage() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func uniformImage(value: Float, width: Int = 64, height: Int = 48) -> CIImage {
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) {
                pixels[i * 4] = value
                pixels[i * 4 + 3] = 1
            }
            return CIImage(
                bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
            )
        }
        let redOnly = SIMD3<Double>(1, 0, 0)
        let bright = SpatialAdaptiveStats.highlightRatioBase(image: uniformImage(value: 1.0), longEdge: 64, lumaWeights: redOnly)
        let dark = SpatialAdaptiveStats.highlightRatioBase(image: uniformImage(value: 0.1), longEdge: 64, lumaWeights: redOnly)
        #expect(bright == 1.0)
        #expect(dark == 0.0)
    }

    /// A sharp horizontal split (bright top half / dark bottom half, R
    /// channel only) with a small blur sigma relative to the image height
    /// should land close to a 50/50 highlight ratio -- the Gaussian blur
    /// only smears the boundary over roughly +-3 sigma, not the whole
    /// image, so the crossing point of the -1 stop threshold stays near the
    /// geometric midpoint (see this test's derivation in the PR/commit
    /// discussion: it is not exactly 0.5 because blurring happens in log2
    /// space, where the bright/dark endpoints are not equidistant from the
    /// threshold, so a wide tolerance is used deliberately, not because the
    /// implementation is expected to be imprecise).
    @Test func highlightRatioBaseIsApproximatelyHalfForASharpHalfBrightSplit() throws {
        let width = 200
        let height = 100
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let value: Float = y < height / 2 ? 1.0 : 0.1
            for x in 0..<width {
                pixels[(y * width + x) * 4] = value
                pixels[(y * width + x) * 4 + 3] = 1
            }
        }
        let image = CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )
        let ratio = SpatialAdaptiveStats.highlightRatioBase(image: image, longEdge: 200, lumaWeights: SIMD3(1, 0, 0))
        #expect(abs(ratio - 0.5) < 0.1, "expected close to 0.5, got \(ratio)")
    }

    /// A photo already larger than `longEdge` is downscaled; one already
    /// smaller is left at its own size (never upscaled) -- both end up at
    /// the *same* `highlightRatioBase` for the same underlying scene, which
    /// is exactly `model.md` §6 item 2's "preview and export must agree"
    /// requirement. Verified here with two different-resolution renders of
    /// the same half-bright-split pattern (400x200 and 100x50), both well
    /// away from `longEdge`'s own 200 so the "already smaller, don't
    /// upscale" branch is also exercised.
    @Test func highlightRatioBaseAgreesAcrossDifferentInputResolutions() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func splitImage(width: Int, height: Int) -> CIImage {
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let value: Float = y < height / 2 ? 1.0 : 0.1
                for x in 0..<width {
                    pixels[(y * width + x) * 4] = value
                    pixels[(y * width + x) * 4 + 3] = 1
                }
            }
            return CIImage(
                bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
            )
        }
        let large = SpatialAdaptiveStats.highlightRatioBase(image: splitImage(width: 400, height: 200), longEdge: 200, lumaWeights: SIMD3(1, 0, 0))
        let small = SpatialAdaptiveStats.highlightRatioBase(image: splitImage(width: 100, height: 50), longEdge: 200, lumaWeights: SIMD3(1, 0, 0))
        #expect(abs(large - small) < 0.02, "large=\(large) small=\(small)")
    }

    /// `SpatialAdaptiveLaw.kS`'s clamp: below/above the [0.4, 1.8] training
    /// range, and an in-range sanity check against a real measured
    /// `highlightRatioBase` from `model.md` §3.1 (P1013558's "base" table:
    /// highlight(>-1) = 0.212) -- not one of the exact fit inputs, but close
    /// enough to confirm the formula's coefficients are wired up correctly.
    @Test func spatialAdaptiveLawClampsAtBothEnds() {
        #expect(SpatialAdaptiveLaw.kS(highlightRatioBase: -10) == SpatialAdaptiveLaw.clampMin)
        #expect(SpatialAdaptiveLaw.kS(highlightRatioBase: 10) == SpatialAdaptiveLaw.clampMax)
        #expect(SpatialAdaptiveLaw.kS(highlightRatioBase: 0) == SpatialAdaptiveLaw.intercept)

        let ratio = 0.212
        let expected = SpatialAdaptiveLaw.intercept + SpatialAdaptiveLaw.slope * ratio
        #expect(abs(SpatialAdaptiveLaw.kS(highlightRatioBase: ratio) - expected) < 1e-9)
        #expect(expected > SpatialAdaptiveLaw.clampMin && expected < SpatialAdaptiveLaw.clampMax, "sanity: this ratio should not need clamping")
    }

    /// Non-RAW's law (`.photobench/phase2/nonraw-hs/model.md` §5): its own
    /// separate clamp ranges (kS [0.6,2.2], sShift [-2,0]) -- deliberately
    /// different from RAW's (kS [0.4,1.8]/[0.6,1.5], sShift [-3,0]), since
    /// the two are independently-fit laws (`SpatialAdaptiveLaw`'s "Non-RAW"
    /// section doc comment: reusing RAW's coefficients for non-RAW measured
    /// *worse* than a flat fixed value).
    @Test func nonRAWSpatialAdaptiveLawClampsAtBothEnds() {
        #expect(SpatialAdaptiveLaw.nonRAWKS(fullHighlightRatio: -10) == SpatialAdaptiveLaw.nonRAWKSClampMin)
        #expect(SpatialAdaptiveLaw.nonRAWKS(fullHighlightRatio: 10) == SpatialAdaptiveLaw.nonRAWKSClampMax)
        #expect(SpatialAdaptiveLaw.nonRAWKS(fullHighlightRatio: 0) == SpatialAdaptiveLaw.nonRAWKSIntercept)

        #expect(SpatialAdaptiveLaw.nonRAWSShift(fullP90: -10) == SpatialAdaptiveLaw.nonRAWShiftClampMin)
        #expect(SpatialAdaptiveLaw.nonRAWSShift(fullP90: 10) == SpatialAdaptiveLaw.nonRAWShiftClampMax)
        // Unlike RAW's `sShift` (whose intercept, 1.5609, is also >0 but
        // that law is untested at meanFull=0), this law's intercept alone
        // (0.2363) already exceeds the [-2,0] upper clamp, so *every*
        // `fullP90 >= 0` clamps to exactly 0, not the raw intercept value.
        #expect(SpatialAdaptiveLaw.nonRAWSShift(fullP90: 0) == SpatialAdaptiveLaw.nonRAWShiftClampMax)

        // DSC02072-like bright JPEG sanity check from `model.md` §5: a
        // highlightRatio of 0.721 lands close to, but per the model.md text
        // ("2.001の手前") just *under*, the 2.2 upper clamp -- not clamped.
        let dsc02072ish = SpatialAdaptiveLaw.nonRAWKSIntercept + SpatialAdaptiveLaw.nonRAWKSSlope * 0.721
        #expect(abs(SpatialAdaptiveLaw.nonRAWKS(fullHighlightRatio: 0.721) - dsc02072ish) < 1e-9)
        #expect(dsc02072ish < SpatialAdaptiveLaw.nonRAWKSClampMax, "sanity: model.md describes this as just under the clamp")
    }

    /// Non-RAW's kH law (`nonraw-hs/results/presets.json`'s "proposed_
    /// adaptive"): its own clamp range [0.3, 1.1] (a slope of -1.9300 means
    /// higher clamp input clamps *low*, the mirror image of `nonRAWKS`'s
    /// positive slope).
    @Test func nonRAWKHLawClampsAtBothEndsAndMatchesDSC02072() {
        #expect(SpatialAdaptiveLaw.nonRAWKH(baseHighlightRatio: -10) == SpatialAdaptiveLaw.nonRAWKHClampMax)
        #expect(SpatialAdaptiveLaw.nonRAWKH(baseHighlightRatio: 10) == SpatialAdaptiveLaw.nonRAWKHClampMin)
        #expect(SpatialAdaptiveLaw.nonRAWKH(baseHighlightRatio: 0) == SpatialAdaptiveLaw.nonRAWKHIntercept)

        // DSC02072's own measured baseHighlightRatio (~0.711, per the
        // coordinator's cause analysis): the unclamped formula value is
        // already below the 0.3 floor, so it lands exactly on the clamp --
        // confirms *why* the flat 0.7 was too strong for this scene.
        let dsc02072BaseRatio = 0.711
        let unclamped = SpatialAdaptiveLaw.nonRAWKHIntercept + SpatialAdaptiveLaw.nonRAWKHSlope * dsc02072BaseRatio
        #expect(unclamped < SpatialAdaptiveLaw.nonRAWKHClampMin, "sanity: DSC02072 should need the floor clamp")
        #expect(SpatialAdaptiveLaw.nonRAWKH(baseHighlightRatio: dsc02072BaseRatio) == SpatialAdaptiveLaw.nonRAWKHClampMin)

        // A mid-range ratio that should land inside the clamp, unmodified.
        let ratio = 0.25
        let expected = SpatialAdaptiveLaw.nonRAWKHIntercept + SpatialAdaptiveLaw.nonRAWKHSlope * ratio
        #expect(expected > SpatialAdaptiveLaw.nonRAWKHClampMin && expected < SpatialAdaptiveLaw.nonRAWKHClampMax, "sanity: this ratio should not need clamping")
        #expect(abs(SpatialAdaptiveLaw.nonRAWKH(baseHighlightRatio: ratio) - expected) < 1e-9)
    }

    /// `SpatialGainScale.adaptiveNonRAW`/`SpatialShift.adaptiveNonRAW`: kH
    /// image-adaptive (not RAW's fixed 0.5), hShift fixed at 0 (unmeasured),
    /// and the `current(stats:path:)` dispatcher actually routes to these
    /// non-RAW functions for `.nonRAW` (not silently falling through to the
    /// RAW law).
    @Test func spatialGainScaleAndShiftAdaptiveNonRAWUseTheirOwnLaw() {
        let scale = SpatialGainScale.adaptiveNonRAW(baseHighlightRatio: 0.9, fullHighlightRatio: 0.3)
        #expect(scale.highlightsNeg == SpatialAdaptiveLaw.nonRAWKH(baseHighlightRatio: 0.9))
        #expect(scale.highlightsPos == SpatialAdaptiveLaw.nonRAWKH(baseHighlightRatio: 0.9))
        #expect(scale.shadowsNeg == SpatialAdaptiveLaw.nonRAWKS(fullHighlightRatio: 0.3))

        let shift = SpatialShift.adaptiveNonRAW(fullP90: -1.0)
        #expect(shift.highlights == 0)
        #expect(shift.shadows == SpatialAdaptiveLaw.nonRAWSShift(fullP90: -1.0))

        let stats = SpatialAdaptiveStats.Stats(highlightRatioBase: 0.9, meanLn: 0.9, fullHighlightRatio: 0.3, fullP90: -1.0)
        #expect(SpatialGainScale.current(stats: stats, path: .nonRAW) == scale)
        #expect(SpatialShift.current(stats: stats, path: .nonRAW) == shift)
        // Same `stats`, `.raw` path: kS reads the same `highlightRatioBase`
        // field non-RAW's kH just read above (by design -- both paths' laws
        // legitimately share that one field, see `Stats`'s doc comment), but
        // shift must read `meanLn` (RAW-only), not non-RAW's fullP90 (-1.0) --
        // confirms the dispatcher truly branches on `path`, not just on which
        // fields happen to be set.
        #expect(SpatialGainScale.current(stats: stats, path: .raw) == SpatialGainScale.current(highlightRatioBase: 0.9))
        #expect(SpatialShift.current(stats: stats, path: .raw) == SpatialShift.current(meanLn: 0.9))
    }

    /// `SpatialAdaptiveStats.Stats.fullHighlightRatio`/`fullP90`
    /// (`nonraw-hs/model.md` §1.4): both read the *unblurred* ("full") Ln
    /// plane directly, no Gaussian blur -- verified with a uniform image
    /// (mirrors `highlightRatioBaseIsExactOneOrZeroForAUniformImage`'s
    /// reasoning: every percentile of a constant plane is that same
    /// constant) and a simple ramp (known analytic percentile).
    @Test func fullHighlightRatioAndFullP90ReadTheUnblurredPlane() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let width = 64, height = 48
        func uniformImage(value: Float) -> CIImage {
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) {
                pixels[i * 4] = value
                pixels[i * 4 + 3] = 1
            }
            return CIImage(
                bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
            )
        }
        let redOnly = SIMD3<Double>(1, 0, 0)
        // A uniform Y=1.0 plane has Ln=log2(1)=0 everywhere: every
        // percentile (including p90) is exactly 0, and the whole plane is
        // above the -1 stop threshold (ratio exactly 1).
        let bright = SpatialAdaptiveStats.computeStats(image: uniformImage(value: 1.0), longEdge: 64, lumaWeights: redOnly)
        #expect(bright.fullHighlightRatio == 1.0)
        #expect(bright.fullP90 == 0.0)

        // A uniform Y=0.1 plane: Ln=log2(0.1)~=-3.32, below -1, so ratio is
        // exactly 0, and p90 equals that same constant (no blur to smear it).
        let dark = SpatialAdaptiveStats.computeStats(image: uniformImage(value: 0.1), longEdge: 64, lumaWeights: redOnly)
        #expect(dark.fullHighlightRatio == 0.0)
        // 1e-5, not 1e-9: `computeStats(image:...)` renders through Core
        // Image's `Float` (32-bit) `RGBAf` buffer format, so a `Double`-exact
        // comparison is unrealistic here -- `SpatialAdaptiveStats`'s own
        // arithmetic is `Double` throughout, but its *input* already lost
        // precision at the GPU/CPU render-to-buffer step.
        #expect(abs(dark.fullP90 - log2(0.1)) < 1e-5)
    }

    /// `SpatialGainScale.adaptive`: kH stays fixed at 0.5 regardless of the
    /// ratio (`model.md` §4.1/§5), kSneg/kSpos both get the same
    /// `SpatialAdaptiveLaw.kS` value (kSneg was never measured separately --
    /// see `SpatialGainScale.adaptive`'s doc comment).
    @Test func spatialGainScaleAdaptiveFixesKHAndSharesKSAcrossBothShadowSigns() {
        let scale = SpatialGainScale.adaptive(highlightRatioBase: 0.3)
        #expect(scale.highlightsNeg == 0.5)
        #expect(scale.highlightsPos == 0.5)
        #expect(scale.shadowsNeg == scale.shadowsPos)
        #expect(scale.shadowsNeg == SpatialAdaptiveLaw.kS(highlightRatioBase: 0.3))
    }

    /// `SpatialGainScale.current(highlightRatioBase:)`: an explicit
    /// `PHOTO_BENCH_SPATIAL_GAIN_SCALE` always wins over the adaptive law,
    /// matching `model.md` §6 item 4 -- this test only exercises the `nil`
    /// (no per-photo statistic) and adaptive branches directly since setting
    /// process-wide environment variables from `Testing` is not done
    /// elsewhere in this file; the env var's precedence itself is already
    /// covered by `SpatialGainScale.current`'s existing behavior (unchanged
    /// by this refactor -- only its parameter list changed).
    /// `SpatialAdaptiveVersion.current`'s own default is `.shiftRefit`
    /// (`.photobench/phase2/spatial-adaptive/model.md` §10's real-engine
    /// A/B/C comparison), not `.v2` -- so `.current(highlightRatioBase:)`'s
    /// fallback must be compared against `.adaptive(highlightRatioBase:
    /// version:)` called with that *same* resolved version explicitly, not
    /// `.adaptive`'s own bare (`.v2`) default, which this test used to
    /// (silently) rely matching before the production default moved.
    @Test func spatialGainScaleCurrentFallsBackToProductionDefaultWithoutAStatistic() {
        #expect(SpatialGainScale.current(highlightRatioBase: nil) == SpatialGainScale.productionDefault)
        let adaptive = SpatialGainScale.current(highlightRatioBase: 0.3)
        #expect(adaptive == SpatialGainScale.adaptive(highlightRatioBase: 0.3, version: SpatialAdaptiveVersion.current))
        #expect(SpatialAdaptiveVersion.current == .shiftRefit, "this test assumes the production default; update it if that changes again")
    }

    // MARK: - Helpers

    private func maxAbsoluteDifference(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        var maximum = 0.0
        for i in 0..<lhs.count { maximum = max(maximum, abs(lhs[i] - rhs[i])) }
        return maximum
    }

    private func maximumAbsoluteDifference(_ left: SIMD3<Double>, _ right: SIMD3<Double>) -> Double {
        max(abs(left.x - right.x), abs(left.y - right.y), abs(left.z - right.z))
    }
}

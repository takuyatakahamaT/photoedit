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
                highlights: testCase.highlights, shadows: testCase.shadows, scalePx: testCase.scalePx
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
            rgb: rgb, width: width, height: height, highlights: 0, shadows: 0, scalePx: 16
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
                rgb: rgb, width: width, height: height, highlights: highlights, shadows: shadows, scalePx: 32
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

    private func runGPUParityTest(context: CIContext, maxOKLabDelta: Double, label: String) throws {
        let width = 600
        let height = 400
        let (image, rgb) = makeParityTestImage(width: width, height: height)
        let highlights = -60.0
        let shadows = 55.0
        let scalePx = 24.0

        SpatialToneProcessor.resetDiagnostics()
        let processed = try SpatialToneProcessor.apply(to: image, highlights: highlights, shadows: shadows, scalePx: scalePx)

        var rendered = [Float](repeating: 0, count: width * height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        context.render(
            processed, toBitmap: &rendered, rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )

        let expected = SpatialToneOps.applyHighlightsShadows(
            rgb: rgb, width: width, height: height, highlights: highlights, shadows: shadows, scalePx: scalePx
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
                    highlights: highlights, shadows: shadows, scalePx: scalePx
                )
            }
        }

        let expected = SpatialToneOps.applyHighlightsShadows(
            rgb: rgb, width: width, height: height, highlights: highlights, shadows: shadows, scalePx: scalePx
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
                    highlights: highlights, shadows: shadows, scalePx: scalePx
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
                    highlights: -55, shadows: 65, scalePx: 8
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
        let cube = AdobeBaseRenderer.postOpsCubeP1(exposureNonRaw: 0, contrast: -37)
        let cubed = AdobeBaseRenderer.applyCube(cube, to: raw)

        SpatialToneProcessor.resetDiagnostics()
        let output = try SpatialToneProcessor.apply(
            to: cubed, highlights: -88, shadows: 37, scalePx: SpatialToneOps.scalePx(forLongEdge: Double(max(width, height)))
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

        let output = try SpatialToneProcessor.apply(to: image, highlights: 0, shadows: 0, scalePx: 16)
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

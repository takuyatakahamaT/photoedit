import CoreImage
import Foundation
import Metal

/// GPU (`CIImageProcessorKernel`/Metal compute) implementation of
/// `SpatialToneOps.applyHighlightsShadows`, plus a CPU-buffer fallback for
/// non-Metal `CIContext`s (`.useSoftwareRenderer: true`, or any context that
/// otherwise can't hand this kernel a Metal texture).
///
/// Every dispatch mirrors `SpatialToneOps`/`SpatialToneMetalSource`'s
/// doc comments 1:1; this file is purely the Swift-side orchestration
/// (texture allocation, dispatch order, and the two required entry points a
/// `CIImageProcessorKernel` subclass needs) around those kernels.
///
/// **Alpha**: Core Image images are premultiplied. Straight (unpremultiplied)
/// RGB matters only for computing `Ln` (the log-luminance the whole pyramid
/// decomposition is driven by) -- using premultiplied RGB there would leak
/// `log2(alpha)` into `Ln`, and therefore into which gain-curve/pyramid
/// value applies, at any partially-transparent pixel (see
/// `spatialLuminance` in `SpatialToneMetalSource`). The final scale does
/// **not** need its own unpremultiply/premultiply round trip: output
/// premultiplied RGB = `straightRGB_out * alpha = (straightRGB_in *
/// yRatio) * alpha = (straightRGB_in * alpha) * yRatio =
/// premultipliedRGB_in * yRatio` -- multiplying the already-premultiplied
/// input directly by the per-pixel ratio (`spatialApplyRatio`) gives exactly
/// the correctly premultiplied output, since `yRatio` is a per-pixel scalar
/// (homogeneous in RGB). Production photos are always fully opaque, but this
/// keeps the same "no accidental coupling to alpha" invariant the deleted
/// `BasicToneModel` CIKernel had, and `SpatialToneOpsTests`
/// (`ToneAndCalibrationTests.swift`'s replacement test) exercises it.
///
/// **Two Core Image limitations found while building this file, both
/// reproduced only as "the input never reaches `process(with:...)` at all" --
/// no thrown Swift error, no console log, an all-zero (transparent black)
/// result, on both a Metal-backed and a `.useSoftwareRenderer` `CIContext`:**
///
/// 1. **A `height == 1` input.** Any image whose height is exactly 1 pixel
///    silently fails this way, regardless of how it was constructed. Width
///    == 1 (a 1-pixel-*wide*, tall image) works fine, as does any height >=
///    2. This never affects a real photo (never 1px tall) or this pipeline's
///    own use (below), but it means test fixtures for this kernel must not
///    reuse this module's sibling tests' 1-row "ramp" image convention
///    (`ToneAndCalibrationTests.image(from:)`) -- see
///    `ToneAndCalibrationTests.highlightsShadowsPreserveStraightColorAcross
///    PremultipliedAlpha`'s own comment, which hit exactly this.
/// 2. **An input that traces back through `CIGammaAdjust`, `CIColorCube`, or
///    `CIImage(mtlTexture:options:)`** -- confirmed with a minimal repro: a
///    plain `CIImage(bitmapData:...)` works, and chaining a `CIColorMatrix`
///    onto one still works, but chaining *only* `CIGammaAdjust` (no cube at
///    all) already fails, an identity `CIColorCube` alone already fails, and
///    reconstructing a `CIImage` from an explicit, freshly rendered
///    `MTLTexture` (`CIImage(mtlTexture:options:)`, entirely GPU-side, no
///    CPU array) *also* fails even for otherwise-untouched content.
///    `insertingIntermediate()` and an unpremultiply/premultiply round trip
///    do not help either. The **only** construction found to reliably work
///    regardless of history is a true CPU buffer round trip: render to a
///    `[Float]` via `CIContext.render(_:toBitmap:...)`, then
///    `CIImage(bitmapData:...)` from that buffer -- see
///    `materializeForCustomKernelInput`, which `apply(to:highlights:shadows:
///    scalePx:)` runs unconditionally, since every real caller
///    (`AdobeBaseRenderer.applySpatialToneOps`) feeds this kernel an image
///    that has already gone through at least one `applyCube`
///    (`CIGammaAdjust`+`CIColorCube`) -- Stage H/L/T for RAW, cube P1
///    otherwise -- so this is not a defensive-only measure, it is load-
///    bearing for correctness in the actual pipeline. The performance cost
///    (one full-resolution GPU render to a CPU buffer and back) is reported
///    in this task's own measurements; a cheaper GPU-resident fix (e.g. an
///    IOSurface/`CVPixelBuffer`-backed round trip) is a plausible follow-up
///    but was not found to work in the time available -- see this file's
///    change history/the C3 report for the full repro matrix this comment
///    summarizes.
public final class SpatialToneProcessor: CIImageProcessorKernel {
    enum ProcessorError: Error {
        case missingResources
        case pipelineCreationFailed(String)
        case invalidTileGeometry
    }

    // MARK: - Public entry point

    /// Thin wrapper around `CIImageProcessorKernel.apply(withExtent:inputs:
    /// arguments:)`. `scalePx` should already be `SpatialToneOps.scalePx(
    /// forLongEdge:)` of the image `image` is (the caller's own long edge,
    /// at whatever resolution it is actually processing).
    ///
    /// Runs `image` through `materializeForCustomKernelInput` first --
    /// unconditionally, not just for known-bad inputs -- see this class's
    /// doc comment for why that is required for correctness here, not
    /// optional defensive cleanup.
    public static func apply(to image: CIImage, highlights: Double, shadows: Double, scalePx: Double) throws -> CIImage {
        let materialized = materializeForCustomKernelInput(image)
        return try self.apply(
            withExtent: materialized.extent,
            inputs: [materialized],
            arguments: ["highlights": highlights, "shadows": shadows, "scalePx": scalePx]
        )
    }

    /// A CPU buffer round trip (`CIContext.render(_:toBitmap:...)` then
    /// `CIImage(bitmapData:...)`) -- see this class's doc comment (point 2)
    /// for why this specific, expensive-looking construction is the one
    /// empirically found to work regardless of `image`'s filter-graph
    /// history. `.extendedLinearSRGB` here is purely a wide-range, no-clip
    /// numeric container (matching this codebase's existing convention for
    /// non-sRGB intermediate data, e.g. `PhotoBenchRender`'s stage-debug
    /// TIFF dump) -- both the render and the reconstruction use the exact
    /// same tag, so no gamut/primaries conversion actually happens; the
    /// image reaching this function is linear ProPhoto, and it stays that
    /// way numerically.
    static func materializeForCustomKernelInput(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0
        else {
            return image
        }
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return image }

        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        var buffer = [Float](repeating: 0, count: width * height * 4)
        materializationContext.render(
            image, toBitmap: &buffer, rowBytes: bytesPerRow,
            bounds: extent, format: .RGBAf, colorSpace: colorSpace
        )
        let data = buffer.withUnsafeBytes { Data($0) }
        return CIImage(
            bitmapData: data, bytesPerRow: bytesPerRow,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )
    }

    /// Dedicated to `materializeForCustomKernelInput`'s render call --
    /// `.cacheIntermediates: false` since each render is a one-shot
    /// materialization, never revisited.
    private static let materializationContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Diagnostics (`process(with:...)` call count -- tiling check)

    private static let diagnosticsLock = NSLock()
    nonisolated(unsafe) private static var diagnosticsCallCount = 0
    nonisolated(unsafe) private static var diagnosticsMetalCallCount = 0
    nonisolated(unsafe) private static var diagnosticsCPUCallCount = 0

    /// Exposed so tests/the phase3 gate script's Swift entry point can
    /// confirm whether Core Image split one `apply(to:...)` into multiple
    /// `process(with:...)` calls (tiling) -- see the C3 brief's "process の
    /// 呼び出し回数" report item.
    public static func resetDiagnostics() {
        diagnosticsLock.lock()
        diagnosticsCallCount = 0
        diagnosticsMetalCallCount = 0
        diagnosticsCPUCallCount = 0
        diagnosticsLock.unlock()
    }

    public static var diagnosticsSnapshot: (total: Int, metal: Int, cpu: Int) {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return (diagnosticsCallCount, diagnosticsMetalCallCount, diagnosticsCPUCallCount)
    }

    // MARK: - CIImageProcessorKernel overrides

    override public class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        // The Gaussian/Laplacian pyramid's coarsest levels (and, for
        // Shadows, the global min/max the discretization grid is built
        // from) have global support: even a small requested output tile can
        // depend on the whole image. `.infinite` tells Core Image "the
        // entire input", which it resolves to the input's actual (finite)
        // extent when building this kernel's `CIImageProcessorInput`.
        .infinite
    }

    override public class func formatForInput(at input: Int32) -> CIFormat {
        .RGBAf
    }

    override public class var outputFormat: CIFormat {
        .RGBAf
    }

    override public class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        diagnosticsLock.lock()
        diagnosticsCallCount += 1
        diagnosticsLock.unlock()

        guard let input = inputs?.first else { throw ProcessorError.missingResources }
        let highlights = (arguments?["highlights"] as? Double) ?? 0
        let shadows = (arguments?["shadows"] as? Double) ?? 0
        let scalePx = (arguments?["scalePx"] as? Double) ?? 32

        if let inputTexture = input.metalTexture,
           let outputTexture = output.metalTexture,
           let commandBuffer = output.metalCommandBuffer {
            diagnosticsLock.lock()
            diagnosticsMetalCallCount += 1
            diagnosticsLock.unlock()
            try processMetal(
                inputTexture: inputTexture, inputRegion: input.region,
                outputTexture: outputTexture, outputRegion: output.region,
                commandBuffer: commandBuffer,
                highlights: highlights, shadows: shadows, scalePx: scalePx
            )
        } else {
            diagnosticsLock.lock()
            diagnosticsCPUCallCount += 1
            diagnosticsLock.unlock()
            try processCPU(input: input, output: output, highlights: highlights, shadows: shadows, scalePx: scalePx)
        }
    }

    // MARK: - CPU (software-`CIContext`) fallback

    /// Delegates straight to `SpatialToneOps` (already exhaustively checked
    /// against the Python reference fixture) rather than re-implementing the
    /// algorithm a second time in terms of raw buffers -- this path exists
    /// for correctness (software `CIContext`s, or any context that cannot
    /// hand this kernel a Metal texture), not performance.
    private static func processCPU(
        input: CIImageProcessorInput,
        output: CIImageProcessorOutput,
        highlights: Double,
        shadows: Double,
        scalePx: Double
    ) throws {
        let width = Int(input.region.width.rounded())
        let height = Int(input.region.height.rounded())
        let outWidth = Int(output.region.width.rounded())
        let outHeight = Int(output.region.height.rounded())
        let offsetX = Int((output.region.origin.x - input.region.origin.x).rounded())
        let offsetY = Int((output.region.origin.y - input.region.origin.y).rounded())
        try processCPUBuffers(
            inputBase: input.baseAddress, inputBytesPerRow: input.bytesPerRow, inputWidth: width, inputHeight: height,
            outputBase: output.baseAddress, outputBytesPerRow: output.bytesPerRow,
            outputWidth: outWidth, outputHeight: outHeight, offsetX: offsetX, offsetY: offsetY,
            highlights: highlights, shadows: shadows, scalePx: scalePx
        )
    }

    /// The actual buffer marshaling `processCPU` delegates to (RGBAf,
    /// premultiplied, row-major, 4 floats/pixel) -- split out so it is
    /// directly unit-testable with hand-built buffers. `SpatialToneOpsTests`
    /// exercises this because, empirically (see that test file's comment),
    /// `CIContext(options: [.useSoftwareRenderer: true])` does not appear to
    /// make Core Image actually hand this `CIImageProcessorKernel` a
    /// `baseAddress`-only `CIImageProcessorInput`/`Output` on this
    /// OS/hardware combination (`process(with:)` still receives Metal
    /// textures either way), so this path cannot currently be forced through
    /// a real render the way the brief's GPU-vs-CPU test anticipated.
    static func processCPUBuffers(
        inputBase: UnsafeRawPointer,
        inputBytesPerRow: Int,
        inputWidth: Int,
        inputHeight: Int,
        outputBase: UnsafeMutableRawPointer,
        outputBytesPerRow: Int,
        outputWidth: Int,
        outputHeight: Int,
        offsetX: Int,
        offsetY: Int,
        highlights: Double,
        shadows: Double,
        scalePx: Double
    ) throws {
        guard inputWidth > 0, inputHeight > 0 else { throw ProcessorError.invalidTileGeometry }
        guard offsetX >= 0, offsetY >= 0,
              offsetX + outputWidth <= inputWidth, offsetY + outputHeight <= inputHeight
        else {
            throw ProcessorError.invalidTileGeometry
        }

        var rgb = [SIMD3<Double>](repeating: .zero, count: inputWidth * inputHeight)
        var alphas = [Double](repeating: 1, count: inputWidth * inputHeight)
        for y in 0..<inputHeight {
            let row = inputBase.advanced(by: y * inputBytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<inputWidth {
                let base = x * 4
                let r = Double(row[base])
                let g = Double(row[base + 1])
                let b = Double(row[base + 2])
                let a = Double(row[base + 3])
                let index = y * inputWidth + x
                alphas[index] = a
                rgb[index] = a > 1e-7 ? SIMD3(r / a, g / a, b / a) : SIMD3(r, g, b)
            }
        }

        let resultStraight = SpatialToneOps.applyHighlightsShadows(
            rgb: rgb, width: inputWidth, height: inputHeight,
            highlights: highlights, shadows: shadows, scalePx: scalePx
        )

        for y in 0..<outputHeight {
            let srcY = y + offsetY
            let row = outputBase.advanced(by: y * outputBytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<outputWidth {
                let srcIndex = srcY * inputWidth + (x + offsetX)
                let straight = resultStraight[srcIndex]
                let alpha = alphas[srcIndex]
                let base = x * 4
                row[base] = Float(straight.x * alpha)
                row[base + 1] = Float(straight.y * alpha)
                row[base + 2] = Float(straight.z * alpha)
                row[base + 3] = Float(alpha)
            }
        }
    }

    // MARK: - Metal (GPU) path

    private static func processMetal(
        inputTexture: MTLTexture,
        inputRegion: CGRect,
        outputTexture: MTLTexture,
        outputRegion: CGRect,
        commandBuffer: MTLCommandBuffer,
        highlights: Double,
        shadows: Double,
        scalePx: Double
    ) throws {
        let device = commandBuffer.device
        let resources = try metalResources(for: device)
        let width = inputTexture.width
        let height = inputTexture.height

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ProcessorError.missingResources
        }
        encoder.label = "SpatialToneProcessor.compute"

        let ln0 = makePlaneTexture(device: device, width: width, height: height)
        runLuminance(encoder: encoder, resources: resources, rgba: inputTexture, lnOut: ln0)

        let levelsH = max(1, Int(log2(max(scalePx, 2.0)).rounded(.toNearestOrEven)))
        var currentLn = ln0

        if highlights != 0 {
            let curveBuffer = makeCurveBuffer(device: device, values: SpatialToneOps.highlightsGainCurve(highlights))
            currentLn = applySingleOpLLF(
                encoder: encoder, resources: resources, device: device,
                ln: currentLn, curveBuffer: curveBuffer,
                alpha: SpatialToneOps.highlightsParams.alpha,
                beta: SpatialToneOps.highlightsParams.beta,
                sigmaR: SpatialToneOps.highlightsParams.sigmaR,
                levels: levelsH
            )
        }
        if shadows != 0 {
            let levelsS = max(1, levelsH + SpatialToneOps.shadowsLevelsOffset)
            let curveBuffer = makeCurveBuffer(device: device, values: SpatialToneOps.shadowsGainCurve(shadows))
            currentLn = applySingleOpLLF(
                encoder: encoder, resources: resources, device: device,
                ln: currentLn, curveBuffer: curveBuffer,
                alpha: SpatialToneOps.shadowsParams.alpha,
                beta: SpatialToneOps.shadowsParams.beta,
                sigmaR: SpatialToneOps.shadowsParams.sigmaR,
                levels: levelsS
            )
        }

        let scratchRGBA = makeRGBATexture(device: device, width: width, height: height)
        runApplyRatio(encoder: encoder, resources: resources, rgbaIn: inputTexture, lnFinal: currentLn, ln0: ln0, rgbaOut: scratchRGBA)

        encoder.endEncoding()

        // `output.region` may be a tile of `input.region` (Core Image is
        // free to split the graph up); copy only the requested sub-rect out
        // of the full-image result computed above. In the common (untiled)
        // case this is a same-size, zero-offset copy.
        let offsetX = Int((outputRegion.origin.x - inputRegion.origin.x).rounded())
        let offsetY = Int((outputRegion.origin.y - inputRegion.origin.y).rounded())
        guard offsetX >= 0, offsetY >= 0,
              offsetX + outputTexture.width <= scratchRGBA.width,
              offsetY + outputTexture.height <= scratchRGBA.height
        else {
            throw ProcessorError.invalidTileGeometry
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw ProcessorError.missingResources
        }
        blit.label = "SpatialToneProcessor.blit"
        blit.copy(
            from: scratchRGBA, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: offsetX, y: offsetY, z: 0),
            sourceSize: MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1),
            to: outputTexture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    /// `SpatialToneOps.applySingleOpLLF`'s GPU counterpart: identical
    /// structure (fast identity-remap path for `alpha == beta == 1`,
    /// otherwise the `n_disc`-point discretized sweep), just issuing Metal
    /// dispatches into `encoder` instead of looping over `Double` arrays.
    private static func applySingleOpLLF(
        encoder: MTLComputeCommandEncoder,
        resources: MetalResources,
        device: MTLDevice,
        ln: MTLTexture,
        curveBuffer: MTLBuffer,
        alpha: Double,
        beta: Double,
        sigmaR: Double,
        levels: Int,
        nDisc: Int = 10
    ) -> MTLTexture {
        let g = gaussianPyramid(encoder: encoder, resources: resources, device: device, base: ln, levels: levels)

        if alpha == 1.0 && beta == 1.0 {
            var lap = laplacianPyramid(encoder: encoder, resources: resources, device: device, g: g)
            let lastIndex = lap.count - 1
            let newBase = makePlaneTexture(device: device, width: lap[lastIndex].width, height: lap[lastIndex].height)
            runAddCurve(encoder: encoder, resources: resources, src: lap[lastIndex], dst: newBase, curveBuffer: curveBuffer)
            lap[lastIndex] = newBase
            return reconstruct(encoder: encoder, resources: resources, device: device, lap: lap)
        }

        // Shadows: the whole-image min/max, the g0 discretization grid, and
        // every per-level bracket/weight all stay on the GPU -- there is no
        // CPU round trip between them (see `SpatialToneMetalSource`'s
        // `spatialComputeG0Grid` doc comment).
        let minMaxBuffer = makeMinMaxBuffer(device: device)
        runMinMaxReduceInit(encoder: encoder, resources: resources, buffer: minMaxBuffer)
        runMinMaxReduce(encoder: encoder, resources: resources, ln: ln, resultBuffer: minMaxBuffer)

        let n = nDisc
        let g0Buffer = makeG0Buffer(device: device, count: n)
        runComputeG0Grid(encoder: encoder, resources: resources, minMaxBuffer: minMaxBuffer, g0Buffer: g0Buffer, n: n)

        var idxTextures: [MTLTexture] = []
        var fracTextures: [MTLTexture] = []
        for level in 0..<levels {
            let idxTex = makePlaneTexture(device: device, width: g[level].width, height: g[level].height)
            let fracTex = makePlaneTexture(device: device, width: g[level].width, height: g[level].height)
            runComputeBracket(encoder: encoder, resources: resources, g: g[level], idxOut: idxTex, fracOut: fracTex, g0Buffer: g0Buffer, n: n)
            idxTextures.append(idxTex)
            fracTextures.append(fracTex)
        }

        let acc: [MTLTexture] = (0..<levels).map { makePlaneTexture(device: device, width: g[$0].width, height: g[$0].height) }

        for k in 0..<n {
            let remapped = makePlaneTexture(device: device, width: ln.width, height: ln.height)
            runRemap(encoder: encoder, resources: resources, ln: ln, out: remapped, g0Buffer: g0Buffer, k: k, sigmaR: sigmaR, alpha: alpha, beta: beta)
            let gk = gaussianPyramid(encoder: encoder, resources: resources, device: device, base: remapped, levels: levels)
            let lk = laplacianPyramid(encoder: encoder, resources: resources, device: device, g: gk)
            for level in 0..<levels {
                runAccumulateWeighted(
                    encoder: encoder, resources: resources,
                    lk: lk[level], idxTex: idxTextures[level], fracTex: fracTextures[level], acc: acc[level],
                    k: k, isFirst: k == 0
                )
            }
        }

        let baseFinal = makePlaneTexture(device: device, width: g[levels].width, height: g[levels].height)
        runAddCurve(encoder: encoder, resources: resources, src: g[levels], dst: baseFinal, curveBuffer: curveBuffer)

        var lapFull = acc
        lapFull.append(baseFinal)
        return reconstruct(encoder: encoder, resources: resources, device: device, lap: lapFull)
    }

    private static func gaussianPyramid(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, device: MTLDevice,
        base: MTLTexture, levels: Int
    ) -> [MTLTexture] {
        var g = [base]
        for _ in 0..<levels {
            let previous = g[g.count - 1]
            let vBlurred = makePlaneTexture(device: device, width: previous.width, height: previous.height)
            runBlurVertical(encoder: encoder, resources: resources, src: previous, dst: vBlurred)
            let outWidth = (previous.width + 1) / 2
            let outHeight = (previous.height + 1) / 2
            let down = makePlaneTexture(device: device, width: outWidth, height: outHeight)
            runDownsampleHorizontal(encoder: encoder, resources: resources, src: vBlurred, dst: down)
            g.append(down)
        }
        return g
    }

    private static func pyrUp(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, device: MTLDevice,
        src: MTLTexture, outWidth: Int, outHeight: Int
    ) -> MTLTexture {
        let height2 = src.height * 2
        let vUp = makePlaneTexture(device: device, width: src.width, height: height2)
        runUpsampleVertical(encoder: encoder, resources: resources, src: src, dst: vUp)
        let out = makePlaneTexture(device: device, width: outWidth, height: outHeight)
        runUpsampleHorizontalScaled(encoder: encoder, resources: resources, src: vUp, dst: out)
        return out
    }

    private static func laplacianPyramid(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, device: MTLDevice, g: [MTLTexture]
    ) -> [MTLTexture] {
        var lap: [MTLTexture] = []
        lap.reserveCapacity(g.count)
        for i in 0..<(g.count - 1) {
            let up = pyrUp(encoder: encoder, resources: resources, device: device, src: g[i + 1], outWidth: g[i].width, outHeight: g[i].height)
            let diff = makePlaneTexture(device: device, width: g[i].width, height: g[i].height)
            runSubtract(encoder: encoder, resources: resources, a: g[i], b: up, out: diff)
            lap.append(diff)
        }
        lap.append(g[g.count - 1])
        return lap
    }

    private static func reconstruct(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, device: MTLDevice, lap: [MTLTexture]
    ) -> MTLTexture {
        var x = lap[lap.count - 1]
        var i = lap.count - 2
        while i >= 0 {
            let up = pyrUp(encoder: encoder, resources: resources, device: device, src: x, outWidth: lap[i].width, outHeight: lap[i].height)
            let sum = makePlaneTexture(device: device, width: lap[i].width, height: lap[i].height)
            runAdd(encoder: encoder, resources: resources, a: up, b: lap[i], out: sum)
            x = sum
            i -= 1
        }
        return x
    }

    // MARK: - Individual kernel dispatch wrappers

    private static let defaultThreadgroupSize = MTLSize(width: 16, height: 16, depth: 1)

    private static func threadgroups(width: Int, height: Int) -> MTLSize {
        MTLSize(
            width: (width + defaultThreadgroupSize.width - 1) / defaultThreadgroupSize.width,
            height: (height + defaultThreadgroupSize.height - 1) / defaultThreadgroupSize.height,
            depth: 1
        )
    }

    private static func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.dispatchThreadgroups(threadgroups(width: width, height: height), threadsPerThreadgroup: defaultThreadgroupSize)
    }

    private static func runLuminance(encoder: MTLComputeCommandEncoder, resources: MetalResources, rgba: MTLTexture, lnOut: MTLTexture) {
        encoder.setComputePipelineState(resources.pipeline("spatialLuminance"))
        encoder.setTexture(rgba, index: 0)
        encoder.setTexture(lnOut, index: 1)
        var ppLuma = SIMD4<Float>(
            Float(SpatialToneOps.ppLuma.x), Float(SpatialToneOps.ppLuma.y), Float(SpatialToneOps.ppLuma.z), 0
        )
        var epsilon = Float(SpatialToneOps.eps)
        encoder.setBytes(&ppLuma, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setBytes(&epsilon, length: MemoryLayout<Float>.size, index: 1)
        dispatch(encoder, width: lnOut.width, height: lnOut.height)
    }

    private static func runApplyRatio(
        encoder: MTLComputeCommandEncoder, resources: MetalResources,
        rgbaIn: MTLTexture, lnFinal: MTLTexture, ln0: MTLTexture, rgbaOut: MTLTexture
    ) {
        encoder.setComputePipelineState(resources.pipeline("spatialApplyRatio"))
        encoder.setTexture(rgbaIn, index: 0)
        encoder.setTexture(lnFinal, index: 1)
        encoder.setTexture(ln0, index: 2)
        encoder.setTexture(rgbaOut, index: 3)
        dispatch(encoder, width: rgbaOut.width, height: rgbaOut.height)
    }

    private static func runBlurVertical(encoder: MTLComputeCommandEncoder, resources: MetalResources, src: MTLTexture, dst: MTLTexture) {
        encoder.setComputePipelineState(resources.pipeline("spatialBlurVertical"))
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        dispatch(encoder, width: dst.width, height: dst.height)
    }

    private static func runDownsampleHorizontal(encoder: MTLComputeCommandEncoder, resources: MetalResources, src: MTLTexture, dst: MTLTexture) {
        encoder.setComputePipelineState(resources.pipeline("spatialDownsampleHorizontal"))
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        dispatch(encoder, width: dst.width, height: dst.height)
    }

    private static func runUpsampleVertical(encoder: MTLComputeCommandEncoder, resources: MetalResources, src: MTLTexture, dst: MTLTexture) {
        encoder.setComputePipelineState(resources.pipeline("spatialUpsampleVertical"))
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        dispatch(encoder, width: dst.width, height: dst.height)
    }

    private static func runUpsampleHorizontalScaled(encoder: MTLComputeCommandEncoder, resources: MetalResources, src: MTLTexture, dst: MTLTexture) {
        encoder.setComputePipelineState(resources.pipeline("spatialUpsampleHorizontalScaled"))
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        dispatch(encoder, width: dst.width, height: dst.height)
    }

    private static func runSubtract(encoder: MTLComputeCommandEncoder, resources: MetalResources, a: MTLTexture, b: MTLTexture, out: MTLTexture) {
        encoder.setComputePipelineState(resources.pipeline("spatialSubtract"))
        encoder.setTexture(a, index: 0)
        encoder.setTexture(b, index: 1)
        encoder.setTexture(out, index: 2)
        dispatch(encoder, width: out.width, height: out.height)
    }

    private static func runAdd(encoder: MTLComputeCommandEncoder, resources: MetalResources, a: MTLTexture, b: MTLTexture, out: MTLTexture) {
        encoder.setComputePipelineState(resources.pipeline("spatialAdd"))
        encoder.setTexture(a, index: 0)
        encoder.setTexture(b, index: 1)
        encoder.setTexture(out, index: 2)
        dispatch(encoder, width: out.width, height: out.height)
    }

    private static func runAddCurve(encoder: MTLComputeCommandEncoder, resources: MetalResources, src: MTLTexture, dst: MTLTexture, curveBuffer: MTLBuffer) {
        encoder.setComputePipelineState(resources.pipeline("spatialAddCurve"))
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        encoder.setBuffer(curveBuffer, offset: 0, index: 0)
        dispatch(encoder, width: dst.width, height: dst.height)
    }

    private static func runRemap(
        encoder: MTLComputeCommandEncoder, resources: MetalResources,
        ln: MTLTexture, out: MTLTexture, g0Buffer: MTLBuffer, k: Int, sigmaR: Double, alpha: Double, beta: Double
    ) {
        encoder.setComputePipelineState(resources.pipeline("spatialRemap"))
        encoder.setTexture(ln, index: 0)
        encoder.setTexture(out, index: 1)
        encoder.setBuffer(g0Buffer, offset: 0, index: 0)
        var kk = UInt32(k)
        var sigmaRF = Float(sigmaR)
        var alphaF = Float(alpha)
        var betaF = Float(beta)
        encoder.setBytes(&kk, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&sigmaRF, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&alphaF, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&betaF, length: MemoryLayout<Float>.size, index: 4)
        dispatch(encoder, width: out.width, height: out.height)
    }

    private static func runMinMaxReduceInit(encoder: MTLComputeCommandEncoder, resources: MetalResources, buffer: MTLBuffer) {
        encoder.setComputePipelineState(resources.pipeline("spatialMinMaxReduceInit"))
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    private static func runMinMaxReduce(encoder: MTLComputeCommandEncoder, resources: MetalResources, ln: MTLTexture, resultBuffer: MTLBuffer) {
        encoder.setComputePipelineState(resources.pipeline("spatialMinMaxReduce"))
        encoder.setTexture(ln, index: 0)
        encoder.setBuffer(resultBuffer, offset: 0, index: 0)
        dispatch(encoder, width: ln.width, height: ln.height)
    }

    private static func runComputeG0Grid(encoder: MTLComputeCommandEncoder, resources: MetalResources, minMaxBuffer: MTLBuffer, g0Buffer: MTLBuffer, n: Int) {
        encoder.setComputePipelineState(resources.pipeline("spatialComputeG0Grid"))
        encoder.setBuffer(minMaxBuffer, offset: 0, index: 0)
        encoder.setBuffer(g0Buffer, offset: 0, index: 1)
        var nn = UInt32(n)
        encoder.setBytes(&nn, length: MemoryLayout<UInt32>.size, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    private static func runComputeBracket(
        encoder: MTLComputeCommandEncoder, resources: MetalResources,
        g: MTLTexture, idxOut: MTLTexture, fracOut: MTLTexture, g0Buffer: MTLBuffer, n: Int
    ) {
        encoder.setComputePipelineState(resources.pipeline("spatialComputeBracket"))
        encoder.setTexture(g, index: 0)
        encoder.setTexture(idxOut, index: 1)
        encoder.setTexture(fracOut, index: 2)
        encoder.setBuffer(g0Buffer, offset: 0, index: 0)
        var nn = UInt32(n)
        encoder.setBytes(&nn, length: MemoryLayout<UInt32>.size, index: 1)
        dispatch(encoder, width: g.width, height: g.height)
    }

    private static func runAccumulateWeighted(
        encoder: MTLComputeCommandEncoder, resources: MetalResources,
        lk: MTLTexture, idxTex: MTLTexture, fracTex: MTLTexture, acc: MTLTexture, k: Int, isFirst: Bool
    ) {
        encoder.setComputePipelineState(resources.pipeline("spatialAccumulateWeighted"))
        encoder.setTexture(lk, index: 0)
        encoder.setTexture(idxTex, index: 1)
        encoder.setTexture(fracTex, index: 2)
        encoder.setTexture(acc, index: 3)
        var kk = UInt32(k)
        var first: UInt32 = isFirst ? 1 : 0
        encoder.setBytes(&kk, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.setBytes(&first, length: MemoryLayout<UInt32>.size, index: 1)
        dispatch(encoder, width: acc.width, height: acc.height)
    }

    // MARK: - Resource allocation

    private static func makePlaneTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: max(width, 1), height: max(height, 1), mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            preconditionFailure("SpatialToneProcessor: failed to allocate a \(width)x\(height) r32Float plane texture")
        }
        return texture
    }

    private static func makeRGBATexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: max(width, 1), height: max(height, 1), mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            preconditionFailure("SpatialToneProcessor: failed to allocate a \(width)x\(height) rgba32Float scratch texture")
        }
        return texture
    }

    private static func makeCurveBuffer(device: MTLDevice, values: [Double]) -> MTLBuffer {
        var floats = values.map { Float($0) }
        guard let buffer = device.makeBuffer(bytes: &floats, length: MemoryLayout<Float>.size * floats.count, options: .storageModeShared) else {
            preconditionFailure("SpatialToneProcessor: failed to allocate a \(floats.count)-entry curve buffer")
        }
        return buffer
    }

    private static func makeMinMaxBuffer(device: MTLDevice) -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: MemoryLayout<UInt32>.size * 2, options: .storageModeShared) else {
            preconditionFailure("SpatialToneProcessor: failed to allocate the min/max reduction buffer")
        }
        return buffer
    }

    private static func makeG0Buffer(device: MTLDevice, count: Int) -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: MemoryLayout<Float>.size * count, options: .storageModeShared) else {
            preconditionFailure("SpatialToneProcessor: failed to allocate the \(count)-entry g0Grid buffer")
        }
        return buffer
    }

    // MARK: - Per-device compiled pipeline cache

    private final class MetalResources {
        let device: MTLDevice
        private let pipelineStates: [String: MTLComputePipelineState]

        init(device: MTLDevice) throws {
            self.device = device
            let library = try device.makeLibrary(source: SpatialToneMetalSource.source, options: nil)
            var built: [String: MTLComputePipelineState] = [:]
            for name in SpatialToneMetalSource.functionNames {
                guard let function = library.makeFunction(name: name) else {
                    throw ProcessorError.pipelineCreationFailed(name)
                }
                built[name] = try device.makeComputePipelineState(function: function)
            }
            self.pipelineStates = built
        }

        func pipeline(_ name: String) -> MTLComputePipelineState {
            guard let state = pipelineStates[name] else {
                preconditionFailure("SpatialToneProcessor: missing compiled pipeline \(name)")
            }
            return state
        }
    }

    private static let resourceCacheLock = NSLock()
    nonisolated(unsafe) private static var resourceCache: [ObjectIdentifier: MetalResources] = [:]

    private static func metalResources(for device: MTLDevice) throws -> MetalResources {
        resourceCacheLock.lock()
        defer { resourceCacheLock.unlock() }
        let key = ObjectIdentifier(device)
        if let cached = resourceCache[key] { return cached }
        let created = try MetalResources(device: device)
        resourceCache[key] = created
        return created
    }
}

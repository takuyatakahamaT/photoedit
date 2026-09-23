import CoreImage
import Foundation
import Metal

/// GPU (explicit Metal compute, driven by a manually managed
/// `MTLCommandBuffer`) implementation of `SpatialToneOps.
/// applyHighlightsShadows`, plus a CPU-buffer fallback for systems with no
/// Metal device.
///
/// Every dispatch mirrors `SpatialToneOps`/`SpatialToneMetalSource`'s doc
/// comments 1:1; this file is purely the Swift-side orchestration (texture
/// allocation/pooling, dispatch order, and the explicit GPU round trip
/// around those kernels).
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
/// `BasicToneModel` CIKernel had, and `SpatialToneOpsTests` exercises it.
///
/// **Why this is not a `CIImageProcessorKernel` subclass (it was, twice,
/// during this feature's development -- see git history for the full
/// story)**: a custom kernel's `roi(forInput:arguments:outputRect:)` must
/// answer, for the coarsest pyramid levels and Shadows' whole-image min/max,
/// "the whole input" regardless of `outputRect`. Returning `.infinite` for
/// that turned out to silently never invoke `process(with:...)` at all
/// whenever the input traced back through `CIGammaAdjust`/`CIColorCube`
/// (which every real caller's input does -- Stage H/L/T for RAW, cube
/// P/P1/P2/Q). Returning the input's own *exact finite* extent instead
/// fixed that -- but for a large image, Core Image tiles the *output*, and
/// because this kernel's `roi` always demands the whole input for any tile,
/// Core Image re-evaluated the *entire upstream graph* (every DCP cube) once
/// per output tile, then this kernel's own (many-dispatch) pyramid
/// computation on top of that, per tile -- dozens of full-image
/// recomputations for one `apply()` call, observed as `process(with:...)`
/// called dozens of times and multi-minute renders on a full-resolution
/// photo. Neither fix is usable, so this type does its own single, explicit
/// GPU round trip instead: `CIContext.render(_:to:MTLTexture:commandBuffer:
/// bounds:colorSpace:)` renders the whole input into one texture exactly
/// once, this file's own compute dispatches run on that texture in the same
/// command buffer, and the result is wrapped back into a `CIImage` with
/// `CIImage(mtlTexture:options:)` -- no custom kernel, no `roi`, no tiling
/// decision for Core Image to make about this stage at all.
///
/// Preview responsiveness (owner-reported: RAW Shadows/Highlights sliders
/// felt sluggish while dragging, even though the CLI-measured *effect size*
/// already matches Lightroom): `.interactive` trades a coarser Shadows
/// discretization sweep (`n_disc` 10 -> 5; Highlights/Texture/Clarity
/// unaffected -- Highlights takes the `alpha==beta==1` fast path, which
/// never runs this sweep at all) for a cheaper `apply()` call during a
/// slider drag. No formula or other constant changes -- only this one
/// sampling-density knob. `RenderEngine`'s preview path resolves
/// `.interactive`; export/CLI always resolve `.final` (the default, so
/// every pre-existing call site keeps its exact prior behavior unchanged).
public enum SpatialToneQuality: Sendable, Equatable, Hashable {
    case interactive
    case final

    /// Shadows' `applySingleOpLLF`/GPU `applySingleOpLLF`'s `nDisc` --
    /// Highlights never reads this (fast path), Texture/Clarity don't use
    /// discretization at all.
    var shadowsDiscretizationCount: Int {
        switch self {
        case .interactive: return 5
        case .final: return 10
        }
    }
}

public enum SpatialToneProcessor {
    enum ProcessorError: Error {
        case deviceUnavailable
        case commandBufferCreationFailed
        case pipelineCreationFailed(String)
        case commandBufferFailed(String)
        case outputConstructionFailed
    }

    // MARK: - Public entry point

    /// `PHOTO_BENCH_SPATIAL_DIAG=1` prints, to stderr, this call's index and
    /// wall time (encoding + GPU execution) in milliseconds -- for
    /// `photobench-render`/manual profiling, not routine use.
    private static let diagnosticsEnabled = ProcessInfo.processInfo.environment["PHOTO_BENCH_SPATIAL_DIAG"] != nil
    /// `PHOTO_BENCH_SPATIAL_DIAG=2` (a superset of `=1`'s per-call total-time
    /// line): also prints one `applyGPU` call's stage breakdown -- encode
    /// (Swift-side command-buffer building), `waitUntilCompleted` wait, GPU
    /// execution (`MTLCommandBuffer.gpuStartTime`/`gpuEndTime`, only valid
    /// once the buffer has completed), and total dispatch count. Added to
    /// profile the owner-reported "apply() is ~200-350ms and barely moves
    /// with resolution" sluggishness -- dispatch *count* (not per-pixel
    /// work) was the suspected dominant cost; this is how that was measured.
    private static let verboseDiagnosticsEnabled = ProcessInfo.processInfo.environment["PHOTO_BENCH_SPATIAL_DIAG"] == "2"

    private static let diagnosticsLock = NSLock()
    nonisolated(unsafe) private static var applyCallCount = 0
    nonisolated(unsafe) private static var gpuCallCount = 0
    nonisolated(unsafe) private static var cpuFallbackCallCount = 0
    /// One `applyGPU` call's dispatch count, valid only for `=2` profiling of
    /// a single sequential call -- like `applyCallCount` etc. above, a global
    /// counter under `diagnosticsLock`, reset at the start of each `applyGPU`
    /// call and read at its end. Concurrent `apply()` calls (from different
    /// threads/photos) would interleave and give a meaningless count for
    /// each; this feature is for deliberate, sequential profiling runs
    /// (`photobench-render`), not routine concurrent production use.
    nonisolated(unsafe) private static var currentDispatchCount = 0

    private static func countDispatch() {
        guard verboseDiagnosticsEnabled else { return }
        diagnosticsLock.lock(); currentDispatchCount += 1; diagnosticsLock.unlock()
    }

    /// Exposed for tests (and manual diagnostics) to confirm how many times
    /// `apply(to:...)` actually ran, and via which path.
    public static func resetDiagnostics() {
        diagnosticsLock.lock()
        applyCallCount = 0
        gpuCallCount = 0
        cpuFallbackCallCount = 0
        diagnosticsLock.unlock()
    }

    public static var diagnosticsSnapshot: (total: Int, metal: Int, cpu: Int) {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return (applyCallCount, gpuCallCount, cpuFallbackCallCount)
    }

    /// `scalePx` should already be `SpatialToneOps.scalePx(forLongEdge:)` of
    /// the image `image` is (the caller's own long edge, at whatever
    /// resolution it is actually processing). `texture`/`clarity` (Phase2
    /// C4) default to `0` so pre-C4 call sites keep compiling unchanged; see
    /// `SpatialToneOps.applyHighlightsShadows`'s doc comment for why
    /// chaining all four into one `Ln` pass with a single final ratio is
    /// exact, not an approximation.
    public static func apply(
        to image: CIImage, highlights: Double, shadows: Double, scalePx: Double,
        texture: Double = 0, clarity: Double = 0, gainScale: SpatialGainScale = .identity, shift: SpatialShift = .zero,
        quality: SpatialToneQuality = .final
    ) throws -> CIImage {
        diagnosticsLock.lock()
        applyCallCount += 1
        let callIndex = applyCallCount
        diagnosticsLock.unlock()
        let startTime = diagnosticsEnabled ? DispatchTime.now() : nil
        defer {
            if let startTime {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000
                FileHandle.standardError.write(Data(
                    "SpatialToneProcessor.apply #\(callIndex): \(String(format: "%.2f", elapsedMs))ms\n".utf8
                ))
            }
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            diagnosticsLock.lock(); cpuFallbackCallCount += 1; diagnosticsLock.unlock()
            return try applyCPUFallback(
                to: image, highlights: highlights, shadows: shadows, scalePx: scalePx, texture: texture, clarity: clarity,
                gainScale: gainScale, shift: shift, quality: quality
            )
        }
        diagnosticsLock.lock(); gpuCallCount += 1; diagnosticsLock.unlock()
        return try applyGPU(
            device: device, to: image, highlights: highlights, shadows: shadows, scalePx: scalePx,
            texture: texture, clarity: clarity, gainScale: gainScale, shift: shift, quality: quality
        )
    }

    // MARK: - GPU path: one explicit command buffer, no custom kernel

    /// Vertical orientation between `CIContext.render(_:to:MTLTexture:...)`
    /// (write) and `CIImage(mtlTexture:options:)` (read) -- verified by
    /// `SpatialToneOpsTests.gpuRoundTripPreservesVerticalOrientation` with a
    /// top-bright/bottom-dark asymmetric fixture run through an identity
    /// (`highlights: 0, shadows: 0`) call, which still exercises this whole
    /// round trip (there is no early-return shortcut for that case). Flip
    /// this if that test ever needs it on a different OS/hardware; measured
    /// `false` (no flip needed) on this configuration.
    static let needsVerticalFlipAfterRoundTrip = false

    private static func applyGPU(
        device: MTLDevice, to image: CIImage, highlights: Double, shadows: Double, scalePx: Double,
        texture: Double, clarity: Double, gainScale: SpatialGainScale, shift: SpatialShift,
        quality: SpatialToneQuality = .final
    ) throws -> CIImage {
        let resources = try metalResources(for: device)

        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            return image
        }
        let width = Int(extent.width)
        let height = Int(extent.height)

        guard let commandBuffer = resources.commandQueue.makeCommandBuffer() else {
            throw ProcessorError.commandBufferCreationFailed
        }
        commandBuffer.label = "SpatialToneProcessor.apply"

        let allocator = TextureAllocator(device: device)
        // The single explicit GPU round trip: render the whole (possibly
        // cube-chained) input CIImage graph into one texture, once, in this
        // same command buffer. `.shaderWrite` is required here even though
        // this file never itself writes to `inputTexture` via compute --
        // without it, `CIContext.render(to:MTLTexture:)` silently leaves the
        // texture untouched (no thrown error, no `commandBuffer.error`; it
        // just never actually renders), because Core Image's own internal
        // Metal pipeline apparently needs compute-shader write access to its
        // destination for at least part of what it does. Found by a minimal
        // repro (`/tmp/probe2.swift`-style standalone script) after this
        // exact omission made every pixel of every render come back as
        // whatever garbage was already in the freshly allocated `.private`
        // texture (observed as all-zero in isolation, and as NaN once fed
        // through `log2` in this file's own luminance kernel) --
        // `SpatialToneOpsTests.gpuRoundTripPreservesVerticalOrientation`
        // guards against this regressing silently again.
        let inputTexture = allocator.track(checkoutTexture(
            device: device, width: width, height: height, format: .rgba32Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget]
        ))
        // `CIContext.render(_:to:MTLTexture:...)` requires a concrete
        // `CGColorSpace` (unlike the `toBitmap:` variant, there is no `nil`/
        // "no color management" overload for a texture destination).
        // `.extendedLinearSRGB` is this codebase's established "generic
        // wide-range linear container, no gamut conversion intended" tag
        // (matching `RenderEngine`'s own `.workingColorSpace` and
        // `PhotoBenchRender`'s stage-debug TIFF dump) -- verified numerically
        // unchanged by `SpatialToneOpsTests`' fixture/GPU-parity tests.
        resources.ciContext.render(
            image, to: inputTexture, commandBuffer: commandBuffer, bounds: extent, colorSpace: resources.numericPassthroughColorSpace
        )

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ProcessorError.commandBufferCreationFailed
        }
        encoder.label = "SpatialToneProcessor.compute"

        if verboseDiagnosticsEnabled {
            diagnosticsLock.lock(); currentDispatchCount = 0; diagnosticsLock.unlock()
        }
        let encodeStartTime = verboseDiagnosticsEnabled ? DispatchTime.now() : nil

        let ln0 = allocator.plane(width: width, height: height)
        runLuminance(encoder: encoder, resources: resources, rgba: inputTexture, lnOut: ln0)

        let levelsH = max(1, Int(log2(max(scalePx, 2.0)).rounded(.toNearestOrEven)))
        var currentLn = ln0

        if highlights != 0 {
            let curveBuffer = makeCurveBuffer(device: device, values: SpatialToneOps.highlightsGainCurve(highlights, scale: gainScale))
            currentLn = applySingleOpLLF(
                encoder: encoder, resources: resources, allocator: allocator,
                ln: currentLn, curveBuffer: curveBuffer,
                alpha: SpatialToneOps.highlightsParams.alpha,
                beta: SpatialToneOps.highlightsParams.beta,
                sigmaR: SpatialToneOps.highlightsParams.sigmaR,
                levels: levelsH, shift: shift.highlights
            )
        }
        if shadows != 0 {
            let levelsS = max(1, levelsH + SpatialToneOps.shadowsLevelsOffset)
            let curveBuffer = makeCurveBuffer(device: device, values: SpatialToneOps.shadowsGainCurve(shadows, scale: gainScale))
            currentLn = applySingleOpLLF(
                encoder: encoder, resources: resources, allocator: allocator,
                ln: currentLn, curveBuffer: curveBuffer,
                alpha: SpatialToneOps.shadowsParams.alpha,
                beta: SpatialToneOps.shadowsParams.beta,
                sigmaR: SpatialToneOps.shadowsParams.sigmaR,
                levels: levelsS, nDisc: quality.shadowsDiscretizationCount, shift: shift.shadows
            )
        }
        if texture != 0 {
            let gains = SpatialToneOps.gainProfile(
                amount: texture, pos: SpatialToneOps.textureGain60Pos, neg: SpatialToneOps.textureGain60Neg, levelsTotal: levelsH
            )
            currentLn = applyMultiscaleGainGPU(encoder: encoder, resources: resources, allocator: allocator, ln: currentLn, gains: gains)
        }
        if clarity != 0 {
            let levelsC = levelsH + SpatialToneOps.clarityLevelOffset
            let gains = SpatialToneOps.gainProfile(
                amount: clarity, pos: SpatialToneOps.clarityGain60Pos, neg: SpatialToneOps.clarityGain60Neg, levelsTotal: levelsC
            )
            currentLn = applyMultiscaleGainGPU(encoder: encoder, resources: resources, allocator: allocator, ln: currentLn, gains: gains)
        }

        // Not pooled: this texture escapes into the returned `CIImage` and
        // its lifetime passes to Core Image/ARC, unlike every intermediate
        // above (all fully consumed by the time `waitUntilCompleted`
        // returns, and safe to recycle from that point on).
        let outputTexture = makeRGBATexture(device: device, width: width, height: height)
        runApplyRatio(encoder: encoder, resources: resources, rgbaIn: inputTexture, lnFinal: currentLn, ln0: ln0, rgbaOut: outputTexture)

        encoder.endEncoding()
        let encodeEndTime = verboseDiagnosticsEnabled ? DispatchTime.now() : nil
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let waitEndTime = verboseDiagnosticsEnabled ? DispatchTime.now() : nil
        checkinTextures(allocator.allocated)

        if let error = commandBuffer.error {
            throw ProcessorError.commandBufferFailed(String(describing: error))
        }

        if verboseDiagnosticsEnabled, let encodeStartTime, let encodeEndTime, let waitEndTime {
            let encodeMs = Double(encodeEndTime.uptimeNanoseconds &- encodeStartTime.uptimeNanoseconds) / 1_000_000
            let waitMs = Double(waitEndTime.uptimeNanoseconds &- encodeEndTime.uptimeNanoseconds) / 1_000_000
            // `gpuStartTime`/`gpuEndTime` are `CFTimeInterval` (seconds since
            // an unspecified epoch, monotonic only relative to each other) --
            // only their *difference* is meaningful, not either value alone.
            let gpuMs = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
            diagnosticsLock.lock()
            let dispatches = currentDispatchCount
            diagnosticsLock.unlock()
            let message = "SpatialToneProcessor.applyGPU breakdown: encode=\(String(format: "%.2f", encodeMs))ms "
                + "wait=\(String(format: "%.2f", waitMs))ms gpu=\(String(format: "%.2f", gpuMs))ms "
                + "dispatches=\(dispatches)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        guard var output = CIImage(mtlTexture: outputTexture, options: [.colorSpace: NSNull()]) else {
            throw ProcessorError.outputConstructionFailed
        }
        if needsVerticalFlipAfterRoundTrip {
            output = output.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
        }
        if extent.origin != .zero {
            output = output.transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
        }
        return output
    }

    /// `SpatialToneOps.applySingleOpLLF`'s GPU counterpart: identical
    /// structure (fast identity-remap path for `alpha == beta == 1`,
    /// otherwise the `n_disc`-point discretized sweep), just issuing Metal
    /// dispatches into `encoder` instead of looping over `Double` arrays.
    private static func applySingleOpLLF(
        encoder: MTLComputeCommandEncoder,
        resources: MetalResources,
        allocator: TextureAllocator,
        ln: MTLTexture,
        curveBuffer: MTLBuffer,
        alpha: Double,
        beta: Double,
        sigmaR: Double,
        levels: Int,
        nDisc: Int = 10,
        shift: Double = 0
    ) -> MTLTexture {
        let g = gaussianPyramid(encoder: encoder, resources: resources, allocator: allocator, base: ln, levels: levels)

        if alpha == 1.0 && beta == 1.0 {
            var lap = laplacianPyramid(encoder: encoder, resources: resources, allocator: allocator, g: g)
            let lastIndex = lap.count - 1
            let newBase = allocator.plane(width: lap[lastIndex].width, height: lap[lastIndex].height)
            runAddCurve(encoder: encoder, resources: resources, src: lap[lastIndex], dst: newBase, curveBuffer: curveBuffer, shift: shift)
            lap[lastIndex] = newBase
            return reconstruct(encoder: encoder, resources: resources, allocator: allocator, lap: lap)
        }

        // Shadows: the whole-image min/max, the g0 discretization grid, and
        // every per-level bracket/weight all stay on the GPU -- there is no
        // CPU round trip between them (see `SpatialToneMetalSource`'s
        // `spatialComputeG0Grid` doc comment).
        let minMaxBuffer = makeMinMaxBuffer(device: allocator.device)
        runMinMaxReduceInit(encoder: encoder, resources: resources, buffer: minMaxBuffer)
        runMinMaxReduce(encoder: encoder, resources: resources, ln: ln, resultBuffer: minMaxBuffer)

        let n = nDisc
        let g0Buffer = makeG0Buffer(device: allocator.device, count: n)
        runComputeG0Grid(encoder: encoder, resources: resources, minMaxBuffer: minMaxBuffer, g0Buffer: g0Buffer, n: n)

        var idxTextures: [MTLTexture] = []
        var fracTextures: [MTLTexture] = []
        for level in 0..<levels {
            let idxTex = allocator.plane(width: g[level].width, height: g[level].height)
            let fracTex = allocator.plane(width: g[level].width, height: g[level].height)
            runComputeBracket(encoder: encoder, resources: resources, g: g[level], idxOut: idxTex, fracOut: fracTex, g0Buffer: g0Buffer, n: n)
            idxTextures.append(idxTex)
            fracTextures.append(fracTex)
        }

        let acc: [MTLTexture] = (0..<levels).map { allocator.plane(width: g[$0].width, height: g[$0].height) }

        for k in 0..<n {
            let remapped = allocator.plane(width: ln.width, height: ln.height)
            runRemap(encoder: encoder, resources: resources, ln: ln, out: remapped, g0Buffer: g0Buffer, k: k, sigmaR: sigmaR, alpha: alpha, beta: beta)
            let gk = gaussianPyramid(encoder: encoder, resources: resources, allocator: allocator, base: remapped, levels: levels)
            let lk = laplacianPyramid(encoder: encoder, resources: resources, allocator: allocator, g: gk)
            for level in 0..<levels {
                runAccumulateWeighted(
                    encoder: encoder, resources: resources,
                    lk: lk[level], idxTex: idxTextures[level], fracTex: fracTextures[level], acc: acc[level],
                    k: k, isFirst: k == 0
                )
            }
        }

        let baseFinal = allocator.plane(width: g[levels].width, height: g[levels].height)
        runAddCurve(encoder: encoder, resources: resources, src: g[levels], dst: baseFinal, curveBuffer: curveBuffer, shift: shift)

        var lapFull = acc
        lapFull.append(baseFinal)
        return reconstruct(encoder: encoder, resources: resources, allocator: allocator, lap: lapFull)
    }

    /// `SpatialToneOps.applyMultiscaleGain`'s GPU counterpart (Phase2 C4
    /// Texture/Clarity2012 "Model L"): a purely linear filter, no remap or
    /// discretization sweep -- reuses the exact same `gaussianPyramid`/
    /// `laplacianPyramid`/`reconstruct` helpers Highlights/Shadows use, with
    /// one new primitive (`spatialMultiplyScalar`) multiplying each band
    /// (every detail level **and** the coarsest base) by its own gain.
    private static func applyMultiscaleGainGPU(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, allocator: TextureAllocator,
        ln: MTLTexture, gains: [Double]
    ) -> MTLTexture {
        let levels = gains.count - 1
        guard levels > 0 else { return ln }
        let g = gaussianPyramid(encoder: encoder, resources: resources, allocator: allocator, base: ln, levels: levels)
        var lap = laplacianPyramid(encoder: encoder, resources: resources, allocator: allocator, g: g)
        for i in 0..<lap.count {
            let scaled = allocator.plane(width: lap[i].width, height: lap[i].height)
            runMultiplyScalar(encoder: encoder, resources: resources, src: lap[i], dst: scaled, scalar: gains[i])
            lap[i] = scaled
        }
        return reconstruct(encoder: encoder, resources: resources, allocator: allocator, lap: lap)
    }

    /// Kept as separate vertical-blur + horizontal-blur-and-downsample
    /// dispatches -- see `SpatialToneMetalSource.spatialBlurVertical`'s doc
    /// comment for why a fused single-dispatch version measured *slower*.
    private static func gaussianPyramid(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, allocator: TextureAllocator,
        base: MTLTexture, levels: Int
    ) -> [MTLTexture] {
        var g = [base]
        for _ in 0..<levels {
            let previous = g[g.count - 1]
            let vBlurred = allocator.plane(width: previous.width, height: previous.height)
            runBlurVertical(encoder: encoder, resources: resources, src: previous, dst: vBlurred)
            let outWidth = (previous.width + 1) / 2
            let outHeight = (previous.height + 1) / 2
            let down = allocator.plane(width: outWidth, height: outHeight)
            runDownsampleHorizontal(encoder: encoder, resources: resources, src: vBlurred, dst: down)
            g.append(down)
        }
        return g
    }

    private static func pyrUp(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, allocator: TextureAllocator,
        src: MTLTexture, outWidth: Int, outHeight: Int
    ) -> MTLTexture {
        let height2 = src.height * 2
        let vUp = allocator.plane(width: src.width, height: height2)
        runUpsampleVertical(encoder: encoder, resources: resources, src: src, dst: vUp)
        let out = allocator.plane(width: outWidth, height: outHeight)
        runUpsampleHorizontalScaled(encoder: encoder, resources: resources, src: vUp, dst: out)
        return out
    }

    private static func laplacianPyramid(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, allocator: TextureAllocator, g: [MTLTexture]
    ) -> [MTLTexture] {
        var lap: [MTLTexture] = []
        lap.reserveCapacity(g.count)
        for i in 0..<(g.count - 1) {
            let up = pyrUp(encoder: encoder, resources: resources, allocator: allocator, src: g[i + 1], outWidth: g[i].width, outHeight: g[i].height)
            let diff = allocator.plane(width: g[i].width, height: g[i].height)
            runSubtract(encoder: encoder, resources: resources, a: g[i], b: up, out: diff)
            lap.append(diff)
        }
        lap.append(g[g.count - 1])
        return lap
    }

    private static func reconstruct(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, allocator: TextureAllocator, lap: [MTLTexture]
    ) -> MTLTexture {
        var x = lap[lap.count - 1]
        var i = lap.count - 2
        while i >= 0 {
            let up = pyrUp(encoder: encoder, resources: resources, allocator: allocator, src: x, outWidth: lap[i].width, outHeight: lap[i].height)
            let sum = allocator.plane(width: lap[i].width, height: lap[i].height)
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
        countDispatch()
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

    private static func runAddCurve(
        encoder: MTLComputeCommandEncoder, resources: MetalResources, src: MTLTexture, dst: MTLTexture,
        curveBuffer: MTLBuffer, shift: Double = 0
    ) {
        encoder.setComputePipelineState(resources.pipeline("spatialAddCurve"))
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        encoder.setBuffer(curveBuffer, offset: 0, index: 0)
        var shiftF = Float(shift)
        encoder.setBytes(&shiftF, length: MemoryLayout<Float>.size, index: 1)
        dispatch(encoder, width: dst.width, height: dst.height)
    }

    private static func runMultiplyScalar(encoder: MTLComputeCommandEncoder, resources: MetalResources, src: MTLTexture, dst: MTLTexture, scalar: Double) {
        encoder.setComputePipelineState(resources.pipeline("spatialMultiplyScalar"))
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        var scalarF = Float(scalar)
        encoder.setBytes(&scalarF, length: MemoryLayout<Float>.size, index: 0)
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
        countDispatch()
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
        countDispatch()
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

    // MARK: - CPU fallback (no Metal device)

    /// Only reached when `MTLCreateSystemDefaultDevice()` returns `nil`.
    /// Renders the whole (possibly cube-chained) input graph to a CPU
    /// buffer once, delegates to the already-fixture-tested `SpatialToneOps`
    /// directly, and rebuilds a fresh `CIImage` -- the same shape as the GPU
    /// path's single round trip, just entirely on the CPU.
    private static func applyCPUFallback(
        to image: CIImage, highlights: Double, shadows: Double, scalePx: Double,
        texture: Double = 0, clarity: Double = 0, gainScale: SpatialGainScale = .identity, shift: SpatialShift = .zero,
        quality: SpatialToneQuality = .final
    ) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            return image
        }
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            throw ProcessorError.outputConstructionFailed
        }

        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        var inputBuffer = [Float](repeating: 0, count: width * height * 4)
        cpuFallbackContext.render(
            image, toBitmap: &inputBuffer, rowBytes: bytesPerRow, bounds: extent, format: .RGBAf, colorSpace: colorSpace
        )

        var outputBuffer = [Float](repeating: 0, count: width * height * 4)
        try inputBuffer.withUnsafeBytes { inRaw in
            try outputBuffer.withUnsafeMutableBytes { outRaw in
                try processCPUBuffers(
                    inputBase: inRaw.baseAddress!, inputBytesPerRow: bytesPerRow, inputWidth: width, inputHeight: height,
                    outputBase: outRaw.baseAddress!, outputBytesPerRow: bytesPerRow,
                    outputWidth: width, outputHeight: height, offsetX: 0, offsetY: 0,
                    highlights: highlights, shadows: shadows, scalePx: scalePx, texture: texture, clarity: clarity,
                    gainScale: gainScale, shift: shift, quality: quality
                )
            }
        }

        let data = outputBuffer.withUnsafeBytes { Data($0) }
        var output = CIImage(
            bitmapData: data, bytesPerRow: bytesPerRow,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )
        if extent.origin != .zero {
            output = output.transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
        }
        return output
    }

    private static let cpuFallbackContext = CIContext(options: [.cacheIntermediates: false])

    /// The actual buffer marshaling `applyCPUFallback` delegates to (RGBAf,
    /// premultiplied, row-major, 4 floats/pixel) -- split out so it is
    /// directly unit-testable with hand-built buffers (`SpatialToneOpsTests`
    /// exercises alpha handling and the general offset/window logic this
    /// way, independent of whatever full-image or tiled shape a caller
    /// passes; `applyCPUFallback` itself always calls it with
    /// `offsetX == offsetY == 0` and matching input/output dimensions, since
    /// there is no tiling concept left in this design).
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
        scalePx: Double,
        texture: Double = 0,
        clarity: Double = 0,
        gainScale: SpatialGainScale = .identity, shift: SpatialShift = .zero,
        quality: SpatialToneQuality = .final
    ) throws {
        guard inputWidth > 0, inputHeight > 0 else { throw ProcessorError.outputConstructionFailed }
        guard offsetX >= 0, offsetY >= 0,
              offsetX + outputWidth <= inputWidth, offsetY + outputHeight <= inputHeight
        else {
            throw ProcessorError.outputConstructionFailed
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
            highlights: highlights, shadows: shadows, scalePx: scalePx, texture: texture, clarity: clarity,
            gainScale: gainScale, shift: shift, quality: quality
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

    // MARK: - Texture allocation and pooling

    /// Collects every texture allocated while building one `apply()` call's
    /// GPU graph, so they can all be returned to the pool in bulk once
    /// `waitUntilCompleted()` confirms nothing on the GPU is still
    /// reading/writing them. Not thread-safe by itself (one instance per
    /// `apply()` call, used only from that call's thread); the pool it
    /// checks in/out of is what needs (and has) its own lock.
    private final class TextureAllocator {
        let device: MTLDevice
        private(set) var allocated: [MTLTexture] = []

        init(device: MTLDevice) {
            self.device = device
        }

        @discardableResult
        func track(_ texture: MTLTexture) -> MTLTexture {
            allocated.append(texture)
            return texture
        }

        func plane(width: Int, height: Int) -> MTLTexture {
            track(SpatialToneProcessor.checkoutTexture(
                device: device, width: width, height: height, format: .r32Float, usage: [.shaderRead, .shaderWrite]
            ))
        }
    }

    private struct TextureKey: Hashable {
        let width: Int
        let height: Int
        let format: MTLPixelFormat
    }

    private static let texturePoolLock = NSLock()
    nonisolated(unsafe) private static var texturePool: [TextureKey: [MTLTexture]] = [:]

    /// Reuses a pooled texture of the exact same `(width, height, format)`
    /// if one is free, else allocates a fresh one. Every texture that ever
    /// enters the pool was created with the same `usage` for that
    /// `(width, height, format)` key in practice (`.r32Float` intermediates
    /// via `TextureAllocator.plane`; `.rgba32Float` *input* textures here --
    /// the *output* texture is deliberately never pooled, see `applyGPU`),
    /// so a pooled hit's usage always matches what the caller needs.
    private static func checkoutTexture(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture {
        let key = TextureKey(width: max(width, 1), height: max(height, 1), format: format)
        texturePoolLock.lock()
        if var bucket = texturePool[key], let texture = bucket.popLast() {
            texturePool[key] = bucket
            texturePoolLock.unlock()
            return texture
        }
        texturePoolLock.unlock()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: key.width, height: key.height, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            preconditionFailure("SpatialToneProcessor: failed to allocate a \(key.width)x\(key.height) texture (format \(format.rawValue))")
        }
        return texture
    }

    private static func checkinTextures(_ textures: [MTLTexture]) {
        texturePoolLock.lock()
        for texture in textures {
            let key = TextureKey(width: texture.width, height: texture.height, format: texture.pixelFormat)
            texturePool[key, default: []].append(texture)
        }
        texturePoolLock.unlock()
    }

    /// Test-only escape hatch: pooled textures are keyed only by size/format,
    /// so a stale texture from an earlier, differently-shaped test can in
    /// principle be handed back out. Production never needs this (the pool
    /// is a pure performance optimization, not a correctness dependency).
    static func clearTexturePoolForTesting() {
        texturePoolLock.lock()
        texturePool.removeAll()
        texturePoolLock.unlock()
    }

    private static func makeRGBATexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: max(width, 1), height: max(height, 1), mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            preconditionFailure("SpatialToneProcessor: failed to allocate a \(width)x\(height) rgba32Float output texture")
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

    // MARK: - Per-device compiled pipeline / command queue / CIContext cache

    private final class MetalResources {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        /// Dedicated to this file's one `CIContext.render(_:to:MTLTexture:
        /// commandBuffer:bounds:colorSpace:)` call -- `.cacheIntermediates:
        /// false` since each render is a one-shot materialization, never
        /// revisited.
        let ciContext: CIContext
        let numericPassthroughColorSpace: CGColorSpace
        private let pipelineStates: [String: MTLComputePipelineState]

        init(device: MTLDevice) throws {
            self.device = device
            guard let commandQueue = device.makeCommandQueue() else {
                throw ProcessorError.commandBufferCreationFailed
            }
            self.commandQueue = commandQueue
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
                throw ProcessorError.commandBufferCreationFailed
            }
            self.numericPassthroughColorSpace = colorSpace

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

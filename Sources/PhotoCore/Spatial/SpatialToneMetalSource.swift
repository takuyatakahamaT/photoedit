import Foundation

/// The Metal Shading Language source for `SpatialToneProcessor`'s GPU path,
/// compiled at runtime (`MTLDevice.makeLibrary(source:options:)`, cached per
/// device by `SpatialToneProcessor`) rather than through SwiftPM's `.metal`
/// -> metallib build step -- matching how this module's existing `CIKernel`s
/// (`BasicToneModel`, `ToneCurveModel`, `SRGBOutputTransform`) are all
/// runtime-compiled from a Swift string constant, just via raw Metal compute
/// instead of the Core Image Kernel Language.
///
/// Every kernel here mirrors one piece of `SpatialToneOps`'s CPU port of
/// `spatial_model_v2.py` 1:1 (see that file's doc comments for the Python
/// line each one corresponds to), with two pure algebraic fusions that keep
/// the *exact* same math while avoiding materializing an intermediate
/// texture Python computes for free with a broadcasted `numpy` expression:
///   - `spatialDownsampleHorizontal` fuses `_pyr_down`'s horizontal blur with
///     its `[::2]` column subsampling (only the kept columns are ever
///     computed).
///   - `spatialUpsampleVertical`/`spatialUpsampleHorizontalScaled` fuse
///     `_pyr_up`'s zero-insertion into each blur pass (a zero-inserted
///     sample contributes exactly zero to the blur sum, so it is simply
///     skipped rather than written and read back).
enum SpatialToneMetalSource {
    /// Every `kernel void` entry point below, in the order
    /// `SpatialToneProcessor` looks them up and builds one
    /// `MTLComputePipelineState` per name.
    static let functionNames = [
        "spatialLuminance",
        "spatialBlurVertical",
        "spatialDownsampleHorizontal",
        "spatialUpsampleVertical",
        "spatialUpsampleHorizontalScaled",
        "spatialSubtract",
        "spatialAdd",
        "spatialAddCurve",
        "spatialRemap",
        "spatialMinMaxReduceInit",
        "spatialMinMaxReduce",
        "spatialComputeG0Grid",
        "spatialComputeBracket",
        "spatialAccumulateWeighted",
        "spatialApplyRatio",
        "spatialMultiplyScalar"
    ]

    /// Threadgroup size `spatialMinMaxReduce` is always dispatched with
    /// (`16*16 == 256`, matching the fixed-size `threadgroup` arrays in the
    /// kernel itself).
    static let minMaxReduceThreadgroupWidth = 16
    static let minMaxReduceThreadgroupHeight = 16

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // MARK: - Burt-Adelson 5-tap binomial kernel, reflect addressing

    constant float kSpatialBinom5[5] = { 1.0 / 16.0, 4.0 / 16.0, 6.0 / 16.0, 4.0 / 16.0, 1.0 / 16.0 };

    /// `numpy.pad(..., mode="reflect")`'s index mapping (mirrors without
    /// repeating the edge sample) -- exactly `SpatialToneOps.reflectIndex`.
    inline int spatialReflectIndex(int i, int n) {
        if (n <= 1) { return 0; }
        int period = 2 * (n - 1);
        int r = i % period;
        if (r < 0) { r += period; }
        return (r < n) ? r : (period - r);
    }

    // MARK: - Luminance / ratio (image edges: RGBA, premultiplied alpha)

    kernel void spatialLuminance(
        texture2d<float, access::read> rgba [[texture(0)]],
        texture2d<float, access::write> lnOut [[texture(1)]],
        constant float4 &ppLuma [[buffer(0)]],
        constant float &epsilon [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= lnOut.get_width() || gid.y >= lnOut.get_height()) { return; }
        float4 pixel = rgba.read(gid);
        float alpha = pixel.a;
        // Straight (unpremultiplied) RGB only for the *luminance* used to
        // pick which gain-curve/pyramid value applies -- alpha must not leak
        // into the log-luminance driving the spatial decomposition (see
        // `SpatialToneProcessor`'s doc comment on why the final RGB scale
        // does not need this same unpremultiply/premultiply round trip).
        // `ppLuma` is padded to `float4` (`.w` unused) to sidestep the
        // `float3`-in-a-buffer alignment ambiguity between Metal and Swift.
        float3 straight = (alpha > 1e-7) ? (pixel.rgb / alpha) : pixel.rgb;
        float y = dot(straight, ppLuma.xyz);
        lnOut.write(float4(log2(max(y, epsilon)), 0.0, 0.0, 0.0), gid);
    }

    kernel void spatialApplyRatio(
        texture2d<float, access::read> rgbaIn [[texture(0)]],
        texture2d<float, access::read> lnFinal [[texture(1)]],
        texture2d<float, access::read> ln0 [[texture(2)]],
        texture2d<float, access::write> rgbaOut [[texture(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= rgbaOut.get_width() || gid.y >= rgbaOut.get_height()) { return; }
        float4 pixel = rgbaIn.read(gid);
        float ratio = exp2(lnFinal.read(gid).r - ln0.read(gid).r);
        rgbaOut.write(float4(pixel.rgb * ratio, pixel.a), gid);
    }

    // MARK: - Pyramid (single-channel `r32Float` planes)

    /// `_blur5_axis(x, axis=0)` (vertical/row axis), full resolution --
    /// `_pyr_down`'s first pass.
    kernel void spatialBlurVertical(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int height = int(src.get_height());
        float sum = 0.0;
        for (int k = 0; k < 5; k++) {
            int sy = spatialReflectIndex(int(gid.y) + k - 2, height);
            sum += kSpatialBinom5[k] * src.read(uint2(gid.x, uint(sy))).r;
        }
        dst.write(float4(sum, 0.0, 0.0, 0.0), gid);
    }

    /// `_blur5_axis(x, axis=1)` fused with `_pyr_down`'s `[::2, ::2]`
    /// column subsample: only ever computes the horizontal blur at the
    /// columns `_pyr_down` keeps (mathematically identical to blurring every
    /// column then discarding half -- the discarded ones are never read).
    /// `src` is `spatialBlurVertical`'s full-resolution output; `dst` is
    /// `(ceil(w/2), ceil(h/2))`.
    kernel void spatialDownsampleHorizontal(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int width = int(src.get_width());
        uint srcY = gid.y * 2;
        int baseX = int(gid.x) * 2;
        float sum = 0.0;
        for (int k = 0; k < 5; k++) {
            int sx = spatialReflectIndex(baseX + k - 2, width);
            sum += kSpatialBinom5[k] * src.read(uint2(uint(sx), srcY)).r;
        }
        dst.write(float4(sum, 0.0, 0.0, 0.0), gid);
    }

    /// `_pyr_up`'s zero-insertion fused into the vertical blur pass: a
    /// zero-inserted sample contributes exactly `0` to the weighted sum, so
    /// odd rows are simply skipped rather than materialized. `src` is
    /// `(w, h)`; `dst` is `(w, 2h)` (the width doubling happens in the next,
    /// horizontal pass).
    kernel void spatialUpsampleVertical(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int height2 = int(dst.get_height());
        float sum = 0.0;
        for (int k = 0; k < 5; k++) {
            int sy = spatialReflectIndex(int(gid.y) + k - 2, height2);
            if ((sy & 1) == 0) {
                sum += kSpatialBinom5[k] * src.read(uint2(gid.x, uint(sy / 2))).r;
            }
        }
        dst.write(float4(sum, 0.0, 0.0, 0.0), gid);
    }

    /// The horizontal half of `_pyr_up`'s zero-insert + blur + `*4` gain,
    /// writing directly at the final `(outWidth, outHeight)` size -- which
    /// is exactly `_pyr_up`'s own `up[:H, :W]` crop, since
    /// `2*ceil(n/2) >= n` always holds for the shapes this is called with
    /// (every dispatched output pixel is therefore always in range; see
    /// `SpatialToneOps.pyrUp`'s doc comment for the same invariant on the
    /// CPU side). `src` is `spatialUpsampleVertical`'s `(w, 2h)` output.
    kernel void spatialUpsampleHorizontalScaled(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        int width2 = int(src.get_width()) * 2;
        float sum = 0.0;
        for (int k = 0; k < 5; k++) {
            int sx = spatialReflectIndex(int(gid.x) + k - 2, width2);
            if ((sx & 1) == 0) {
                sum += kSpatialBinom5[k] * src.read(uint2(uint(sx / 2), gid.y)).r;
            }
        }
        dst.write(float4(sum * 4.0, 0.0, 0.0, 0.0), gid);
    }

    kernel void spatialSubtract(
        texture2d<float, access::read> a [[texture(0)]],
        texture2d<float, access::read> b [[texture(1)]],
        texture2d<float, access::write> out [[texture(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        out.write(float4(a.read(gid).r - b.read(gid).r, 0.0, 0.0, 0.0), gid);
    }

    kernel void spatialAdd(
        texture2d<float, access::read> a [[texture(0)]],
        texture2d<float, access::read> b [[texture(1)]],
        texture2d<float, access::write> out [[texture(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        out.write(float4(a.read(gid).r + b.read(gid).r, 0.0, 0.0, 0.0), gid);
    }

    // MARK: - Global gain curve (`_GRID`/`GAIN_TABLE_*`, `np.interp`)

    /// `np.interp(x, _GRID, curve)` where `_GRID = linspace(-14, 0, 29)` is a
    /// *uniform* grid (step exactly 0.5): the bracket index is therefore a
    /// closed form instead of `SpatialToneOps.interpCurve`'s binary-search-
    /// free linear scan (which exists on the CPU side only because it is
    /// shared code -- both give bit-identical results for this fixed grid).
    inline float spatialInterpCurve(float x, device const float *curve) {
        float indexF = clamp((x + 14.0) / 0.5, 0.0, 28.0);
        int index0 = min(int(indexF), 27);
        float frac = indexF - float(index0);
        return mix(curve[index0], curve[index0 + 1], frac);
    }

    /// `lap[-1] = lap[-1] + curve_fn(lap[-1])` (Highlights fast path) /
    /// `base_final = G[levels] + curve_fn(G[levels])` (Shadows): both are
    /// this same "add the global curve to this one base level" operation.
    kernel void spatialAddCurve(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        device const float *curve [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        float v = src.read(gid).r;
        dst.write(float4(v + spatialInterpCurve(v, curve), 0.0, 0.0, 0.0), gid);
    }

    // MARK: - Shadows' discretized `g0` sweep (`_apply_single_op_llf`'s non-fast-path)

    /// `_remap_magnitude` + `remapped_full = g0 + sign(Ln-g0)*mag(...)`, for
    /// one `g0 = g0Grid[k]`. `g0Grid` is itself GPU-computed
    /// (`spatialComputeG0Grid`, from the whole image's min/max, which this
    /// process cannot read back to the CPU mid-`process()` call), so `k`
    /// (known at Swift encode time -- it is just this op's own loop counter)
    /// indexes into the buffer rather than the kernel taking `g0` directly.
    kernel void spatialRemap(
        texture2d<float, access::read> ln [[texture(0)]],
        texture2d<float, access::write> out [[texture(1)]],
        device const float *g0Grid [[buffer(0)]],
        constant uint &k [[buffer(1)]],
        constant float &sigmaR [[buffer(2)]],
        constant float &remapAlpha [[buffer(3)]],
        constant float &remapBeta [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
        float g0 = g0Grid[k];
        float v = ln.read(gid).r;
        float d = v - g0;
        float ad = fabs(d);
        float sgn = (d > 0.0) ? 1.0 : ((d < 0.0) ? -1.0 : 0.0);
        float mag = (ad <= sigmaR)
            ? (sigmaR * pow(max(ad / sigmaR, 0.0), remapAlpha))
            : (remapBeta * (ad - sigmaR) + sigmaR);
        out.write(float4(g0 + sgn * mag, 0.0, 0.0, 0.0), gid);
    }

    // Order-preserving float<->uint mapping (standard GPU atomic-min/max-on-
    // float trick): lets `atomic_fetch_min_explicit`/`_max_explicit` (which
    // MSL only defines for integers) reduce IEEE-754 floats of either sign.
    inline uint spatialFloatToOrderedUint(float f) {
        uint bits = as_type<uint>(f);
        uint mask = uint(-(int)(bits >> 31)) | 0x80000000u;
        return bits ^ mask;
    }
    inline float spatialOrderedUintToFloat(uint u) {
        uint mask = ((u >> 31) - 1) | 0x80000000u;
        return as_type<float>(u ^ mask);
    }

    /// Resets the 2-element (`[min, max]`) ordered-uint accumulator so
    /// `spatialMinMaxReduce`'s atomics have a correct starting point, without
    /// a CPU round trip (a `.storageModeShared` buffer could be initialized
    /// from Swift directly, but keeping the whole min/max/`g0Grid` chain
    /// GPU-side in one command buffer -- no readback in between -- is the
    /// same discipline the discretized sweep itself needs, so this kernel
    /// keeps it uniform).
    kernel void spatialMinMaxReduceInit(
        device atomic_uint *result [[buffer(0)]]
    ) {
        atomic_store_explicit(&result[0], 0xFFFFFFFFu, memory_order_relaxed);
        atomic_store_explicit(&result[1], 0x00000000u, memory_order_relaxed);
    }

    /// Two-level reduction (threadgroup-local tree reduction, then one
    /// atomic update per threadgroup) for `Ln`'s global min/max over the
    /// *whole* image -- `_apply_single_op_llf`'s `gmin, gmax = np.min(Ln),
    /// np.max(Ln)`. Always dispatched with a fixed 16x16 (256-thread)
    /// threadgroup, matching the fixed-size `threadgroup` arrays below.
    kernel void spatialMinMaxReduce(
        texture2d<float, access::read> ln [[texture(0)]],
        device atomic_uint *result [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 tid [[thread_position_in_threadgroup]]
    ) {
        threadgroup uint tgMin[256];
        threadgroup uint tgMax[256];
        uint localIndex = tid.y * 16 + tid.x;
        uint orderedMin = 0xFFFFFFFFu;
        uint orderedMax = 0x00000000u;
        if (gid.x < ln.get_width() && gid.y < ln.get_height()) {
            uint ordered = spatialFloatToOrderedUint(ln.read(gid).r);
            orderedMin = ordered;
            orderedMax = ordered;
        }
        tgMin[localIndex] = orderedMin;
        tgMax[localIndex] = orderedMax;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (localIndex < stride) {
                tgMin[localIndex] = min(tgMin[localIndex], tgMin[localIndex + stride]);
                tgMax[localIndex] = max(tgMax[localIndex], tgMax[localIndex + stride]);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (localIndex == 0) {
            atomic_fetch_min_explicit(&result[0], tgMin[0], memory_order_relaxed);
            atomic_fetch_max_explicit(&result[1], tgMax[0], memory_order_relaxed);
        }
    }

    /// `pad = 0.05*(gmax-gmin+1e-6); g0_grid = linspace(gmin-pad, gmax+pad,
    /// n_disc)`, entirely on the GPU (single-thread dispatch) from
    /// `spatialMinMaxReduce`'s result -- so the sweep below never needs a
    /// CPU round trip for image-content-dependent data.
    kernel void spatialComputeG0Grid(
        device atomic_uint *minMax [[buffer(0)]],
        device float *g0Grid [[buffer(1)]],
        constant uint &n [[buffer(2)]]
    ) {
        float gmin = spatialOrderedUintToFloat(atomic_load_explicit(&minMax[0], memory_order_relaxed));
        float gmax = spatialOrderedUintToFloat(atomic_load_explicit(&minMax[1], memory_order_relaxed));
        float pad = 0.05 * (gmax - gmin + 1e-6);
        float lo = gmin - pad;
        float hi = gmax + pad;
        for (uint i = 0; i < n; i++) {
            float t = (n <= 1) ? 0.0 : (float(i) / float(n - 1));
            g0Grid[i] = lo + (hi - lo) * t;
        }
    }

    /// `idx = clip(searchsorted(g0_grid, vals) - 1, 0, n-2); frac = clip((vals
    /// - g_lo)/(g_hi-g_lo+1e-12), 0, 1)` for one pyramid level's Gaussian
    /// value `G[l]` -- computed once per level, reused by every `k` in the
    /// sweep below (`idx`/`frac` depend only on `G[l]` and the fixed
    /// `g0Grid`, not on which `k` is currently being accumulated).
    kernel void spatialComputeBracket(
        texture2d<float, access::read> g [[texture(0)]],
        texture2d<float, access::write> idxOut [[texture(1)]],
        texture2d<float, access::write> fracOut [[texture(2)]],
        device const float *g0Grid [[buffer(0)]],
        constant uint &n [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= g.get_width() || gid.y >= g.get_height()) { return; }
        float v = g.read(gid).r;
        int idx = -1;
        for (uint k = 0; k < n; k++) {
            if (g0Grid[k] < v) { idx = int(k); } else { break; }
        }
        idx = clamp(idx, 0, int(n) - 2);
        float gLo = g0Grid[idx];
        float gHi = g0Grid[idx + 1];
        float frac = clamp((v - gLo) / (gHi - gLo + 1e-12), 0.0, 1.0);
        idxOut.write(float4(float(idx), 0.0, 0.0, 0.0), gid);
        fracOut.write(float4(frac, 0.0, 0.0, 0.0), gid);
    }

    /// `acc[l] = acc[l] + w*Lk[l]` where `w` selects (by linear interpolation
    /// weight) whether this pixel's bracketing `g0` pair includes `k` --
    /// `isFirst` replaces a separate "zero `acc` before the sweep" pass
    /// (`k == 0` always runs first, so it can simply overwrite instead of
    /// accumulate). `acc` is `access::read_write`: every thread only ever
    /// touches its own texel across the whole `k` sweep, so there is no
    /// cross-thread hazard from updating it in place.
    kernel void spatialAccumulateWeighted(
        texture2d<float, access::read> lk [[texture(0)]],
        texture2d<float, access::read> idxTex [[texture(1)]],
        texture2d<float, access::read> fracTex [[texture(2)]],
        texture2d<float, access::read_write> acc [[texture(3)]],
        constant uint &k [[buffer(0)]],
        constant uint &isFirst [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= acc.get_width() || gid.y >= acc.get_height()) { return; }
        int idx = int(idxTex.read(gid).r + 0.5);
        float frac = fracTex.read(gid).r;
        float w = 0.0;
        if (idx == int(k)) { w = 1.0 - frac; } else if (idx + 1 == int(k)) { w = frac; }
        float contribution = w * lk.read(gid).r;
        float previous = (isFirst != 0) ? 0.0 : acc.read(gid).r;
        acc.write(float4(previous + contribution, 0.0, 0.0, 0.0), gid);
    }

    // MARK: - Texture / Clarity2012 (Phase2 C4 "Model L": per-level scalar gain)

    /// `SpatialToneOps.applyMultiscaleGain`'s one new primitive: every other
    /// piece (Gaussian pyramid, Laplacian bands, reconstruct) is already
    /// shared with Highlights/Shadows above. Multiplies one Laplacian band
    /// (or the coarsest base) by its own per-level scalar gain.
    kernel void spatialMultiplyScalar(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant float &scalar [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        dst.write(float4(src.read(gid).r * scalar, 0.0, 0.0, 0.0), gid);
    }
    """
}

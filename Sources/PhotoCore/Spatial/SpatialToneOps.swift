import CoreImage
import Foundation

/// Phase2 C3: a faithful Swift port of `.photobench/phase2/spatial-v2/
/// spatial_model_v2.py`'s `apply_highlights_shadows` -- the measured
/// local-Laplacian model for `Highlights2012`/`Shadows2012`. See
/// `.photobench/phase2/spatial-v2/model.md` for the derivation, the
/// (a)/(b) global-curve-placement comparison, and every residual; every
/// constant and formula below is transcribed verbatim from that reference,
/// not re-derived.
///
/// Unlike every other Phase2 tone/color operation (`ToneOps`, `ColorOps`),
/// this is fundamentally a **spatial** operation -- its Gaussian/Laplacian
/// pyramid decomposition mixes neighboring pixels, so (unlike a `CIColorCube`)
/// it cannot be baked into a per-pixel LUT. `applyHighlightsShadows` below is
/// the CPU reference (`Double`, matching the Python reference's `float64`);
/// `SpatialToneProcessor` is the GPU (`CIImageProcessorKernel`/Metal) version
/// this CPU code is also the software-renderer fallback for.
/// Where the spatial pass [S] (Highlights/Shadows/Texture/Clarity,
/// `AdobeBaseRenderer.applySpatialToneOps`) runs relative to cube P
/// (Contrast/Dehaze/Whites/Blacks/Parametric/Point curve), cube Q (color),
/// and Calibration. Originally an experiment-only switch (`PHOTO_BENCH_
/// SPATIAL_ORDER`) added to measure the C4-era full-recipe darkness
/// regression (4 presets x 2 scenes, uniformly -0.24..-0.58 EV vs C2's
/// +0.06..+0.34) under every plausible [S] position; the coordinator's
/// grid-search review adopted **RAW = `.preTone`, non-RAW = `.sP1P2`** as
/// the new production default (`currentForRAW`/`currentForNonRAW` below) --
/// `.p1SP2` (the old default) is kept only as a case, no longer privileged.
/// The env var stays as an experiment/override hook: when set to a valid
/// raw value it forces *both* paths to that one order (unchanged semantics
/// from before); when unset, each path falls back to its own new default
/// instead of both falling back to `.p1SP2`. Used by `AdobeBaseRenderer.
/// Handle.image(settings:)` (RAW, via `currentForRAW`) and `RenderEngine.
/// applyNonRAWStageP`/`applyNonRAWStageQ` (non-RAW, via `currentForNonRAW`).
public enum SpatialOrder: String {
    /// Today's production order: cube P1 (Contrast -> Dehaze) -> [S] ->
    /// cube P2 (Whites -> Blacks -> Parametric -> Point curve).
    case p1SP2 = "p1-s-p2"
    /// [S] -> cube P (Contrast -> Dehaze -> Whites -> Blacks -> Parametric
    /// -> Point curve, unsplit -- valid because nothing before Contrast
    /// depends on [S] having already run in this ordering).
    case sP1P2 = "s-p1-p2"
    /// cube P (unsplit, as above) -> [S], run after the *entire* Basic
    /// panel instead of in the middle of it.
    case p1P2S = "p1-p2-s"
    /// RAW: right after Stage E (exposure), before Stage L (look table) --
    /// i.e. before the DCP look/tone curve cubes even run. Non-RAW: right
    /// after `exposureNonRaw`, before Contrast (mirrors the RAW
    /// Stage-E-relative position as closely as a pipeline with no Stage
    /// L/T can).
    case preTone = "pre-tone"
    /// After cube Q (`ColorOps`) and Calibration, the last thing before the
    /// ProPhoto -> working-space matrix.
    case postQ = "post-q"

    /// The raw env var, unresolved (`nil` = unset or an unrecognized raw
    /// value) -- callers should use `currentForRAW`/`currentForNonRAW`
    /// instead of this directly, so that "unset" resolves to *this path's*
    /// new default rather than a single shared one.
    public static var current: SpatialOrder? {
        guard let raw = ProcessInfo.processInfo.environment["PHOTO_BENCH_SPATIAL_ORDER"] else {
            return nil
        }
        return SpatialOrder(rawValue: raw)
    }

    /// RAW pipeline default (`AdobeBaseRenderer.Handle.image(settings:)`):
    /// `.preTone` unless the env var forces something else.
    public static var currentForRAW: SpatialOrder { current ?? .preTone }

    /// Non-RAW pipeline default (`RenderEngine.applyNonRAWStageP`/
    /// `applyNonRAWStageQ`): `.sP1P2` unless the env var forces something
    /// else (the old shared default for both paths was `.p1SP2`).
    public static var currentForNonRAW: SpatialOrder { current ?? .sP1P2 }
}

/// A per-sign amplitude multiplier applied to `SpatialToneOps.
/// highlightsGainCurve`/`shadowsGainCurve`'s output (the `_interp_table`-
/// equivalent 29-point curve). Added to re-fit H/S's amplitude once
/// `SpatialOrder`'s new defaults (RAW `.preTone`, non-RAW `.sP1P2`) moved
/// the spatial pass to a different position than the one the gain tables
/// were originally measured at (output-referred, after the tone curve).
///
/// This type itself, and `highlightsGainCurve`/`shadowsGainCurve`/
/// `applyHighlightsShadows` below, are **pure** -- they take a
/// `SpatialGainScale` as an explicit parameter (default `.identity`, a
/// true no-op) and never read the environment themselves. Only the
/// pipeline entry point (`AdobeBaseRenderer.applySpatialToneOps`) resolves
/// `.current` (env var, falling back to `.productionDefault`) and passes it
/// down explicitly through `SpatialToneProcessor.apply` -> `applyGPU`/
/// `applyCPUFallback`/`processCPUBuffers` -> `applyHighlightsShadows`. This
/// keeps every fixture/parity/regression test that calls those functions
/// directly (and passes `.identity`, or omits the parameter) byte-identical
/// to the fixtures generated before this type existed, regardless of what
/// the production default is.
public struct SpatialGainScale: Sendable, Equatable {
    public let highlightsNeg: Double
    public let highlightsPos: Double
    public let shadowsNeg: Double
    public let shadowsPos: Double

    public init(highlightsNeg: Double = 1.0, highlightsPos: Double = 1.0, shadowsNeg: Double = 1.0, shadowsPos: Double = 1.0) {
        self.highlightsNeg = highlightsNeg
        self.highlightsPos = highlightsPos
        self.shadowsNeg = shadowsNeg
        self.shadowsPos = shadowsPos
    }

    /// The mathematically neutral value -- every fixture test should pass
    /// this explicitly (see the type's doc comment).
    public static let identity = SpatialGainScale()

    /// Adopted from the coordinator's real-engine 16-combination grid
    /// search + one round of neg/pos-split fine-tuning (kH shared-neg/pos
    /// training-optimum was 0.65, kS 0.6, but real composite presets/
    /// full_bluesky2 holdout prefers kS close to 1.0 -- the opposite
    /// direction -- so this is a deliberately balanced point rather than
    /// the pure training-argmin: training avg meanDeltaE00 2.68 (best was
    /// 2.36 at kH/kS 0.65/0.6), holdout avg meanDeltaE00 3.41 (best was
    /// 3.36 at kH/kS 0.5/1.0), both within ~0.05-0.32 of their respective
    /// bests. See the grid-search report for the full 16-combo table.
    public static let productionDefault = SpatialGainScale(highlightsNeg: 0.5, highlightsPos: 0.5, shadowsNeg: 0.8, shadowsPos: 0.8)

    /// round2 set A (`.photobench/phase2/spatial-adaptive/model.md` §5):
    /// `SpatialAdaptiveLaw.kS(highlightRatioBase:)` applied to both shadow
    /// signs. kSneg (Shadows2012 negative) was never measured in that round
    /// (its gate XMPs were `Shadows2012_{+50,+100}` only) -- this reuses the
    /// positive-fit value for both, a provisional stand-in flagged in
    /// `model.md` §5/§8 pending a future round's negative-side measurement.
    /// kH stays at the fixed production value: `model.md` §4.1 found no
    /// usable image-adaptive predictor for it.
    public static func adaptive(highlightRatioBase: Double) -> SpatialGainScale {
        let kS = SpatialAdaptiveLaw.kS(highlightRatioBase: highlightRatioBase)
        return SpatialGainScale(
            highlightsNeg: SpatialAdaptiveLaw.kHFixed, highlightsPos: SpatialAdaptiveLaw.kHFixed,
            shadowsNeg: kS, shadowsPos: kS
        )
    }

    /// Env-var override/experiment hook, resolved **only** by the pipeline
    /// entry point (see the type's doc comment) -- unset *or* unparseable
    /// (wrong count, non-numeric) both fall back to the image-adaptive law
    /// (`.adaptive(highlightRatioBase:)`) when a per-photo statistic is
    /// available, else `.productionDefault`, since an explicitly-set-but-
    /// malformed value should fail toward today's real production behavior,
    /// not silently revert to the pre-fit-amplitude behavior. `PHOTO_BENCH_
    /// SPATIAL_GAIN_SCALE`'s explicit value always wins over the adaptive
    /// law when both are present, matching `model.md` §6 item 4 (keeps the
    /// env var usable for A/B comparison against the adaptive default).
    public static func current(highlightRatioBase: Double?) -> SpatialGainScale {
        let fallback = highlightRatioBase.map { SpatialGainScale.adaptive(highlightRatioBase: $0) } ?? .productionDefault
        guard let raw = ProcessInfo.processInfo.environment["PHOTO_BENCH_SPATIAL_GAIN_SCALE"] else {
            return fallback
        }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4 else { return fallback }
        let values = parts.compactMap { Double($0) }
        guard values.count == 4 else { return fallback }
        return SpatialGainScale(highlightsNeg: values[0], highlightsPos: values[1], shadowsNeg: values[2], shadowsPos: values[3])
    }
}

/// round2 set A (`.photobench/phase2/spatial-adaptive/model.md` §5): the
/// single home for the image-adaptive Shadows2012-amplitude law's
/// constants, so a future re-fit (more scenes, `model.md` §7/§8) only
/// touches this one place.
public enum SpatialAdaptiveLaw {
    /// `kS = clamp(intercept + slope * highlightRatioBase, clampMin, clampMax)`,
    /// a 1-variable linear regression against each scene's real-engine-
    /// measured optimal kS -- `model.md` §4.2. Refit on the 16-scene
    /// dataset (originally n=6); `highlightRatioBase` itself also moved from
    /// a neutral render to a "preHS" one (`model.md` §6/§7) at this same
    /// refit -- see `Handle.highlightRatioBase(for:)`/`RenderEngine`'s
    /// non-RAW equivalent.
    public static let intercept = 0.4008
    public static let slope = 1.6900
    /// The regression's training data only spans kS in [0.4, 1.8]
    /// (`model.md` §5) -- clamped rather than extrapolated beyond that.
    public static let clampMin = 0.4
    public static let clampMax = 1.8
    /// kH: no significant image-adaptive predictor was found (`model.md`
    /// §4.1) -- stays at the existing fixed production value.
    public static let kHFixed = 0.5

    public static func kS(highlightRatioBase: Double) -> Double {
        min(max(intercept + slope * highlightRatioBase, clampMin), clampMax)
    }
}

/// round2 set A (`.photobench/phase2/spatial-adaptive/model.md` §3.1/§6):
/// computes `highlightRatioBase`, the per-photo statistic `SpatialAdaptiveLaw`
/// consumes -- the fraction of a photo's *neutral* (no preset/slider edits)
/// rendering, downscaled and Gaussian-blurred, that is brighter than -1 stop.
/// This is a coarse, heuristic feature (fit from n=6 scenes), not a
/// bit-exact port: its Gaussian blur reuses this file's own `reflectIndex`
/// boundary convention (`np.pad(mode: "reflect")`-equivalent) rather than
/// exactly replicating the Python analysis's `cv2.GaussianBlur(...,
/// borderType=cv2.BORDER_REFLECT)` (a different, edge-inclusive reflect
/// variant) -- the resulting whole-image ratio differs by a negligible
/// amount at the image border either way. Verified only via a synthetic-
/// image unit test with an analytically-known ratio, not a Python fixture.
enum SpatialAdaptiveStats {
    /// `model.md` §3.1's analysis resolution/sigma pair (1500px long edge,
    /// sigma 32px = 2.1333% of that width); other resolutions scale sigma
    /// by the same width fraction (`model.md` §5), matching this file's own
    /// `scalePx(forLongEdge:)` convention.
    static let referenceLongEdge = 1500.0
    static let referenceSigma = 32.0
    static let lnFloor = 1e-4
    static let highlightThreshold = -1.0

    static func sigma(forLongEdge longEdge: Double) -> Double {
        longEdge * (referenceSigma / referenceLongEdge)
    }

    /// Separable Gaussian blur, truncated at +-3 sigma (>99.7% of the
    /// kernel's mass) -- see the type's doc comment re: boundary handling.
    static func gaussianBlur(_ plane: SpatialPlane, sigma: Double) -> SpatialPlane {
        guard sigma > 0, plane.width > 0, plane.height > 0 else { return plane }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        let offsets = Array(-radius...radius)
        var kernel = offsets.map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let kernelSum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / kernelSum }

        var horizontal = SpatialPlane(width: plane.width, height: plane.height)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                var acc = 0.0
                for (offset, weight) in zip(offsets, kernel) {
                    acc += plane[SpatialToneOps.reflectIndex(x + offset, plane.width), y] * weight
                }
                horizontal[x, y] = acc
            }
        }
        var result = SpatialPlane(width: plane.width, height: plane.height)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                var acc = 0.0
                for (offset, weight) in zip(offsets, kernel) {
                    acc += horizontal[x, SpatialToneOps.reflectIndex(y + offset, plane.height)] * weight
                }
                result[x, y] = acc
            }
        }
        return result
    }

    /// `Ln` (log2 luminance, `lumaWeights`-projected, floored at `lnFloor`)
    /// for straight (unpremultiplied) RGB samples.
    static func lnPlane(rgb: [SIMD3<Double>], width: Int, height: Int, lumaWeights: SIMD3<Double>) -> SpatialPlane {
        var values = [Double](repeating: 0, count: width * height)
        for i in 0..<rgb.count {
            let y = max(rgb[i].x * lumaWeights.x + rgb[i].y * lumaWeights.y + rgb[i].z * lumaWeights.z, lnFloor)
            values[i] = log2(y)
        }
        return SpatialPlane(width: width, height: height, values: values)
    }

    /// The fraction of `plane`'s values greater than `highlightThreshold`.
    static func highlightRatio(_ plane: SpatialPlane, threshold: Double = highlightThreshold) -> Double {
        guard !plane.values.isEmpty else { return 0 }
        let count = plane.values.reduce(0) { $1 > threshold ? $0 + 1 : $0 }
        return Double(count) / Double(plane.values.count)
    }

    /// The full statistic from an already-decoded `[SIMD3<Double>]` buffer
    /// (straight RGB) at `width`x`height` -- `longEdge` is `max(width,
    /// height)`, used only to pick the matching blur sigma.
    static func highlightRatioBase(rgb: [SIMD3<Double>], width: Int, height: Int, lumaWeights: SIMD3<Double>) -> Double {
        let ln = lnPlane(rgb: rgb, width: width, height: height, lumaWeights: lumaWeights)
        let blurred = gaussianBlur(ln, sigma: sigma(forLongEdge: Double(max(width, height))))
        return highlightRatio(blurred)
    }

    /// End-to-end from a `CIImage` (any resolution): downscales to at most
    /// `longEdge` (never upscales -- a smaller source keeps its own size,
    /// matching `CoreImageDecoder`'s `min(1, ...)` convention), renders to a
    /// CPU `RGBAf` buffer, unpremultiplies, and computes the statistic.
    /// Non-throwing: a degenerate (zero/non-finite extent) `image` returns
    /// `0` (the law's most-negative, clamp-floor-adjacent answer) rather
    /// than propagating an error for what is a soft, best-effort feature.
    static func highlightRatioBase(image: CIImage, longEdge: Double, lumaWeights: SIMD3<Double>) -> Double {
        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return 0 }
        let currentLongEdge = max(extent.width, extent.height)
        let scale = min(1, CGFloat(longEdge) / currentLongEdge)
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        let scaledExtent = scaled.extent.integral
        guard scaledExtent.width.isFinite, scaledExtent.height.isFinite, scaledExtent.width > 0, scaledExtent.height > 0 else { return 0 }
        let width = Int(scaledExtent.width)
        let height = Int(scaledExtent.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return 0 }

        let context = CIContext(options: [.cacheIntermediates: false])
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        var buffer = [Float](repeating: 0, count: width * height * 4)
        context.render(scaled, toBitmap: &buffer, rowBytes: bytesPerRow, bounds: scaledExtent, format: .RGBAf, colorSpace: colorSpace)

        var rgb = [SIMD3<Double>](repeating: .zero, count: width * height)
        for i in 0..<(width * height) {
            let base = i * 4
            let a = Double(buffer[base + 3])
            let r = Double(buffer[base]), g = Double(buffer[base + 1]), b = Double(buffer[base + 2])
            rgb[i] = a > 1e-7 ? SIMD3(r / a, g / a, b / a) : SIMD3(r, g, b)
        }
        return highlightRatioBase(rgb: rgb, width: width, height: height, lumaWeights: lumaWeights)
    }
}

public enum SpatialToneOps {
    public static let identifier = "spatial-v2-local-laplacian-highlights-shadows-v1"

    /// Whether `settings` would do anything other than pass its input through
    /// unchanged -- mirrors every other Phase2 op's own `needsXxx` gate
    /// (`ToneOps.needsPostOps`, `ColorOps.needsColorOps`). Phase2 C4 added
    /// Texture/Clarity2012 to this same Ln chain (see `applyHighlightsShadows`'s
    /// doc comment), so they gate it too; Dehaze does not -- it has no
    /// spatial component (`ToneOps.dehaze`, baked into cube P/P1 instead).
    public static func needsSpatial(_ settings: EditSettings) -> Bool {
        settings.highlights != 0 || settings.shadows != 0 || settings.texture != 0 || settings.clarity != 0
    }

    /// `spatial_model_v2.py` was fit at a 1500x1000 analysis resolution with
    /// `scale_px = 32`. Every caller (RAW, non-RAW, preview, and export --
    /// they may all run this op at different actual pixel dimensions,
    /// depending on decode intent) converts its own image's long edge (in the
    /// resolution it is *actually* processing at -- already reflecting any
    /// decode-time downscale, so `appliedScaleFactor` must not be multiplied
    /// in again) through this one function, so every path fits the same
    /// physical detail scale.
    public static func scalePx(forLongEdge longEdge: Double) -> Double {
        32.0 * (longEdge / 1500.0)
    }

    // MARK: - Luminance (`PP_LUMA`/`EPS`, identical to v1's `spatial_model.py`)

    static let ppLuma = SIMD3<Double>(0.2880402, 0.7118741, 0.0000857)
    /// 16bit ProPhoto gamma-1.8 representation's floor, roughly -15 stops.
    static let eps = 3e-5

    // MARK: - Gain curve grid (`_GRID = np.linspace(-14.0, 0.0, 29)`)

    /// `numpy.linspace(-14.0, 0.0, 29)`: 29 points, step exactly 0.5, so this
    /// closed form is bit-exact with the reference (every value is exactly
    /// representable in binary floating point; verified against the actual
    /// `numpy.linspace` output while porting).
    static let grid: [Double] = (0..<29).map { -14.0 + Double($0) * 0.5 }

    // MARK: - Gain tables (verbatim copies of `spatial_model_v2.py`'s
    // `GAIN_TABLE_100`/`GAIN_TABLE_50`, derived from
    // `c1_ramp_{Highlights2012,Shadows2012}_{±50,±100}.tif` -- not
    // re-measured for this port).

    static let gainTable100HighlightsNeg: [Double] = [
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.0285, -0.0361, -0.0548, -0.0905, -0.1057,
        -0.1355, -0.1683, -0.1982, -0.2291, -0.2523, -0.2719, -0.2833, -0.292, -0.3017, -0.321,
        -0.3621, -0.6364, -0.9061, -1.0604, -1.0853, -0.618
    ]
    static let gainTable100HighlightsPos: [Double] = [
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0749, 0.0476, 0.0265, 0.0343, 0.0832, 0.0925, 0.1134,
        0.1403, 0.1735, 0.2056, 0.2326, 0.2548, 0.2697, 0.2794, 0.2885, 0.2988, 0.3188, 0.3603,
        0.554, 0.6777, 0.6751, 0.4355, 0.0
    ]
    static let gainTable100ShadowsNeg: [Double] = [
        -1.0247, -1.5247, -2.0247, -2.5247, -3.0247, -3.5247, -4.0, -3.7774, -3.4303, -3.2054,
        -2.5716, -2.4087, -2.1987, -2.1127, -2.1691, -2.1106, -2.0646, -1.9637, -1.8008, -1.5945,
        -1.197, -0.8621, -0.5819, -0.2478, -0.2117, -0.1516, -0.0945, -0.0418, 0.0
    ]
    static let gainTable100ShadowsPos: [Double] = [
        4.202, 3.7756, 3.3491, 2.9366, 2.5562, 2.1978, 2.1055, 2.2045, 2.3594, 2.7803, 3.2581,
        3.2836, 3.2459, 3.1226, 2.9496, 2.6903, 2.4299, 2.1085, 1.7869, 1.5143, 1.1335, 0.8335,
        0.5719, 0.2465, 0.1988, 0.1432, 0.0897, 0.0402, 0.0
    ]
    static let gainTable50HighlightsNeg: [Double] = [
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.0285, -0.0239, -0.0283, -0.0401, -0.0523,
        -0.067, -0.0839, -0.0998, -0.1159, -0.1274, -0.1358, -0.1409, -0.1453, -0.1503, -0.16,
        -0.1807, -0.3145, -0.4234, -0.475, -0.4585, -0.2147
    ]
    static let gainTable50HighlightsPos: [Double] = [
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0119, 0.0399, 0.0473, 0.0549, 0.0699,
        0.0849, 0.1026, 0.1154, 0.1268, 0.135, 0.1405, 0.1449, 0.1498, 0.1598, 0.1807, 0.2902,
        0.3676, 0.3831, 0.3343, 0.0
    ]
    static let gainTable50ShadowsNeg: [Double] = [
        -1.0247, -1.5247, -2.0247, -2.5247, -3.0131, -3.5, -3.0, -2.9301, -2.4531, -1.9154,
        -1.2042, -1.1572, -1.2147, -1.1986, -1.1703, -1.1533, -1.1329, -1.0504, -0.9306, -0.8011,
        -0.59, -0.4268, -0.2894, -0.1237, -0.1043, -0.0748, -0.0466, -0.0207, 0.0
    ]
    static let gainTable50ShadowsPos: [Double] = [
        2.9829, 2.6344, 2.2858, 1.9612, 1.6822, 1.4101, 1.3076, 1.1292, 0.9768, 1.1936, 1.4409,
        1.4263, 1.4515, 1.457, 1.4308, 1.3421, 1.2334, 1.078, 0.9121, 0.7692, 0.5726, 0.4194,
        0.2869, 0.1235, 0.101, 0.0727, 0.0454, 0.0203, 0.0
    ]

    /// `_interp_table`: blends `GAIN_TABLE_50`/`GAIN_TABLE_100` by `|value|`
    /// (linear 0...50, linear extrapolation-by-difference 50...100), picking
    /// the `_neg`/`_pos` table by `value`'s sign.
    static func interpTable(_ value: Double, neg50: [Double], neg100: [Double], pos50: [Double], pos100: [Double]) -> [Double] {
        guard value != 0 else { return [Double](repeating: 0, count: grid.count) }
        let g50 = value > 0 ? pos50 : neg50
        let g100 = value > 0 ? pos100 : neg100
        let v = abs(value)
        if v <= 50 {
            let scale = v / 50.0
            return g50.map { $0 * scale }
        }
        let t = (v - 50.0) / 50.0
        return zip(g50, g100).map { lo, hi in lo + (hi - lo) * t }
    }

    /// `scale` is an explicit parameter, not `SpatialGainScale.current` --
    /// see that type's doc comment for why (pure function, pipeline resolves
    /// the env var/default exactly once and threads it down).
    static func highlightsGainCurve(_ value: Double, scale: SpatialGainScale = .identity) -> [Double] {
        let curve = interpTable(
            value,
            neg50: gainTable50HighlightsNeg, neg100: gainTable100HighlightsNeg,
            pos50: gainTable50HighlightsPos, pos100: gainTable100HighlightsPos
        )
        let k = value > 0 ? scale.highlightsPos : scale.highlightsNeg
        guard k != 1.0 else { return curve }
        return curve.map { $0 * k }
    }

    /// `scale` is an explicit parameter -- see `highlightsGainCurve`.
    static func shadowsGainCurve(_ value: Double, scale: SpatialGainScale = .identity) -> [Double] {
        let curve = interpTable(
            value,
            neg50: gainTable50ShadowsNeg, neg100: gainTable100ShadowsNeg,
            pos50: gainTable50ShadowsPos, pos100: gainTable100ShadowsPos
        )
        let k = value > 0 ? scale.shadowsPos : scale.shadowsNeg
        guard k != 1.0 else { return curve }
        return curve.map { $0 * k }
    }

    /// `np.interp(x, _GRID, curve)`: clamps outside `grid`'s range, exact
    /// linear interpolation between knots (identical algorithm to
    /// `ToneOps`'s private `piecewiseLinear`, duplicated here so this file
    /// has no dependency on `ToneOps`'s internals).
    static func interpCurve(_ x: Double, _ curve: [Double]) -> Double {
        if x <= grid[0] { return curve[0] }
        let last = grid.count - 1
        if x >= grid[last] { return curve[last] }
        for index in 1...last where x <= grid[index] {
            let t = (x - grid[index - 1]) / (grid[index] - grid[index - 1])
            return curve[index - 1] + (curve[index] - curve[index - 1]) * t
        }
        return curve[last]
    }

    // MARK: - detail/edge remapping shape parameters (`OP_PARAMS`)

    struct OpParams {
        let alpha: Double
        let beta: Double
        let sigmaR: Double
    }

    static let highlightsParams = OpParams(alpha: 1.0, beta: 1.0, sigmaR: 1.0)
    static let shadowsParams = OpParams(alpha: 1.0, beta: 0.85, sigmaR: 0.5)
    /// `OP_PARAMS["shadows"]["levels_offset"]`.
    static let shadowsLevelsOffset = -3

    // MARK: - Burt-Adelson pyramid (5-tap binomial, separable, reflect pad)

    static let binom5: [Double] = [1.0 / 16.0, 4.0 / 16.0, 6.0 / 16.0, 4.0 / 16.0, 1.0 / 16.0]

    /// `numpy.pad(..., mode="reflect")`'s index mapping for an arbitrary
    /// (possibly out-of-range) integer coordinate: mirrors without repeating
    /// the edge sample (period `2*(n-1)`). `n <= 1` has no reflection target
    /// in real `numpy` (it raises) -- this returns the sole index instead, a
    /// deliberate leniency for degenerate (1px-wide/tall) synthetic images
    /// that real photos never produce.
    static func reflectIndex(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let period = 2 * (n - 1)
        var r = i % period
        if r < 0 { r += period }
        return r < n ? r : period - r
    }

    /// `_blur5_axis(x, axis=0)`: blurs along the vertical (row) axis.
    static func blur5Vertical(_ p: SpatialPlane) -> SpatialPlane {
        var out = SpatialPlane(width: p.width, height: p.height)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var sum = 0.0
                for k in 0..<5 {
                    let sy = reflectIndex(y + k - 2, p.height)
                    sum += binom5[k] * p[x, sy]
                }
                out[x, y] = sum
            }
        }
        return out
    }

    /// `_blur5_axis(x, axis=1)`: blurs along the horizontal (column) axis.
    static func blur5Horizontal(_ p: SpatialPlane) -> SpatialPlane {
        var out = SpatialPlane(width: p.width, height: p.height)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var sum = 0.0
                for k in 0..<5 {
                    let sx = reflectIndex(x + k - 2, p.width)
                    sum += binom5[k] * p[sx, y]
                }
                out[x, y] = sum
            }
        }
        return out
    }

    /// `_blur5(x) = _blur5_axis(_blur5_axis(x, 0), 1)`: axis 0 (vertical)
    /// first, then axis 1 (horizontal).
    static func blur5(_ p: SpatialPlane) -> SpatialPlane {
        blur5Horizontal(blur5Vertical(p))
    }

    /// `_pyr_down`: blur, then take every other row/column (`ceil(n/2)`
    /// output size per axis).
    static func pyrDown(_ p: SpatialPlane) -> SpatialPlane {
        let blurred = blur5(p)
        let outWidth = (p.width + 1) / 2
        let outHeight = (p.height + 1) / 2
        var out = SpatialPlane(width: outWidth, height: outHeight)
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                out[x, y] = blurred[2 * x, 2 * y]
            }
        }
        return out
    }

    /// `_pyr_up`: zero-insert to `2h x 2w`, blur (`x4` gain), then crop (or,
    /// in the unreachable-in-practice case documented at its call site, edge
    /// pad) to `(outWidth, outHeight)`.
    static func pyrUp(_ p: SpatialPlane, outWidth: Int, outHeight: Int) -> SpatialPlane {
        let width2 = p.width * 2
        let height2 = p.height * 2
        var upsampled = SpatialPlane(width: width2, height: height2)
        for y in 0..<p.height {
            for x in 0..<p.width {
                upsampled[2 * x, 2 * y] = p[x, y]
            }
        }
        var blurred = blur5(upsampled)
        for i in 0..<blurred.values.count { blurred.values[i] *= 4.0 }
        if blurred.width == outWidth && blurred.height == outHeight { return blurred }
        // `2*ceil(n/2) >= n` always holds for the shapes this is actually
        // called with, so this branch (crop when larger, edge-pad via
        // `min()` clamp when -- unreachably -- smaller) never runs in
        // practice; kept only because the Python reference keeps it.
        var out = SpatialPlane(width: outWidth, height: outHeight)
        for y in 0..<outHeight {
            let sy = min(y, blurred.height - 1)
            for x in 0..<outWidth {
                let sx = min(x, blurred.width - 1)
                out[x, y] = blurred[sx, sy]
            }
        }
        return out
    }

    static func gaussianPyramid(_ x: SpatialPlane, levels: Int) -> [SpatialPlane] {
        var g = [x]
        for _ in 0..<levels { g.append(pyrDown(g[g.count - 1])) }
        return g
    }

    /// `_laplacian_from_gaussian`: `lap[i] = G[i] - pyrUp(G[i+1])` for every
    /// level but the last, then the coarsest Gaussian level itself
    /// (`lap[levels] == G[levels]`, the "base").
    static func laplacianPyramid(from g: [SpatialPlane]) -> [SpatialPlane] {
        var lap: [SpatialPlane] = []
        lap.reserveCapacity(g.count)
        for i in 0..<(g.count - 1) {
            let up = pyrUp(g[i + 1], outWidth: g[i].width, outHeight: g[i].height)
            lap.append(g[i] - up)
        }
        lap.append(g[g.count - 1])
        return lap
    }

    static func reconstruct(_ lap: [SpatialPlane]) -> SpatialPlane {
        var x = lap[lap.count - 1]
        var i = lap.count - 2
        while i >= 0 {
            x = pyrUp(x, outWidth: lap[i].width, outHeight: lap[i].height) + lap[i]
            i -= 1
        }
        return x
    }

    // MARK: - Texture / Clarity2012 (Phase2 C4, `detail_model.py`'s "Model L")

    /// Verbatim from `.photobench/phase2/detail/detail_model.py`'s
    /// `TEXTURE_GAIN_60`/`CLARITY_GAIN_60`: 9 measured per-Laplacian-level
    /// gains (level 0 = finest detail .. level 8 = coarsest measured base),
    /// from a least-squares fit of `detail_edited ~= k_l * detail_neutral`
    /// per level, pooled over 3 real photos at `Texture`/`Clarity2012` =
    /// ±60. Unlike Highlights/Shadows' additive log2-luminance gain curve,
    /// this is a *multiplicative* gain applied directly to each Laplacian
    /// band (`applyMultiscaleGain`) -- no remapping/discretization sweep at
    /// all (`model.md`'s "Model L", chosen over the fitted local-Laplacian
    /// "Model N" because it was at least as accurate and far cheaper).
    static let textureGain60Neg: [Double] = [
        0.8567, 0.8955, 0.9436, 0.9797, 0.9951, 0.9996, 1.0005, 1.0008, 0.9982
    ]
    static let textureGain60Pos: [Double] = [
        1.1616, 1.1282, 1.0704, 1.0265, 1.0074, 1.0015, 1.0007, 1.0004, 1.0031
    ]
    static let clarityGain60Neg: [Double] = [
        0.8517, 0.8534, 0.8603, 0.8787, 0.9153, 0.9696, 1.0039, 1.0177, 0.9972
    ]
    static let clarityGain60Pos: [Double] = [
        1.3641, 1.3005, 1.2463, 1.203, 1.1634, 1.1203, 1.0776, 1.0456, 1.0155
    ]
    /// `CLARITY_LEVEL_OFFSET`: Clarity's measured effect reaches a visibly
    /// broader spatial scale than Texture's (chart period > 150px, real-photo
    /// levels 7-8 still non-1.0), so Clarity always uses a pyramid 3 levels
    /// deeper than the same `scalePx` would give Texture/Highlights --
    /// opposite sign from Shadows' `shadowsLevelsOffset` (Clarity goes
    /// *deeper* than the Texture/Highlights baseline, Shadows shallower).
    static let clarityLevelOffset = 3

    /// `_gain_profile`: `n_levels_total + 1` per-level gains (index
    /// `levels_total` is the coarsest base). `amount == 0` is the identity
    /// (`ones`); otherwise `(table[key] - 1)` is scaled by `|amount| / 60`
    /// (exact at the measured ±60) and added back to 1. The 9 measured
    /// levels are truncated if fewer are needed, or the last (~1.0, already
    /// near-identity) value is repeated to fill any additional levels a
    /// larger `scalePx`/Clarity's offset asks for.
    static func gainProfile(amount: Double, pos: [Double], neg: [Double], levelsTotal: Int) -> [Double] {
        let n = levelsTotal + 1
        guard amount != 0 else { return [Double](repeating: 1.0, count: n) }
        let table = amount > 0 ? pos : neg
        let scale = amount > 0 ? amount / 60.0 : amount / -60.0
        let dev = table.map { ($0 - 1.0) * scale }
        if n <= dev.count {
            return dev[0..<n].map { 1.0 + $0 }
        }
        var result = dev.map { 1.0 + $0 }
        let padValue = 1.0 + (dev.last ?? 0)
        result.append(contentsOf: [Double](repeating: padValue, count: n - dev.count))
        return result
    }

    /// `_apply_multiscale_gain`: builds `Ln`'s Gaussian/Laplacian pyramid
    /// (`gains.count - 1` levels), multiplies *every* band (every detail
    /// level **and** the coarsest base -- unlike Highlights/Shadows, which
    /// only ever touches the base) by its own scalar gain, and reconstructs.
    /// A purely linear filter: no remap, no discretization sweep.
    static func applyMultiscaleGain(_ ln: SpatialPlane, gains: [Double]) -> SpatialPlane {
        let levels = gains.count - 1
        guard levels > 0 else { return ln }
        let g = gaussianPyramid(ln, levels: levels)
        var lap = laplacianPyramid(from: g)
        for i in 0..<lap.count {
            lap[i] = lap[i].mapValues { $0 * gains[i] }
        }
        return reconstruct(lap)
    }

    /// `apply_texture`: standalone (matches the Python reference's own
    /// isolated function exactly, for fixture testing) -- production always
    /// calls this via `applyHighlightsShadows`'s chained `texture`/`clarity`
    /// parameters instead, never this directly.
    public static func applyTexture(
        rgb: [SIMD3<Double>], width: Int, height: Int, amount: Double, scalePx: Double
    ) -> [SIMD3<Double>] {
        precondition(rgb.count == width * height, "SpatialToneOps: rgb.count must equal width*height")
        guard amount != 0 else { return rgb }
        let ln0 = luminancePlane(rgb: rgb, width: width, height: height)
        let levels = max(1, Int(log2(max(scalePx, 2.0)).rounded(.toNearestOrEven)))
        let gains = gainProfile(amount: amount, pos: textureGain60Pos, neg: textureGain60Neg, levelsTotal: levels)
        let lnOut = applyMultiscaleGain(ln0, gains: gains)
        return applyRatio(rgb: rgb, lnOut: lnOut, ln0: ln0)
    }

    /// `apply_clarity`: standalone, see `applyTexture`'s doc comment.
    public static func applyClarity(
        rgb: [SIMD3<Double>], width: Int, height: Int, amount: Double, scalePx: Double
    ) -> [SIMD3<Double>] {
        precondition(rgb.count == width * height, "SpatialToneOps: rgb.count must equal width*height")
        guard amount != 0 else { return rgb }
        let ln0 = luminancePlane(rgb: rgb, width: width, height: height)
        let levels = max(1, Int(log2(max(scalePx, 2.0)).rounded(.toNearestOrEven))) + clarityLevelOffset
        let gains = gainProfile(amount: amount, pos: clarityGain60Pos, neg: clarityGain60Neg, levelsTotal: levels)
        let lnOut = applyMultiscaleGain(ln0, gains: gains)
        return applyRatio(rgb: rgb, lnOut: lnOut, ln0: ln0)
    }

    static func luminancePlane(rgb: [SIMD3<Double>], width: Int, height: Int) -> SpatialPlane {
        var values = [Double](repeating: 0, count: rgb.count)
        for i in 0..<rgb.count {
            let sample = rgb[i]
            let y = sample.x * ppLuma.x + sample.y * ppLuma.y + sample.z * ppLuma.z
            values[i] = log2(max(y, eps))
        }
        return SpatialPlane(width: width, height: height, values: values)
    }

    static func applyRatio(rgb: [SIMD3<Double>], lnOut: SpatialPlane, ln0: SpatialPlane) -> [SIMD3<Double>] {
        var out = [SIMD3<Double>](repeating: .zero, count: rgb.count)
        for i in 0..<rgb.count {
            out[i] = rgb[i] * exp2(lnOut.values[i] - ln0.values[i])
        }
        return out
    }

    /// `_remap_magnitude`: `|I-g0| -> `unsigned post-remap distance, `alpha`
    /// for the detail term (`<= sigma_r`), `beta` for the edge term (`>
    /// sigma_r`), continuous at `sigma_r`.
    static func remapMagnitude(_ ad: Double, sigmaR: Double, alpha: Double, beta: Double) -> Double {
        if ad <= sigmaR {
            return sigmaR * pow(max(ad / sigmaR, 0.0), alpha)
        }
        return beta * (ad - sigmaR) + sigmaR
    }

    /// `np.searchsorted(grid, v, side="left") - 1`: the index `i` such that
    /// `grid[i] < v <= grid[i+1]` (before the caller's own clip to
    /// `[0, n-2]`).
    static func bracketIndex(_ grid: [Double], _ v: Double) -> Int {
        var lo = 0
        var hi = grid.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if grid[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// `_apply_single_op_llf`: one operation's local Laplacian filter pass.
    /// `alpha == beta == 1` (Highlights) takes the identity-remap fast path
    /// (no discretization sweep, global curve added straight to the coarsest
    /// base level); otherwise (Shadows) runs the full `n_disc`-point `g0`
    /// discretization sweep, gathering each pixel's two bracketing `g0`
    /// Laplacian coefficients by linear interpolation (Aubry 2014).
    static func applySingleOpLLF(
        _ ln: SpatialPlane,
        curve: (Double) -> Double,
        alpha: Double,
        beta: Double,
        sigmaR: Double,
        levels: Int,
        nDisc: Int = 10
    ) -> SpatialPlane {
        let g = gaussianPyramid(ln, levels: levels)
        if alpha == 1.0 && beta == 1.0 {
            var lap = laplacianPyramid(from: g)
            let lastIndex = lap.count - 1
            lap[lastIndex] = lap[lastIndex].mapValues { $0 + curve($0) }
            return reconstruct(lap)
        }

        let gmin = ln.values.min() ?? 0
        let gmax = ln.values.max() ?? 0
        let pad = 0.05 * (gmax - gmin + 1e-6)
        let lo = gmin - pad
        let hi = gmax + pad
        let n = nDisc
        let g0Grid: [Double] = n <= 1
            ? [lo]
            : (0..<n).map { i in lo + (hi - lo) * Double(i) / Double(n - 1) }

        // Per level (0..<levels), each pixel's bracketing `g0Grid` index and
        // fractional position, from that level's own Gaussian value `G[l]`
        // (fixed for this op -- computed once, reused across all `k`).
        var idxByLevel: [[Int]] = []
        var fracByLevel: [[Double]] = []
        idxByLevel.reserveCapacity(levels)
        fracByLevel.reserveCapacity(levels)
        for l in 0..<levels {
            let plane = g[l]
            var idxArr = [Int](repeating: 0, count: plane.values.count)
            var fracArr = [Double](repeating: 0, count: plane.values.count)
            for i in 0..<plane.values.count {
                let v = plane.values[i]
                let idx = min(max(bracketIndex(g0Grid, v), 0), n - 2)
                let gLo = g0Grid[idx]
                let gHi = g0Grid[idx + 1]
                idxArr[i] = idx
                fracArr[i] = min(max((v - gLo) / (gHi - gLo + 1e-12), 0.0), 1.0)
            }
            idxByLevel.append(idxArr)
            fracByLevel.append(fracArr)
        }

        var acc: [SpatialPlane] = (0..<levels).map { SpatialPlane(width: g[$0].width, height: g[$0].height) }

        for k in 0..<n {
            let g0 = g0Grid[k]
            var remapped = SpatialPlane(width: ln.width, height: ln.height)
            for i in 0..<ln.values.count {
                let d = ln.values[i] - g0
                let ad = abs(d)
                let sgn: Double = d > 0 ? 1.0 : (d < 0 ? -1.0 : 0.0)
                remapped.values[i] = g0 + sgn * remapMagnitude(ad, sigmaR: sigmaR, alpha: alpha, beta: beta)
            }
            let gk = gaussianPyramid(remapped, levels: levels)
            let lk = laplacianPyramid(from: gk)
            for l in 0..<levels {
                let idxArr = idxByLevel[l]
                let fracArr = fracByLevel[l]
                for i in 0..<acc[l].values.count {
                    let idx = idxArr[i]
                    let w: Double
                    if idx == k { w = 1.0 - fracArr[i] } else if idx + 1 == k { w = fracArr[i] } else { w = 0.0 }
                    if w != 0 { acc[l].values[i] += w * lk[l].values[i] }
                }
            }
        }

        var baseFinal = g[levels]
        for i in 0..<baseFinal.values.count {
            baseFinal.values[i] = g[levels].values[i] + curve(g[levels].values[i])
        }
        acc.append(baseFinal)
        return reconstruct(acc)
    }

    // MARK: - Public entry point

    /// `apply_highlights_shadows(rgb_linear, highlights, shadows, scale_px,
    /// order="highlights_first")`. Fixed at the production `order` (the only
    /// one the pipeline calls with -- `model.md` §4 measured it as slightly
    /// but consistently better than `"shadows_first"`), so there is no
    /// `order` parameter here.
    ///
    /// - Parameters:
    ///   - rgb: linear ProPhoto RGB, row-major, `width * height` elements.
    ///   - scalePx: see `scalePx(forLongEdge:)`.
    /// - Returns: linear ProPhoto RGB, same shape. Not clipped to `[0,1]`
    ///   (neither is the Python reference -- the caller's next cube clips).
    /// Phase2 C4 extended this from "Highlights/Shadows" to the full
    /// Ln-chain `SpatialToneProcessor` runs: Highlights -> Shadows ->
    /// Texture -> Clarity, each stage's output `Ln` feeding the next, with
    /// exactly one `y_ratio = 2^(Ln_final - Ln0)` applied to `rgb` at the
    /// end -- not one round trip per stage. This is not an approximation of
    /// calling `detail_model.py`'s `apply_texture`/`apply_clarity` (and
    /// `spatial_model_v2.py`'s `apply_highlights_shadows`) sequentially on
    /// each other's RGB output: because every stage here is exactly
    /// "recompute a per-pixel ratio from Ln and multiply all of RGB by it",
    /// re-deriving `Y -> Ln` from a previous stage's RGB output always
    /// reproduces that stage's own final `Ln` exactly (`Y' = ratio * Y`, so
    /// `log2(Y') = log2(ratio) + log2(Y) = (Ln_stage - Ln0) + Ln0 =
    /// Ln_stage`) -- so chaining `Ln` directly and ratio-ing once at the end
    /// is bit-for-bit the same computation, just without three redundant
    /// luminance-recompute-and-multiply round trips. Kept as one function
    /// (rather than one per stage) so that equivalence is structural, not
    /// something a caller could get wrong by chaining calls in the wrong
    /// way. `texture`/`clarity` default to `0` (no-op) so every pre-C4 call
    /// site keeps compiling and behaving identically.
    /// `gainScale` is an explicit parameter, default `.identity` -- see
    /// `SpatialGainScale`'s doc comment. Every fixture/parity test below
    /// passes `.identity` explicitly; only `SpatialToneProcessor.
    /// processCPUBuffers` (the CPU/software-fallback production path)
    /// threads through a caller-resolved value.
    public static func applyHighlightsShadows(
        rgb: [SIMD3<Double>],
        width: Int,
        height: Int,
        highlights: Double,
        shadows: Double,
        scalePx: Double,
        texture: Double = 0,
        clarity: Double = 0,
        gainScale: SpatialGainScale = .identity
    ) -> [SIMD3<Double>] {
        precondition(rgb.count == width * height, "SpatialToneOps: rgb.count must equal width*height")
        guard highlights != 0 || shadows != 0 || texture != 0 || clarity != 0 else { return rgb }

        let ln0 = luminancePlane(rgb: rgb, width: width, height: height)
        let levelsH = max(1, Int(log2(max(scalePx, 2.0)).rounded(.toNearestOrEven)))

        var ln = ln0
        if highlights != 0 {
            let curveTable = highlightsGainCurve(highlights, scale: gainScale)
            ln = applySingleOpLLF(
                ln, curve: { interpCurve($0, curveTable) },
                alpha: highlightsParams.alpha, beta: highlightsParams.beta, sigmaR: highlightsParams.sigmaR,
                levels: levelsH
            )
        }
        if shadows != 0 {
            let levelsS = max(1, levelsH + shadowsLevelsOffset)
            let curveTable = shadowsGainCurve(shadows, scale: gainScale)
            ln = applySingleOpLLF(
                ln, curve: { interpCurve($0, curveTable) },
                alpha: shadowsParams.alpha, beta: shadowsParams.beta, sigmaR: shadowsParams.sigmaR,
                levels: levelsS
            )
        }
        if texture != 0 {
            let gains = gainProfile(amount: texture, pos: textureGain60Pos, neg: textureGain60Neg, levelsTotal: levelsH)
            ln = applyMultiscaleGain(ln, gains: gains)
        }
        if clarity != 0 {
            let levelsC = levelsH + clarityLevelOffset
            let gains = gainProfile(amount: clarity, pos: clarityGain60Pos, neg: clarityGain60Neg, levelsTotal: levelsC)
            ln = applyMultiscaleGain(ln, gains: gains)
        }

        return applyRatio(rgb: rgb, lnOut: ln, ln0: ln0)
    }
}

/// A single-channel `width x height` row-major plane of `Double`s -- the
/// working representation for `SpatialToneOps`'s luminance/pyramid math
/// (kept internal: it is an implementation detail of the port, not part of
/// the op's public surface, but left directly testable via `@testable
/// import PhotoCore`, matching every other internal pyramid function above).
struct SpatialPlane {
    var width: Int
    var height: Int
    var values: [Double]

    init(width: Int, height: Int, values: [Double]) {
        precondition(values.count == width * height, "SpatialPlane: values.count must equal width*height")
        self.width = width
        self.height = height
        self.values = values
    }

    init(width: Int, height: Int, repeating: Double = 0) {
        self.width = width
        self.height = height
        self.values = [Double](repeating: repeating, count: width * height)
    }

    @inline(__always) subscript(x: Int, y: Int) -> Double {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }

    func mapValues(_ transform: (Double) -> Double) -> SpatialPlane {
        SpatialPlane(width: width, height: height, values: values.map(transform))
    }

    static func + (lhs: SpatialPlane, rhs: SpatialPlane) -> SpatialPlane {
        precondition(lhs.width == rhs.width && lhs.height == rhs.height)
        var out = lhs
        for i in 0..<out.values.count { out.values[i] += rhs.values[i] }
        return out
    }

    static func - (lhs: SpatialPlane, rhs: SpatialPlane) -> SpatialPlane {
        precondition(lhs.width == rhs.width && lhs.height == rhs.height)
        var out = lhs
        for i in 0..<out.values.count { out.values[i] -= rhs.values[i] }
        return out
    }
}

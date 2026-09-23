import Foundation

/// Phase2 C1's Stage P (and the non-RAW Exposure2012 stand-in): a faithful
/// Swift port of `.photobench/phase2/tone/tone_model.py`, the real-photo /
/// HALD-chart-measured reference model for `Exposure2012` (non-RAW only),
/// `Contrast2012`, `Whites2012`, `Blacks2012`, `ParametricShadows/Darks/
/// Lights/Highlights`, and `ToneCurvePV2012` (point curve). See
/// `docs/PHASE2_DEVELOP_PIPELINE.md` and `.photobench/phase2/tone/model.md`
/// for the derivation, confidence levels, and residuals of every constant
/// below -- they are transcribed verbatim, not re-derived.
///
/// Every function takes/returns `SIMD3<Double>` **linear ProPhoto**, exactly
/// like `AdobeColorMath`'s stage functions, and every function is a no-op
/// passthrough at its own neutral parameter value (`amount == 0`, no curve
/// points, etc.) so callers can compose them freely without special-casing
/// "am I active".
///
/// Color application throughout is `RGBTone.applyEncoded` (already in this
/// module): each operation's "gray curve" `f_enc: encoded -> encoded` is
/// evaluated on the sRGB-*encoded* (not decoded) max/min channel and mixed
/// hue-preservingly, matching `model.md`'s Q2 conclusion that this beats
/// every alternative (yratio, maxratio, linear RGBTone) tried. v2/v3's one
/// exception: Whites (lowered/raised) and Blacks (raised) mix that result
/// with a luminance-move result (`rgbToneMixedWithLuminanceRatio`), fitted
/// on strong real-photo settings where pure RGBTone loses saturation.
public enum ToneOps {
    /// Covered by `PhotoCoreProcessingFingerprint.basicTone` together with
    /// `SpatialToneOps.identifier` (Contrast/Whites/Blacks are basic-tone
    /// sliders too).
    public static let identifier = "measured-tone-ops-cube-p-v3"

    // MARK: - Shared helpers

    /// `tone_model._power_ratio`: `u^a / (u^a + c*(1-u)^a)`, clamping only
    /// the base of each power (not the result) so the caller's own anchoring/
    /// clipping stays in charge of the final range -- matching
    /// `np.clip(u, 1e-12, None)` (lower-bound-only clip).
    private static func powerRatio(_ u: Double, a: Double, c: Double) -> Double {
        let ua = pow(max(u, 1e-12), a)
        let oa = pow(max(1.0 - u, 1e-12), a)
        return ua / (ua + c * oa)
    }

    /// `np.interp`-equivalent piecewise-linear interpolation: clamps to the
    /// first/last `ys` outside `xs`'s range, exact linear interpolation
    /// between knots. `xs` must be strictly ascending (every table below is).
    private static func piecewiseLinear(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        if x <= xs[0] { return ys[0] }
        let last = xs.count - 1
        if x >= xs[last] { return ys[last] }
        for index in 1...last where x <= xs[index] {
            let t = (x - xs[index - 1]) / (xs[index] - xs[index - 1])
            return ys[index - 1] + (ys[index] - ys[index - 1]) * t
        }
        return ys[last]
    }

    private static func encodedCurve(_ value: SIMD3<Double>, _ curve: (Double) -> Double) -> SIMD3<Double> {
        RGBTone.applyEncoded(value, curve: curve, encode: DNGColorSpace.srgbEncode, decode: DNGColorSpace.srgbDecode)
    }

    // MARK: - 1) Exposure2012 (non-RAW only) -- anchored power-ratio, LINEAR space

    private static let exposureEV: [Double] = [-2.0, -1.0, 0.0, 1.0, 2.0, 3.0]
    private static let exposureM: [Double] = [0.5503, 0.9715, 1.0000, 1.0077, 1.0012, 1.0017]
    private static let exposureA: [Double] = [0.9836, 0.9777, 1.0000, 1.0245, 1.0514, 1.1313]
    private static let exposureC: [Double] = [4.5684, 2.9495, 1.0000, 0.3214, 0.0999, 0.0256]

    private static func exposureGrayCurveLinear(_ xLinear: Double, ev: Double) -> Double {
        let evClamped = min(max(ev, exposureEV[0]), exposureEV[exposureEV.count - 1])
        let m = piecewiseLinear(evClamped, xs: exposureEV, ys: exposureM)
        let a = piecewiseLinear(evClamped, xs: exposureEV, ys: exposureA)
        let c = piecewiseLinear(evClamped, xs: exposureEV, ys: exposureC)
        return min(max(m * powerRatio(xLinear, a: a, c: c), 0.0), 1.0)
    }

    /// `tone_model.apply_exposure`. **Non-RAW input only**: RAW's own
    /// `Exposure2012` is the separate, simpler `2^(baselineEV + EV)` linear
    /// gain already applied at Stage E (`AdobeColorMath`/`AdobeBaseRenderer`);
    /// this anchored power-ratio is the non-RAW-specific fit
    /// (`docs/PHASE2_DEVELOP_PIPELINE.md`'s RAW/non-RAW pipeline split).
    public static func exposureNonRaw(_ value: SIMD3<Double>, ev: Double) -> SIMD3<Double> {
        guard ev != 0 else { return value }
        func fEncoded(_ vEncoded: Double) -> Double {
            DNGColorSpace.srgbEncode(exposureGrayCurveLinear(DNGColorSpace.srgbDecode(vEncoded), ev: ev))
        }
        return encodedCurve(value, fEncoded)
    }

    // MARK: - 2) Contrast2012 -- symmetric power-ratio, pivot 0.5, sRGB-encoded

    private static let contrastK = 0.419

    /// `tone_model.apply_contrast`.
    public static func contrast(_ value: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        guard amount != 0 else { return value }
        let e = exp(contrastK * min(max(amount / 100.0, -1.0), 1.0))
        return encodedCurve(value) { powerRatio($0, a: e, c: 1.0) }
    }

    // MARK: - 2b) Dehaze (Phase2 C4) -- LINEAR space global log2-luminance curve + saturation

    /// `.photobench/phase2/detail/detail_model.py`'s `_DEHAZE_GRID`
    /// (`np.linspace(-14.0, 0.0, 29)`, identical closed form to
    /// `SpatialToneOps.grid`, duplicated here rather than shared -- this
    /// operation is pointwise/cube-bakeable and deliberately has no
    /// dependency on the `Spatial` module).
    private static let dehazeGrid: [Double] = (0..<29).map { -14.0 + Double($0) * 0.5 }
    private static let dehazePPLuma = SIMD3<Double>(0.2880402, 0.7118741, 0.0000857)
    private static let dehazeEPS = 3e-5

    /// `DEHAZE_GAIN_50`: a 29-point additive log2-luminance gain curve (same
    /// shape as the spatial family's `GAIN_TABLE`, but this one is *not*
    /// spatial -- Dehaze's local-contrast/dark-channel component was
    /// measured and found not to improve on real photos, `model.md` §3),
    /// extracted from a frequency chart's soft band + step-edge plateaus at
    /// `Dehaze` = ±50. `+50`/`-50` are not antisymmetric (measured, not a
    /// modeling choice).
    private static let dehazeGain50Pos: [Double] = [
        -0.9862, -0.9862, -0.9862, -0.9862, -0.9862, -0.9862, -0.9862, -0.9862, -0.9862, -0.9862,
        -0.9862, -0.9862, -0.9862, -0.9862, -0.9862, -0.9862, -0.9862, -0.996347, -1.034678, -1.045433,
        -1.033353, -1.011323, -0.992833, -0.956357, -0.887950, -0.728754, -0.435554, -0.3194, -0.3194
    ]
    private static let dehazeGain50Neg: [Double] = [
        1.7478, 1.7478, 1.7478, 1.7478, 1.7478, 1.7478, 1.7478, 1.7478, 1.7478, 1.7478,
        1.7478, 1.7478, 1.7478, 1.7478, 1.7478, 1.7478, 1.7478, 1.732147, 1.654377, 1.574631,
        1.498939, 1.422737, 1.309562, 1.139466, 0.919832, 0.681691, 0.422810, 0.2216, 0.2216
    ]
    /// `DEHAZE_SAT_K_AT_40`: pooled least-squares fit (P1013558/P1013207/
    /// P1012822: 1.51/1.42/1.53) of `chroma_out = k * chroma_in` (hue/luma
    /// preserving, same mechanism as `ColorOps`' saturation) at `Dehaze` =
    /// `+40` on real photos. Superseded as a runtime formula by
    /// `dehazeKSatAmountXs`/`dehazeKSatMinus1Ys` below (round2-bcd `model.md`
    /// §2.3), but kept as the documented `+40` anchor's provenance -- its
    /// value (1.4693) is exactly `1 + dehazeKSatMinus1Ys[3]` (0.4693).
    private static let dehazeSatKAt40 = 1.4693

    /// round2-bcd `model.md` §2.3: real-photo tone-curve/saturation
    /// projections at `Dehaze` = {-40,+20,+40(existing round1 anchor),+80}
    /// replace the old `amount/50` (tone) and `amount/40` (saturation)
    /// single-point proportional scales, which round2 found non-linear on
    /// real photos (positive side saturates: +20 measures 54% of the old
    /// proportional prediction, +80 measures 77%; negative side is slightly
    /// *stronger* than proportional: -40 measures 105%). Piecewise-linear
    /// (`piecewiseLinear`, i.e. `np.interp` semantics: clamps flat outside
    /// the anchor range on both ends) over these directly-measured anchors,
    /// per `model.md` §2.4 this cuts the 9-case (3 amounts x 3 scenes)
    /// average pixel ΔE00 from 3.56 to 2.83 with no case regressing. The
    /// negative side still has only the one `-40` real-photo anchor (`model.
    /// md` §6 unresolved item) -- `amount` beyond -40 clamps at -40's value
    /// rather than continuing to extrapolate, unlike the old proportional
    /// formula which had no such ceiling.
    private static let dehazeToneScalePosXs: [Double] = [0, 20, 50, 80]
    private static let dehazeToneScalePosYs: [Double] = [0.0, 0.216, 1.0, 1.237]
    private static let dehazeToneScaleNegXs: [Double] = [0, 40, 50]  // |amount|; 50 = existing +-50 chart anchor (scale=1)
    private static let dehazeToneScaleNegYs: [Double] = [0.0, 0.840, 1.0]
    private static let dehazeKSatAmountXs: [Double] = [-40, 0, 20, 40, 80]
    private static let dehazeKSatMinus1Ys: [Double] = [-0.3503, 0.0, 0.1027, 0.4693, 0.5805]

    private static func dehazeToneScale(_ amount: Double) -> Double {
        amount >= 0
            ? piecewiseLinear(amount, xs: dehazeToneScalePosXs, ys: dehazeToneScalePosYs)
            : piecewiseLinear(-amount, xs: dehazeToneScaleNegXs, ys: dehazeToneScaleNegYs)
    }

    private static func dehazeKSat(_ amount: Double) -> Double {
        1.0 + piecewiseLinear(amount, xs: dehazeKSatAmountXs, ys: dehazeKSatMinus1Ys)
    }

    private static func dehazeCurveGain(_ amount: Double) -> [Double] {
        guard amount != 0 else { return [Double](repeating: 0, count: dehazeGrid.count) }
        let table = amount > 0 ? dehazeGain50Pos : dehazeGain50Neg
        let scale = dehazeToneScale(amount)
        return table.map { $0 * scale }
    }

    /// `apply_dehaze`. Unlike every other op in this file, this operates
    /// directly on **linear** ProPhoto (like `exposureNonRaw`) rather than
    /// through `encodedCurve`'s sRGB-encoded gray-curve mixing -- the
    /// reference model is defined in linear log2-luminance space (matching
    /// the `Spatial` module's convention) and the saturation step needs the
    /// same linear chroma (`toned - Y`) `ColorOps` uses, so there is no
    /// shared helper to reuse here. `scalePx` is not a parameter (Dehaze has
    /// no spatial component, unlike Highlights/Shadows/Texture/Clarity).
    public static func dehaze(_ value: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        guard amount != 0 else { return value }
        let y0 = max(value.x * dehazePPLuma.x + value.y * dehazePPLuma.y + value.z * dehazePPLuma.z, dehazeEPS)
        let ln0 = log2(y0)
        let curve = dehazeCurveGain(amount)
        let gain = piecewiseLinear(ln0, xs: dehazeGrid, ys: curve)
        let toned = value * exp2(gain)

        let kSat = dehazeKSat(amount)
        let y1 = toned.x * dehazePPLuma.x + toned.y * dehazePPLuma.y + toned.z * dehazePPLuma.z
        let chroma = toned - SIMD3(repeating: y1)
        let out = SIMD3(repeating: y1) + chroma * kSat
        return SIMD3(max(out.x, 0.0), max(out.y, 0.0), max(out.z, 0.0))
    }

    // MARK: - 3) Whites2012 / Blacks2012 -- anchored power-ratio, sRGB-encoded

    private static let whitesAmount: [Double] = [-100.0, -50.0, 0.0, 50.0, 100.0]
    private static let whitesM: [Double] = [0.9276, 0.9809, 1.0, 1.0616, 1.1346]
    private static let whitesA: [Double] = [0.9128, 0.9262, 1.0, 1.0663, 1.3269]
    private static let whitesC: [Double] = [1.0134, 1.0865, 1.0, 0.9499, 0.5667]

    private static let blacksAmount: [Double] = [-100.0, -50.0, 0.0, 50.0, 100.0]
    private static let blacksM: [Double] = [1.2659, 1.0672, 1.0, 1.0037, 1.0085]
    private static let blacksA: [Double] = [1.0711, 1.0050, 1.0, 0.9393, 0.8775]
    private static let blacksC: [Double] = [1.0421, 0.9740, 1.0, 0.8579, 0.7453]

    private static func anchoredRatio(_ u: Double, anchor: Double, m: Double, a: Double, c: Double) -> Double {
        min(max(anchor + m * (powerRatio(u, a: a, c: c) - anchor), 0.0), 1.0)
    }

    /// v2 (`tone_model.WHITES_BETA_*` / `BLACKS_BETA_*`, RAW real-photo
    /// round1 +-60 and round5 Whites -83 / Blacks +89): when Whites goes down
    /// or Blacks goes up, LR moves brightness while keeping saturation. The
    /// RGBTone result is mixed with a chromaticity-preserving luminance-ratio
    /// result by `beta` (1 = v1's pure RGBTone). v3 (`WHITES_KAPPA_NEGATIVE`,
    /// adding round5's camera JPEGs and LR-exported JPEGs): lowering Whites
    /// keeps even more absolute chroma in the highlights, so its luminance
    /// move scales the color difference by `gain^kappa` instead of `gain`.
    private static let whitesBetaNegative = 0.4
    private static let whitesKappaNegative = 0.25
    private static let whitesBetaPositive = 0.4
    private static let blacksBetaPositive = 0.4
    private static let blacksBetaNegative = 1.0
    private static let ppLuma = SIMD3<Double>(0.2880402, 0.7118741, 0.0000857)

    /// `tone_model._rgbtone_mixed_with_luminance_ratio`: the gray curve moves
    /// linear ProPhoto Y only and RGB is scaled by the Y ratio; a lifting
    /// ratio stops where the largest channel reaches 1 (keeps high-chroma,
    /// low-Y colors such as deep blue from blowing out). With `kappa < 1` the
    /// color difference `rgb - Y` is scaled by `gain^kappa` (0 keeps absolute
    /// chroma) and channels pushed below 0 are clipped.
    private static func rgbToneMixedWithLuminanceRatio(
        _ value: SIMD3<Double>, beta: Double, kappa: Double = 1.0, _ curve: (Double) -> Double
    ) -> SIMD3<Double> {
        let tone = encodedCurve(value, curve)
        guard beta < 1.0 else { return tone }
        let clipped = SIMD3(max(value.x, 0.0), max(value.y, 0.0), max(value.z, 0.0))
        let y = max(clipped.x * ppLuma.x + clipped.y * ppLuma.y + clipped.z * ppLuma.z, 1e-6)
        var gain = DNGColorSpace.srgbDecode(curve(DNGColorSpace.srgbEncode(y))) / y
        if gain > 1.0 {
            let largest = max(max(clipped.x, clipped.y), max(clipped.z, 1e-6))
            gain = min(gain, max(1.0, 1.0 / largest))
        }
        let ratio: SIMD3<Double>
        if kappa == 1.0 {
            ratio = clipped * gain
        } else {
            let moved = SIMD3(repeating: y * gain) + (clipped - SIMD3(repeating: y)) * pow(gain, kappa)
            ratio = SIMD3(max(moved.x, 0.0), max(moved.y, 0.0), max(moved.z, 0.0))
        }
        return ratio + beta * (tone - ratio)
    }

    /// `tone_model.apply_whites`. anchor=0 (black fixed; `m>1` overshoots
    /// white and clips highlights).
    public static func whites(_ value: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        guard amount != 0 else { return value }
        let m = piecewiseLinear(amount, xs: whitesAmount, ys: whitesM)
        let a = piecewiseLinear(amount, xs: whitesAmount, ys: whitesA)
        let c = piecewiseLinear(amount, xs: whitesAmount, ys: whitesC)
        if amount < 0 {
            return rgbToneMixedWithLuminanceRatio(value, beta: whitesBetaNegative, kappa: whitesKappaNegative) {
                anchoredRatio($0, anchor: 0.0, m: m, a: a, c: c)
            }
        }
        return rgbToneMixedWithLuminanceRatio(value, beta: whitesBetaPositive) { anchoredRatio($0, anchor: 0.0, m: m, a: a, c: c) }
    }

    /// `tone_model.apply_blacks`. anchor=1 (white fixed; `m>1` undershoots
    /// black and crushes shadows).
    public static func blacks(_ value: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        guard amount != 0 else { return value }
        let m = piecewiseLinear(amount, xs: blacksAmount, ys: blacksM)
        let a = piecewiseLinear(amount, xs: blacksAmount, ys: blacksA)
        let c = piecewiseLinear(amount, xs: blacksAmount, ys: blacksC)
        let beta = amount > 0 ? blacksBetaPositive : blacksBetaNegative
        return rgbToneMixedWithLuminanceRatio(value, beta: beta) { anchoredRatio($0, anchor: 1.0, m: m, a: a, c: c) }
    }

    // MARK: - 4) Parametric Shadows/Darks/Lights/Highlights

    /// `tone_model._asym_cosine_window`.
    private static func asymCosineWindow(
        _ xEncoded: Double, peak: Double, leftEdge: Double, rightEdge: Double, power: Double = 2.0
    ) -> Double {
        if xEncoded < peak {
            guard peak > leftEdge else { return 0.0 }
            let t = min(max((xEncoded - peak) / (peak - leftEdge), -1.0), 0.0)
            return pow(cos(t * Double.pi / 2.0), power)
        } else {
            guard rightEdge > peak else { return 0.0 }
            let t = min(max((xEncoded - peak) / (rightEdge - peak), 0.0), 1.0)
            return pow(cos(t * Double.pi / 2.0), power)
        }
    }

    /// `tone_model.apply_parametric`. `shadowSplit`/`midtoneSplit`/
    /// `highlightSplit` are 0...100 (Adobe default 25/50/75); the rest are
    /// -100...100. Peak deltas are the measured ±60 values, linearly scaled
    /// from `amount == 0` (`model.md`'s Q1 "採用" table) -- there is no
    /// closed-form amount dependence, this is the documented fallback.
    public static func parametric(
        _ value: SIMD3<Double>,
        shadows: Double, darks: Double, lights: Double, highlights: Double,
        shadowSplit: Double, midtoneSplit: Double, highlightSplit: Double
    ) -> SIMD3<Double> {
        guard shadows != 0 || darks != 0 || lights != 0 || highlights != 0 else { return value }
        let ss = shadowSplit / 100.0
        let ms = midtoneSplit / 100.0
        let hs = highlightSplit / 100.0

        func scale(_ amount: Double, _ deltaAt60: Double) -> Double { (amount / 60.0) * deltaAt60 }

        func fEncoded(_ vEncoded: Double) -> Double {
            var out = vEncoded
            if shadows != 0 {
                let pd = scale(shadows, shadows > 0 ? 0.0541 : 0.0617)
                out += pd * asymCosineWindow(vEncoded, peak: ss, leftEdge: 0.0, rightEdge: ms)
            }
            if darks != 0 {
                let pd = scale(darks, darks > 0 ? 0.1025 : 0.1147)
                out += pd * asymCosineWindow(vEncoded, peak: ms, leftEdge: 0.0, rightEdge: 1.0)
            }
            if lights != 0 {
                let pd = scale(lights, lights > 0 ? 0.1632 : 0.1249)
                out += pd * asymCosineWindow(vEncoded, peak: hs, leftEdge: 0.0, rightEdge: 1.0)
            }
            if highlights != 0 {
                // Empirical peak-position formula, verified at only the
                // default split (model.md Q1: "外挿の妥当性は未確認").
                let peakHighlights = hs + 0.36 * (1.0 - hs)
                let pd = scale(highlights, highlights > 0 ? 0.0871 : 0.0774)
                out += pd * asymCosineWindow(vEncoded, peak: peakHighlights, leftEdge: ms, rightEdge: 1.0)
            }
            return min(max(out, 0.0), 1.0)
        }
        return encodedCurve(value, fEncoded)
    }

    // MARK: - 5) Point curve (ToneCurvePV2012 / Red / Green / Blue)

    /// The point curves with every spline built once. A cube bake evaluates
    /// the same curves at every grid point (262,144 at 64^3), and rebuilding
    /// the splines and re-sanitizing their points for each point was most of
    /// cube P's bake time. `pointCurve(_:curves:)` goes through this too, so
    /// there is one implementation and a bake's values are identical.
    public struct PreparedPointCurve: Sendable {
        let composite: DNGSpline?
        let red: DNGSpline?
        let green: DNGSpline?
        let blue: DNGSpline?

        /// Points are sanitized exactly like the legacy piecewise-linear
        /// model (`ToneCurveModel.normalizedPoints`: 0...1 clamp, sorted,
        /// duplicate-x last-authored-wins) so malformed/duplicate XMP curves
        /// degrade the same way regardless of which renderer sees them. A
        /// curve with fewer than 2 usable points (or one `DNGSpline` rejects)
        /// is skipped.
        public init(curves: [ToneCurve]) {
            composite = Self.spline(curves.first { $0.channel == .rgb })
            red = Self.spline(curves.first { $0.channel == .red })
            green = Self.spline(curves.first { $0.channel == .green })
            blue = Self.spline(curves.first { $0.channel == .blue })
        }

        private static func spline(_ curve: ToneCurve?) -> DNGSpline? {
            let points = ToneCurveModel.normalizedPoints(curve)
            guard points.count >= 2 else { return nil }
            return try? DNGSpline(points: points.map { ($0.x, $0.y) })
        }

        /// Composite RGB curve first (`tone_model.apply_point_curve`,
        /// hue-preserving via `RGBTone.applyEncoded`), then any single-channel
        /// Red/Green/Blue curves independently -- both may be present in the
        /// same XMP.
        public func apply(_ value: SIMD3<Double>) -> SIMD3<Double> {
            var result = value
            if let composite {
                result = ToneOps.encodedCurve(result) { min(max(composite.evaluate($0), 0.0), 1.0) }
            }
            if let red { result = Self.applyChannel(result, spline: red, channel: \.x) }
            if let green { result = Self.applyChannel(result, spline: green, channel: \.y) }
            if let blue { result = Self.applyChannel(result, spline: blue, channel: \.z) }
            return result
        }

        /// `tone_model.apply_point_curve_channel`: a single channel's curve
        /// applied directly to that channel in sRGB-encoded space, independent
        /// of the other two channels (NOT hue-preserving mixing -- there is
        /// only one channel to move). Per `model.md`'s Q3, the round1
        /// measurement of this specific XMP shape (`ToneCurvePV2012Red`/
        /// `Blue`) did not reach Lightroom at all (identical to neutral), so
        /// this is an unvalidated, best-effort placeholder matching the Python
        /// reference's own caveat.
        private static func applyChannel(
            _ value: SIMD3<Double>, spline: DNGSpline, channel: WritableKeyPath<SIMD3<Double>, Double>
        ) -> SIMD3<Double> {
            var result = value
            let encoded = DNGColorSpace.srgbEncode(min(max(result[keyPath: channel], 0.0), 1.0))
            let curved = min(max(spline.evaluate(encoded), 0.0), 1.0)
            result[keyPath: channel] = DNGColorSpace.srgbDecode(curved)
            return result
        }
    }

    /// `PreparedPointCurve(curves:).apply(_:)`.
    public static func pointCurve(_ value: SIMD3<Double>, curves: [ToneCurve]) -> SIMD3<Double> {
        guard !curves.isEmpty else { return value }
        return PreparedPointCurve(curves: curves).apply(value)
    }

    // MARK: - 6) Stage P composition

    /// `docs/PHASE2_DEVELOP_PIPELINE.md`'s Stage P order: Contrast -> Dehaze
    /// -> Whites -> Blacks -> Parametric -> Point curve (Phase2 C4 inserted
    /// Dehaze directly after Contrast -- `.photobench/phase2/detail/
    /// model.md`; it has no spatial component, so it stays in this cube
    /// rather than joining Highlights/Shadows/Texture/Clarity in
    /// `SpatialToneOps`). Exposure is **not** included here -- RAW applies
    /// it at Stage E (a plain linear gain, unrelated to `exposureNonRaw`),
    /// and the non-RAW caller applies `exposureNonRaw` itself immediately
    /// before this function (`RenderEngine`).
    ///
    /// Expressed as `applyContrastAndDehaze` followed by
    /// `applyPostOpsAfterContrast` (not its own independent copy of the
    /// ops) so that, when phase2 C3's spatial pass needs to split cube P
    /// into P1 (Contrast -> Dehaze) and P2 (everything after),
    /// `postOpsCubeP1 ∘ postOpsCubeP2 == postOpsCube` *exactly* -- same
    /// order, same computation, just with an `S` (`SpatialToneOps`) step
    /// inserted between the two halves by `AdobeBaseRenderer`/
    /// `RenderEngine`, never a second implementation that could quietly
    /// drift from this one.
    public static func applyPostOps(_ value: SIMD3<Double>, settings: EditSettings) -> SIMD3<Double> {
        applyPostOpsAfterContrast(applyContrastAndDehaze(value, settings: settings), settings: settings)
    }

    /// Cube P1's exact content in the C3 spatial-active pipeline: Contrast
    /// then Dehaze (both pointwise/cube-bakeable, unlike the spatial pass
    /// that runs between P1 and P2).
    public static func applyContrastAndDehaze(_ value: SIMD3<Double>, settings: EditSettings) -> SIMD3<Double> {
        dehaze(contrast(value, amount: settings.contrast), amount: settings.dehaze)
    }

    /// `applyPostOps` minus its leading `applyContrastAndDehaze` call:
    /// Whites -> Blacks -> Parametric -> Point curve. This is cube P2 in
    /// the C3 spatial-active pipeline (`docs/PHASE2_C2_C3.md`'s C3
    /// section); `applyContrastAndDehaze` is cube P1.
    public static func applyPostOpsAfterContrast(_ value: SIMD3<Double>, settings: EditSettings) -> SIMD3<Double> {
        PreparedPostOps(settings: settings).applyAfterContrast(value)
    }

    /// `applyPostOps` / `applyPostOpsAfterContrast` for one `settings`, with
    /// the point curves' splines built once (`PreparedPointCurve`) -- what a
    /// cube bake evaluates at every grid point. Same operations in the same
    /// order, so the values are identical.
    public struct PreparedPostOps: Sendable {
        let settings: EditSettings
        let pointCurve: PreparedPointCurve

        public init(settings: EditSettings) {
            self.settings = settings
            pointCurve = PreparedPointCurve(curves: settings.toneCurves)
        }

        public func apply(_ value: SIMD3<Double>) -> SIMD3<Double> {
            applyAfterContrast(ToneOps.applyContrastAndDehaze(value, settings: settings))
        }

        public func applyAfterContrast(_ value: SIMD3<Double>) -> SIMD3<Double> {
            var result = value
            result = ToneOps.whites(result, amount: settings.whites)
            result = ToneOps.blacks(result, amount: settings.blacks)
            result = ToneOps.parametric(
                result,
                shadows: settings.parametricShadows, darks: settings.parametricDarks,
                lights: settings.parametricLights, highlights: settings.parametricHighlights,
                shadowSplit: settings.parametricShadowSplit, midtoneSplit: settings.parametricMidtoneSplit,
                highlightSplit: settings.parametricHighlightSplit
            )
            return pointCurve.apply(result)
        }
    }

    /// Whether `applyPostOps` would do anything other than return its input
    /// unchanged -- used to skip baking/caching a cube P that would just be
    /// the identity, exactly like every individual op's own `amount == 0`
    /// no-op guard above.
    public static func needsPostOps(_ settings: EditSettings) -> Bool {
        needsContrastOrDehaze(settings) || needsPostOpsAfterContrast(settings)
    }

    /// As `needsPostOps`, but for `applyContrastAndDehaze` alone (cube P1's
    /// gate in the C3 spatial-active pipeline).
    public static func needsContrastOrDehaze(_ settings: EditSettings) -> Bool {
        settings.contrast != 0 || settings.dehaze != 0
    }

    /// As `needsPostOps`, but for `applyPostOpsAfterContrast` alone (cube
    /// P2) -- `settings.contrast`/`settings.dehaze` deliberately excluded,
    /// since those are cube P1's own gate (`needsContrastOrDehaze`).
    public static func needsPostOpsAfterContrast(_ settings: EditSettings) -> Bool {
        settings.whites != 0
            || settings.blacks != 0
            || settings.parametricShadows != 0
            || settings.parametricDarks != 0
            || settings.parametricLights != 0
            || settings.parametricHighlights != 0
            || !ToneCurveModel.isIdentity(settings.toneCurves)
    }
}

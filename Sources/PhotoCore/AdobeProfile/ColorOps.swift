import Foundation

/// Phase2 C2's Stage Q (`docs/PHASE2_C2_C3.md`): a faithful Swift port of
/// `.photobench/phase2/color/color_model.py` (Saturation, Vibrance, Camera
/// Calibration, Color Grading) and `.photobench/phase2/hsl/hsl_model.py`
/// (the 8-band HSL mixer) -- the real-photo/HALD-chart-measured reference
/// models for those Adobe controls. See those files' own `model.md` for the
/// derivation, confidence levels, and residuals of every constant below --
/// they are transcribed verbatim, not re-derived.
///
/// Every function takes/returns `SIMD3<Double>` **linear ProPhoto**, exactly
/// like `ToneOps`, and every function is a no-op passthrough at its own
/// neutral parameter value so callers can compose them freely -- including
/// where the Python reference itself has no such guard (e.g. `hsl_model.
/// apply_hsl` always round-trips through HSV; `hsl(_:adjustments:)` below
/// adds an exact bypass so a neutral `EditSettings.hsl` never perturbs a
/// pixel even by float-rounding noise, matching `ToneOps`'s own stated
/// convention).
/// Where Camera Calibration (`ColorOps.calibrationMatrix`, applied via
/// `AdobeBaseRenderer.applyCalibration`'s exact `CIColorMatrix`) runs
/// relative to cube Q (Vibrance -> Saturation -> HSL -> Color Grading).
/// Since 2026-09-24 (round4) the default is **before** cube Q: the HALD
/// pair measurement (`color/model.md` §6, `hsl/model.md` §5) puts
/// Calibration ahead of HSL, and on real photos with the white-preserving
/// matrix it wins on every combined case (night colour-only 2.26 -> 2.13,
/// Calibration + HSL 1.99 -> 1.93, 5 scenes) while single-operation cases
/// are unchanged. Both orders stay output-referred (after the tone curve and
/// cube P). `PHOTO_BENCH_CALIBRATION_FIRST=0` restores the old order (cube Q
/// then Calibration) for comparison; production code never sets it. Used
/// by both `AdobeBaseRenderer.Handle.image(settings:)` (RAW) and
/// `RenderEngine.applyNonRAWStageQ` (non-RAW).
public enum CalibrationOrder {
    public static var calibrationFirst: Bool {
        ProcessInfo.processInfo.environment["PHOTO_BENCH_CALIBRATION_FIRST"] != "0"
    }
}

public enum ColorOps {
    /// Identifies this stage's processing semantics for
    /// `PhotoCoreProcessingFingerprint.colorMixer` -- the field name is kept
    /// (rather than renamed to "colorOps") so the fingerprint's `Codable`
    /// contract and every existing consumer of that JSON key stay stable;
    /// only the deleted `PerceptualColorMixer`'s identity is replaced.
    public static let identifier = "measured-color-ops-cube-q-v2"

    // MARK: - Shared helpers

    /// ProPhoto RGB (D50) relative luminance -- `color_model.PP_LUMA` /
    /// `hsl_model.PP_LUMA`, identical to `ToneOps`'s implicit sRGB-encoded
    /// pipeline's own `AdobeColorMath` luminance row.
    private static let ppLuma = SIMD3<Double>(0.2880402, 0.7118741, 0.0000857)

    private static func ppLuminance(_ x: SIMD3<Double>) -> Double {
        (x * ppLuma).sum()
    }

    private static func clamp01(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(min(max(v.x, 0.0), 1.0), min(max(v.y, 0.0), 1.0), min(max(v.z, 0.0), 1.0))
    }

    /// Python's `%` (always non-negative for a positive modulus), unlike
    /// Swift's `truncatingRemainder` (C `fmod`, sign-preserving). Every hue
    /// wraparound below needs this, not `truncatingRemainder`.
    private static func pymod(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }

    /// `color_model._hue_deg`: a continuous atan2-based hue used only by
    /// `vibrance`'s skin-tone `hueWeight`. **Not** the same value as
    /// `hsl_model.rgb_to_hsv`'s classic-HSV hue (`hslRGBToHSV` below) --
    /// the two reference models measured and use genuinely different hue
    /// definitions (`.photobench/phase2/hsl/model.md` Q1); do not unify them.
    private static func hueDegreesAtan2(_ x: SIMD3<Double>) -> Double {
        let alpha = x.x - 0.5 * (x.y + x.z)
        let beta = (3.0.squareRoot() / 2.0) * (x.y - x.z)
        return pymod(atan2(beta, alpha) * 180.0 / Double.pi, 360.0)
    }

    /// `color_model.apply_vibrance`'s inline `s` / `color_model.
    /// _existing_saturation`: the classic-HSL relative saturation
    /// `chroma/(1-|2*Lmm-1|)`, shared verbatim by `vibrance`'s protection
    /// curve and `colorGrading`'s existing-saturation protection (both
    /// reference functions compute the exact same formula independently).
    private static func hslRelativeSaturation(_ x: SIMD3<Double>) -> Double {
        let mx = max(x.x, max(x.y, x.z))
        let mn = min(x.x, min(x.y, x.z))
        let chroma = mx - mn
        let lmm = (mx + mn) / 2.0
        return chroma / max(1.0 - abs(2.0 * lmm - 1.0), 1e-6)
    }

    // MARK: - 1) Saturation

    /// `color_model.apply_saturation`: pivot on ProPhoto luminance, hue-
    /// preserving chroma scale by a constant `k`.
    public static func saturation(_ value: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        guard amount != 0 else { return value }
        let k = 1.0 + amount / 100.0
        let l = SIMD3(repeating: ppLuminance(value))
        return clamp01(l + k * (value - l))
    }

    // MARK: - 2) Vibrance

    /// `color_model.apply_vibrance`: same pivot/hue-preserving mechanism as
    /// `saturation`, but `k` depends on the pixel's current relative
    /// saturation (protection, asymmetric by sign) and hue (skin-tone
    /// protection).
    public static func vibrance(_ value: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        guard amount != 0 else { return value }
        let l = ppLuminance(value)
        let s = hslRelativeSaturation(value)
        let hue = hueDegreesAtan2(value)
        let hueWeight = 1.0 + 0.08 * cos((hue - 170.0) * Double.pi / 180.0)
        let p = amount > 0 ? 1.0 : 0.32
        let g = pow(min(max(1.0 - s, 0.0), 1.0), p)
        let k = max(1.0 + (amount / 100.0) * g * hueWeight, 0.0)
        let lVec = SIMD3(repeating: l)
        return clamp01(lVec + k * (value - lVec))
    }

    // MARK: - 3) Camera Calibration

    /// `color_model._CALIB_D_PLUS`: each slider's +50 measured deviation
    /// matrix `M(+50) - I`, in the same row-major layout as the Python
    /// nested lists.
    private static let calibDPlusRedHue = Matrix3x3(
        0.0002, 0.0007, 0.0014,
        0.1659, -0.1494, 0.0013,
        -0.1490, -0.0097, 0.1286
    )
    private static let calibDPlusRedSaturation = Matrix3x3(
        -0.0021, -0.0070, -0.0007,
        -0.1804, 0.1629, -0.0042,
        -0.1750, -0.0106, 0.1528
    )
    private static let calibDPlusGreenHue = Matrix3x3(
        0.1646, -0.1614, -0.0054,
        -0.0020, -0.0018, -0.0005,
        -0.0001, 0.1771, -0.1442
    )
    private static let calibDPlusGreenSaturation = Matrix3x3(
        0.1992, -0.2227, -0.0093,
        0.0031, -0.0036, 0.0008,
        0.0130, -0.2070, 0.1461
    )
    private static let calibDPlusBlueHue = Matrix3x3(
        -0.1652, -0.0051, 0.1725,
        0.0070, 0.1217, -0.1554,
        0.0029, 0.0046, -0.0021
    )
    private static let calibDPlusBlueSaturation = Matrix3x3(
        0.1920, -0.0131, -0.2228,
        0.0082, 0.1484, -0.2031,
        -0.0011, 0.0051, -0.0018
    )

    /// `color_model.apply_calibration`'s matrix construction:
    /// `M = I + Σ (value/50) * D_i`. `shadowTint` is intentionally not a
    /// parameter -- the measured reference found it has zero effect
    /// (`color/model.md` §3.3) -- matching the Python reference's own
    /// `# noqa: ARG001 - 効果なし` kwarg-that-does-nothing.
    public static func calibrationMatrix(_ settings: CalibrationSettings) -> Matrix3x3 {
        var m = Matrix3x3.identity
        let contributions: [(Double, Matrix3x3)] = [
            (settings.redHue, calibDPlusRedHue),
            (settings.redSaturation, calibDPlusRedSaturation),
            (settings.greenHue, calibDPlusGreenHue),
            (settings.greenSaturation, calibDPlusGreenSaturation),
            (settings.blueHue, calibDPlusBlueHue),
            (settings.blueSaturation, calibDPlusBlueSaturation)
        ]
        for (value, d) in contributions where value != 0 {
            m = m + (value / 50.0) * d
        }
        // `color_model.calibration_matrix` v2: divide each row by its own sum
        // so white stays white. The chart-measured +50 matrices' row sums are
        // 0.95-1.03 (up to a 5% cast on neutrals); real RAW photos fitted
        // LR-to-LR are white-preserving, and normalizing cuts the mean
        // Calibration error from 1.67 to 0.72 dE00 (ideal 3x3 fit: 0.56).
        m.row0 /= m.row0.sum()
        m.row1 /= m.row1.sum()
        m.row2 /= m.row2.sum()
        return m
    }

    /// CPU reference for `calibrationMatrix`, used by the fixture test and by
    /// callers that want the whole slider-to-pixel operation (`y = clip(M@x,
    /// 0, 1)`) without building the matrix themselves. Production rendering
    /// (`AdobeBaseRenderer`) applies `calibrationMatrix` as its own
    /// `CIColorMatrix` + full [0,1] `CIColorClamp` instead of calling this
    /// per pixel -- see that file's `applyCalibration`.
    public static func calibration(_ value: SIMD3<Double>, settings: CalibrationSettings) -> SIMD3<Double> {
        let m = calibrationMatrix(settings)
        guard m != .identity else { return value }
        return clamp01(m * value)
    }

    /// Whether `calibrationMatrix(settings)` would differ from the identity
    /// -- `shadowTint` excluded, matching `calibrationMatrix`'s own no-op.
    public static func needsCalibration(_ settings: CalibrationSettings) -> Bool {
        settings.redHue != 0 || settings.redSaturation != 0
            || settings.greenHue != 0 || settings.greenSaturation != 0
            || settings.blueHue != 0 || settings.blueSaturation != 0
    }

    // MARK: - 4) HSL (8-band Hue/Saturation/Luminance)

    /// `hsl_model.BANDS`'s fixed cyclic order -- identical to
    /// `HSLBand.allCases`'s declaration order (`red, orange, yellow, green,
    /// aqua, blue, purple, magenta`), verified once here rather than at every
    /// call site. `hsl(_:adjustments:)`'s outer loop is the only place that
    /// still deals in `HSLBand` values directly; every per-pixel helper below
    /// takes a plain `Int` ordinal (`hslOrdinal(_:)`) into the arrays below
    /// instead -- this cube's `transform` closure runs once per grid point
    /// (64^3 = 262,144 times), so replacing what were originally per-band
    /// dictionary lookups / `Array.firstIndex(of:)` linear scans with direct
    /// indexing is a measured ~15% bake-time win (730ms -> 610ms for a
    /// several-controls-active `EditSettings`, release build), not a formula
    /// change. The remaining cost is dominated by this model's own several
    /// `pow()` calls per active band per grid point (the bell/beta-weight
    /// curves themselves), not by lookups -- `postColorCube`'s own cache
    /// means this is paid once per distinct Vibrance/Saturation/HSL/Color
    /// Grading combination, not once per render.
    private static let hslBandOrder: [HSLBand] = HSLBand.allCases

    private static func hslOrdinal(_ band: HSLBand) -> Int {
        switch band {
        case .red: 0
        case .orange: 1
        case .yellow: 2
        case .green: 3
        case .aqua: 4
        case .blue: 5
        case .purple: 6
        case .magenta: 7
        }
    }

    /// `hsl_model.CENTERS_DEG`: measured band centers, indexed by
    /// `hslOrdinal(_:)` (same order as `hslBandOrder`) -- **not** the same as
    /// `HSLBand.centerHue`'s coarse, evenly-spaced values (that property is
    /// display-only, used by the deleted `PerceptualColorMixer`'s OKLCh
    /// approximation).
    private static let hslCenters: [Double] = [
        359.990, 29.883, 55.251, 95.283, 160.041, 229.730, 275.113, 329.638
    ]

    private static func wrap180(_ deg: Double) -> Double {
        pymod(deg + 180.0, 360.0) - 180.0
    }

    /// `hsl_model.band_weights`, evaluated for one band at a time (each
    /// band's weight depends only on its own two neighbor centers, so this
    /// is not a reformulation, just an un-vectorized read of the same
    /// formula): cos²(constant-power) crossfade between neighbor centers.
    private static func hslBandWeight(hueDeg: Double, ordinal: Int) -> Double {
        let n = hslCenters.count
        let center = hslCenters[ordinal]
        let dPrev = wrap180(hslCenters[(ordinal - 1 + n) % n] - center)
        let dNext = wrap180(hslCenters[(ordinal + 1) % n] - center)
        let dh = wrap180(hueDeg - center)
        if dh >= dPrev, dh <= 0 {
            return pow(cos((dh / dPrev) * Double.pi / 2.0), 2)
        }
        if dh >= 0, dh <= dNext {
            return pow(cos((dh / dNext) * Double.pi / 2.0), 2)
        }
        return 0
    }

    /// `hsl_model._gap_to_next` / `_gap_from_prev`.
    private static func gapToNext(_ ordinal: Int) -> Double {
        let n = hslCenters.count
        return pymod(wrap180(hslCenters[(ordinal + 1) % n] - hslCenters[ordinal]), 360.0)
    }

    private static func gapFromPrev(_ ordinal: Int) -> Double {
        let n = hslCenters.count
        return pymod(wrap180(hslCenters[ordinal] - hslCenters[(ordinal - 1 + n) % n]), 360.0)
    }

    private static let hueFloorDegAt60 = 17.983
    private static let hueKGapAt60 = 0.5414

    /// `hsl_model.hue_shift_max_deg`: the "boundary budget" shared by two
    /// neighboring bands, not a per-band constant.
    private static func hueShiftMaxDeg(ordinal: Int, sign: Double) -> Double {
        let gap = sign > 0 ? gapToNext(ordinal) : gapFromPrev(ordinal)
        return sign * max(hueFloorDegAt60, hueKGapAt60 * gap)
    }

    private static let hslSatAPlus = 0.6109
    private static let hslSatAMinus = -0.6252
    private static let hslSatBMinus = 0.2262

    /// `hsl_model.sat_delta_unit`: "+" is a bell curve (both-end protected),
    /// "-" is near-linear (bottom-only protected) -- a genuine asymmetry in
    /// the fitted *shape*, not just its sign, per that file's own comment.
    private static func hslSatDeltaUnit(sIn: Double, slider: Double) -> Double {
        let scale = abs(slider) / 60.0
        let bell = hslSatAPlus * sIn * (1.0 - sIn)
        let quad = hslSatAMinus * sIn + hslSatBMinus * sIn * sIn
        return scale * (slider >= 0 ? bell : quad)
    }

    private struct HSLLumParams {
        let kPlus: Double, pPlus: Double, qPlus: Double
        let kMinus: Double, pMinus: Double, qMinus: Double
    }

    /// `hsl_model.LUM_PARAMS_AT60`, transcribed verbatim (including the two
    /// `pMinus == 0` entries the Python reference clips from small negative
    /// measured values -- see that file's own inline comments) and indexed
    /// by `hslOrdinal(_:)`.
    private static let hslLumParamsAt60: [HSLLumParams] = [
        HSLLumParams(kPlus: 0.5043, pPlus: 0.4057, qPlus: 1.3574, kMinus: -0.4577, pMinus: 0.2445, qMinus: 1.4495),
        HSLLumParams(kPlus: 0.4786, pPlus: 0.5539, qPlus: 1.1517, kMinus: -0.5940, pMinus: 0.4513, qMinus: 1.3820),
        HSLLumParams(kPlus: 0.3728, pPlus: 0.6234, qPlus: 0.7955, kMinus: -0.6795, pMinus: 0.6115, qMinus: 1.2223),
        HSLLumParams(kPlus: 0.3150, pPlus: 0.5862, qPlus: 0.7122, kMinus: -0.5476, pMinus: 0.5373, qMinus: 1.1360),
        HSLLumParams(kPlus: 0.4859, pPlus: 0.6716, qPlus: 1.0188, kMinus: -0.8015, pMinus: 0.6525, qMinus: 1.3838),
        // round2-bcd model.md §3.3 re-fit Blue (kPlus 1.19 / kMinus -1.29 / pMinus 0.84) on 4 real-photo
        // amplitudes, but that fit amplifies the known `yMid` blow-up for near-fully-saturated blue
        // (ProPhoto's blue luma coefficient is ~0), producing outputs ~1e4 for [0,0,1] and white
        // blobs on saturated blue lights. Real-photo gain was only ±0.05-0.08 dE, so the ±60-chart
        // fit is kept until the model gets a saturation guard (docs/ENGINE_ROADMAP.md).
        HSLLumParams(kPlus: 0.5194, pPlus: 0.4228, qPlus: 1.3609, kMinus: -0.3748, pMinus: 0.0, qMinus: 1.4781),
        HSLLumParams(kPlus: 0.4064, pPlus: 0.2450, qPlus: 1.3563, kMinus: -0.2764, pMinus: 0.0, qMinus: 1.3945),
        HSLLumParams(kPlus: 0.6047, pPlus: 0.5042, qPlus: 1.4334, kMinus: -0.4994, pMinus: 0.2566, qMinus: 1.5077)
    ]
    private static let hslLowSFade = 0.04

    private static func smoothstep(_ t: Double) -> Double {
        let c = min(max(t, 0.0), 1.0)
        return c * c * (3.0 - 2.0 * c)
    }

    /// `hsl_model.lum_delta_unit`: absolute linear-luminance shift `dY`, not
    /// a ratio (the Python reference's own §Q4 rationale for why a ratio
    /// fit worse).
    private static func hslLumDeltaUnit(ordinal: Int, sIn: Double, vIn: Double, slider: Double) -> Double {
        let p = hslLumParamsAt60[ordinal]
        let sSafe = max(sIn, 1e-9)
        let vSafe = max(vIn, 1e-9)
        let fade = smoothstep(sIn / hslLowSFade)
        let pos = p.kPlus * pow(sSafe, p.pPlus) * pow(vSafe, p.qPlus) * fade
        let neg = p.kMinus * pow(sSafe, p.pMinus) * pow(vSafe, p.qMinus) * fade
        return (abs(slider) / 60.0) * (slider >= 0 ? pos : neg)
    }

    /// `hsl_model.rgb_to_hsv`: classic (colorsys-equivalent) hue, **not**
    /// `hueDegreesAtan2`'s atan2-based hue -- see that function's doc
    /// comment.
    private static func hslRGBToHSV(_ rgb: SIMD3<Double>) -> (h: Double, s: Double, v: Double) {
        let r = rgb.x, g = rgb.y, b = rgb.z
        let mx = max(r, max(g, b))
        let mn = min(r, min(g, b))
        let d = mx - mn
        let dSafe = d == 0 ? 1.0 : d
        let rc = (mx - r) / dSafe
        let gc = (mx - g) / dSafe
        let bc = (mx - b) / dSafe
        var h: Double
        if mx == r {
            h = bc - gc
        } else if mx == g {
            h = 2.0 + rc - bc
        } else {
            h = 4.0 + gc - rc
        }
        if d == 0 { h = 0.0 }
        h = pymod(h / 6.0, 1.0)
        let s = mx > 0 ? d / mx : 0.0
        return (h * 360.0, s, mx)
    }

    /// `hsl_model.hsv_to_rgb`.
    private static func hslHSVToRGB(h hDeg: Double, s: Double, v: Double) -> SIMD3<Double> {
        let h = pymod(hDeg, 360.0) / 60.0
        let i = min(max(Int(h.rounded(.down)), 0), 5)
        let f = h - h.rounded(.down)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    /// `hsl_model.apply_hsl`: 8-band Hue/Saturation/Luminance color mixer.
    /// Per-band contributions (each weighted by `hslBandWeight`) accumulate
    /// into one hue shift, one saturation delta, and one luminance delta,
    /// applied together (Hue+Sat via HSV reconstruction, then Luminance via
    /// an absolute-`dY` rescale) -- matching the reference's own single-pass
    /// structure, not a per-band sequential re-application.
    public static func hsl(_ value: SIMD3<Double>, adjustments: [HSLBand: HSLAdjustment]) -> SIMD3<Double> {
        guard adjustments.values.contains(where: { $0.hue != 0 || $0.saturation != 0 || $0.luminance != 0 })
        else { return value }

        let (hIn, sIn, vIn) = hslRGBToHSV(value)
        var hueShift = 0.0
        var satDelta = 0.0
        var lumDelta = 0.0
        for band in hslBandOrder {
            guard let adjustment = adjustments[band] else { continue }
            let ordinal = hslOrdinal(band)
            let wi = hslBandWeight(hueDeg: hIn, ordinal: ordinal)
            if adjustment.hue != 0 {
                let sign: Double = adjustment.hue >= 0 ? 1 : -1
                hueShift += wi * (abs(adjustment.hue) / 60.0) * hueShiftMaxDeg(ordinal: ordinal, sign: sign)
            }
            if adjustment.saturation != 0 {
                satDelta += wi * hslSatDeltaUnit(sIn: sIn, slider: adjustment.saturation)
            }
            if adjustment.luminance != 0 {
                lumDelta += wi * hslLumDeltaUnit(ordinal: ordinal, sIn: sIn, vIn: vIn, slider: adjustment.luminance)
            }
        }

        let hOut = pymod(hIn + hueShift, 360.0)
        let sOut = min(max(sIn + satDelta, 0.0), 1.0)
        var rgbOut: SIMD3<Double>
        if satDelta < 0 {
            // `hsl_model.apply_hsl` v2: lowering saturation pivots on HSL
            // lightness (max+min)/2, not HSV value -- real photos (round4,
            // 5 scenes) solve to p/L = 0.984 when lowering and p/V = 1.004
            // when raising. Rotate the hue first, then shrink toward L by
            // the `k` that lands HSV saturation exactly on `sOut`.
            let rgbHue = hslHSVToRGB(h: hOut, s: sIn, v: vIn)
            let mx = rgbHue.max()
            let mn = rgbHue.min()
            let lMid = 0.5 * (mx + mn)
            let denom = (mx - mn) - sOut * (mx - lMid)
            let k = denom > 1e-9 ? sOut * lMid / denom : 1.0
            rgbOut = SIMD3(repeating: lMid) + k * (rgbHue - SIMD3(repeating: lMid))
        } else {
            rgbOut = hslHSVToRGB(h: hOut, s: sOut, v: vIn)
        }

        if lumDelta != 0 {
            let yMid = ppLuminance(rgbOut)
            let yTarget = max(yMid + lumDelta, 0.0)
            let scale = yMid > 1e-9 ? yTarget / yMid : 1.0
            rgbOut *= scale
        }
        return rgbOut
    }

    // MARK: - 5) Color Grading (Color Grading 4-way + legacy Split Toning)

    private struct GradeBetaShape { let a: Double, p: Double, q: Double }

    /// `color_model._grade_direction` (v2, 2026-09-24): the luminance-
    /// preserving direction of hue `hueDeg` -- the classic HSV primary/
    /// secondary blend `hsv(h, 1, 1)` in linear ProPhoto minus its own
    /// ProPhoto luminance, normalized. A **fixed direction per slider hue**
    /// (Color Grading tints every pixel in its luma range toward one
    /// direction, unlike Calibration/HSL). Real-photo split toning
    /// (round4 night, round0 bluesky2) keeps linear ProPhoto luminance and
    /// follows this direction within a few degrees; v1's chart-fitted U/V
    /// basis tilted hue 186 by 24 degrees and brightened it.
    private static func gradeDirection(hueDeg: Double) -> SIMD3<Double> {
        let h = pymod(hueDeg, 360.0) / 60.0
        let i = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let c: SIMD3<Double>
        switch i {
        case 0: c = SIMD3(1.0, f, 0.0)
        case 1: c = SIMD3(1.0 - f, 1.0, 0.0)
        case 2: c = SIMD3(0.0, 1.0, f)
        case 3: c = SIMD3(0.0, 1.0 - f, 1.0)
        case 4: c = SIMD3(f, 0.0, 1.0)
        default: c = SIMD3(1.0, 0.0, 1.0 - f)
        }
        let d = c - SIMD3(repeating: ppLuminance(c))
        return d / (d * d).sum().squareRoot()
    }

    /// `color_model._BAND_BETA` (hue/saturation bands).
    private static let gradeBandShadow = GradeBetaShape(a: exp(-0.86051536), p: 0.88294159, q: 2.34615843)
    private static let gradeBandHighlight = GradeBetaShape(a: exp(0.01113423), p: 1.76472336, q: 1.19134596)
    private static let gradeBandMidtone = GradeBetaShape(a: 1.5920141078510772, p: 1.9378569616662107, q: 3.0530269450978214)
    private static let gradeBandGlobal = GradeBetaShape(a: 0.29233407752050095, p: 0.9920668755406261, q: 1.0121040736037288)

    /// `color_model._LUM_BETA` (the two measured `*Lum` sliders only -- see
    /// `ColorGradingSettings`'s doc comment for why midtone/global have none).
    private static let gradeLumShadow = (beta: GradeBetaShape(a: 0.12947373365072104, p: 0.6354625632941924, q: 2.3947249354714275), sign: -1.0)
    private static let gradeLumHighlight = (beta: GradeBetaShape(a: 0.2916981518720153, p: 1.5394825079594296, q: 0.36475501165219637), sign: 1.0)

    private static func gradeBetaWeight(_ y: Double, _ band: GradeBetaShape) -> Double {
        let yy = min(max(y, 1e-6), 1.0 - 1e-6)
        return band.a * pow(yy, band.p) * pow(1.0 - yy, band.q)
    }

    /// `color_model.GRADE_PROTECT_EXPONENT`: midtone/global (and shadow/
    /// highlight at Blending 100).
    private static let gradeProtectExponent = 1.0

    /// `color_model._protect_exponents` (v2): existing-saturation protection
    /// exponents for (shadow, highlight). Blending 50 real photos (round4
    /// night) show ~0.5 / none; Blending 100 (round0) keeps v1's 1.0 / 1.0;
    /// linear in between, Blending 50's values below 50.
    private static func gradeProtectExponents(blend: Double) -> (shadow: Double, highlight: Double) {
        let t = min(max((blend - 50.0) / 50.0, 0.0), 1.0)
        return (0.5 + 0.5 * t, t)
    }

    /// `color_model._balance_scale`.
    private static func gradeBalanceScale(_ balance: Double) -> (shadow: Double, highlight: Double) {
        (max(1.0 - balance / 100.0 * 0.55, 0.0), max(1.0 + balance / 100.0 * 0.05, 0.0))
    }

    /// `color_model._BLEND50_MASK_Y` / `_BLEND50_MASK` (v2): Blending 50's
    /// luminance mask on the Blending-100 band shapes, measured on round4
    /// night (5 scenes, S < 0.1 pixels). v1's `_blend_shape` sharpened `q`
    /// for both bands, which moved the highlight band's peak toward the
    /// shadows (Y ~0.25) -- the opposite of the measured Y ~0.65.
    private static let gradeBlend50MaskY: [Double] = [0.0, 0.015, 0.045, 0.08, 0.125, 0.185, 0.26, 0.35, 0.45, 0.56, 0.685, 0.825, 1.0]
    private static let gradeBlend50MaskShadow: [Double] = [0.9, 0.86, 0.74, 0.54, 0.39, 0.29, 0.26, 0.26, 0.24, 0.27, 0.30, 0.25, 0.25]
    private static let gradeBlend50MaskHighlight: [Double] = [0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.28, 0.35, 0.45, 0.53, 0.60, 0.64, 0.70]

    /// `np.interp` (clamped to the end values outside the knot range).
    private static func interpolate(_ x: Double, knots: [Double], values: [Double]) -> Double {
        if x <= knots[0] { return values[0] }
        for k in 1..<knots.count where x <= knots[k] {
            let f = (x - knots[k - 1]) / (knots[k] - knots[k - 1])
            return values[k - 1] + (values[k] - values[k - 1]) * f
        }
        return values[values.count - 1]
    }

    /// `color_model._blend_mask` (v2): 1 at Blending 100, the measured mask
    /// at 50, linear in `(100 - blend) / 50` and clipped to [0, 1] below.
    private static func gradeBlendMask(_ blend: Double, shadow: Bool, y: Double) -> Double {
        guard blend < 100 else { return 1.0 }
        let t = (100.0 - min(max(blend, 0.0), 100.0)) / 50.0
        let m50 = interpolate(y, knots: gradeBlend50MaskY, values: shadow ? gradeBlend50MaskShadow : gradeBlend50MaskHighlight)
        return min(max(1.0 - t * (1.0 - m50), 0.0), 1.0)
    }

    /// `color_model.apply_color_grading`. `settings.midtone.luminance` and
    /// `settings.global.luminance` are read nowhere here -- intentional, see
    /// `ColorGradingSettings`'s doc comment.
    public static func colorGrading(_ value: SIMD3<Double>, settings: ColorGradingSettings) -> SIMD3<Double> {
        guard needsColorGrading(settings) else { return value }
        let yLuma = min(max(ppLuminance(value), 0.0), 1.0)
        let (shadowScale, highlightScale) = gradeBalanceScale(settings.balance)
        let unprotected = min(max(1.0 - hslRelativeSaturation(value), 0.0), 1.0)
        let exponents = gradeProtectExponents(blend: settings.blending)

        var delta = SIMD3<Double>.zero
        // (shape, hue, saturation, balance scale, protection exponent, blend mask: nil / shadow / highlight)
        let hueSatBands: [(GradeBetaShape, Double, Double, Double, Double, Bool?)] = [
            (gradeBandShadow, settings.shadow.hue, settings.shadow.saturation, shadowScale, exponents.shadow, true),
            (gradeBandHighlight, settings.highlight.hue, settings.highlight.saturation, highlightScale, exponents.highlight, false),
            (gradeBandMidtone, settings.midtone.hue, settings.midtone.saturation, 1.0, gradeProtectExponent, nil),
            (gradeBandGlobal, settings.global.hue, settings.global.saturation, 1.0, gradeProtectExponent, nil)
        ]
        for (band, hue, sat, extraScale, exponent, maskShadow) in hueSatBands where sat != 0 {
            var w = gradeBetaWeight(yLuma, band) * (sat / 30.0) * extraScale * pow(unprotected, exponent)
            if let maskShadow {
                w *= gradeBlendMask(settings.blending, shadow: maskShadow, y: yLuma)
            }
            delta += w * gradeDirection(hueDeg: hue)
        }

        let lumBands: [((beta: GradeBetaShape, sign: Double), Double, Double)] = [
            (gradeLumShadow, settings.shadow.luminance, shadowScale),
            (gradeLumHighlight, settings.highlight.luminance, highlightScale)
        ]
        for (band, lum, scale) in lumBands where lum != 0 {
            let w = gradeBetaWeight(yLuma, band.beta) * band.sign * (lum / 50.0) * scale
            delta += SIMD3(repeating: w)
        }

        return clamp01(value + delta)
    }

    /// Whether `colorGrading(_:settings:)` would differ from the identity.
    /// Hue-only bands (sat == 0), `blending`/`balance` alone, and
    /// midtone/global luminance are all no-ops in the reference -- matching
    /// `colorGrading`'s own `where sat != 0` / `where lum != 0` guards.
    public static func needsColorGrading(_ settings: ColorGradingSettings) -> Bool {
        settings.shadow.saturation != 0 || settings.shadow.luminance != 0
            || settings.midtone.saturation != 0
            || settings.highlight.saturation != 0 || settings.highlight.luminance != 0
            || settings.global.saturation != 0
    }

    // MARK: - 6) Stage Q composition

    /// `docs/PHASE2_C2_C3.md`'s Stage Q order: Vibrance -> Saturation -> HSL
    /// -> Color Grading. Camera Calibration is **not** included here -- it
    /// is applied as its own `CIColorMatrix` right before cube Q
    /// (`CalibrationOrder`), both for caching (a calibration-only change
    /// never invalidates this cube) and because real photos put it
    /// output-referenced (`.photobench/phase2/raw-validated.md`, round4), not
    /// immediately after Stage H/M -- see
    /// `AdobeBaseRenderer.Handle.image(settings:)`.
    public static func applyColorOps(_ value: SIMD3<Double>, settings: EditSettings) -> SIMD3<Double> {
        var result = value
        result = vibrance(result, amount: settings.vibrance)
        result = saturation(result, amount: settings.saturation)
        result = hsl(result, adjustments: settings.hsl)
        result = colorGrading(result, settings: settings.colorGrading)
        return result
    }

    /// Whether `applyColorOps` would do anything other than return its input
    /// unchanged -- used to skip baking/caching a cube Q that would just be
    /// the identity, exactly like `ToneOps.needsPostOps`.
    public static func needsColorOps(_ settings: EditSettings) -> Bool {
        settings.vibrance != 0
            || settings.saturation != 0
            || settings.hsl.values.contains { $0.hue != 0 || $0.saturation != 0 || $0.luminance != 0 }
            || needsColorGrading(settings.colorGrading)
    }
}

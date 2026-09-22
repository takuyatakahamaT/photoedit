import Foundation

public enum AdobeColorMathError: Error, Sendable, Equatable, LocalizedError {
    case missingColorMatrix
    case missingCalibrationIlluminant

    public var errorDescription: String? {
        switch self {
        case .missingColorMatrix: "DCPにColorMatrix1/2がありません。"
        case .missingCalibrationIlluminant: "DCPにCalibrationIlluminant1/2がありません。"
        }
    }
}

/// Which Adobe Color `ToneCurvePV2012` application to use at Stage C. See
/// `docs/PHASE1_BASE_RENDERING.md` 注1: the three variants agree to within
/// 0.3 ΔE (noise-level for this comparison), and phase1 ships with `.b` as
/// the default while keeping all three selectable pending a confirming
/// measurement.
public enum ToneCurveVariant: String, Sendable, Equatable, CaseIterable {
    /// Applied per-channel on sRGB-OETF-encoded ProPhoto values.
    case a
    /// Applied hue-preserving (`RGBTone.apply`) on linear values. The
    /// phase1 default.
    case b
    /// Not applied at all.
    case c
    /// Applied hue-preserving (`RGBTone.applyEncoded`) in the sRGB-encoded
    /// domain: the curve's 0...255 axis is read as sRGB-encoded tone. The
    /// production default since 2026-09-22 (round1 measurement; together
    /// with the DC-S5 baseline EV of -0.135 it reproduces both Lightroom's
    /// "Adobe Color" default and "Adobe Standard" renders within +/-0.03 EV).
    case d

    /// The variant `RenderStage.final` and the production renderer use.
    public static let production: ToneCurveVariant = .d

    /// Applies Adobe Color's look point curve (`spline`, [0,1] domain) to
    /// linear ProPhoto `value` per this variant.
    public func apply(_ value: SIMD3<Double>, spline: DNGSpline) -> SIMD3<Double> {
        switch self {
        case .c:
            return value
        case .b:
            return RGBTone.apply(value, curve: spline.evaluate)
        case .a:
            let clipped = SIMD3(
                min(max(value.x, 0.0), 1.0),
                min(max(value.y, 0.0), 1.0),
                min(max(value.z, 0.0), 1.0)
            )
            let encoded = SIMD3(
                DNGColorSpace.srgbEncode(clipped.x),
                DNGColorSpace.srgbEncode(clipped.y),
                DNGColorSpace.srgbEncode(clipped.z)
            )
            let curved = SIMD3(spline.evaluate(encoded.x), spline.evaluate(encoded.y), spline.evaluate(encoded.z))
            return SIMD3(
                DNGColorSpace.srgbDecode(curved.x),
                DNGColorSpace.srgbDecode(curved.y),
                DNGColorSpace.srgbDecode(curved.z)
            )
        case .d:
            return RGBTone.applyEncoded(
                value, curve: spline.evaluate,
                encode: DNGColorSpace.srgbEncode, decode: DNGColorSpace.srgbDecode
            )
        }
    }
}

/// A stage boundary in the phase1 base-rendering pipeline (see
/// `docs/PHASE1_BASE_RENDERING.md`'s "処理順"), matching the Python
/// prototype's per-stage checkpoints in
/// `.photobench/engine-research-20260922/dcp-base-prototype/scripts/pipeline.py`
/// and this project's `Tests/Fixtures/phase1/stage-samples.json`.
public enum RenderStage: Sendable, Equatable {
    /// Camera RGB (as-shot white balanced) -> linear ProPhoto, via the
    /// CCT-interpolated ForwardMatrix.
    case matrix
    /// After the DCP's `ProfileHueSatMap` (pre-exposure).
    case hueSat
    /// After the `2^(baselineEV + userEV)` exposure gain.
    case exposure
    /// After the DCP's own embedded `ProfileLookTableData`, if any.
    case lookDCP
    /// After Adobe Color's `LookTable`.
    case lookAdobe
    /// After the ACR3 default tone curve (`RefBaselineRGBTone`).
    case acr3Tone
    /// After Adobe Color's `ToneCurvePV2012` point curve, applied per `ToneCurveVariant`.
    case lookToneCurve(ToneCurveVariant)
    /// `lookToneCurve(ToneCurveVariant.production)`, then converted to linear
    /// sRGB (`docs/PHASE1_BASE_RENDERING.md` 注3: extended range, NOT
    /// clipped and NOT gamma-encoded -- negative/over-1 values are kept for
    /// the existing terminal gamut compression downstream in
    /// `RenderEngine`). This is the actual camera(WB'd)RGB -> working-space
    /// hand-off point to the rest of the app; `Tests/Fixtures/phase1/stage-samples.json`'s
    /// `final_srgb8_variant_b` is a SEPARATE, further-processed
    /// (clipped + gamma-encoded + 8-bit-quantized) value used only for that
    /// fixture's Lightroom-JPEG comparison harness, not this stage's own
    /// contract -- tests reproduce that extra step themselves via
    /// `DNGColorSpace.srgbEncode` when cross-checking against it.
    case final
}

/// Colorimetry- and profile-derived assets for evaluating the phase1 base
/// pipeline against one camera-native white-balance condition (one photo,
/// or more precisely one as-shot neutral / correlated color temperature).
/// Build once per photo (or per profile+neutral pair) and reuse across all
/// pixels.
public struct AdobeBaseAssets: Sendable {
    /// Camera(as-shot-white-balanced) -> linear ProPhoto.
    public internal(set) var combinedMatrix: Matrix3x3
    /// CCT-interpolated `ProfileHueSatMap`, or `nil` if the DCP has none
    /// (Stage H becomes a no-op in that case).
    public internal(set) var huesatTable: DCPProfile.HueSatTable?
    /// The DCP's own embedded `ProfileLookTableData`, or `nil` if absent
    /// (Stage L(dcp) becomes a no-op in that case).
    public let dcpLookTable: DCPProfile.HueSatTable?
    /// Adobe Color's `LookTable`.
    public let adobeLookTable: DCPProfile.HueSatTable
    /// Adobe Color's `ToneCurvePV2012`, pre-solved, in [0,1] domain.
    public let toneCurveSpline: DNGSpline
    /// `AdobeBaseCalibration.baselineEV(uniqueCameraModel:)` for this DCP's camera.
    public let baselineEV: Double
    /// The converged as-shot white chromaticity (`ColorSpec.neutralToXY`), or
    /// (after `rebalanced(toWhiteXY:)`) the phase2 C1 absolute-white-balance
    /// override's chromaticity.
    public internal(set) var whiteXY: ChromaticityXY
    public internal(set) var temperatureKelvin: Double
    /// Dual-illuminant interpolation weight at `whiteXY` (1 == fully the
    /// lower-temperature calibration).
    public internal(set) var gFraction: Double

    /// Retained (not just consumed by `init`) so `rebalanced(toWhiteXY:)` can
    /// re-derive `combinedMatrix`/`huesatTable` for a different white point
    /// -- phase2 C1's absolute white balance (XMP `WhiteBalance == Custom`) --
    /// without needing the caller to hold on to the original `DCPProfile`/
    /// `AdobeLookXMP`/`neutralG1` themselves.
    let spec: ColorSpec
    let neutralG1: SIMD3<Double>
    let rawHueSatMapData1: DCPProfile.HueSatTable?
    let rawHueSatMapData2: DCPProfile.HueSatTable?
    let colorSpecVariant: ColorSpecVariant

    /// - Parameters:
    ///   - neutralG1: the as-shot neutral camera-space RGB ratio, normalized
    ///     so the green channel is 1.0 (the standard DNG `AsShotNeutral`
    ///     convention). NOT the same as a raw `1/WBLevel` ratio some raw
    ///     decoders report on an arbitrary absolute scale -- see
    ///     `Tests/Fixtures/phase1/colorspec-cases.json`'s "notes" for why
    ///     that distinction matters for `.sdkCameraWhite`.
    ///   - variant: `.sdkCameraWhite` (the default) is the DNG-SDK-faithful
    ///     reading; `.matchPrototype` reproduces the Python prototype's
    ///     simplification exactly (fixture-parity / regression use only).
    ///   - baselineEV: overrides `AdobeBaseCalibration` (fixture parity and
    ///     calibration experiments); `nil` uses the per-camera table.
    public init(
        dcp: DCPProfile, look: AdobeLookXMP, neutralG1: SIMD3<Double>,
        variant: ColorSpecVariant = .sdkCameraWhite,
        baselineEV: Double? = nil
    ) throws {
        guard let colorMatrix1 = dcp.colorMatrix1, let colorMatrix2 = dcp.colorMatrix2 else {
            throw AdobeColorMathError.missingColorMatrix
        }
        guard let illuminant1 = dcp.calibrationIlluminant1, let illuminant2 = dcp.calibrationIlluminant2 else {
            throw AdobeColorMathError.missingCalibrationIlluminant
        }

        let spec = try ColorSpec(
            colorMatrix1: colorMatrix1, colorMatrix2: colorMatrix2,
            forwardMatrix1: dcp.forwardMatrix1, forwardMatrix2: dcp.forwardMatrix2,
            calibrationIlluminant1: illuminant1, calibrationIlluminant2: illuminant2
        )
        let whiteXY = try spec.neutralToXY(neutralG1)
        let combined = try AdobeColorSpec.combinedCameraToLinearProPhoto(
            spec: spec, white: whiteXY, neutralG1: neutralG1, variant: variant
        )

        var huesat: DCPProfile.HueSatTable?
        if let data1 = dcp.hueSatMapData1, let data2 = dcp.hueSatMapData2 {
            huesat = try HueSatMap.interpolated(data1, data2, g: spec.gFraction(white: whiteXY))
        }

        self.combinedMatrix = combined
        self.huesatTable = huesat
        self.dcpLookTable = dcp.lookTableData
        self.adobeLookTable = look.lookTableData
        self.toneCurveSpline = try DNGSpline(
            points: look.toneCurvePoints.map { (x: $0.x / 255.0, y: $0.y / 255.0) }
        )
        self.baselineEV = baselineEV ?? AdobeBaseCalibration.baselineEV(uniqueCameraModel: dcp.uniqueCameraModel)
        self.whiteXY = whiteXY
        self.temperatureKelvin = DNGTemperature.xyToTemperature(whiteXY)
        self.gFraction = spec.gFraction(white: whiteXY)
        self.spec = spec
        self.neutralG1 = neutralG1
        self.rawHueSatMapData1 = dcp.hueSatMapData1
        self.rawHueSatMapData2 = dcp.hueSatMapData2
        self.colorSpecVariant = variant
    }

    /// Phase2 C1 absolute white balance (XMP `WhiteBalance == Custom`):
    /// recomputes Stage M's `combinedMatrix` and Stage H's `huesatTable` for
    /// `newWhiteXY` instead of the as-shot white this instance was built
    /// with. `baselineEV`/`dcpLookTable`/`adobeLookTable`/`toneCurveSpline`
    /// never depend on white point, so they carry over unchanged.
    ///
    /// Reuses the *original* `neutralG1` (the physical as-shot calibration
    /// ratio) rather than deriving a fresh "neutral for `newWhiteXY`" and
    /// pre-rebalancing the camera image by `neutralG1/neutral'` before Stage
    /// M, as `docs/PHASE2_DEVELOP_PIPELINE.md`'s prose describes: substituting
    /// `rawRGB = cameraRGB_asShotWB * neutralG1` into the DNG SDK's own
    /// `XYZ = ForwardMatrix(xy) @ diag(1/CameraWhite(xy)) @ rawRGB` shows the
    /// two are algebraically identical for any `xy` (the `neutral'` factor
    /// cancels), so this calls the already-validated
    /// `AdobeColorSpec.combinedCameraToLinearProPhoto` directly at the new
    /// white point instead of introducing a second, redundant diagonal.
    func rebalanced(toWhiteXY newWhiteXY: ChromaticityXY) throws -> AdobeBaseAssets {
        var copy = self
        copy.combinedMatrix = try AdobeColorSpec.combinedCameraToLinearProPhoto(
            spec: spec, white: newWhiteXY, neutralG1: neutralG1, variant: colorSpecVariant
        )
        if let data1 = rawHueSatMapData1, let data2 = rawHueSatMapData2 {
            copy.huesatTable = try HueSatMap.interpolated(data1, data2, g: spec.gFraction(white: newWhiteXY))
        }
        copy.whiteXY = newWhiteXY
        copy.temperatureKelvin = DNGTemperature.xyToTemperature(newWhiteXY)
        copy.gFraction = spec.gFraction(white: newWhiteXY)
        return copy
    }
}

/// CPU reference implementation of the phase1 base-rendering math: the
/// single source of truth the GPU 3D-LUT baking (`AdobeBaseRenderer`, a
/// later phase1 file) samples per stage, and what
/// `Tests/PhotoCoreTests/AdobeProfileTests.swift` cross-checks against the
/// Python prototype's `Tests/Fixtures/phase1/stage-samples.json`.
public enum AdobeColorMath {
    /// Evaluates one camera-space RGB triple through the pipeline up to
    /// (and including) `stage`. `userEV` is always 0 in phase1 (no user
    /// exposure control has been wired in yet); it is threaded through now
    /// so later phases inserting user edits around Stage E do not need to
    /// change this signature.
    public static func evaluate(
        cameraRGB: SIMD3<Double>, through stage: RenderStage, assets: AdobeBaseAssets, userEV: Double = 0
    ) -> SIMD3<Double> {
        var value = assets.combinedMatrix * cameraRGB
        if stage == .matrix { return value }

        if let huesat = assets.huesatTable {
            value = HueSatMap.apply(value, table: huesat)
        }
        if stage == .hueSat { return value }

        let gain = pow(2.0, assets.baselineEV + userEV)
        value *= gain
        if stage == .exposure { return value }

        if let dcpLook = assets.dcpLookTable {
            value = HueSatMap.apply(value, table: dcpLook)
        }
        if stage == .lookDCP { return value }

        value = HueSatMap.apply(value, table: assets.adobeLookTable)
        if stage == .lookAdobe { return value }

        value = RGBTone.apply(value, curve: ACR3DefaultToneCurve.evaluate)
        if stage == .acr3Tone { return value }

        switch stage {
        case .lookToneCurve(let variant):
            return variant.apply(value, spline: assets.toneCurveSpline)

        case .final:
            let afterCurve = ToneCurveVariant.production.apply(value, spline: assets.toneCurveSpline)
            return DNGColorSpace.proPhotoToSRGBLinear * afterCurve

        case .matrix, .hueSat, .exposure, .lookDCP, .lookAdobe, .acr3Tone:
            // Unreachable (handled by the early returns above); listed only
            // so this switch stays exhaustive if RenderStage grows a case.
            return value
        }
    }

}

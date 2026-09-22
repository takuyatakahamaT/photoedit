import Foundation

/// Per-camera-model "baseline EV" correction (Stage E in
/// `docs/PHASE1_BASE_RENDERING.md`): the gap between LibRaw's own white
/// normalization and Adobe's internal exposure scale, which RW2 files do
/// not record (there is no `BaselineExposure` DCP/EXIF tag to read for this
/// camera). Values are fit empirically against Lightroom-default JPEGs, not
/// derived from any spec.
public enum AdobeBaseCalibration {
    /// `UniqueCameraModel` (case-sensitive, matching the DCP's own string)
    /// -> baseline EV in stops.
    ///
    /// "Panasonic DC-S5": -0.135 EV. Fitted 2026-09-22 against LibRaw 0.21.4
    /// output on three Lightroom exports of the same RAWs rendered with BOTH
    /// "Adobe Color" (default look) and "Adobe Standard" (no look): with this
    /// offset and `ToneCurveVariant.d` for the look curve, every render lands
    /// within -0.03...0 EV of Lightroom on a region-average comparison
    /// (`scripts/lr_measure/compare_renders.py`). Earlier values (+0.057 from
    /// the Python prototype, then 0) only fit one profile at a time because
    /// the look curve was being applied on linear values. The RW2 files carry
    /// no `BaselineExposure` tag; re-fit with a pixel-aligned comparison once
    /// lens corrections exist (phase 4).
    private static let baselineEVByModel: [String: Double] = [
        "Panasonic DC-S5": -0.135,
    ]

    /// Baseline EV for `uniqueCameraModel`, or 0 for any unknown model.
    public static func baselineEV(uniqueCameraModel: String) -> Double {
        baselineEVByModel[uniqueCameraModel] ?? 0.0
    }
}

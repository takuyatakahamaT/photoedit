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
    /// "Panasonic DC-S5": +0.057. Source: 2026-09-22,
    /// `.photobench/engine-research-20260922/dcp-base-prototype/` --
    /// against LibRaw 0.21.4's output, fit per-photo against 3 Lightroom-
    /// default JPEGs (P1013558/P1013207/P1012822), giving +0.058 / +0.041 /
    /// +0.071 EV; this constant is their mean. The RW2 files carry no
    /// `BaselineExposure` tag for this camera.
    private static let baselineEVByModel: [String: Double] = [
        "Panasonic DC-S5": 0.057,
    ]

    /// Baseline EV for `uniqueCameraModel`, or 0 for any unknown model.
    public static func baselineEV(uniqueCameraModel: String) -> Double {
        baselineEVByModel[uniqueCameraModel] ?? 0.0
    }
}

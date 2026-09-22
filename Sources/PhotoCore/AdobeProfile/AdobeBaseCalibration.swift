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
    /// "Panasonic DC-S5": 0. History (2026-09-22): the Python prototype in
    /// `.photobench/engine-research-20260922/dcp-base-prototype/` fitted
    /// +0.058 / +0.041 / +0.071 EV per photo (mean +0.057) against LibRaw
    /// 0.21.4 output, but that prototype still misread the Adobe Color look
    /// table and lacked the HueSatMap clamp. With the corrected Swift
    /// pipeline the same three Lightroom-default JPEGs measured a residual
    /// of +0.041 / +0.050 / +0.053 EV at 0.057, i.e. the true offset is
    /// about +0.009 EV -- within the alignment noise of the region-average
    /// comparison, so it is treated as zero (LibRaw's white normalization
    /// matches Adobe's scale for this camera). Re-fit only with a
    /// pixel-aligned comparison after lens correction (phase 4). The RW2
    /// files carry no `BaselineExposure` tag for this camera.
    private static let baselineEVByModel: [String: Double] = [
        "Panasonic DC-S5": 0.0,
    ]

    /// Baseline EV for `uniqueCameraModel`, or 0 for any unknown model.
    public static func baselineEV(uniqueCameraModel: String) -> Double {
        baselineEVByModel[uniqueCameraModel] ?? 0.0
    }
}

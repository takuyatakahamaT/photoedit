import CoreGraphics
import CoreImage
import Foundation

/// Applies a Panasonic RW2's embedded (camera-in-body) radial distortion
/// correction to a decoded camera-RGB image, matching Lightroom's own
/// rendering of the same RAW (`.photobench/phase4/lens/model.md`, confirmed
/// to RMS 0.42-0.63px against real Lightroom exports with zero free
/// parameters).
///
/// Model (`model.md` §1.1, ExifTool `PanasonicRaw.pm`'s `DistortionInfo`
/// comment "ref 3"): `Ru = scale*(Rd + a*Rd^3 + b*Rd^5 + c*Rd^7)`, where
/// `Rd`/`Ru` are the pre-/post-correction radius normalized by the
/// body-constant `R0` (`PanasonicDistortionInfo.r0`), angle preserved
/// (pure radial map), center = each image's own geometric center. Producing
/// a corrected *output* pixel requires the inverse (`Ru` -> `Rd`), solved by
/// Newton's method exactly as `.photobench/phase4/lens/scripts/
/// step4_vignetting.py`'s `invert_distortion` does it (same 8 iterations,
/// same starting guess `Rd = Ru/scale`), so `sourcePosition(forOutput:)`
/// and that script agree to floating-point precision -- this is exactly
/// what `LensCorrectionTests` checks against
/// `Tests/Fixtures/phase4/lens-distortion.json`.
public enum LensDistortion {
    /// Everything the inverse radial map needs, already resolved to one
    /// consistent coordinate space (`model.md` §6: the output canvas is
    /// `(cropRight-cropLeft) x (cropBottom-cropTop)` -- scaled by
    /// `scaleFactor` for a half-size decode -- centered on the decoder's
    /// own output; it is *not* offset by the RAW's `CropLeft`/`CropTop`).
    public struct Parameters: Equatable, Sendable {
        public let scale: Double
        public let a: Double
        public let b: Double
        public let c: Double
        /// Normalization radius (`DistortionN`), already scaled by the same
        /// `scaleFactor` as `outputCenter`/`inputCenter` for a half-size
        /// decode.
        public let r0: Double
        /// Geometric center of the *output* (corrected) canvas.
        public let outputCenter: CGPoint
        /// Geometric center of the *input* (LibRaw-native, uncorrected)
        /// image being sampled.
        public let inputCenter: CGPoint

        public init(
            scale: Double, a: Double, b: Double, c: Double, r0: Double,
            outputCenter: CGPoint, inputCenter: CGPoint
        ) {
            self.scale = scale
            self.a = a
            self.b = b
            self.c = c
            self.r0 = r0
            self.outputCenter = outputCenter
            self.inputCenter = inputCenter
        }
    }

    /// Newton's-method iteration count. Matches the Python prototype
    /// (`step4_vignetting.py`'s `invert_distortion(..., iters=8)`); the
    /// function is smooth and monotonic over the relevant radius range, so
    /// 8 iterations converge far past single-pixel precision (`model.md`
    /// §1.1's "6〜8回の反復で収束").
    private static let newtonIterations = 8
    private static let derivativeFloor = 1e-9

    /// Given a pixel position in the *output* (corrected) image, returns
    /// the position to bilinearly sample from the *input* (uncorrected)
    /// image. Pure Swift, used by tests and by nothing performance-critical
    /// (`apply(to:info:scaleFactor:)` reimplements the same math as a
    /// `CIWarpKernel` for the actual per-pixel resample).
    public static func sourcePosition(forOutput output: CGPoint, parameters: Parameters) -> CGPoint {
        let dx = output.x - parameters.outputCenter.x
        let dy = output.y - parameters.outputCenter.y
        let rOut = (dx * dx + dy * dy).squareRoot()
        let ru = rOut / parameters.r0
        var rd = ru / parameters.scale
        for _ in 0..<newtonIterations {
            let rd2 = rd * rd
            let rd3 = rd2 * rd
            let rd5 = rd3 * rd2
            let rd7 = rd5 * rd2
            let g = parameters.scale * (rd + parameters.a * rd3 + parameters.b * rd5 + parameters.c * rd7) - ru
            let gp = parameters.scale
                * (1 + 3 * parameters.a * rd2 + 5 * parameters.b * rd2 * rd2 + 7 * parameters.c * rd2 * rd2 * rd2)
            rd -= g / (abs(gp) > derivativeFloor ? gp : derivativeFloor)
        }
        // At r=0 the direction (dx,dy) is undefined and irrelevant (it's
        // multiplied by zero below); `model.md` §6 pins the ratio to
        // `1/scale` there purely so this stays finite instead of 0/0.
        let ratio = rOut > 0 ? (rd * parameters.r0) / rOut : 1.0 / parameters.scale
        return CGPoint(x: parameters.inputCenter.x + dx * ratio, y: parameters.inputCenter.y + dy * ratio)
    }

    /// Warps `image` (a decoded-but-uncorrected camera-RGB `CIImage`, e.g.
    /// `LibRawDecoder`'s `makeCameraImage` output -- linear light, no color
    /// management) into the corrected canvas implied by `info` and
    /// `scaleFactor`. `scaleFactor` is `LibRawDecoder`'s own
    /// `appliedScaleFactor` (1.0 full-size, 0.5 half-size): `model.md` §6
    /// says lengths (crop size, `R0`) scale with it while the dimensionless
    /// `scale`/`a`/`b`/`c` do not.
    ///
    /// The output extent is always `(0, 0, round(cropWidth*scaleFactor),
    /// round(cropHeight*scaleFactor))`; both centers are each image's own
    /// geometric center (`model.md` §2/§6 -- confirmed centered, not
    /// `CropLeft`/`CropTop`-offset, to within measurement noise).
    public static func apply(to image: CIImage, info: PanasonicDistortionInfo, scaleFactor: Double) -> CIImage {
        let inputExtent = image.extent
        let outputWidth = (Double(info.cropWidth) * scaleFactor).rounded()
        let outputHeight = (Double(info.cropHeight) * scaleFactor).rounded()
        let outputExtent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let outputCenter = CGPoint(x: outputWidth / 2, y: outputHeight / 2)
        let inputCenter = CGPoint(x: inputExtent.midX, y: inputExtent.midY)
        let r0 = info.r0 * scaleFactor

        guard let warped = warpKernel.apply(
            extent: outputExtent,
            roiCallback: { _, _ in inputExtent },
            image: image,
            arguments: [
                CIVector(x: outputCenter.x, y: outputCenter.y),
                CIVector(x: inputCenter.x, y: inputCenter.y),
                r0, info.scale, info.a, info.b, info.c
            ]
        ) else {
            preconditionFailure("Photo Benchのレンズ歪曲補正カーネルを適用できませんでした。")
        }
        return warped
    }

    /// Same "compile a CIKL string at runtime" convention as
    /// `SRGBOutputTransform.shoulderKernel`/`gamutKernel` and
    /// `ToneCurveModel.makeKernel`, but `CIWarpKernel` instead of
    /// `CIColorKernel`: the kernel function returns the *source* (input
    /// image) sample position for each destination pixel (`destCoord()`),
    /// rather than a color. Math mirrors `sourcePosition(forOutput:)`
    /// above exactly (same Newton iteration count and starting guess).
    static let warpKernel: CIWarpKernel = {
        guard let kernel = CIWarpKernel(source: """
        kernel vec2 photoBenchLensDistortionWarp(
            vec2 outputCenter, vec2 inputCenter, float r0, float scale, float a, float b, float c
        ) {
            vec2 d = destCoord() - outputCenter;
            float rOut = length(d);
            float ru = rOut / r0;
            float rd = ru / scale;
            for (int i = 0; i < 8; i++) {
                float rd2 = rd * rd;
                float rd3 = rd2 * rd;
                float rd5 = rd3 * rd2;
                float rd7 = rd5 * rd2;
                float g = scale * (rd + a * rd3 + b * rd5 + c * rd7) - ru;
                float gp = scale * (1.0 + 3.0 * a * rd2 + 5.0 * b * rd2 * rd2 + 7.0 * c * rd2 * rd2 * rd2);
                rd = rd - g / (abs(gp) > 0.000000001 ? gp : 0.000000001);
            }
            float ratio = rOut > 0.0 ? (rd * r0) / rOut : 1.0 / scale;
            return inputCenter + d * ratio;
        }
        """) else {
            preconditionFailure("Photo Benchのレンズ歪曲補正カーネルをコンパイルできませんでした。")
        }
        return kernel
    }()
}

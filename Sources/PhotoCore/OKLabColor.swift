import Foundation

/// CPU reference implementation of Björn Ottosson's updated OKLab matrices.
/// The renderer keeps scene values in extended-linear sRGB; signed cube roots
/// therefore preserve finite negative components until the final SDR output
/// transform instead of clipping them at an intermediate stage.
struct OKLabColor: Equatable, Sendable {
    var lightness: Double
    var a: Double
    var b: Double

    var chroma: Double { hypot(a, b) }

    var hueDegrees: Double {
        guard chroma > 1e-12 else { return 0 }
        let degrees = atan2(b, a) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    static func from(linearSRGB rgb: SIMD3<Double>) -> OKLabColor {
        let l = 0.412_221_470_8 * rgb.x + 0.536_332_536_3 * rgb.y + 0.051_445_992_9 * rgb.z
        let m = 0.211_903_498_2 * rgb.x + 0.680_699_545_1 * rgb.y + 0.107_396_956_6 * rgb.z
        let s = 0.088_302_461_9 * rgb.x + 0.281_718_837_6 * rgb.y + 0.629_978_700_5 * rgb.z

        let lRoot = cbrt(l)
        let mRoot = cbrt(m)
        let sRoot = cbrt(s)
        return OKLabColor(
            lightness: 0.210_454_255_3 * lRoot + 0.793_617_785_0 * mRoot - 0.004_072_046_8 * sRoot,
            a: 1.977_998_495_1 * lRoot - 2.428_592_205_0 * mRoot + 0.450_593_709_9 * sRoot,
            b: 0.025_904_037_1 * lRoot + 0.782_771_766_2 * mRoot - 0.808_675_766_0 * sRoot
        )
    }

    func linearSRGB() -> SIMD3<Double> {
        // These are the numerical inverses of the updated forward matrices
        // above, rather than a second independently rounded coefficient set.
        // The extra precision prevents hue/chroma reversals for far
        // out-of-gamut working colors before the final compression step.
        let lRoot = 0.999_999_998_450_519_6 * lightness
            + 0.396_337_792_173_767_8 * a + 0.215_803_758_060_758_77 * b
        let mRoot = 1.000_000_008_881_760_7 * lightness
            - 0.105_561_342_323_656_33 * a - 0.063_854_174_771_705_9 * b
        let sRoot = 1.000_000_054_672_410_8 * lightness
            - 0.089_484_182_094_965_74 * a - 1.291_485_537_864_091_7 * b
        let l = lRoot * lRoot * lRoot
        let m = mRoot * mRoot * mRoot
        let s = sRoot * sRoot * sRoot
        return SIMD3(
            4.076_741_661_347_994 * l - 3.307_711_590_408_193_3 * m + 0.230_969_928_729_427_93 * s,
            -1.268_438_004_092_176_3 * l + 2.609_757_400_663_371_5 * m - 0.341_319_396_310_219_6 * s,
            -0.004_196_086_541_837_07 * l - 0.703_418_614_459_449_5 * m + 1.707_614_700_930_944_6 * s
        )
    }

    func replacing(chroma: Double, hueDegrees: Double) -> OKLabColor {
        let radians = hueDegrees * .pi / 180
        return OKLabColor(
            lightness: lightness,
            a: chroma * cos(radians),
            b: chroma * sin(radians)
        )
    }

    static func isInSRGBGamut(_ rgb: SIMD3<Double>, tolerance: Double = 0) -> Bool {
        rgb.x >= -tolerance && rgb.x <= 1 + tolerance
            && rgb.y >= -tolerance && rgb.y <= 1 + tolerance
            && rgb.z >= -tolerance && rgb.z <= 1 + tolerance
    }

    /// Maps the familiar Adobe/HSL band labels to perceptual hue locations.
    /// The source swatches are full-saturation encoded-sRGB colors at L=0.5;
    /// only their OKLCh hue is retained for interpolation.
    static func perceptualHue(for band: HSLBand) -> Double {
        from(linearSRGB: linearSRGBReferenceHue(band.centerHue)).hueDegrees
    }

    private static func linearSRGBReferenceHue(_ degrees: Double) -> SIMD3<Double> {
        let hue = (degrees / 360).truncatingRemainder(dividingBy: 1)
        let channel = { (offset: Double) -> Double in
            var value = (hue + offset).truncatingRemainder(dividingBy: 1)
            if value < 0 { value += 1 }
            let p = 0.0
            let q = 1.0
            if value < 1.0 / 6.0 { return p + (q - p) * 6 * value }
            if value < 1.0 / 2.0 { return q }
            if value < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - value) * 6 }
            return p
        }
        let encoded = SIMD3(channel(1.0 / 3.0), channel(0), channel(-1.0 / 3.0))
        return SIMD3(encoded.x.sRGBToLinear, encoded.y.sRGBToLinear, encoded.z.sRGBToLinear)
    }
}

extension Double {
    var linearToSRGB: Double {
        self <= 0.003_130_8 ? 12.92 * self : 1.055 * pow(self, 1 / 2.4) - 0.055
    }

    var sRGBToLinear: Double {
        self <= 0.040_45 ? self / 12.92 : pow((self + 0.055) / 1.055, 2.4)
    }
}

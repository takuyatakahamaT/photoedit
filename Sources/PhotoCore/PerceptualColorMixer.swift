import CoreImage
import Foundation

/// Eight-band XMP mixer implemented in OKLCh rather than bounded HSL. The
/// transform preserves HDR/negative working values and leaves near-neutrals
/// untouched; gamut fitting is deliberately deferred to the final output node.
enum PerceptualColorMixer {
    static let identifier = "oklch-eight-band-mixer-v1"
    private static let neutralRelativeChromaStart = 0.02
    private static let neutralRelativeChromaEnd = 0.08

    static func isActive(_ hsl: [HSLBand: HSLAdjustment], tolerance: Double = 1e-9) -> Bool {
        hsl.values.contains {
            abs($0.hue) > tolerance
                || abs($0.saturation) > tolerance
                || abs($0.luminance) > tolerance
        }
    }

    static func apply(
        to linearRGB: SIMD3<Double>,
        adjustments: [HSLBand: HSLAdjustment]
    ) -> SIMD3<Double> {
        guard isActive(adjustments) else { return linearRGB }
        var lab = OKLabColor.from(linearSRGB: linearRGB)
        let relativeChroma = lab.chroma / max(abs(lab.lightness), 0.000_1)
        let position = min(max(
            (relativeChroma - neutralRelativeChromaStart)
                / (neutralRelativeChromaEnd - neutralRelativeChromaStart),
            0
        ), 1)
        let chromaWeight = position * position * (3 - 2 * position)
        guard chromaWeight > 0 else { return linearRGB }

        var adjustment = interpolatedAdjustment(
            at: lab.hueDegrees,
            adjustments: adjustments
        )
        adjustment.hue *= chromaWeight
        adjustment.saturation *= chromaWeight
        adjustment.luminance *= chromaWeight

        let hue = normalizedHue(lab.hueDegrees + adjustment.hue / 100 * 30)
        let chroma = lab.chroma * max(0, 1 + adjustment.saturation / 100)
        lab = lab.replacing(chroma: chroma, hueDegrees: hue)

        // OKLab is homogeneous of degree 1/3 with respect to linear RGB.
        // Scaling L/a/b together by this factor is exactly an RGB exposure
        // gain of 2^(adjustment/100), so +100 corresponds to +1 EV.
        let labGain = exp2(adjustment.luminance / 300)
        lab.lightness *= labGain
        lab.a *= labGain
        lab.b *= labGain
        return lab.linearSRGB()
    }

    static func makeKernel(adjustments: [HSLBand: HSLAdjustment]) -> CIColorKernel? {
        let bands = orderedBands(adjustments: adjustments)
        guard let first = bands.first else { return nil }
        var branches = ""
        for index in 0..<(bands.count - 1) {
            let left = bands[index]
            let right = bands[index + 1]
            let keyword = index == 0 ? "if" : "else if"
            branches += """
                \(keyword) (adjustedHue <= \(literal(right.hue))) {
                    float amount = (adjustedHue - \(literal(left.hue))) / \(literal(right.hue - left.hue));
                    adjustment = mix(\(vector(left.adjustment)), \(vector(right.adjustment)), amount);
                }
            """
        }
        let last = bands[bands.count - 1]
        branches += """
                else {
                    float amount = (adjustedHue - \(literal(last.hue))) / \(literal(first.hue + 360 - last.hue));
                    adjustment = mix(\(vector(last.adjustment)), \(vector(first.adjustment)), amount);
                }
        """

        return CIColorKernel(source: """
        vec3 signedCubeRoot(vec3 value) {
            return sign(value) * pow(abs(value), vec3(0.3333333333333333));
        }

        vec3 linearSRGBToOKLab(vec3 rgb) {
            vec3 lms = vec3(
                dot(rgb, vec3(0.4122214708, 0.5363325363, 0.0514459929)),
                dot(rgb, vec3(0.2119034982, 0.6806995451, 0.1073969566)),
                dot(rgb, vec3(0.0883024619, 0.2817188376, 0.6299787005))
            );
            vec3 root = signedCubeRoot(lms);
            return vec3(
                dot(root, vec3(0.2104542553, 0.7936177850, -0.0040720468)),
                dot(root, vec3(1.9779984951, -2.4285922050, 0.4505937099)),
                dot(root, vec3(0.0259040371, 0.7827717662, -0.8086757660))
            );
        }

        vec3 oklabToLinearSRGB(vec3 lab) {
            vec3 root = vec3(
                0.9999999984505196 * lab.x + 0.3963377921737678 * lab.y + 0.21580375806075877 * lab.z,
                1.0000000088817607 * lab.x - 0.10556134232365633 * lab.y - 0.0638541747717059 * lab.z,
                1.0000000546724108 * lab.x - 0.08948418209496574 * lab.y - 1.2914855378640917 * lab.z
            );
            vec3 lms = root * root * root;
            return vec3(
                dot(lms, vec3(4.076741661347994, -3.3077115904081933, 0.23096992872942793)),
                dot(lms, vec3(-1.2684380040921763, 2.6097574006633715, -0.3413193963102196)),
                dot(lms, vec3(-0.00419608654183707, -0.7034186144594495, 1.7076147009309446))
            );
        }

        kernel vec4 photoBenchPerceptualMixer(__sample pixel) {
            float alpha = pixel.a;
            vec3 rgb = alpha > 0.0000001 ? pixel.rgb / alpha : pixel.rgb;
            vec3 lab = linearSRGBToOKLab(rgb);
            float chroma = length(lab.yz);
            float relativeChroma = chroma / max(abs(lab.x), 0.0001);
            float position = clamp((relativeChroma - 0.02) / 0.06, 0.0, 1.0);
            float chromaWeight = position * position * (3.0 - 2.0 * position);
            if (chromaWeight <= 0.0 || chroma <= 0.0000001) {
                return pixel;
            }

            float hue = degrees(atan(lab.z, lab.y));
            if (hue < 0.0) { hue += 360.0; }
            float adjustedHue = hue < \(literal(first.hue)) ? hue + 360.0 : hue;
            vec3 adjustment = vec3(0.0);
        \(branches)
            adjustment *= chromaWeight;

            float outputHue = hue + adjustment.x / 100.0 * 30.0;
            float outputChroma = chroma * max(0.0, 1.0 + adjustment.y / 100.0);
            float radiansHue = radians(outputHue);
            lab.y = outputChroma * cos(radiansHue);
            lab.z = outputChroma * sin(radiansHue);
            lab *= exp2(adjustment.z / 300.0);

            vec3 mapped = oklabToLinearSRGB(lab);
            return vec4(mapped * alpha, alpha);
        }
        """)
    }

    private struct WeightedBand {
        let band: HSLBand
        let hue: Double
        let adjustment: HSLAdjustment
    }

    private static func orderedBands(
        adjustments: [HSLBand: HSLAdjustment]
    ) -> [WeightedBand] {
        HSLBand.allCases.map { band in
            let raw = adjustments[band] ?? HSLAdjustment()
            return WeightedBand(
                band: band,
                hue: OKLabColor.perceptualHue(for: band),
                adjustment: HSLAdjustment(
                    hue: sanitized(raw.hue),
                    saturation: sanitized(raw.saturation),
                    luminance: sanitized(raw.luminance)
                )
            )
        }.sorted { $0.hue < $1.hue }
    }

    private static func interpolatedAdjustment(
        at hue: Double,
        adjustments: [HSLBand: HSLAdjustment]
    ) -> HSLAdjustment {
        let bands = orderedBands(adjustments: adjustments)
        guard let first = bands.first, let last = bands.last else { return HSLAdjustment() }
        let adjustedHue = hue < first.hue ? hue + 360 : hue
        for index in 0..<(bands.count - 1) {
            let left = bands[index]
            let right = bands[index + 1]
            if adjustedHue <= right.hue {
                let amount = (adjustedHue - left.hue) / (right.hue - left.hue)
                return mix(left.adjustment, right.adjustment, amount: amount)
            }
        }
        let amount = (adjustedHue - last.hue) / (first.hue + 360 - last.hue)
        return mix(last.adjustment, first.adjustment, amount: amount)
    }

    private static func mix(
        _ left: HSLAdjustment,
        _ right: HSLAdjustment,
        amount: Double
    ) -> HSLAdjustment {
        HSLAdjustment(
            hue: left.hue + (right.hue - left.hue) * amount,
            saturation: left.saturation + (right.saturation - left.saturation) * amount,
            luminance: left.luminance + (right.luminance - left.luminance) * amount
        )
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let value = hue.truncatingRemainder(dividingBy: 360)
        return value >= 0 ? value : value + 360
    }

    private static func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -100), 100)
    }

    private static func vector(_ adjustment: HSLAdjustment) -> String {
        "vec3(\(literal(adjustment.hue)), \(literal(adjustment.saturation)), \(literal(adjustment.luminance)))"
    }

    private static func literal(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

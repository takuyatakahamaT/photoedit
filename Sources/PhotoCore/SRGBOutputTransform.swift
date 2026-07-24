import CoreImage
import Foundation

/// The only bounded stage in the Photo Bench pipeline. Working pixels remain
/// extended-linear until this output transform: a ratio-preserving highlight
/// shoulder first, then a fixed-lightness/fixed-hue OKLCh chroma compression.
enum SRGBOutputTransform {
    static let identifier = "extended-linear-to-srgb-soft-output-v2"
    static let highlightKnee = 0.99
    static let highlightCeiling = 0.998
    /// Matching the denominator scale to the available output headroom makes
    /// the rational shoulder C1-continuous: its slope is 1 on both sides of
    /// the knee, while the far tail still approaches `highlightCeiling`.
    static let highlightSoftness = highlightCeiling - highlightKnee
    static let gamutKnee = 0.90
    static let gamutBoundaryScale = 0.999
    private static let chromaSearchUpperBound = 0.5
    private static let chromaSearchIterations = 12

    static func map(_ linearRGB: SIMD3<Double>) -> SIMD3<Double> {
        gamutCompress(highlightShoulder(linearRGB))
    }

    static func highlightShoulder(_ linearRGB: SIMD3<Double>) -> SIMD3<Double> {
        let maximum = max(linearRGB.x, max(linearRGB.y, linearRGB.z))
        guard maximum.isFinite, maximum > highlightKnee else { return linearRGB }
        let headroom = highlightCeiling - highlightKnee
        let distance = maximum - highlightKnee
        let mappedMaximum = highlightKnee
            + headroom * distance / (distance + highlightSoftness)
        return linearRGB * (mappedMaximum / maximum)
    }

    static func gamutCompress(_ linearRGB: SIMD3<Double>) -> SIMD3<Double> {
        guard linearRGB.x.isFinite, linearRGB.y.isFinite, linearRGB.z.isFinite else {
            return SIMD3(repeating: 0)
        }
        let lab = OKLabColor.from(linearSRGB: linearRGB)
        guard lab.lightness > 0 else { return SIMD3(repeating: 0) }
        guard lab.lightness < 1 else { return SIMD3(repeating: 1) }
        guard lab.chroma > 0.000_000_1 else { return finalClamp(linearRGB) }

        let maximum = maximumChroma(lightness: lab.lightness, hueDegrees: lab.hueDegrees)
        guard maximum > 0.000_000_1 else {
            let neutral = OKLabColor(lightness: lab.lightness, a: 0, b: 0).linearSRGB()
            return finalClamp(neutral)
        }
        let safeMaximum = maximum * gamutBoundaryScale
        let ratio = lab.chroma / safeMaximum
        guard ratio > gamutKnee else { return finalClamp(linearRGB) }

        let distance = ratio - gamutKnee
        let compressedRatio = gamutKnee
            + (1 - gamutKnee) * distance / (distance + 1 - gamutKnee)
        let mapped = lab.replacing(
            chroma: safeMaximum * compressedRatio,
            hueDegrees: lab.hueDegrees
        ).linearSRGB()
        return finalClamp(mapped)
    }

    static func maximumChroma(lightness: Double, hueDegrees: Double) -> Double {
        guard lightness > 0, lightness < 1 else { return 0 }
        var low = 0.0
        var high = chromaSearchUpperBound
        for _ in 0..<chromaSearchIterations {
            let middle = (low + high) / 2
            let candidate = OKLabColor(
                lightness: lightness,
                a: 0,
                b: 0
            ).replacing(chroma: middle, hueDegrees: hueDegrees).linearSRGB()
            if OKLabColor.isInSRGBGamut(candidate, tolerance: 0.000_000_1) {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    static func apply(to image: CIImage) -> CIImage {
        guard let shouldered = shoulderKernel.apply(extent: image.extent, arguments: [image]) else {
            preconditionFailure("Photo Benchのハイライトshoulderを適用できませんでした。")
        }
        guard let compressed = gamutKernel.apply(extent: image.extent, arguments: [shouldered]) else {
            preconditionFailure("Photo Benchの色域圧縮を適用できませんでした。")
        }
        return compressed
    }

    private static func finalClamp(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            min(max(rgb.x, 0), 1),
            min(max(rgb.y, 0), 1),
            min(max(rgb.z, 0), 1)
        )
    }

    static let shoulderKernel: CIColorKernel = {
        guard let kernel = CIColorKernel(source: """
        kernel vec4 photoBenchHighlightShoulder(__sample pixel) {
            float alpha = pixel.a;
            vec3 rgb = alpha > 0.0000001 ? pixel.rgb / alpha : pixel.rgb;
            float maximum = max(rgb.r, max(rgb.g, rgb.b));
            if (maximum <= 0.99) { return pixel; }
            float distance = maximum - 0.99;
            float mappedMaximum = 0.99 + 0.008 * distance / (distance + 0.008);
            vec3 mapped = rgb * (mappedMaximum / maximum);
            return vec4(mapped * alpha, alpha);
        }
        """) else {
            preconditionFailure("Photo Benchのハイライトshoulderカーネルをコンパイルできませんでした。")
        }
        return kernel
    }()

    static let gamutKernel: CIColorKernel = {
        guard let kernel = CIColorKernel(source: """
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

        bool inSRGBGamut(vec3 rgb) {
            return rgb.r >= -0.0000001 && rgb.r <= 1.0000001
                && rgb.g >= -0.0000001 && rgb.g <= 1.0000001
                && rgb.b >= -0.0000001 && rgb.b <= 1.0000001;
        }

        kernel vec4 photoBenchGamutCompression(__sample pixel) {
            float alpha = pixel.a;
            vec3 rgb = alpha > 0.0000001 ? pixel.rgb / alpha : pixel.rgb;
            vec3 lab = linearSRGBToOKLab(rgb);
            if (lab.x <= 0.0) { return vec4(0.0, 0.0, 0.0, alpha); }
            if (lab.x >= 1.0) { return vec4(alpha, alpha, alpha, alpha); }
            float chroma = length(lab.yz);
            if (chroma <= 0.0000001) {
                return vec4(clamp(rgb, 0.0, 1.0) * alpha, alpha);
            }

            float hue = atan(lab.z, lab.y);
            vec2 direction = vec2(cos(hue), sin(hue));
            float low = 0.0;
            float high = 0.5;
            for (int index = 0; index < 12; index++) {
                float middle = (low + high) * 0.5;
                vec3 candidateLab = vec3(lab.x, direction * middle);
                if (inSRGBGamut(oklabToLinearSRGB(candidateLab))) {
                    low = middle;
                } else {
                    high = middle;
                }
            }
            if (low <= 0.0000001) {
                vec3 neutral = oklabToLinearSRGB(vec3(lab.x, 0.0, 0.0));
                return vec4(clamp(neutral, 0.0, 1.0) * alpha, alpha);
            }

            float safeMaximum = low * 0.999;
            float ratio = chroma / safeMaximum;
            if (ratio <= 0.90) {
                return vec4(clamp(rgb, 0.0, 1.0) * alpha, alpha);
            }
            float distance = ratio - 0.90;
            float compressedRatio = 0.90 + 0.10 * distance / (distance + 0.10);
            vec3 mappedLab = vec3(lab.x, direction * (safeMaximum * compressedRatio));
            vec3 mapped = clamp(oklabToLinearSRGB(mappedLab), 0.0, 1.0);
            return vec4(mapped * alpha, alpha);
        }
        """) else {
            preconditionFailure("Photo Benchの色域圧縮カーネルをコンパイルできませんでした。")
        }
        return kernel
    }()
}

import CoreImage
import Foundation

/// Clean-room, scene-linear approximation of Highlights2012/Shadows2012 only.
///
/// Phase2 C1 (`docs/PHASE2_DEVELOP_PIPELINE.md`) moved Contrast2012/
/// Whites2012/Blacks2012 to `ToneOps` (a real, measured model). This type
/// keeps only its Highlights/Shadows terms as a stopgap approximation until
/// phase3 replaces them with the spatial (Highlights2012/Shadows2012 are
/// local-contrast operations in real Lightroom, unlike the other Basic-panel
/// sliders) model `.photobench/phase2/spatial/` is expected to produce.
/// Adobe publishes the controls' tonal regions, but not the rendering
/// equations, so this remains monotonic clean-room primitives: a toe curve, a
/// bounded midtone warp, a shoulder curve, and an extended highlight-recovery
/// shoulder.
///
/// Every primitive is monotonic. The bounded 0...1 primitives preserve their
/// endpoints, while the extended shoulder deliberately compresses or expands
/// HDR values above its pivot. This matters more than matching one reference
/// scene: arbitrary slider combinations cannot fold the tone curve or require
/// a hidden, preset-dependent strength limit.
enum BasicToneModel {
    static let identifier = "analytic-monotonic-hdr-basic-tone-v4-highlights-shadows-only"

    // The pivots follow Adobe's documented areas of influence, with the wider
    // shadow/highlight pivots providing the smooth compensation visible in the
    // supplied Lightroom before/after references. Response constants remain a
    // clean-room approximation and are deliberately versioned above.
    private static let shadowsPivot = 0.68
    private static let shadowsResponse = 1.00
    private static let shadowsMidtoneResponse = 0.80
    private static let highlightsPivot = 0.32
    private static let highlightsResponse = 0.03
    private static let extendedShoulderPivot = 0.78
    private static let negativeHighlightsResponse = 3.00
    private static let positiveHighlightsResponse = 0.30

    static func isActive(_ settings: EditSettings) -> Bool {
        settings.highlights != 0 || settings.shadows != 0
    }

    static func outputLuminance(_ luminance: Double, settings: EditSettings) -> Double {
        guard isActive(settings), luminance > 0 else { return luminance }
        let encoded = linearToSRGB(luminance)
        return sRGBToLinear(mappedEncodedLuminance(encoded, settings: settings))
    }

    static func mappedEncodedLuminance(_ encoded: Double, settings: EditSettings) -> Double {
        guard isActive(settings), encoded > 0 else { return encoded }
        var value = encoded
        if value < 1 {
            value = toe(
                value,
                pivot: shadowsPivot,
                amount: normalized(settings.shadows),
                response: shadowsResponse
            )
            value = midtoneWarp(
                value,
                amount: normalized(settings.shadows),
                response: shadowsMidtoneResponse
            )
            value = shoulder(
                value,
                pivot: highlightsPivot,
                amount: normalized(settings.highlights),
                response: highlightsResponse
            )
        }
        return extendedHighlightShoulder(value, highlights: normalized(settings.highlights))
    }

    private static func toe(
        _ value: Double,
        pivot: Double,
        amount: Double,
        response: Double
    ) -> Double {
        guard value < pivot else { return value }
        let exponent = exp(-response * amount)
        return pivot * pow(value / pivot, exponent)
    }

    private static func shoulder(
        _ value: Double,
        pivot: Double,
        amount: Double,
        response: Double
    ) -> Double {
        guard value > pivot else { return value }
        let exponent = exp(response * amount)
        let distance = (1 - value) / (1 - pivot)
        return 1 - (1 - pivot) * pow(distance, exponent)
    }

    /// x + a*x*(1-x) has derivative 1+a*(1-2x), which stays positive for
    /// |a| < 1. It gives Shadows a useful midtone component without the very
    /// large near-black lift produced by a toe curve alone.
    private static func midtoneWarp(
        _ value: Double,
        amount: Double,
        response: Double
    ) -> Double {
        guard value > 0, value < 1 else { return value }
        let coefficient = amount * response
        return value + coefficient * value * (1 - value)
    }

    /// Negative Highlights uses an exponential shoulder whose slope is always
    /// positive and whose tail has a finite asymptote. Unlike a 0...1 LUT, it
    /// can pull exposure-created HDR values back into the display range
    /// before the XMP curves are evaluated. Positive Highlights uses a
    /// bounded linear expansion so arbitrary HDR input remains finite.
    private static func extendedHighlightShoulder(_ value: Double, highlights: Double) -> Double {
        guard value > extendedShoulderPivot else { return value }
        let distance = value - extendedShoulderPivot
        let compression = min(highlights, 0) * negativeHighlightsResponse
        var output = value
        if compression < -0.000_001 {
            output = extendedShoulderPivot + expm1(compression * distance) / compression
        }
        let expansion = max(highlights, 0) * positiveHighlightsResponse
        if expansion > 0 {
            output = extendedShoulderPivot
                + (output - extendedShoulderPivot) * exp(expansion)
        }
        return output
    }

    private static func normalized(_ value: Double) -> Double {
        min(max(value / 100, -1), 1)
    }

    private static func linearToSRGB(_ value: Double) -> Double {
        if value <= 0.003_130_8 { return 12.92 * value }
        return 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func sRGBToLinear(_ value: Double) -> Double {
        if value <= 0.040_45 { return value / 12.92 }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    /// Runtime CIKL is used only for this bounded prototype. The formula is
    /// mirrored by the CPU implementation above and exercised through an
    /// actual Core Image render in the test suite. A packaged Metal CI kernel
    /// can replace it later without changing the edit model.
    static let kernel: CIColorKernel = {
        guard let kernel = CIColorKernel(source: """
        kernel vec4 basicTone(
            __sample pixel,
            float highlights,
            float shadows
        ) {
            float alpha = pixel.a;
            vec3 rgb = alpha > 0.0000001 ? pixel.rgb / alpha : pixel.rgb;
            float luminance = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            if (luminance <= 0.0) {
                return pixel;
            }

            float encoded = luminance <= 0.0031308
                ? 12.92 * luminance
                : 1.055 * pow(luminance, 0.4166666667) - 0.055;
            float mapped = encoded;

            if (mapped < 1.0) {
                float normalizedShadows = clamp(shadows / 100.0, -1.0, 1.0);
                float shadowsExponent = exp(-1.00 * normalizedShadows);
                if (mapped < 0.68) {
                    mapped = 0.68 * pow(mapped / 0.68, shadowsExponent);
                }
                mapped = mapped + 0.80 * normalizedShadows * mapped * (1.0 - mapped);

                float highlightsExponent = exp(0.03 * clamp(highlights / 100.0, -1.0, 1.0));
                if (mapped > 0.32) {
                    mapped = 1.0 - 0.68 * pow((1.0 - mapped) / 0.68, highlightsExponent);
                }
            }

            if (mapped > 0.78) {
                float compression = 3.00 * min(clamp(highlights / 100.0, -1.0, 1.0), 0.0);
                if (compression < -0.000001) {
                    mapped = 0.78 + (exp(compression * (mapped - 0.78)) - 1.0) / compression;
                }
                float expansion = 0.30 * max(clamp(highlights / 100.0, -1.0, 1.0), 0.0);
                if (expansion > 0.0) {
                    mapped = 0.78 + (mapped - 0.78) * exp(expansion);
                }
            }

            float outputLuminance = mapped <= 0.04045
                ? mapped / 12.92
                : pow((mapped + 0.055) / 1.055, 2.4);
            float gain = outputLuminance / luminance;
            return vec4(rgb * gain * alpha, alpha);
        }
        """) else {
            preconditionFailure("Photo Benchの基本階調カーネルをコンパイルできませんでした。")
        }
        return kernel
    }()
}

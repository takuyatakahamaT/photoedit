import CoreImage
import Foundation

/// XMP point curves evaluated in encoded-sRGB space without a bounded 3D LUT.
/// Interior segments retain the preset's piecewise-linear semantics. Values
/// outside the authored 0...1 range use a small positive endpoint slope so an
/// HDR highlight cannot collapse onto a constant 1.0 plateau before the final
/// output transform.
enum ToneCurveModel {
    static let identifier = "encoded-srgb-endpoint-extrapolation-v1"
    private static let minimumEndpointSlope = 0.01
    private static let maximumEndpointSlope = 4.0

    static func isIdentity(_ curves: [ToneCurve], tolerance: Double = 1e-9) -> Bool {
        curves.allSatisfy { curve in
            normalizedPoints(curve).allSatisfy { abs($0.x - $0.y) <= tolerance }
        }
    }

    static func apply(to linearRGB: SIMD3<Double>, curves: [ToneCurve]) -> SIMD3<Double> {
        let global = normalizedPoints(curves.first { $0.channel == .rgb })
        let red = normalizedPoints(curves.first { $0.channel == .red })
        let green = normalizedPoints(curves.first { $0.channel == .green })
        let blue = normalizedPoints(curves.first { $0.channel == .blue })

        func map(_ input: Double, channel: [CurvePoint]) -> Double {
            let encoded = input.linearToSRGB
            let channelMapped = interpolate(encoded, points: channel)
            return interpolate(channelMapped, points: global).sRGBToLinear
        }
        return SIMD3(
            map(linearRGB.x, channel: red),
            map(linearRGB.y, channel: green),
            map(linearRGB.z, channel: blue)
        )
    }

    static func makeKernel(curves: [ToneCurve]) -> CIColorKernel? {
        let global = normalizedPoints(curves.first { $0.channel == .rgb })
        let red = normalizedPoints(curves.first { $0.channel == .red })
        let green = normalizedPoints(curves.first { $0.channel == .green })
        let blue = normalizedPoints(curves.first { $0.channel == .blue })

        func mappedExpression(linear: String, channel: [CurvePoint]) -> String {
            let encoded = "((\(linear) <= 0.0031308) ? (12.92 * \(linear)) : (1.055 * pow(\(linear), 0.4166666667) - 0.055))"
            let channelMapped = interpolationExpression(value: encoded, points: channel)
            let globallyMapped = interpolationExpression(value: channelMapped, points: global)
            return "((\(globallyMapped) <= 0.04045) ? (\(globallyMapped) / 12.92) : pow((\(globallyMapped) + 0.055) / 1.055, 2.4))"
        }

        let redExpression = mappedExpression(linear: "rgb.r", channel: red)
        let greenExpression = mappedExpression(linear: "rgb.g", channel: green)
        let blueExpression = mappedExpression(linear: "rgb.b", channel: blue)
        return CIColorKernel(source: """
        kernel vec4 photoBenchToneCurve(__sample pixel) {
            float alpha = pixel.a;
            vec3 rgb = alpha > 0.0000001 ? pixel.rgb / alpha : pixel.rgb;
            vec3 mapped = vec3(
                \(redExpression),
                \(greenExpression),
                \(blueExpression)
            );
            return vec4(mapped * alpha, alpha);
        }
        """)
    }

    /// Not `private`: `ToneOps.pointCurve` (phase2 C1's Stage P point-curve
    /// application) reuses this exact sanitization (0...1 clamp, sort by x,
    /// last-authored-wins on duplicate x) so a malformed/duplicate-x XMP
    /// curve behaves identically whether it reaches the CPU reference or the
    /// GPU cube, rather than reimplementing the same policy twice.
    static func normalizedPoints(_ curve: ToneCurve?) -> [CurvePoint] {
        guard let curve else { return [] }
        // XMPPresetParser normalizes authored 0...255 points to 0...1. Keep
        // that bounded authoring contract here as a defensive invariant;
        // extrapolation applies to image values outside the authored domain,
        // not to out-of-range control points from future callers.
        let finite = curve.points.enumerated()
            .filter { $0.element.x.isFinite && $0.element.y.isFinite }
            .map { index, point in
                (
                    index: index,
                    point: CurvePoint(
                        x: min(max(point.x, 0), 1),
                        y: min(max(point.y, 0), 1)
                    )
                )
            }
            .sorted { $0.point.x < $1.point.x }
        var result = [(index: Int, point: CurvePoint)]()
        for candidate in finite {
            if let last = result.last,
               abs(last.point.x - candidate.point.x) < 0.000_001 {
                // Duplicate x positions cannot define a function. XMP order
                // is authoritative, so make the existing last-authored-wins
                // policy deterministic even when sort stability changes.
                if candidate.index > last.index {
                    result[result.count - 1] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result.count >= 2 ? result.map(\.point) : []
    }

    static func normalizedPoints(_ curve: ToneCurve) -> [CurvePoint] {
        normalizedPoints(Optional(curve))
    }

    private static func interpolate(_ value: Double, points: [CurvePoint]) -> Double {
        guard points.count >= 2 else { return value }
        if value <= points[0].x {
            return points[0].y + endpointSlope(points[0], points[1]) * (value - points[0].x)
        }
        if value >= points[points.count - 1].x {
            let left = points[points.count - 2]
            let right = points[points.count - 1]
            return right.y + endpointSlope(left, right) * (value - right.x)
        }
        for index in 1..<points.count where value <= points[index].x {
            let left = points[index - 1]
            let right = points[index]
            let amount = (value - left.x) / (right.x - left.x)
            return left.y + (right.y - left.y) * amount
        }
        return value
    }

    private static func interpolationExpression(value: String, points: [CurvePoint]) -> String {
        guard points.count >= 2 else { return value }
        let first = points[0]
        let last = points[points.count - 1]
        let low = "(\(literal(first.y)) + \(literal(endpointSlope(first, points[1]))) * ((\(value)) - \(literal(first.x))))"
        let highLeft = points[points.count - 2]
        let high = "(\(literal(last.y)) + \(literal(endpointSlope(highLeft, last))) * ((\(value)) - \(literal(last.x))))"

        var expression = high
        for index in stride(from: points.count - 1, through: 1, by: -1) {
            let left = points[index - 1]
            let right = points[index]
            let slope = (right.y - left.y) / (right.x - left.x)
            let segment = "(\(literal(left.y)) + \(literal(slope)) * ((\(value)) - \(literal(left.x))))"
            expression = "(((\(value)) <= \(literal(right.x))) ? \(segment) : \(expression))"
        }
        return "(((\(value)) <= \(literal(first.x))) ? \(low) : \(expression))"
    }

    private static func endpointSlope(_ left: CurvePoint, _ right: CurvePoint) -> Double {
        let raw = (right.y - left.y) / max(right.x - left.x, 0.000_001)
        return min(max(raw, minimumEndpointSlope), maximumEndpointSlope)
    }

    private static func literal(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

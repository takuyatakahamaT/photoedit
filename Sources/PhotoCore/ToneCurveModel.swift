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

    private static func normalizedPoints(_ curve: ToneCurve?) -> [CurvePoint] {
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

    private static func normalizedPoints(_ curve: ToneCurve) -> [CurvePoint] {
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

/// A small fitted color transform for bluesky2 reference matching. The RAW
/// and JPEG profiles use the same feature definition but separate fitted
/// coefficients, so neither input type inherits the other's tone curve.
public enum BlueskyReferenceLook {
    public static let identifier = ReferenceLook.currentBluesky2.rawValue
    private static let warmV3Adjustments: [HSLBand: HSLAdjustment] = [
        .orange: HSLAdjustment(hue: 0, saturation: 10, luminance: -12)
    ]

    struct Profile {
        let knots: [Double]
        let coefficients: [SIMD3<Double>]
    }

    private final class KernelSet: @unchecked Sendable {
        let raw: CIColorKernel
        let jpeg: CIColorKernel

        init(raw: CIColorKernel, jpeg: CIColorKernel) {
            self.raw = raw
            self.jpeg = jpeg
        }
    }

    public static func supports(info: DecodeInfo) -> Bool {
        guard info.isRAW else { return true }
        return normalizedCameraIdentity(info.cameraMake) == "panasonic"
            && normalizedCameraIdentity(info.cameraModel) == "dcs5"
    }

    /// Maps one unpremultiplied linear-light RGB sample. Non-finite inputs are
    /// made finite before entering the fitted polynomial features.
    public static func map(
        linearRGB: SIMD3<Double>,
        isRAW: Bool,
        look: ReferenceLook = .currentBluesky2
    ) -> SIMD3<Double> {
        let input = SIMD3(
            finiteOrZero(linearRGB.x),
            finiteOrZero(linearRGB.y),
            finiteOrZero(linearRGB.z)
        )
        let encoded = SIMD3(
            max(linearToSRGB(input.x), 0),
            max(linearToSRGB(input.y), 0),
            max(linearToSRGB(input.z), 0)
        )
        let luminance = max(
            encoded.x * 0.2126 + encoded.y * 0.7152 + encoded.z * 0.0722,
            0
        )
        let redChroma = encoded.x - luminance
        let blueChroma = encoded.z - luminance
        let mappedEncoded = mappedEncodedRGB(
            luminance: luminance,
            redChroma: redChroma,
            blueChroma: blueChroma,
            profile: profile(isRAW: isRAW)
        )
        let versionTwoOutput = SIMD3(
            finiteOrZero(sRGBToLinear(mappedEncoded.x)),
            finiteOrZero(sRGBToLinear(mappedEncoded.y)),
            finiteOrZero(sRGBToLinear(mappedEncoded.z))
        )
        guard look == .bluesky2September2026V3 else { return versionTwoOutput }
        let versionThreeOutput = PerceptualColorMixer.apply(
            to: versionTwoOutput,
            adjustments: warmV3Adjustments
        )
        return SIMD3(
            finiteOrZero(versionThreeOutput.x),
            finiteOrZero(versionThreeOutput.y),
            finiteOrZero(versionThreeOutput.z)
        )
    }

    /// Applies the profile selected by decode metadata. Unsupported RAW
    /// cameras are an exact graph bypass.
    public static func apply(
        to image: CIImage,
        info: DecodeInfo,
        look: ReferenceLook = .currentBluesky2
    ) -> CIImage {
        guard supports(info: info) else { return image }
        let profileKernel = info.isRAW ? kernels.raw : kernels.jpeg
        guard let versionTwoOutput = profileKernel.apply(extent: image.extent, arguments: [image]) else {
            preconditionFailure("Photo Benchのbluesky2参照補正を画像へ適用できませんでした。")
        }
        guard look == .bluesky2September2026V3 else { return versionTwoOutput }
        guard let versionThreeOutput = warmV3MixerKernel.apply(
            extent: versionTwoOutput.extent,
            arguments: [versionTwoOutput]
        ) else {
            preconditionFailure("Photo Benchのbluesky2 v3カラーミキサーを画像へ適用できませんでした。")
        }
        return versionThreeOutput
    }

    static let rawProfile = Profile(
        knots: [0.0, 0.025, 0.05, 0.08, 0.12, 0.18, 0.26, 0.36, 0.5, 0.67, 0.85, 1.0, 1.25, 1.6, 2.2, 3.2],
        coefficients: [
            SIMD3<Double>(0.0009012165462870439, 0.0016067044055458524, 0.0021854340302065707),
            SIMD3<Double>(0.01570269269596527, 0.03829921239014238, 0.04612947415404952),
            SIMD3<Double>(0.11147931207848688, 0.11998591853609715, 0.1319203144923851),
            SIMD3<Double>(0.213573765855008, 0.19299539321846107, 0.1985243363578144),
            SIMD3<Double>(0.3163247268868187, 0.297130425154182, 0.2809543129756611),
            SIMD3<Double>(0.4369652468229235, 0.4445091090311343, 0.4298674953338569),
            SIMD3<Double>(0.5335216113804402, 0.5621618790257614, 0.5574854788938649),
            SIMD3<Double>(0.6198269756358195, 0.6639280792485605, 0.6738869947105669),
            SIMD3<Double>(0.7333609094182311, 0.7489966818601578, 0.7428147851557773),
            SIMD3<Double>(0.8207324403404169, 0.8164525310041463, 0.7965608822998451),
            SIMD3<Double>(0.8728018322943462, 0.8839963702948694, 0.8764762316158284),
            SIMD3<Double>(0.9341925243470317, 0.9405988479212246, 0.9371884321090478),
            SIMD3<Double>(0.9584976476282322, 0.9464121615159844, 0.9455520881403343),
            SIMD3<Double>(1.0695715384862479, 1.0818606352085494, 1.0801798604586195),
            SIMD3<Double>(2.2, 2.2, 2.2),
            SIMD3<Double>(3.1999999999999997, 3.1999999999999997, 3.1999999999999997),
            SIMD3<Double>(3.478105612722408, -0.3282049280504537, 0.023479986456141536),
            SIMD3<Double>(-0.8488664226744025, 0.3224783117368552, 2.926850786674426),
            SIMD3<Double>(-6.773839393700824, 0.11787603533774722, -0.007373272039032849),
            SIMD3<Double>(1.799919462233247, -0.9015791352987206, -5.48119573603765),
            SIMD3<Double>(-0.7905505736467623, -0.05253909503039885, 0.2693548589595147),
            SIMD3<Double>(-1.2727669817310283, -0.3890281597580203, -0.22831472401224503),
            SIMD3<Double>(-0.40003354074094194, 0.0910019850678088, -0.27921779565125043)
        ]
    )

    static let jpegProfile = Profile(
        knots: [0.0, 0.025, 0.05, 0.08, 0.12, 0.18, 0.26, 0.36, 0.5, 0.67, 0.85, 1.0, 1.25, 1.6, 2.2, 3.2],
        coefficients: [
            SIMD3<Double>(0.059734111095056476, 0.05172316832090942, 0.04217267992412342),
            SIMD3<Double>(0.16661164051287694, 0.1590675599772076, 0.17309574768239533),
            SIMD3<Double>(0.31184829246968787, 0.2523104336123666, 0.2253021242259284),
            SIMD3<Double>(0.35572836608676456, 0.3479153855593195, 0.33173662077031796),
            SIMD3<Double>(0.4188818311633725, 0.4225506479106393, 0.41706845198936227),
            SIMD3<Double>(0.4824219256036215, 0.5053169109206499, 0.5122407397106432),
            SIMD3<Double>(0.5501281911658337, 0.5885693421281851, 0.5969580302523816),
            SIMD3<Double>(0.6359731818619396, 0.6709478070655168, 0.6758535337252147),
            SIMD3<Double>(0.7311420692901578, 0.748977557574256, 0.7367492744411196),
            SIMD3<Double>(0.8134441435235191, 0.8122193039567572, 0.7954886749760853),
            SIMD3<Double>(0.8551334867089286, 0.8704670882788104, 0.8654511529879084),
            SIMD3<Double>(0.9604350472699356, 0.9642552835119507, 0.9633833301949186),
            SIMD3<Double>(1.2501836788218912, 1.250158040313982, 1.2501214161887995),
            SIMD3<Double>(1.5999999999999999, 1.5999999999999999, 1.5999999999999999),
            SIMD3<Double>(2.2, 2.2, 2.2),
            SIMD3<Double>(3.1999999999999997, 3.1999999999999997, 3.1999999999999997),
            SIMD3<Double>(3.8739157230164634, -0.653180655002158, -0.5294111727471432),
            SIMD3<Double>(-0.4996565326386575, -0.09643743943907732, 2.6589116111493665),
            SIMD3<Double>(-7.099853074179388, 0.8192801154792578, 1.5315569896861576),
            SIMD3<Double>(1.2206328212488153, -0.14557355450973436, -4.688498765404129),
            SIMD3<Double>(-0.6464337898795963, -0.5717817599700964, 0.13236128491084767),
            SIMD3<Double>(-1.4573269174928407, -0.582761519947344, -0.24676491842651366),
            SIMD3<Double>(-0.41702119364906676, -0.1036382375241517, -0.12471091981340204)
        ]
    )

    private static let kernels = makeKernels()
    private static let warmV3MixerKernel = makeWarmV3MixerKernel()

    private static func makeWarmV3MixerKernel() -> CIColorKernel {
        guard let kernel = PerceptualColorMixer.makeKernel(adjustments: warmV3Adjustments) else {
            preconditionFailure("Photo Benchのbluesky2 v3カラーミキサーカーネルを作成できませんでした。")
        }
        return kernel
    }

    private static func makeKernels() -> KernelSet {
        guard let raw = makeKernel(profile: rawProfile, name: "photoBenchBluesky2RawV2"),
              let jpeg = makeKernel(profile: jpegProfile, name: "photoBenchBluesky2JPEGV2")
        else {
            preconditionFailure("Photo Benchのbluesky2参照補正カーネルを作成できませんでした。")
        }
        return KernelSet(raw: raw, jpeg: jpeg)
    }

    private static func makeKernel(profile: Profile, name: String) -> CIColorKernel? {
        let curveValues = (0..<profile.knots.count).map { index in
            SIMD3<Double>(
                profile.coefficients[index].x,
                profile.coefficients[index].y,
                profile.coefficients[index].z
            )
        }
        let channelNames = ["r", "g", "b"]
        let neutralChannels = (0..<3).map { channel in
            interpolationExpression(
                value: "y",
                knots: profile.knots,
                values: curveValues.map { $0[channel] }
            )
        }
        let fittedChannels = (0..<3).map { channel in
            var expression = neutralChannels[channel]
            let featureNames = [
                "cr", "cb", "cr * ym", "cb * ym", "cr * cb / den", "cr * cr / den", "cb * cb / den"
            ]
            for feature in 0..<featureNames.count {
                let coefficient = profile.coefficients[profile.knots.count + feature][channel]
                expression += " + (\(featureNames[feature])) * (\(literal(coefficient)))"
            }
            return expression
        }
        let encodedChannels = channelNames.map { channel in
            "((source.\(channel) <= 0.0031308) ? (12.92 * source.\(channel)) : (1.055 * pow(max(source.\(channel), 0.0), 0.4166666667) - 0.055))"
        }

        return CIColorKernel(source: """
        kernel vec4 \(name)(__sample pixel) {
            float alpha = pixel.a;
            vec3 source = alpha > 0.0 ? pixel.rgb / alpha : vec3(0.0);
            vec3 encoded = max(vec3(
                \(encodedChannels[0]),
                \(encodedChannels[1]),
                \(encodedChannels[2])
            ), vec3(0.0));
            float y = max(dot(encoded, vec3(0.2126, 0.7152, 0.0722)), 0.0);
            float cr = encoded.r - y;
            float cb = encoded.b - y;
            float ym = y / (1.0 + y);
            float den = 0.1 + y;
            vec3 neutral = vec3(
                \(neutralChannels[0]),
                \(neutralChannels[1]),
                \(neutralChannels[2])
            );
            vec3 fitted = vec3(
                \(fittedChannels[0]),
                \(fittedChannels[1]),
                \(fittedChannels[2])
            );
            float radius = sqrt(cr * cr + cb * cb) / den;
            float t = clamp((radius - 0.65) / (1.1 - 0.65), 0.0, 1.0);
            float blend = t * t * (3.0 - 2.0 * t);
            vec3 sourceChroma = vec3(
                cr,
                -(0.2126 * cr + 0.0722 * cb) / 0.7152,
                cb
            );
            vec3 safe = neutral + 0.9 * sourceChroma;
            vec3 mappedEncoded = fitted * (1.0 - blend) + safe * blend;
            vec3 mapped = vec3(
                ((mappedEncoded.r <= 0.04045) ? (mappedEncoded.r / 12.92) : pow((mappedEncoded.r + 0.055) / 1.055, 2.4)),
                ((mappedEncoded.g <= 0.04045) ? (mappedEncoded.g / 12.92) : pow((mappedEncoded.g + 0.055) / 1.055, 2.4)),
                ((mappedEncoded.b <= 0.04045) ? (mappedEncoded.b / 12.92) : pow((mappedEncoded.b + 0.055) / 1.055, 2.4))
            );
            return vec4(mapped * alpha, alpha);
        }
        """)
    }

    private static func mappedEncodedRGB(
        luminance: Double,
        redChroma: Double,
        blueChroma: Double,
        profile: Profile
    ) -> SIMD3<Double> {
        let index = segmentIndex(for: luminance, knots: profile.knots)
        let left = profile.knots[index]
        let right = profile.knots[index + 1]
        let amount = (luminance - left) / (right - left)
        let neutral = profile.coefficients[index] * (1 - amount)
            + profile.coefficients[index + 1] * amount
        let ym = luminance / (1 + luminance)
        let denominator = 0.1 + luminance
        let features = [
            redChroma,
            blueChroma,
            redChroma * ym,
            blueChroma * ym,
            redChroma * blueChroma / denominator,
            redChroma * redChroma / denominator,
            blueChroma * blueChroma / denominator
        ]
        var fitted = neutral
        for index in 0..<features.count {
            fitted += profile.coefficients[profile.knots.count + index] * features[index]
        }
        let radius = sqrt(redChroma * redChroma + blueChroma * blueChroma) / denominator
        let blendAmount = min(max((radius - 0.65) / (1.1 - 0.65), 0), 1)
        let blend = blendAmount * blendAmount * (3 - 2 * blendAmount)
        let sourceChroma = SIMD3(
            redChroma,
            -(0.2126 * redChroma + 0.0722 * blueChroma) / 0.7152,
            blueChroma
        )
        let safe = neutral + sourceChroma * 0.9
        return fitted * (1 - blend) + safe * blend
    }

    private static func segmentIndex(for value: Double, knots: [Double]) -> Int {
        if value <= knots[0] { return 0 }
        for index in 1..<knots.count where value <= knots[index] {
            return index - 1
        }
        return knots.count - 2
    }

    private static func interpolationExpression(
        value: String,
        knots: [Double],
        values: [Double]
    ) -> String {
        func segment(_ index: Int) -> String {
            let leftX = knots[index]
            let rightX = knots[index + 1]
            let leftY = values[index]
            let slope = (values[index + 1] - leftY) / (rightX - leftX)
            return "(\(literal(leftY)) + \(literal(slope)) * ((\(value)) - \(literal(leftX))))"
        }

        var expression = segment(knots.count - 2)
        for index in stride(from: knots.count - 1, through: 1, by: -1) {
            expression = "(((\(value)) <= \(literal(knots[index]))) ? \(segment(index - 1)) : \(expression))"
        }
        return "(((\(value)) <= \(literal(knots[0]))) ? \(segment(0)) : \(expression))"
    }

    static func profile(isRAW: Bool) -> Profile {
        isRAW ? rawProfile : jpegProfile
    }

    private static func normalizedCameraIdentity(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private static func linearToSRGB(_ value: Double) -> Double {
        value <= 0.0031308
            ? 12.92 * value
            : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func sRGBToLinear(_ value: Double) -> Double {
        value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func literal(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

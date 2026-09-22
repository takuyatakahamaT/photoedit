import Foundation

/// A 3x3 matrix of `Double`s, row-major, used throughout `AdobeProfile` for
/// color-space and camera-calibration transforms. `* ` on a vector follows
/// the "matrix times column vector" convention: `result = M * v`.
public struct Matrix3x3: Sendable, Equatable {
    public var row0: SIMD3<Double>
    public var row1: SIMD3<Double>
    public var row2: SIMD3<Double>

    public init(row0: SIMD3<Double>, row1: SIMD3<Double>, row2: SIMD3<Double>) {
        self.row0 = row0
        self.row1 = row1
        self.row2 = row2
    }

    /// Builds from 9 values in row-major order.
    public init(_ m00: Double, _ m01: Double, _ m02: Double,
                _ m10: Double, _ m11: Double, _ m12: Double,
                _ m20: Double, _ m21: Double, _ m22: Double) {
        self.row0 = SIMD3(m00, m01, m02)
        self.row1 = SIMD3(m10, m11, m12)
        self.row2 = SIMD3(m20, m21, m22)
    }

    public static let identity = Matrix3x3(row0: [1, 0, 0], row1: [0, 1, 0], row2: [0, 0, 1])
    public static let zero = Matrix3x3(row0: [0, 0, 0], row1: [0, 0, 0], row2: [0, 0, 0])

    public subscript(_ r: Int, _ c: Int) -> Double {
        get {
            switch r {
            case 0: return row0[c]
            case 1: return row1[c]
            default: return row2[c]
            }
        }
        set {
            switch r {
            case 0: row0[c] = newValue
            case 1: row1[c] = newValue
            default: row2[c] = newValue
            }
        }
    }

    public static func diagonal(_ v: SIMD3<Double>) -> Matrix3x3 {
        Matrix3x3(row0: [v.x, 0, 0], row1: [0, v.y, 0], row2: [0, 0, v.z])
    }

    public static func + (lhs: Matrix3x3, rhs: Matrix3x3) -> Matrix3x3 {
        Matrix3x3(row0: lhs.row0 + rhs.row0, row1: lhs.row1 + rhs.row1, row2: lhs.row2 + rhs.row2)
    }

    public static func * (scalar: Double, m: Matrix3x3) -> Matrix3x3 {
        Matrix3x3(row0: scalar * m.row0, row1: scalar * m.row1, row2: scalar * m.row2)
    }

    /// Matrix-vector product (column-vector convention).
    public static func * (m: Matrix3x3, v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            (m.row0 * v).sum(),
            (m.row1 * v).sum(),
            (m.row2 * v).sum()
        )
    }

    /// Matrix-matrix product.
    public static func * (lhs: Matrix3x3, rhs: Matrix3x3) -> Matrix3x3 {
        let rt = rhs.transposed()
        return Matrix3x3(
            row0: SIMD3((lhs.row0 * rt.row0).sum(), (lhs.row0 * rt.row1).sum(), (lhs.row0 * rt.row2).sum()),
            row1: SIMD3((lhs.row1 * rt.row0).sum(), (lhs.row1 * rt.row1).sum(), (lhs.row1 * rt.row2).sum()),
            row2: SIMD3((lhs.row2 * rt.row0).sum(), (lhs.row2 * rt.row1).sum(), (lhs.row2 * rt.row2).sum())
        )
    }

    public func transposed() -> Matrix3x3 {
        Matrix3x3(
            row0: SIMD3(row0.x, row1.x, row2.x),
            row1: SIMD3(row0.y, row1.y, row2.y),
            row2: SIMD3(row0.z, row1.z, row2.z)
        )
    }

    public var determinant: Double {
        row0.x * (row1.y * row2.z - row1.z * row2.y)
            - row0.y * (row1.x * row2.z - row1.z * row2.x)
            + row0.z * (row1.x * row2.y - row1.y * row2.x)
    }

    /// Explicit cofactor/adjugate inverse. Throws rather than dividing by
    /// (near) zero, per this module's "throws, never preconditionFailure"
    /// convention.
    public func inverted() throws -> Matrix3x3 {
        let det = determinant
        guard abs(det) > 1e-12 else { throw ColorSpecError.singularMatrix }
        let invDet = 1.0 / det
        let c00 = (row1.y * row2.z - row1.z * row2.y)
        let c01 = (row1.z * row2.x - row1.x * row2.z)
        let c02 = (row1.x * row2.y - row1.y * row2.x)
        let c10 = (row0.z * row2.y - row0.y * row2.z)
        let c11 = (row0.x * row2.z - row0.z * row2.x)
        let c12 = (row0.y * row2.x - row0.x * row2.y)
        let c20 = (row0.y * row1.z - row0.z * row1.y)
        let c21 = (row0.z * row1.x - row0.x * row1.z)
        let c22 = (row0.x * row1.y - row0.y * row1.x)
        // Adjugate is the transpose of the cofactor matrix; rows below are
        // already written in that transposed order.
        return invDet * Matrix3x3(row0: SIMD3(c00, c10, c20), row1: SIMD3(c01, c11, c21), row2: SIMD3(c02, c12, c22))
    }
}

public enum ColorSpecError: Error, Sendable, Equatable, LocalizedError {
    case singularMatrix
    case unsupportedIlluminant(Int)
    case missingForwardMatrix
    case tableSearchFailed

    public var errorDescription: String? {
        switch self {
        case .singularMatrix: "行列が特異でXYZ変換を反転できません。"
        case .unsupportedIlluminant(let code): "未対応のCalibrationIlluminantコードです: \(code)"
        case .missingForwardMatrix: "ForwardMatrixがDCPプロファイルにありません。"
        case .tableSearchFailed: "色温度テーブルの探索に失敗しました。"
        }
    }
}

/// A chromaticity coordinate in the CIE xyY sense (Y implicit == 1).
public struct ChromaticityXY: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let d50 = ChromaticityXY(x: 0.3457, y: 0.3585)
}

/// Working color-space matrices (`dng_color_space.cpp`). The PCS is always
/// XYZ D50.
public enum DNGColorSpace {
    public static let proPhotoToXYZD50 = Matrix3x3(
        0.7977, 0.1352, 0.0313,
        0.2880, 0.7119, 0.0001,
        0.0000, 0.0000, 0.8249
    )
    public static let xyzD50ToProPhoto = try! proPhotoToXYZD50.inverted()

    public static let srgbToXYZD50 = Matrix3x3(
        0.4361, 0.3851, 0.1431,
        0.2225, 0.7169, 0.0606,
        0.0139, 0.0971, 0.7141
    )
    public static let xyzD50ToSRGB = try! srgbToXYZD50.inverted()

    /// Linear ProPhoto -> linear sRGB (both still scene-linear); used as
    /// the renderer's `fRGBtoFinal` in phase1.
    public static let proPhotoToSRGBLinear = xyzD50ToSRGB * proPhotoToXYZD50

    /// Inverse of `proPhotoToSRGBLinear`: linear sRGB (the app's working
    /// space) -> linear ProPhoto. Phase2 C1's non-RAW path (`RenderEngine`)
    /// uses this to hand a JPEG/HEIC/PNG/TIFF's already-decoded working-space
    /// image to `ToneOps.exposureNonRaw`/`applyPostOps` (measured in ProPhoto)
    /// and back.
    public static let srgbLinearToProPhoto = try! proPhotoToSRGBLinear.inverted()

    /// `dng_function_GammaEncode_sRGB::Evaluate` -- the standard sRGB OETF.
    /// Not clamped to an upper bound of 1 (extended-range input encodes to
    /// an extended-range, still-monotonic output), matching
    /// `dng_ops.srgb_encode`.
    public static func srgbEncode(_ x: Double) -> Double {
        x <= 0.0031308 ? x * 12.92 : 1.055 * pow(max(x, 0.0), 1.0 / 2.4) - 0.055
    }

    /// Inverse of `srgbEncode`, clipped to [0,1] first (only ever used on
    /// tone-curve output already expected in that range -- Stage C variant
    /// "a").
    public static func srgbDecode(_ y: Double) -> Double {
        let clipped = min(max(y, 0.0), 1.0)
        return clipped <= 0.0031308 * 12.92 ? clipped / 12.92 : pow((clipped + 0.055) / 1.055, 2.4)
    }
}

/// Port of `dng_temperature.cpp`: xy <-> correlated color temperature via
/// the Robertson/Wyszecki-Stiles isotherm table (`LegacySetXY`), and
/// `dng_camera_profile::IlluminantToTemperature`. Only xy -> temperature is
/// needed downstream (tint is unused by the phase1 pipeline), and only the
/// legacy (non-extended-range) table is implemented: the DNG SDK's extended
/// low-temperature LUT is disabled by default and our illuminants
/// (StandardLightA 2850K .. D65 6500K) sit well inside the legacy table's
/// range (mireds 0-600, i.e. infinite..~1667K).
public enum DNGTemperature {
    private struct Isotherm {
        let mired: Double
        let u: Double
        let v: Double
        let slope: Double
    }

    // Exact constants from dng_temperature.cpp's kTempTable.
    private static let table: [Isotherm] = [
        Isotherm(mired: 0, u: 0.18006, v: 0.26352, slope: -0.24341),
        Isotherm(mired: 10, u: 0.18066, v: 0.26589, slope: -0.25479),
        Isotherm(mired: 20, u: 0.18133, v: 0.26846, slope: -0.26876),
        Isotherm(mired: 30, u: 0.18208, v: 0.27119, slope: -0.28539),
        Isotherm(mired: 40, u: 0.18293, v: 0.27407, slope: -0.30470),
        Isotherm(mired: 50, u: 0.18388, v: 0.27709, slope: -0.32675),
        Isotherm(mired: 60, u: 0.18494, v: 0.28021, slope: -0.35156),
        Isotherm(mired: 70, u: 0.18611, v: 0.28342, slope: -0.37915),
        Isotherm(mired: 80, u: 0.18740, v: 0.28668, slope: -0.40955),
        Isotherm(mired: 90, u: 0.18880, v: 0.28997, slope: -0.44278),
        Isotherm(mired: 100, u: 0.19032, v: 0.29326, slope: -0.47888),
        Isotherm(mired: 125, u: 0.19462, v: 0.30141, slope: -0.58204),
        Isotherm(mired: 150, u: 0.19962, v: 0.30921, slope: -0.70471),
        Isotherm(mired: 175, u: 0.20525, v: 0.31647, slope: -0.84901),
        Isotherm(mired: 200, u: 0.21142, v: 0.32312, slope: -1.0182),
        Isotherm(mired: 225, u: 0.21807, v: 0.32909, slope: -1.2168),
        Isotherm(mired: 250, u: 0.22511, v: 0.33439, slope: -1.4512),
        Isotherm(mired: 275, u: 0.23247, v: 0.33904, slope: -1.7298),
        Isotherm(mired: 300, u: 0.24010, v: 0.34308, slope: -2.0637),
        Isotherm(mired: 325, u: 0.24702, v: 0.34655, slope: -2.4681),
        Isotherm(mired: 350, u: 0.25591, v: 0.34951, slope: -2.9641),
        Isotherm(mired: 375, u: 0.26400, v: 0.35200, slope: -3.5814),
        Isotherm(mired: 400, u: 0.27218, v: 0.35407, slope: -4.3633),
        Isotherm(mired: 425, u: 0.28039, v: 0.35577, slope: -5.3762),
        Isotherm(mired: 450, u: 0.28863, v: 0.35714, slope: -6.7262),
        Isotherm(mired: 475, u: 0.29685, v: 0.35823, slope: -8.5955),
        Isotherm(mired: 500, u: 0.30505, v: 0.35907, slope: -11.324),
        Isotherm(mired: 525, u: 0.31320, v: 0.35968, slope: -15.628),
        Isotherm(mired: 550, u: 0.32129, v: 0.36011, slope: -23.325),
        Isotherm(mired: 575, u: 0.32931, v: 0.36038, slope: -40.770),
        Isotherm(mired: 600, u: 0.33724, v: 0.36051, slope: -116.45),
    ]

    /// `dng_camera_profile::IlluminantToTemperature` for the illuminant
    /// codes this project's profiles use.
    public static func illuminantToTemperature(_ code: Int) throws -> Double {
        switch code {
        case 17, 3: return 2850.0 // StandardLightA, Tungsten
        case 24: return 3200.0 // ISOStudioTungsten
        case 23: return 5000.0 // D50
        case 20, 1, 9, 4, 18: return 5500.0 // D55, Daylight, FineWeather, Flash, StandardLightB
        case 21, 19, 10: return 6500.0 // D65, StandardLightC, CloudyWeather
        case 22, 11: return 7500.0 // D75, Shade
        default: throw ColorSpecError.unsupportedIlluminant(code)
        }
    }

    /// `dng_temperature::LegacySetXY`, temperature output only (tint is
    /// computed by the SDK but unused downstream in phase1).
    public static func xyToTemperature(_ xy: ChromaticityXY) -> Double {
        let u = 2.0 * xy.x / (1.5 - xy.x + 6.0 * xy.y)
        let v = 3.0 * xy.y / (1.5 - xy.x + 6.0 * xy.y)

        var lastDt = 0.0
        let n = table.count

        for index in 1..<n {
            var du = 1.0
            var dv = table[index].slope
            let length = (du * du + dv * dv).squareRoot()
            du /= length
            dv /= length

            let uu = u - table[index].u
            let vv = v - table[index].v

            var dt = -uu * dv + vv * du

            if dt <= 0.0 || index == n - 1 {
                if dt > 0.0 { dt = 0.0 }
                dt = -dt

                let f = index == 1 ? 0.0 : dt / (lastDt + dt)

                return 1.0e6 / (table[index - 1].mired * f + table[index].mired * (1.0 - f))
            }

            lastDt = dt
        }
        // Unreachable: the loop above always returns at index == n-1.
        return 1.0e6 / table[n - 1].mired
    }

    /// `dng_temperature.cpp`'s `LegacyGetXY`: the exact inverse of
    /// `xyToTemperature` (`LegacySetXY`) over the same Robertson isotherm
    /// table, used by phase2 C1's absolute white balance (XMP `WhiteBalance
    /// == Custom`'s `Temperature`/`Tint`). `kTintScale == -3000` per the SDK.
    ///
    /// Only the "legacy" (non-extended) table is implemented -- matching
    /// `xyToTemperature`'s own scope note -- so `temperature` is clamped to
    /// >= 2000K before the table search: below that the legacy table's mired
    /// domain (0...600, i.e. this table's own lowest entry is ~1667K) is
    /// exceeded and the loop's last-segment extrapolation (`index == 29`)
    /// becomes numerically unstable. This project's use (XMP Temperature
    /// sliders in the ~2000...50000 range) never legitimately needs colors
    /// below 2000K.
    public static func xy(fromTemperature temperature: Double, tint: Double) -> ChromaticityXY {
        let clampedTemperature = max(temperature, 2_000.0)
        let r = 1.0e6 / clampedTemperature
        let offset = tint * (1.0 / kTintScale)

        for index in 0..<(table.count - 1) {
            guard r < table[index + 1].mired || index == table.count - 2 else { continue }

            let f = (table[index + 1].mired - r) / (table[index + 1].mired - table[index].mired)

            var u = table[index].u * f + table[index + 1].u * (1.0 - f)
            var v = table[index].v * f + table[index + 1].v * (1.0 - f)

            var uu1 = 1.0
            var vv1 = table[index].slope
            var uu2 = 1.0
            var vv2 = table[index + 1].slope

            let len1 = (1.0 + vv1 * vv1).squareRoot()
            let len2 = (1.0 + vv2 * vv2).squareRoot()
            uu1 /= len1; vv1 /= len1
            uu2 /= len2; vv2 /= len2

            var uu3 = uu1 * f + uu2 * (1.0 - f)
            var vv3 = vv1 * f + vv2 * (1.0 - f)
            let len3 = (uu3 * uu3 + vv3 * vv3).squareRoot()
            uu3 /= len3; vv3 /= len3

            u += uu3 * offset
            v += vv3 * offset

            return ChromaticityXY(x: 1.5 * u / (u - 4.0 * v + 2.0), y: v / (u - 4.0 * v + 2.0))
        }
        // Unreachable: the loop above always returns by `index == table.count - 2`.
        return .d50
    }

    private static let kTintScale = -3_000.0

    /// `dng_color_spec.cpp`'s `XYtoXYZ` (Y == 1), with the same
    /// near-degenerate-chromaticity clamping.
    public static func xyToXYZ(_ xy: ChromaticityXY) -> SIMD3<Double> {
        var x = min(max(xy.x, 1e-6), 0.999999)
        var y = min(max(xy.y, 1e-6), 0.999999)
        if x + y > 0.999999 {
            let scale = 0.999999 / (x + y)
            x *= scale
            y *= scale
        }
        return SIMD3(x / y, 1.0, (1.0 - x - y) / y)
    }

    /// `dng_color_spec.cpp`'s `XYZtoXY`.
    public static func xyzToXY(_ xyz: SIMD3<Double>) -> ChromaticityXY {
        let total = xyz.x + xyz.y + xyz.z
        guard total > 0.0 else { return .d50 }
        return ChromaticityXY(x: xyz.x / total, y: xyz.y / total)
    }
}

extension DNGTemperature {
    /// Port of `dng_temperature::Set_xy_coord`: the two-output companion to
    /// `xyToTemperature` (`LegacySetXY`) over the same Robertson isotherm
    /// table, adding the perpendicular "tint" component `xyToTemperature`
    /// discards. Shares `xyToTemperature`'s exact search loop (same `u`/`v`
    /// conversion, same `dt`/`lastDt`/`f` interpolation), then projects the
    /// residual between the measured `(u, v)` and the interpolated isotherm
    /// base point onto that isotherm's normalized direction -- the same
    /// construction `xy(fromTemperature:tint:)` (`LegacyGetXY`) uses in
    /// reverse to turn a `tint` into a `(u, v)` offset -- and rescales by
    /// `kTintScale` to invert that function's own
    /// `offset = tint * (1 / kTintScale)`. Phase2 C1's absolute white
    /// balance UI (RAW "as shot" temperature/tint display) is the only
    /// caller; see `ColorSpec.temperatureAndTint(fromXY:)` for the public
    /// entry point.
    static func temperatureAndTint(fromXY xy: ChromaticityXY) -> (temperature: Double, tint: Double) {
        let u = 2.0 * xy.x / (1.5 - xy.x + 6.0 * xy.y)
        let v = 3.0 * xy.y / (1.5 - xy.x + 6.0 * xy.y)

        var lastDt = 0.0
        let n = table.count

        for index in 1..<n {
            var du = 1.0
            var dv = table[index].slope
            let length = (du * du + dv * dv).squareRoot()
            du /= length
            dv /= length

            let uu = u - table[index].u
            let vv = v - table[index].v

            var dt = -uu * dv + vv * du

            if dt <= 0.0 || index == n - 1 {
                if dt > 0.0 { dt = 0.0 }
                dt = -dt

                let f = index == 1 ? 0.0 : dt / (lastDt + dt)

                let temperature = 1.0e6 / (table[index - 1].mired * f + table[index].mired * (1.0 - f))

                // Interpolate the isotherm's base point and normalized
                // direction exactly as `xy(fromTemperature:tint:)` does when
                // going the other way (that function's `(index, index + 1)`
                // is this loop's `(index - 1, index)` for the same
                // segment), then project the residual onto that direction
                // to recover `tint`.
                let uBase = table[index - 1].u * f + table[index].u * (1.0 - f)
                let vBase = table[index - 1].v * f + table[index].v * (1.0 - f)

                var uu1 = 1.0
                var vv1 = table[index - 1].slope
                var uu2 = 1.0
                var vv2 = table[index].slope
                let len1 = (1.0 + vv1 * vv1).squareRoot()
                let len2 = (1.0 + vv2 * vv2).squareRoot()
                uu1 /= len1; vv1 /= len1
                uu2 /= len2; vv2 /= len2

                var duBase = uu1 * f + uu2 * (1.0 - f)
                var dvBase = vv1 * f + vv2 * (1.0 - f)
                let lenBase = (duBase * duBase + dvBase * dvBase).squareRoot()
                duBase /= lenBase
                dvBase /= lenBase

                let residualU = u - uBase
                let residualV = v - vBase
                let tint = (residualU * duBase + residualV * dvBase) * kTintScale

                return (temperature, tint)
            }

            lastDt = dt
        }
        // Unreachable: the loop above always returns at index == n-1.
        return (1.0e6 / table[n - 1].mired, 0.0)
    }
}

/// Dual-illuminant camera colorimetry (`dng_color_spec`'s two-illuminant
/// path). The Panasonic DC-S5 Adobe Standard DCP has exactly two
/// calibration illuminants (StandardLightA, D65), so only this path is
/// implemented -- matching the Python prototype's `DualIlluminantSpec`.
public struct ColorSpec: Sendable {
    public let temperatureLow: Double
    public let temperatureHigh: Double
    private let colorMatrixLow: Matrix3x3
    private let colorMatrixHigh: Matrix3x3
    private let forwardMatrixLow: Matrix3x3?
    private let forwardMatrixHigh: Matrix3x3?

    public init(
        colorMatrix1: Matrix3x3, colorMatrix2: Matrix3x3,
        forwardMatrix1: Matrix3x3?, forwardMatrix2: Matrix3x3?,
        calibrationIlluminant1: Int, calibrationIlluminant2: Int
    ) throws {
        let t1 = try DNGTemperature.illuminantToTemperature(calibrationIlluminant1)
        let t2 = try DNGTemperature.illuminantToTemperature(calibrationIlluminant2)
        // dng_color_spec's constructor canonicalizes so illuminant "1" is
        // the lower temperature; replicate that here.
        if t1 <= t2 {
            temperatureLow = t1
            temperatureHigh = t2
            colorMatrixLow = colorMatrix1
            colorMatrixHigh = colorMatrix2
            forwardMatrixLow = forwardMatrix1
            forwardMatrixHigh = forwardMatrix2
        } else {
            temperatureLow = t2
            temperatureHigh = t1
            colorMatrixLow = colorMatrix2
            colorMatrixHigh = colorMatrix1
            forwardMatrixLow = forwardMatrix2
            forwardMatrixHigh = forwardMatrix1
        }
    }

    /// Weight for the *low*-temperature calibration
    /// (`FindXYZtoCamera_SingleOrDual`'s `g`).
    public func gFraction(temperature: Double) -> Double {
        if temperature <= temperatureLow { return 1.0 }
        if temperature >= temperatureHigh { return 0.0 }
        let invT = 1.0 / temperature
        return (invT - (1.0 / temperatureHigh)) / ((1.0 / temperatureLow) - (1.0 / temperatureHigh))
    }

    public func gFraction(white: ChromaticityXY) -> Double {
        gFraction(temperature: DNGTemperature.xyToTemperature(white))
    }

    /// Interpolated `ColorMatrix` (XYZ D50 -> camera) for a given white point.
    public func colorMatrix(white: ChromaticityXY) -> Matrix3x3 {
        let g = gFraction(white: white)
        if g >= 1.0 { return colorMatrixLow }
        if g <= 0.0 { return colorMatrixHigh }
        return g * colorMatrixLow + (1.0 - g) * colorMatrixHigh
    }

    /// Interpolated `ForwardMatrix` (camera -> XYZ D50) for a given white point.
    public func forwardMatrix(white: ChromaticityXY) throws -> Matrix3x3 {
        guard let low = forwardMatrixLow, let high = forwardMatrixHigh else {
            throw ColorSpecError.missingForwardMatrix
        }
        let g = gFraction(white: white)
        if g >= 1.0 { return low }
        if g <= 0.0 { return high }
        return g * low + (1.0 - g) * high
    }

    /// `dng_color_spec::NeutralToXY`: iterate scene-white chromaticity from
    /// a camera-space neutral color. `neutral`'s absolute scale does not
    /// matter (the xy result is scale-invariant), only its per-channel
    /// ratios.
    public func neutralToXY(_ neutral: SIMD3<Double>, maxPasses: Int = 30) throws -> ChromaticityXY {
        var last = ChromaticityXY.d50
        for pass in 0..<maxPasses {
            let cm = colorMatrix(white: last)
            let inv = try cm.inverted()
            var next = DNGTemperature.xyzToXY(inv * neutral)
            if abs(next.x - last.x) + abs(next.y - last.y) < 1e-7 {
                return next
            }
            if pass == maxPasses - 1 {
                next = ChromaticityXY(x: (last.x + next.x) * 0.5, y: (last.y + next.y) * 0.5)
            }
            last = next
        }
        return last
    }
}

/// Which way to compute the camera(WB'd)->linear-ProPhoto matrix. See
/// `AdobeColorSpec.combinedCameraToLinearProPhoto` for the derivation of
/// each variant, and `Tests/Fixtures/phase1/colorspec-cases.json`'s "notes"
/// field for the numeric cross-check this was validated against.
public enum ColorSpecVariant: Sendable, Equatable {
    /// What the Python prototype (`run_all.py`'s `build_assets`) actually
    /// renders with: the interpolated ForwardMatrix applied directly to
    /// already as-shot-white-balanced camera RGB, with no extra per-channel
    /// normalization. Kept only for fixture parity / regression testing.
    case matchPrototype
    /// The DNG-SDK-faithful reading: `dng_color_spec::SetWhiteXY` folds
    /// `diag(1/fCameraWhite)` into the transform it applies to PRE-white-
    /// balance camera values. Re-expressed for as-shot-white-balanced input
    /// (this renderer's actual working representation), this becomes
    /// `ForwardMatrix @ diag(neutralG1 / cameraWhite)`. This is the default
    /// `AdobeColorMath` uses.
    case sdkCameraWhite
}

public enum AdobeColorSpec {
    /// `dng_color_spec::SetWhiteXY`'s `fCameraWhite`: derived from the
    /// *converged* white xy through the CCT-interpolated `ColorMatrix`
    /// (XYZ->camera), max-entry-normalized, then pinned to [0.001, 1.0] per
    /// channel (the SDK's "we don't support non-positive neutral values"
    /// guard).
    public static func cameraWhite(colorMatrix: Matrix3x3, white: ChromaticityXY) -> SIMD3<Double> {
        let xyz = DNGTemperature.xyToXYZ(white)
        let raw = colorMatrix * xyz
        let maxEntry = Swift.max(raw.x, Swift.max(raw.y, raw.z))
        let scale = maxEntry == 0 ? 0 : 1.0 / maxEntry
        func pin(_ v: Double) -> Double { min(max(v * scale, 0.001), 1.0) }
        return SIMD3(pin(raw.x), pin(raw.y), pin(raw.z))
    }

    /// The combined camera(as-shot-white-balanced) -> linear ProPhoto
    /// matrix, in either variant.
    ///
    /// - Parameters:
    ///   - neutralG1: the as-shot neutral ratio, normalized so the green
    ///     channel is 1.0 (== `AsShotNeutral` on the DNG-standard scale --
    ///     NOT the raw `1/WBLevel` ratio some raw decoders report, which is
    ///     on an arbitrary absolute scale). Only used by `.sdkCameraWhite`.
    public static func combinedCameraToLinearProPhoto(
        spec: ColorSpec, white: ChromaticityXY, neutralG1: SIMD3<Double>, variant: ColorSpecVariant
    ) throws -> Matrix3x3 {
        let forward = try spec.forwardMatrix(white: white) // camera -> XYZ D50
        let combined = DNGColorSpace.xyzD50ToProPhoto * forward
        switch variant {
        case .matchPrototype:
            return combined
        case .sdkCameraWhite:
            let cm = spec.colorMatrix(white: white)
            let camWhite = cameraWhite(colorMatrix: cm, white: white)
            let correction = Matrix3x3.diagonal(neutralG1 / camWhite)
            return combined * correction
        }
    }
}

public extension ColorSpec {
    /// `dng_temperature::Set_xy_coord`, exposed here for callers (phase2's
    /// absolute-white-balance UI, which reads a RAW's as-shot chromaticity
    /// to seed its temperature/tint sliders) that only need the
    /// xy -> (CCT, tint) direction, not a full dual-illuminant `ColorSpec`
    /// instance. Delegates to `DNGTemperature.temperatureAndTint(fromXY:)`,
    /// the inverse of `DNGTemperature.xy(fromTemperature:tint:)`.
    static func temperatureAndTint(fromXY xy: ChromaticityXY) -> (temperature: Double, tint: Double) {
        DNGTemperature.temperatureAndTint(fromXY: xy)
    }
}

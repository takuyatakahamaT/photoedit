import Foundation

public enum HueSatMapError: Error, Sendable, Equatable, LocalizedError {
    case dimensionMismatch

    public var errorDescription: String? {
        switch self {
        case .dimensionMismatch: "2つのHueSatMapテーブルの分割数が一致しません。"
        }
    }
}

/// `dng_hue_sat_map`'s table type and the reference application algorithm
/// (`RefBaselineHueSatMap`, `dng_reference.cpp`), plus the dual-illuminant
/// table interpolation (`dng_camera_profile::HueSatMapForWhite_Dual`).
///
/// Used for both a DCP's `ProfileHueSatMap` (valDivisions == 1, the "2.5D"
/// fast path) and any LookTable (valDivisions >= 2, the full trilinear
/// path) -- the SDK shares one function for both, and so does this port.
public enum HueSatMap {
    public typealias Table = DCPProfile.HueSatTable
    public typealias Entry = DCPProfile.HueSatEntry

    // MARK: - HSV <-> RGB (dng_utils.h: DNG_RGBtoHSV / DNG_HSVtoRGB)

    /// Hue range [0,6), saturation and value in [0,1] for normal inputs.
    /// Faithful to `DNG_RGBtoHSV`: NOT pinned to nonnegative first (that is
    /// a separate SDK wrapper, `DNG_PinnedNonnegativeRGBtoHSV`, which
    /// `RefBaselineHueSatMap` only uses when `supportOverrange` is set --
    /// phase1 never sets it). As in the SDK, a pixel with `v == 0` and
    /// `gap > 0` (only possible with negative input, e.g. from an
    /// out-of-gamut upstream stage) divides by zero here; this is
    /// intentionally preserved for fidelity rather than papered over.
    public static func rgbToHSV(_ rgb: SIMD3<Double>) -> (h: Double, s: Double, v: Double) {
        let r = rgb.x, g = rgb.y, b = rgb.z
        let v = max(r, max(g, b))
        let gap = v - min(r, min(g, b))
        guard gap > 0.0 else { return (0, 0, v) }

        let h: Double
        if r == v {
            var hh = (g - b) / gap
            if hh < 0.0 { hh += 6.0 }
            h = hh
        } else if g == v {
            h = 2.0 + (b - r) / gap
        } else {
            h = 4.0 + (r - g) / gap
        }
        return (h, gap / v, v)
    }

    /// `DNG_HSVtoRGB`. `h` in [0,6) (wrapped internally), `s`/`v` in [0,1].
    public static func hsvToRGB(h: Double, s: Double, v: Double) -> SIMD3<Double> {
        guard s > 0.0 else { return SIMD3(v, v, v) }

        var hh = h.truncatingRemainder(dividingBy: 6.0)
        if hh < 0.0 { hh += 6.0 }
        // The SDK's rare i==6 edge case (hh rounds to exactly 6.0 for a
        // negative h of tiny magnitude) uses the same formula as i==0; here
        // that is provably numerically identical to clamping i to 5 and
        // computing f = hh - 5 (both reduce to (v, p, p) at that boundary),
        // so this port keeps the simpler clamp rather than a separate case.
        var i = Int(hh)
        i = min(max(i, 0), 5)
        let f = hh - Double(i)

        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))

        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q) // i == 5
        }
    }

    // MARK: - Dual-illuminant table interpolation

    /// Entry-wise linear blend of two same-shaped tables
    /// (`HueSatMapForWhite_Dual`'s plain per-entry interpolation). `g == 1`
    /// returns `table1` unchanged (and vice versa for `g == 0`), matching
    /// the SDK's short-circuit at the illuminant endpoints.
    public static func interpolated(_ table1: Table, _ table2: Table, g: Double) throws -> Table {
        guard table1.dims == table2.dims else { throw HueSatMapError.dimensionMismatch }
        if g >= 1.0 { return table1 }
        if g <= 0.0 { return table2 }

        var entries = [Entry]()
        entries.reserveCapacity(table1.entries.count)
        for index in 0..<table1.entries.count {
            let e1 = table1.entries[index]
            let e2 = table2.entries[index]
            entries.append(Entry(
                hueShift: g * e1.hueShift + (1.0 - g) * e2.hueShift,
                satScale: g * e1.satScale + (1.0 - g) * e2.satScale,
                valScale: g * e1.valScale + (1.0 - g) * e2.valScale
            ))
        }
        return Table(dims: table1.dims, entries: entries)
    }

    // MARK: - RefBaselineHueSatMap

    /// Direct port of `RefBaselineHueSatMap` (`dng_reference.cpp`) for a
    /// single RGB triple. `supportOverrange` is always `false` in phase1
    /// (SDR working range only); the parameter is kept so the "2.5D"
    /// (valDivisions < 2) vs full trilinear branch selection, which the SDK
    /// shares with the overrange path, stays structurally identical to the
    /// source for future phases.
    ///
    /// Encode/decode 1D tables (`ProfileHueSatMapEncoding` /
    /// `ProfileLookTableEncoding` other than "linear") are not implemented:
    /// no profile or look table observed in this project sets them, and the
    /// DNG default (absent tag) is linear, i.e. identity encode/decode --
    /// exactly this function's behavior.
    public static func apply(_ rgb: SIMD3<Double>, table: Table) -> SIMD3<Double> {
        let hueDivs = table.dims.hue
        let satDivs = table.dims.sat
        let valDivs = table.dims.val

        let hScale = hueDivs < 2 ? 0.0 : Double(hueDivs) * (1.0 / 6.0)
        let sScale = Double(satDivs - 1)
        let maxHueIndex0 = hueDivs - 1
        let maxSatIndex0 = satDivs - 2

        let (h, s, v) = rgbToHSV(rgb)
        let vEncoded = v // identity encode table (linear encoding only)

        let hueShift: Double
        let satScale: Double
        let valScale: Double

        if valDivs < 2 {
            let hScaled = h * hScale
            let sScaled = s * sScale

            var hIndex0 = pinIndex(hScaled, maxHueIndex0)
            let sIndex0 = pinIndex(sScaled, maxSatIndex0)
            var hIndex1 = hIndex0 + 1
            if hIndex0 >= maxHueIndex0 { hIndex0 = maxHueIndex0; hIndex1 = 0 }

            let hFrac1 = hScaled - Double(hIndex0)
            let sFrac1 = sScaled - Double(sIndex0)
            let hFrac0 = 1.0 - hFrac1
            let sFrac0 = 1.0 - sFrac1

            let e00 = table[0, hIndex0, sIndex0]
            let e01 = table[0, hIndex1, sIndex0]
            let e00b = table[0, hIndex0, sIndex0 + 1]
            let e01b = table[0, hIndex1, sIndex0 + 1]

            let hueShift0 = hFrac0 * e00.hueShift + hFrac1 * e01.hueShift
            let satScale0 = hFrac0 * e00.satScale + hFrac1 * e01.satScale
            let valScale0 = hFrac0 * e00.valScale + hFrac1 * e01.valScale

            let hueShift1 = hFrac0 * e00b.hueShift + hFrac1 * e01b.hueShift
            let satScale1 = hFrac0 * e00b.satScale + hFrac1 * e01b.satScale
            let valScale1 = hFrac0 * e00b.valScale + hFrac1 * e01b.valScale

            hueShift = sFrac0 * hueShift0 + sFrac1 * hueShift1
            satScale = sFrac0 * satScale0 + sFrac1 * satScale1
            valScale = sFrac0 * valScale0 + sFrac1 * valScale1
        } else {
            let vScale = Double(valDivs - 1)
            let maxValIndex0 = valDivs - 2

            let hScaled = h * hScale
            let sScaled = s * sScale
            let vScaled = vEncoded * vScale

            var hIndex0 = pinIndex(hScaled, maxHueIndex0)
            let sIndex0 = pinIndex(sScaled, maxSatIndex0)
            let vIndex0 = pinIndex(vScaled, maxValIndex0)
            var hIndex1 = hIndex0 + 1
            if hIndex0 >= maxHueIndex0 { hIndex0 = maxHueIndex0; hIndex1 = 0 }
            let vIndex1 = vIndex0 + 1

            let hFrac1 = hScaled - Double(hIndex0)
            let sFrac1 = sScaled - Double(sIndex0)
            let vFrac1 = vScaled - Double(vIndex0)
            let hFrac0 = 1.0 - hFrac1
            let sFrac0 = 1.0 - sFrac1
            let vFrac0 = 1.0 - vFrac1

            let e000 = table[vIndex0, hIndex0, sIndex0]
            let e001 = table[vIndex0, hIndex1, sIndex0]
            let e010 = table[vIndex0, hIndex0, sIndex0 + 1]
            let e011 = table[vIndex0, hIndex1, sIndex0 + 1]
            let e100 = table[vIndex1, hIndex0, sIndex0]
            let e101 = table[vIndex1, hIndex1, sIndex0]
            let e110 = table[vIndex1, hIndex0, sIndex0 + 1]
            let e111 = table[vIndex1, hIndex1, sIndex0 + 1]

            func blend(_ key: KeyPath<Entry, Double>) -> Double {
                let a0 = vFrac0 * (hFrac0 * e000[keyPath: key] + hFrac1 * e001[keyPath: key])
                    + vFrac1 * (hFrac0 * e100[keyPath: key] + hFrac1 * e101[keyPath: key])
                let a1 = vFrac0 * (hFrac0 * e010[keyPath: key] + hFrac1 * e011[keyPath: key])
                    + vFrac1 * (hFrac0 * e110[keyPath: key] + hFrac1 * e111[keyPath: key])
                return sFrac0 * a0 + sFrac1 * a1
            }

            hueShift = blend(\.hueShift)
            satScale = blend(\.satScale)
            valScale = blend(\.valScale)
        }

        let hueShiftInternal = hueShift * (6.0 / 360.0) // degrees -> internal [0,6) hue range
        let hNew = h + hueShiftInternal
        let sNew = min(s * satScale, 1.0)
        let vEncodedNew = pin01(vEncoded * valScale)
        let vNew = vEncodedNew // identity decode table (linear encoding only)

        return hsvToRGB(h: hNew, s: sNew, v: vNew)
    }

    private static func pinIndex(_ scaled: Double, _ maxIndex0: Int) -> Int {
        guard scaled.isFinite else { return 0 } // NaN-safe: avoid Int(Double.nan) trapping
        return min(max(Int(scaled.rounded(.down)), 0), maxIndex0)
    }

    private static func pin01(_ x: Double) -> Double {
        min(max(x, 0.0), 1.0)
    }
}

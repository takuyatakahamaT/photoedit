import Foundation

/// Panasonic RW2's embedded lens-distortion correction parameters
/// (`PanasonicRaw::DistortionInfo`, IFD0 tag 0x0119) plus the camera-declared
/// active image area (`Crop*` tags), read directly from the RW2's own IFD0.
///
/// `.photobench/phase4/lens/model.md` §1/§2/§6 is the source of truth for
/// the correction model this feeds; this type only extracts the raw numbers.
public struct PanasonicDistortionInfo: Equatable, Sendable {
    /// Camera-declared active image area, in the RAW's own native pixel
    /// coordinate system (`CropLeft/Top/Right/Bottom`, IFD0 tags
    /// 0x30/0x2f/0x32/0x31). Only `cropWidth`/`cropHeight` (its *size*) feed
    /// `LensDistortion`: the output canvas is that size, centered on the
    /// decoder's own output -- not offset by `left`/`top` (`model.md` §2:
    /// the measured LibRaw-output-center <-> LR-center correspondence is a
    /// pure geometric-center relationship, not a `CropLeft`/`CropTop`
    /// translation, even though the two happen to match numerically for the
    /// DC-S5's own sensor).
    public struct CropRect: Equatable, Sendable {
        public let left: Int
        public let top: Int
        public let right: Int
        public let bottom: Int

        public init(left: Int, top: Int, right: Int, bottom: Int) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    /// `DistortionScale` (`ValueConv '1/(1+$val/32768)'`, already applied).
    public let scale: Double
    /// `DistortionParam08` (`model.md`'s `a`; `$val/32768`, already applied).
    public let a: Double
    /// `DistortionParam04` (`model.md`'s `b`; `$val/32768`, already applied).
    public let b: Double
    /// `DistortionParam11` (`model.md`'s `c`; `$val/32768`, already applied).
    public let c: Double
    /// `DistortionN`: the body-constant normalization radius, in px, used
    /// as-is (no `ValueConv`).
    public let r0: Double
    /// `DistortionCorrection` (`Mask => 0x0f` on the same 16-`int16s` array,
    /// element 7; `{0 => 'Off', 1 => 'On'}`). `false` means the camera did
    /// not apply (and Lightroom therefore does not need/expect) any
    /// correction for this shot; callers must not warp in that case.
    public let correctionEnabled: Bool
    public let cropRect: CropRect

    public var cropWidth: Int { cropRect.right - cropRect.left }
    public var cropHeight: Int { cropRect.bottom - cropRect.top }

    public init(
        scale: Double, a: Double, b: Double, c: Double, r0: Double,
        correctionEnabled: Bool, cropRect: CropRect
    ) {
        self.scale = scale
        self.a = a
        self.b = b
        self.c = c
        self.r0 = r0
        self.correctionEnabled = correctionEnabled
        self.cropRect = cropRect
    }
}

/// Minimal, read-only Panasonic RW2 IFD0 parser: just enough of the TIFF
/// structure to reach tags 0x0119 (`DistortionInfo`), 0x2f/0x30/0x31/0x32
/// (`CropTop/Left/Bottom/Right`) and 0x02/0x03 (`SensorWidth/Height`, used
/// only as a cross-check that the crop rect it found is plausible). Never
/// loads the whole file -- every read is a small, targeted `FileHandle`
/// seek+read -- and never attempts to parse anything other RAW formats'
/// makernotes or Panasonic tags this feature doesn't need.
///
/// Field layout and semantics come from ExifTool's `PanasonicRaw.pm`
/// (`%Image::ExifTool::PanasonicRaw::DistortionInfo`, comment "ref 3"):
/// 16 little-endian `int16s` values `data[0...15]` live at tag 0x0119
/// (`FORMAT => 'int16s'`, regardless of what type/count the IFD entry itself
/// declares -- Panasonic firmwares have been observed declaring this as
/// UNDEFINED/BYTE count 32 or SHORT count 16; both are 32 raw bytes and are
/// read identically here), with:
///   - `data[5]`       -> `DistortionScale`,  `ValueConv '1/(1+$val/32768)'`
///   - `data[8]`       -> `DistortionParam08` (`a`), `$val/32768`
///   - `data[4]`       -> `DistortionParam04` (`b`), `$val/32768`
///   - `data[11]`      -> `DistortionParam11` (`c`), `$val/32768`
///   - `data[12]`      -> `DistortionN` (`R0`), used as-is (px)
///   - `data[7] & 0x0F` -> `DistortionCorrection` (`Mask => 0x0f`,
///     `{0 => 'Off', 1 => 'On'}`; exiftool's comment notes some bodies set
///     the upper nibble too, hence the mask)
/// Verified against `exports/editing-mvp-20260922/lightroom-reference/
/// P1013558.RW2`'s raw tag bytes (`exiftool -H -u -s -DistortionInfo`):
/// `data[5]=-1070 -> scale=1.03375607293836`, `data[8]=-1117 ->
/// a=-0.034088134765625`, `data[4]=111 -> b=0.003387451171875`,
/// `data[11]=-49 -> c=-0.001495361328125`, `data[12]=3605 -> R0=3605` --
/// all matching `exiftool -u -s3 -DistortionScale -DistortionParam08
/// -DistortionParam04 -DistortionParam11 -DistortionN` to full double
/// precision; `data[7]`'s raw bit pattern is `0xE901`, whose low nibble
/// `0x1` matches exiftool's own `DistortionCorrection: On` for that file.
public enum PanasonicRW2Metadata {
    /// RW2's non-standard TIFF magic number (a normal TIFF/DNG/NEF/ARW uses
    /// 0x002A; only Panasonic/Leica RW2 and RWL use 0x0055), at byte offset
    /// 2 of the header, right after the "II" byte-order mark.
    private static let rw2Magic: UInt16 = 0x0055
    private static let distortionInfoTag: UInt16 = 0x0119
    private static let cropTopTag: UInt16 = 0x002F
    private static let cropLeftTag: UInt16 = 0x0030
    private static let cropBottomTag: UInt16 = 0x0031
    private static let cropRightTag: UInt16 = 0x0032
    private static let sensorWidthTag: UInt16 = 0x0002
    private static let sensorHeightTag: UInt16 = 0x0003
    private static let ifdEntrySize = 12
    private static let distortionInfoByteCount = 32

    /// `nil` when `url` is not an RW2/RWL ("II" + magic 0x0055 TIFF-like
    /// file), IFD0 has no 0x0119 tag or is missing any of the four Crop*
    /// tags, the raw bytes don't sanity-check against `SensorWidth/Height`
    /// when those are present, or the file otherwise cannot be read.
    public static func readDistortionInfo(url: URL) -> PanasonicDistortionInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? parse(handle)
    }

    private static func parse(_ handle: FileHandle) throws -> PanasonicDistortionInfo? {
        guard let header = try handle.read(upToCount: 8), header.count == 8 else { return nil }
        let headerBytes = [UInt8](header)
        guard headerBytes[0] == UInt8(ascii: "I"), headerBytes[1] == UInt8(ascii: "I") else { return nil }
        guard readUInt16LE(headerBytes, at: 2) == rw2Magic else { return nil }
        let ifd0Offset = readUInt32LE(headerBytes, at: 4)

        try handle.seek(toOffset: UInt64(ifd0Offset))
        guard let countBytes = try handle.read(upToCount: 2), countBytes.count == 2 else { return nil }
        let entryCount = Int(readUInt16LE([UInt8](countBytes), at: 0))
        guard entryCount > 0, entryCount < 4_096 else { return nil } // sanity bound, not a real IFD0 has this many

        guard let entriesData = try handle.read(upToCount: entryCount * ifdEntrySize),
              entriesData.count == entryCount * ifdEntrySize
        else { return nil }
        let entryBytes = [UInt8](entriesData)

        var distortionEntry: (type: UInt16, count: UInt32, valueField: [UInt8])?
        var cropTop, cropLeft, cropBottom, cropRight, sensorWidth, sensorHeight: Int?

        for index in 0..<entryCount {
            let base = index * ifdEntrySize
            let tag = readUInt16LE(entryBytes, at: base)
            let type = readUInt16LE(entryBytes, at: base + 2)
            let count = readUInt32LE(entryBytes, at: base + 4)
            let valueField = Array(entryBytes[(base + 8)..<(base + 12)])
            switch tag {
            case distortionInfoTag:
                distortionEntry = (type, count, valueField)
            case cropTopTag:
                cropTop = inlineUnsignedValue(type: type, count: count, valueField: valueField)
            case cropLeftTag:
                cropLeft = inlineUnsignedValue(type: type, count: count, valueField: valueField)
            case cropBottomTag:
                cropBottom = inlineUnsignedValue(type: type, count: count, valueField: valueField)
            case cropRightTag:
                cropRight = inlineUnsignedValue(type: type, count: count, valueField: valueField)
            case sensorWidthTag:
                sensorWidth = inlineUnsignedValue(type: type, count: count, valueField: valueField)
            case sensorHeightTag:
                sensorHeight = inlineUnsignedValue(type: type, count: count, valueField: valueField)
            default:
                break
            }
        }

        guard let (type, count, valueField) = distortionEntry else { return nil }
        guard let left = cropLeft, let top = cropTop, let right = cropRight, let bottom = cropBottom,
              right > left, bottom > top
        else { return nil }
        // Cross-check against SensorWidth/Height when the camera wrote them:
        // the declared active area must fit inside the sensor. Skipped
        // (not required) when either tag is absent.
        if let sensorWidth, right > sensorWidth { return nil }
        if let sensorHeight, bottom > sensorHeight { return nil }

        guard let rawBytes = try readTagBytes(
            handle, type: type, count: count, valueField: valueField, expectedByteCount: distortionInfoByteCount
        ) else { return nil }

        var data16 = [Int16](repeating: 0, count: 16)
        for index in 0..<16 {
            let lo = UInt16(rawBytes[index * 2])
            let hi = UInt16(rawBytes[index * 2 + 1])
            data16[index] = Int16(bitPattern: lo | (hi << 8))
        }

        let scale = 1.0 / (1.0 + Double(data16[5]) / 32_768.0)
        let a = Double(data16[8]) / 32_768.0
        let b = Double(data16[4]) / 32_768.0
        let c = Double(data16[11]) / 32_768.0
        let r0 = Double(data16[12])
        let correctionEnabled = (data16[7] & 0x0F) != 0

        return PanasonicDistortionInfo(
            scale: scale, a: a, b: b, c: c, r0: r0,
            correctionEnabled: correctionEnabled,
            cropRect: .init(left: left, top: top, right: right, bottom: bottom)
        )
    }

    /// Resolves a TIFF IFD entry's payload to exactly `expectedByteCount`
    /// raw bytes, regardless of what `type` the entry declares (Panasonic
    /// firmwares are inconsistent about whether 0x0119 is typed as
    /// UNDEFINED/BYTE count 32 or SHORT count 16 -- both resolve to 32
    /// bytes here, read identically). Inline when the whole payload fits in
    /// the entry's own 4-byte value/offset field; otherwise that field is a
    /// little-endian file offset to seek to.
    private static func readTagBytes(
        _ handle: FileHandle, type: UInt16, count: UInt32, valueField: [UInt8], expectedByteCount: Int
    ) throws -> [UInt8]? {
        guard let elementSize = elementSize(forType: type) else { return nil }
        let totalBytes = Int(count) * elementSize
        guard totalBytes >= expectedByteCount else { return nil }
        if totalBytes <= 4 {
            return Array(valueField.prefix(expectedByteCount))
        }
        let offset = readUInt32LE(valueField, at: 0)
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: expectedByteCount), data.count == expectedByteCount
        else { return nil }
        return [UInt8](data)
    }

    /// A single-count, <=4-byte-wide tag's value, always inline in the
    /// entry's own value/offset field (true for every `Crop*`/`Sensor*`
    /// tag this reads, which are all `int16u` in practice; BYTE/LONG are
    /// tolerated too since nothing here depends on the declared type being
    /// exactly SHORT).
    private static func inlineUnsignedValue(type: UInt16, count: UInt32, valueField: [UInt8]) -> Int? {
        guard count == 1, let elementSize = elementSize(forType: type), elementSize <= 4 else { return nil }
        switch elementSize {
        case 1: return Int(valueField[0])
        case 2: return Int(readUInt16LE(valueField, at: 0))
        default: return Int(readUInt32LE(valueField, at: 0))
        }
    }

    /// TIFF field type -> byte width (types 1/2/6/7 = BYTE/ASCII/SBYTE/
    /// UNDEFINED, 3/8 = SHORT/SSHORT, 4/9/11 = LONG/SLONG/FLOAT, 5/10/12 =
    /// RATIONAL/SRATIONAL/DOUBLE). `nil` for anything else (unused here).
    private static func elementSize(forType type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return nil
        }
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

import Compression
import CryptoKit
import Foundation

public enum AdobeLookXMPError: Error, Sendable, Equatable, LocalizedError {
    case lookTableIDNotFound
    case tableBlobNotFound
    case truncatedBlob
    case inflateLengthMismatch(expected: Int, actual: Int)
    case statedLengthMismatch(stated: Int, actual: Int)
    case md5Mismatch(expected: String, actual: String)
    case unexpectedTableType(Int)
    case unexpectedDataSize(expected: Int, actual: Int)
    case unexpectedTrailer
    case toneCurveNotFound
    case noToneCurvePoints

    public var errorDescription: String? {
        switch self {
        case .lookTableIDNotFound: "crs:LookTable属性が見つかりません。"
        case .tableBlobNotFound: "crs:Table_<ID>属性が見つかりません。"
        case .truncatedBlob: "テーブルblobが短すぎます。"
        case .inflateLengthMismatch(let expected, let actual):
            "展開後バイト数が不一致です（期待\(expected)、実際\(actual)）。"
        case .statedLengthMismatch(let stated, let actual):
            "先頭4バイトの長さ表記と展開結果が不一致です（表記\(stated)、実際\(actual)）。"
        case .md5Mismatch(let expected, let actual):
            "展開後データのMD5が一致しません（期待\(expected)、実際\(actual)）。"
        case .unexpectedTableType(let type): "未知のルックテーブル種別です: \(type)"
        case .unexpectedDataSize(let expected, let actual):
            "ルックテーブルのデータサイズが想定外です（期待\(expected)、実際\(actual)）。"
        case .unexpectedTrailer: "ルックテーブルデータの末尾4バイトが想定外です。"
        case .toneCurveNotFound: "crs:ToneCurvePV2012が見つかりません。"
        case .noToneCurvePoints: "crs:ToneCurvePV2012の制御点を読み取れませんでした。"
        }
    }
}

/// Parses Lightroom's camera-agnostic "Adobe Color" look profile XMP
/// (`Adobe Color.xmp`): the proprietary base85-ish + zlib `Table_<MD5>`
/// blob attribute, decoded into a `DCPProfile.HueSatTable`-compatible grid,
/// plus the `ToneCurvePV2012` point-curve control points.
///
/// CORRECTION (2026-09-22, see
/// `.photobench/engine-research-20260922/dcp-base-prototype/CORRECTION.md`
/// and `scripts/adobe_color_xmp.py`'s module docstring for the full
/// history): the inflated blob's header is **u32x5 = 20 bytes** (type=0,
/// version=1, hueDivs, satDivs, valDivs); data starts at byte offset 20 and
/// is a flat float32 stream of (hueShiftDeg, satScale, valScale) triples in
/// the *standard* DNG order (same as `ProfileHueSatMapData`/
/// `ProfileLookTableData` -- no proprietary channel reordering), followed
/// by a 4-byte all-zero trailer.
public struct AdobeLookXMP: Sendable, Equatable {
    public var lookTableID: String
    public var headerType: Int
    public var headerVersion: Int
    public var dims: DCPProfile.Dimensions3 // (hue, sat, val)
    public var lookTableData: DCPProfile.HueSatTable
    /// `ToneCurvePV2012` control points, in the file's own 0...255 domain
    /// (NOT pre-normalized to [0,1] -- callers building a render pipeline
    /// divide by 255 explicitly, matching the Python prototype's separate
    /// `look.tone_curve_points / 255.0` step).
    public var toneCurvePoints: [SIMD2<Double>]

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AdobeLookXMPError.lookTableIDNotFound
        }
        try self.init(xmlText: text)
    }

    init(xmlText text: String) throws {
        let delegate = AdobeLookXMLDelegate()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate
        _ = parser.parse() // Fall through to explicit field checks below even on a parse error;

        guard let lookTableID = delegate.lookTableID else {
            throw AdobeLookXMPError.lookTableIDNotFound
        }
        guard let blob = delegate.tableBlob else {
            throw AdobeLookXMPError.tableBlobNotFound
        }
        guard !delegate.toneCurvePoints.isEmpty else {
            throw AdobeLookXMPError.noToneCurvePoints
        }

        let packed = Self.decodeBase85ish(blob)
        guard packed.count >= 4 else { throw AdobeLookXMPError.truncatedBlob }
        let statedLength = Int(Self.readU32LE(packed, at: 0))
        let compressed = Array(packed[4...])

        let inflated = try Self.inflateZlibPayload(compressed, expectedLength: statedLength)
        guard inflated.count == statedLength else {
            throw AdobeLookXMPError.statedLengthMismatch(stated: statedLength, actual: inflated.count)
        }

        let digest = Insecure.MD5.hash(data: Data(inflated))
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        guard digestHex.caseInsensitiveCompare(lookTableID) == .orderedSame else {
            throw AdobeLookXMPError.md5Mismatch(expected: lookTableID, actual: digestHex)
        }

        guard inflated.count >= 20 else { throw AdobeLookXMPError.truncatedBlob }
        let type = Int(Self.readU32LE(inflated, at: 0))
        let version = Int(Self.readU32LE(inflated, at: 4))
        let hueDivs = Int(Self.readU32LE(inflated, at: 8))
        let satDivs = Int(Self.readU32LE(inflated, at: 12))
        let valDivs = Int(Self.readU32LE(inflated, at: 16))
        guard type == 0 else { throw AdobeLookXMPError.unexpectedTableType(type) }

        let expectedEntries = hueDivs * satDivs * valDivs
        let dataBytes = expectedEntries * 3 * 4
        guard inflated.count >= 20 + dataBytes else {
            throw AdobeLookXMPError.unexpectedDataSize(expected: 20 + dataBytes, actual: inflated.count)
        }
        let trailer = Array(inflated[(20 + dataBytes)...])
        guard trailer.count == 4, trailer.allSatisfy({ $0 == 0 }) else {
            throw AdobeLookXMPError.unexpectedTrailer
        }

        var entries = [DCPProfile.HueSatEntry]()
        entries.reserveCapacity(expectedEntries)
        var cursor = 20
        for _ in 0..<expectedEntries {
            let hueShift = Double(Self.readF32LE(inflated, at: cursor))
            let satScale = Double(Self.readF32LE(inflated, at: cursor + 4))
            let valScale = Double(Self.readF32LE(inflated, at: cursor + 8))
            entries.append(DCPProfile.HueSatEntry(hueShift: hueShift, satScale: satScale, valScale: valScale))
            cursor += 12
        }
        // Documented dng_hue_sat_map order: value outermost, hue, saturation innermost.
        let dims = DCPProfile.Dimensions3(hue: hueDivs, sat: satDivs, val: valDivs)

        self.lookTableID = lookTableID
        self.headerType = type
        self.headerVersion = version
        self.dims = dims
        self.lookTableData = DCPProfile.HueSatTable(dims: dims, entries: entries)
        self.toneCurvePoints = delegate.toneCurvePoints.sorted { $0.x < $1.x }
    }

    // MARK: - Base85-ish decode

    private static let alphabet =
        Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#")
    private static let decodeTable: [Character: UInt64] = {
        var table: [Character: UInt64] = [:]
        for (index, char) in alphabet.enumerated() { table[char] = UInt64(index) }
        return table
    }()
    private static let powersOf85: [UInt64] = [1, 85, 85 * 85, 85 * 85 * 85, 85 * 85 * 85 * 85]

    /// Decodes the proprietary base85-ish blob: unrecognized characters
    /// (whitespace, XML-decoded newlines, etc.) are skipped; every 5 valid
    /// characters pack into one little-endian `UInt32`; a 2-4 character
    /// remainder packs into the corresponding number of low-order bytes
    /// (matching the Python prototype's `_decode_blob`); a lone leftover
    /// character (not enough to reconstruct even one byte) is dropped.
    static func decodeBase85ish(_ blob: String) -> [UInt8] {
        var out: [UInt8] = []
        var phase = 0
        var value: UInt64 = 0
        for char in blob {
            guard let digit = decodeTable[char] else { continue }
            value += digit * powersOf85[phase]
            phase += 1
            if phase == 5 {
                let word = UInt32(truncatingIfNeeded: value)
                out.append(contentsOf: withUnsafeBytes(of: word.littleEndian) { Array($0) })
                phase = 0
                value = 0
            }
        }
        if phase > 1 {
            let word = UInt32(truncatingIfNeeded: value)
            let bytes = withUnsafeBytes(of: word.littleEndian) { Array($0) }
            out.append(contentsOf: bytes.prefix(phase - 1))
        }
        return out
    }

    // MARK: - zlib (raw-deflate-with-header-skip) inflate

    /// Inflates a standard zlib stream (2-byte header + raw DEFLATE +
    /// 4-byte Adler32, RFC 1950) using the `Compression` framework, whose
    /// `COMPRESSION_ZLIB` algorithm actually implements raw DEFLATE only
    /// (RFC 1951) -- so the 2-byte zlib header must be skipped first. The
    /// trailing Adler32 checksum is not validated (not exposed by this
    /// API); `statedLengthMismatch`/MD5 checks above already guard data
    /// integrity end-to-end.
    static func inflateZlibPayload(_ compressed: [UInt8], expectedLength: Int) throws -> [UInt8] {
        guard compressed.count > 2 else { throw AdobeLookXMPError.truncatedBlob }
        let deflateBytes = Array(compressed.dropFirst(2))
        guard expectedLength > 0 else { return [] }

        var destination = [UInt8](repeating: 0, count: expectedLength)
        let decodedCount = destination.withUnsafeMutableBufferPointer { destBuffer -> Int in
            deflateBytes.withUnsafeBufferPointer { srcBuffer -> Int in
                guard let srcBase = srcBuffer.baseAddress, let destBase = destBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destBase, expectedLength,
                    srcBase, srcBuffer.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == expectedLength else {
            throw AdobeLookXMPError.inflateLengthMismatch(expected: expectedLength, actual: decodedCount)
        }
        return destination
    }

    // MARK: - Little-endian primitive reads

    private static func readU32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readF32LE(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: readU32LE(bytes, at: offset))
    }
}

/// Minimal XML delegate extracting exactly the three things
/// `AdobeLookXMP` needs: the top-level `rdf:Description`'s `crs:LookTable`
/// and `crs:Table_<id>` attributes, and the `crs:ToneCurvePV2012` sequence's
/// control points. Entity references in attribute values (e.g. `&#xA;`)
/// are already decoded by `XMLParser` itself before reaching this delegate.
private final class AdobeLookXMLDelegate: NSObject, XMLParserDelegate {
    var lookTableID: String?
    var tableBlob: String?
    var toneCurvePoints: [SIMD2<Double>] = []

    private var descriptionDepth = 0
    private var elementStack: [String] = []
    private var insideToneCurve = false
    private var insideToneCurveListItem = false
    private var listItemText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let qualified = qName ?? elementName

        if qualified == "rdf:Description" {
            descriptionDepth += 1
            if descriptionDepth == 1 {
                for (key, value) in attributeDict {
                    if key == "crs:LookTable" {
                        lookTableID = value
                    } else if key.hasPrefix("crs:Table_") {
                        tableBlob = value
                    }
                }
            }
        }

        elementStack.append(qualified)

        if qualified == "crs:ToneCurvePV2012" {
            insideToneCurve = true
        }
        if insideToneCurve, qualified == "rdf:li" {
            insideToneCurveListItem = true
            listItemText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideToneCurveListItem else { return }
        listItemText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let qualified = qName ?? elementName

        if qualified == "rdf:li", insideToneCurveListItem {
            let parts = listItemText
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if parts.count == 2 {
                toneCurvePoints.append(SIMD2(parts[0], parts[1]))
            }
            insideToneCurveListItem = false
            listItemText = ""
        }
        if qualified == "crs:ToneCurvePV2012" {
            insideToneCurve = false
        }
        if qualified == "rdf:Description" {
            descriptionDepth -= 1
        }
        if elementStack.last == qualified {
            elementStack.removeLast()
        }
    }
}

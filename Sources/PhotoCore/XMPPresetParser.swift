import Foundation

public enum CompatibilityLevel: String, Codable, Sendable {
    case supported = "対応"
    case approximate = "近似"
    case unsupported = "未対応"
    case metadata = "情報"
}

public struct CompatibilityItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let property: String
    public let value: String
    public let level: CompatibilityLevel
    public let note: String

    public init(property: String, value: String, level: CompatibilityLevel, note: String) {
        self.id = property
        self.property = property
        self.value = value
        self.level = level
        self.note = note
    }
}

public struct XMPPreset: Codable, Equatable, Sendable {
    public let name: String
    public let processVersion: String?
    public let cameraRawVersion: String?
    public let settings: EditSettings
    public let compatibility: [CompatibilityItem]
    public let rawProperties: [String: String]

    public init(
        name: String,
        processVersion: String?,
        cameraRawVersion: String?,
        settings: EditSettings,
        compatibility: [CompatibilityItem],
        rawProperties: [String: String]
    ) {
        self.name = name
        self.processVersion = processVersion
        self.cameraRawVersion = cameraRawVersion
        self.settings = settings
        self.compatibility = compatibility
        self.rawProperties = rawProperties
    }

    /// Applies this preset as a patch. Adobe presets may intentionally contain
    /// only a subset of controls, so absent fields must not reset an existing
    /// edit to zero.
    public func applying(to base: EditSettings) -> EditSettings {
        var result = base

        func hasFiniteNumber(_ key: String) -> Bool {
            guard let raw = rawProperties[key], let value = Double(raw) else { return false }
            return value.isFinite
        }

        if hasFiniteNumber("Exposure2012") { result.exposure = settings.exposure }
        if hasFiniteNumber("Contrast2012") { result.contrast = settings.contrast }
        if hasFiniteNumber("Highlights2012") { result.highlights = settings.highlights }
        if hasFiniteNumber("Shadows2012") { result.shadows = settings.shadows }
        if hasFiniteNumber("Whites2012") { result.whites = settings.whites }
        if hasFiniteNumber("Blacks2012") { result.blacks = settings.blacks }
        if hasFiniteNumber("Vibrance") { result.vibrance = settings.vibrance }
        if hasFiniteNumber("Saturation") { result.saturation = settings.saturation }

        if rawProperties["WhiteBalance"] != nil {
            result.whiteBalance.mode = settings.whiteBalance.mode
        }
        if hasFiniteNumber("Temperature") {
            result.whiteBalance.temperature = settings.whiteBalance.temperature
        }
        if hasFiniteNumber("Tint") {
            result.whiteBalance.tint = settings.whiteBalance.tint
        }
        if hasFiniteNumber("IncrementalTemperature") {
            result.whiteBalance.incrementalTemperature = settings.whiteBalance.incrementalTemperature
        }
        if hasFiniteNumber("IncrementalTint") {
            result.whiteBalance.incrementalTint = settings.whiteBalance.incrementalTint
        }

        for curve in settings.toneCurves {
            result.toneCurves.removeAll { $0.channel == curve.channel }
            result.toneCurves.append(curve)
        }
        result.toneCurves.sort { $0.channel.rawValue < $1.channel.rawValue }

        for band in HSLBand.allCases {
            let suffix = band.rawValue.prefix(1).uppercased() + band.rawValue.dropFirst()
            let parsed = settings.hsl[band] ?? HSLAdjustment()
            var adjustment = result.hsl[band] ?? HSLAdjustment()
            if hasFiniteNumber("HueAdjustment\(suffix)") { adjustment.hue = parsed.hue }
            if hasFiniteNumber("SaturationAdjustment\(suffix)") {
                adjustment.saturation = parsed.saturation
            }
            if hasFiniteNumber("LuminanceAdjustment\(suffix)") {
                adjustment.luminance = parsed.luminance
            }
            if adjustment == HSLAdjustment() {
                result.hsl.removeValue(forKey: band)
            } else {
                result.hsl[band] = adjustment
            }
        }
        return result
    }
}

public enum XMPPresetError: LocalizedError {
    case invalidXML

    public var errorDescription: String? {
        switch self {
        case .invalidXML: "XMPを解析できませんでした。"
        }
    }
}

public enum XMPPresetParser {
    public static func parse(url: URL) throws -> XMPPreset {
        let data = try Data(contentsOf: url)
        return try parse(data: data, fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(data: Data, fallbackName: String) throws -> XMPPreset {
        let delegate = XMPDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? XMPPresetError.invalidXML }
        return delegate.makePreset(fallbackName: fallbackName)
    }
}

private final class XMPDelegate: NSObject, XMLParserDelegate {
    private enum SimpleElementTarget {
        case root
        case nested
    }

    private struct ActiveSimpleElement {
        let qualifiedName: String
        let property: String
        let depth: Int
        let target: SimpleElementTarget
        var text = ""
        var hasChildElement = false
    }

    private var properties: [String: String] = [:]
    private var nestedProperties: [String: String] = [:]
    private var sequences: [String: [CurvePoint]] = [:]
    private var descriptionDepth = 0
    private var elementStack: [String] = []
    private var activeSimpleElements: [ActiveSimpleElement] = []
    private var activeSequence: String?
    private var activeTextElement: String?
    private var textBuffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let qualified = qName ?? elementName
        let parent = elementStack.last

        // A crs element that later proves to contain another XML element is a
        // resource/container, not an RDF literal. Keep nested candidates so a
        // leaf such as Look/Description/Name can still be reported separately.
        for index in activeSimpleElements.indices {
            activeSimpleElements[index].hasChildElement = true
        }

        if qualified == "rdf:Description" {
            descriptionDepth += 1
        }
        if qualified == "rdf:Description", descriptionDepth == 1 {
            for (key, value) in attributeDict where key.hasPrefix("crs:") {
                properties[String(key.dropFirst(4))] = value
            }
        } else if qualified == "rdf:Description", descriptionDepth > 1 {
            for (key, value) in attributeDict where key.hasPrefix("crs:") {
                nestedProperties[String(key.dropFirst(4))] = value
            }
        }

        elementStack.append(qualified)
        if parent == "rdf:Description", qualified.hasPrefix("crs:") {
            activeSimpleElements.append(
                ActiveSimpleElement(
                    qualifiedName: qualified,
                    property: String(qualified.dropFirst(4)),
                    depth: elementStack.count,
                    target: descriptionDepth == 1 ? .root : .nested
                )
            )
        }

        if Self.curveMap[qualified] != nil {
            activeSequence = qualified
            sequences[qualified] = []
        }
        if qualified == "rdf:li", activeSequence != nil {
            activeTextElement = qualified
            textBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in activeSimpleElements.indices
        where activeSimpleElements[index].depth == elementStack.count
            && !activeSimpleElements[index].hasChildElement
        {
            activeSimpleElements[index].text += string
        }
        guard activeTextElement != nil else { return }
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        self.parser(parser, foundCharacters: string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let qualified = qName ?? elementName
        if let index = activeSimpleElements.lastIndex(where: {
            $0.qualifiedName == qualified && $0.depth == elementStack.count
        }) {
            let element = activeSimpleElements.remove(at: index)
            let value = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !element.hasChildElement, !value.isEmpty {
                switch element.target {
                case .root:
                    properties[element.property] = value
                case .nested:
                    nestedProperties[element.property] = value
                }
            }
        }

        if qualified == "rdf:li", let activeSequence {
            let parts = textBuffer.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if parts.count == 2, parts.allSatisfy(\.isFinite) {
                sequences[activeSequence, default: []].append(
                    CurvePoint(
                        x: min(max(parts[0] / 255, 0), 1),
                        y: min(max(parts[1] / 255, 0), 1)
                    )
                )
            }
            activeTextElement = nil
            textBuffer = ""
        }
        if Self.curveMap[qualified] != nil { activeSequence = nil }
        if qualified == "rdf:Description" { descriptionDepth -= 1 }
        if elementStack.last == qualified {
            elementStack.removeLast()
        }
    }

    func makePreset(fallbackName: String) -> XMPPreset {
        var settings = EditSettings()
        settings.exposure = number("Exposure2012", range: -5...5)
        settings.contrast = number("Contrast2012", range: -100...100)
        settings.highlights = number("Highlights2012", range: -100...100)
        settings.shadows = number("Shadows2012", range: -100...100)
        settings.whites = number("Whites2012", range: -100...100)
        settings.blacks = number("Blacks2012", range: -100...100)
        settings.vibrance = number("Vibrance", range: -100...100)
        settings.saturation = number("Saturation", range: -100...100)
        settings.whiteBalance = WhiteBalanceSettings(
            mode: whiteBalanceMode(properties["WhiteBalance"]),
            temperature: optionalNumber("Temperature"),
            tint: optionalNumber("Tint"),
            incrementalTemperature: optionalNumber("IncrementalTemperature"),
            incrementalTint: optionalNumber("IncrementalTint")
        )
        settings.toneCurves = sequences.compactMap { key, points in
            guard let channel = Self.curveMap[key], points.count >= 2 else { return nil }
            return ToneCurve(channel: channel, points: points)
        }.sorted { $0.channel.rawValue < $1.channel.rawValue }

        for band in HSLBand.allCases {
            let suffix = band.rawValue.prefix(1).uppercased() + band.rawValue.dropFirst()
            let adjustment = HSLAdjustment(
                hue: number("HueAdjustment\(suffix)", range: -100...100),
                saturation: number("SaturationAdjustment\(suffix)", range: -100...100),
                luminance: number("LuminanceAdjustment\(suffix)", range: -100...100)
            )
            if adjustment != HSLAdjustment() { settings.hsl[band] = adjustment }
        }

        return XMPPreset(
            // Adobe XMP may contain nested profile/look names (for example
            // "Adobe Color"). They are not the user preset's name, so the
            // imported file name is the stable, unambiguous display name.
            name: fallbackName,
            processVersion: properties["ProcessVersion"],
            cameraRawVersion: properties["Version"],
            settings: settings,
            compatibility: compatibilityItems(),
            rawProperties: properties
        )
    }

    private func number(_ key: String, range: ClosedRange<Double>? = nil) -> Double {
        guard let value = Double(properties[key] ?? ""), value.isFinite else { return 0 }
        guard let range else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func optionalNumber(_ key: String) -> Double? {
        guard let rawValue = properties[key],
              let value = Double(rawValue),
              value.isFinite
        else { return nil }
        return value
    }

    private func whiteBalanceMode(_ value: String?) -> WhiteBalanceMode {
        guard let value else { return .asShot }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "as shot", "asshot":
            return .asShot
        case "custom":
            return .custom
        default:
            return .unknown
        }
    }

    private func compatibilityItems() -> [CompatibilityItem] {
        let approximate = Set([
            "Exposure2012", "Contrast2012", "Vibrance", "Saturation",
            "ToneCurveName2012",
            "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012"
        ])
        let unsupported = Set([
            "WhiteBalance", "Temperature", "Tint", "IncrementalTemperature", "IncrementalTint",
            "Texture", "Clarity2012", "Dehaze", "Sharpness", "SharpenRadius",
            "SharpenDetail", "SharpenEdgeMasking", "LuminanceSmoothing",
            "ColorNoiseReduction", "ColorNoiseReductionDetail", "ColorNoiseReductionSmoothness",
            "AutoLateralCA", "LensProfileEnable", "LensProfileSetup"
        ])

        var items: [CompatibilityItem] = []
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            let isHSL = key.hasPrefix("HueAdjustment") || key.hasPrefix("SaturationAdjustment") || key.hasPrefix("LuminanceAdjustment")
            let level: CompatibilityLevel
            let note: String
            if key == "ToneCurveName2012", sequences.isEmpty {
                level = .metadata
                note = "名称のみ保持（曲線点なし）"
            } else if approximate.contains(key) || isHSL {
                level = .approximate
                if isHSL {
                    note = "OKLCh 8色バンド・低彩度保護で近似（初期OFF）"
                } else if key == "Exposure2012" {
                    note = "EV値を近似適用（Adobe PV2012と同一式ではない）"
                } else if Self.toneKeys.contains(key) {
                    note = "単調性保証済み・2画像で暫定検証のトーン近似"
                } else {
                    note = "Photo Benchの処理へ近似変換"
                }
            } else if unsupported.contains(key) {
                level = .unsupported
                note = Self.whiteBalanceKeys.contains(key)
                    ? "値を保持（レンダー未実装）"
                    : "Phase 0では適用しない"
            } else if Self.metadataKeys.contains(key) {
                level = .metadata
                note = "値を保持"
            } else {
                level = .unsupported
                note = "未認識のCamera Raw画像処理設定。Phase 0では適用しない"
            }
            items.append(CompatibilityItem(property: key, value: value, level: level, note: note))
        }

        for (key, value) in nestedProperties.sorted(by: { $0.key < $1.key }) {
            items.append(CompatibilityItem(
                property: "Look.\(key)",
                value: value,
                level: .unsupported,
                note: "埋め込みAdobe Look。Phase 0では適用しない"
            ))
        }

        for (key, points) in sequences.sorted(by: { $0.key < $1.key }) {
            items.append(CompatibilityItem(
                property: key.replacingOccurrences(of: "crs:", with: ""),
                value: "\(points.count) points",
                level: .approximate,
                note: "encoded-sRGB 1D曲線・HDR端点外挿で近似（初期OFF）"
            ))
        }
        return items
    }

    private static let curveMap: [String: ToneCurveChannel] = [
        "crs:ToneCurvePV2012": .rgb,
        "crs:ToneCurvePV2012Red": .red,
        "crs:ToneCurvePV2012Green": .green,
        "crs:ToneCurvePV2012Blue": .blue
    ]

    private static let toneKeys: Set<String> = [
        "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012"
    ]

    private static let whiteBalanceKeys: Set<String> = [
        "WhiteBalance", "Temperature", "Tint", "IncrementalTemperature", "IncrementalTint"
    ]

    private static let metadataKeys: Set<String> = [
        "Version", "ProcessVersion", "UUID", "Name", "ShortName", "SortName",
        "PresetType", "CameraModelRestriction", "Copyright", "ContactInfo", "Description",
        "HasSettings", "Cluster", "Group", "Stubbed", "RequiresRGBTables",
        "SupportsAmount", "SupportsAmount2", "SupportsColor", "SupportsHighDynamicRange",
        "SupportsMonochrome", "SupportsNormalDynamicRange", "SupportsOutputReferred",
        "SupportsSceneReferred"
    ]
}

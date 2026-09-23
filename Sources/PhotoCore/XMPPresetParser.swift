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
        if hasFiniteNumber("ParametricShadows") { result.parametricShadows = settings.parametricShadows }
        if hasFiniteNumber("ParametricDarks") { result.parametricDarks = settings.parametricDarks }
        if hasFiniteNumber("ParametricLights") { result.parametricLights = settings.parametricLights }
        if hasFiniteNumber("ParametricHighlights") { result.parametricHighlights = settings.parametricHighlights }
        if hasFiniteNumber("ParametricShadowSplit") {
            result.parametricShadowSplit = settings.parametricShadowSplit
        }
        if hasFiniteNumber("ParametricMidtoneSplit") {
            result.parametricMidtoneSplit = settings.parametricMidtoneSplit
        }
        if hasFiniteNumber("ParametricHighlightSplit") {
            result.parametricHighlightSplit = settings.parametricHighlightSplit
        }
        if hasFiniteNumber("CurveRefineSaturation") {
            result.curveRefineSaturation = settings.curveRefineSaturation
        }
        if hasFiniteNumber("Texture") { result.texture = settings.texture }
        if hasFiniteNumber("Clarity2012") { result.clarity = settings.clarity }
        if hasFiniteNumber("Dehaze") { result.dehaze = settings.dehaze }

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

        if hasFiniteNumber("ShadowTint") { result.calibration.shadowTint = settings.calibration.shadowTint }
        if hasFiniteNumber("RedHue") { result.calibration.redHue = settings.calibration.redHue }
        if hasFiniteNumber("RedSaturation") { result.calibration.redSaturation = settings.calibration.redSaturation }
        if hasFiniteNumber("GreenHue") { result.calibration.greenHue = settings.calibration.greenHue }
        if hasFiniteNumber("GreenSaturation") {
            result.calibration.greenSaturation = settings.calibration.greenSaturation
        }
        if hasFiniteNumber("BlueHue") { result.calibration.blueHue = settings.calibration.blueHue }
        if hasFiniteNumber("BlueSaturation") { result.calibration.blueSaturation = settings.calibration.blueSaturation }

        if hasFiniteNumber("ColorGradeShadowHue") || hasFiniteNumber("SplitToningShadowHue") {
            result.colorGrading.shadow.hue = settings.colorGrading.shadow.hue
        }
        if hasFiniteNumber("ColorGradeShadowSat") || hasFiniteNumber("SplitToningShadowSaturation") {
            result.colorGrading.shadow.saturation = settings.colorGrading.shadow.saturation
        }
        if hasFiniteNumber("ColorGradeShadowLum") {
            result.colorGrading.shadow.luminance = settings.colorGrading.shadow.luminance
        }
        if hasFiniteNumber("ColorGradeMidtoneHue") {
            result.colorGrading.midtone.hue = settings.colorGrading.midtone.hue
        }
        if hasFiniteNumber("ColorGradeMidtoneSat") {
            result.colorGrading.midtone.saturation = settings.colorGrading.midtone.saturation
        }
        if hasFiniteNumber("ColorGradeMidtoneLum") {
            result.colorGrading.midtone.luminance = settings.colorGrading.midtone.luminance
        }
        if hasFiniteNumber("ColorGradeHighlightHue") || hasFiniteNumber("SplitToningHighlightHue") {
            result.colorGrading.highlight.hue = settings.colorGrading.highlight.hue
        }
        if hasFiniteNumber("ColorGradeHighlightSat") || hasFiniteNumber("SplitToningHighlightSaturation") {
            result.colorGrading.highlight.saturation = settings.colorGrading.highlight.saturation
        }
        if hasFiniteNumber("ColorGradeHighlightLum") {
            result.colorGrading.highlight.luminance = settings.colorGrading.highlight.luminance
        }
        if hasFiniteNumber("ColorGradeGlobalHue") { result.colorGrading.global.hue = settings.colorGrading.global.hue }
        if hasFiniteNumber("ColorGradeGlobalSat") {
            result.colorGrading.global.saturation = settings.colorGrading.global.saturation
        }
        if hasFiniteNumber("ColorGradeGlobalLum") {
            result.colorGrading.global.luminance = settings.colorGrading.global.luminance
        }
        if hasFiniteNumber("ColorGradeBlending") { result.colorGrading.blending = settings.colorGrading.blending }
        if hasFiniteNumber("SplitToningBalance") { result.colorGrading.balance = settings.colorGrading.balance }

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

        // Only the photo's own (root) curves. A nested `crs:Look` carries its
        // profile's own parameters -- Adobe Color's look point curve among them
        // -- which the base rendering already applies; reading that nested
        // `ToneCurvePV2012` here used to overwrite the root "Linear" curve and
        // apply Adobe Color's curve a second time (-0.07 to -0.11 EV).
        if Self.curveMap[qualified] != nil, descriptionDepth == 1 {
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
        settings.parametricShadows = number("ParametricShadows", range: -100...100)
        settings.parametricDarks = number("ParametricDarks", range: -100...100)
        settings.parametricLights = number("ParametricLights", range: -100...100)
        settings.parametricHighlights = number("ParametricHighlights", range: -100...100)
        settings.parametricShadowSplit = number("ParametricShadowSplit", default: 25, range: 0...100)
        settings.parametricMidtoneSplit = number("ParametricMidtoneSplit", default: 50, range: 0...100)
        settings.parametricHighlightSplit = number("ParametricHighlightSplit", default: 75, range: 0...100)
        settings.curveRefineSaturation = number("CurveRefineSaturation", default: 100, range: 0...100)
        settings.texture = number("Texture", range: -100...100)
        settings.clarity = number("Clarity2012", range: -100...100)
        settings.dehaze = number("Dehaze", range: -100...100)
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

        settings.calibration = CalibrationSettings(
            shadowTint: number("ShadowTint", range: -100...100),
            redHue: number("RedHue", range: -100...100),
            redSaturation: number("RedSaturation", range: -100...100),
            greenHue: number("GreenHue", range: -100...100),
            greenSaturation: number("GreenSaturation", range: -100...100),
            blueHue: number("BlueHue", range: -100...100),
            blueSaturation: number("BlueSaturation", range: -100...100)
        )
        // `ColorGrade{Shadow,Highlight}{Hue,Sat}` are the modern Color Grading
        // names; `SplitToning{Shadow,Highlight}{Hue,Saturation}` are the same
        // sliders under their pre-Color-Grading XMP names (`docs/
        // PHASE2_C2_C3.md`'s C2 item 1). Midtone/Global have no legacy name.
        settings.colorGrading = ColorGradingSettings(
            shadow: ColorGradeBand(
                hue: numberPreferring(["ColorGradeShadowHue", "SplitToningShadowHue"], range: 0...359),
                saturation: numberPreferring(
                    ["ColorGradeShadowSat", "SplitToningShadowSaturation"], range: 0...100
                ),
                luminance: number("ColorGradeShadowLum", range: -100...100)
            ),
            midtone: ColorGradeBand(
                hue: number("ColorGradeMidtoneHue", range: 0...359),
                saturation: number("ColorGradeMidtoneSat", range: 0...100),
                luminance: number("ColorGradeMidtoneLum", range: -100...100)
            ),
            highlight: ColorGradeBand(
                hue: numberPreferring(["ColorGradeHighlightHue", "SplitToningHighlightHue"], range: 0...359),
                saturation: numberPreferring(
                    ["ColorGradeHighlightSat", "SplitToningHighlightSaturation"], range: 0...100
                ),
                luminance: number("ColorGradeHighlightLum", range: -100...100)
            ),
            global: ColorGradeBand(
                hue: number("ColorGradeGlobalHue", range: 0...359),
                saturation: number("ColorGradeGlobalSat", range: 0...100),
                luminance: number("ColorGradeGlobalLum", range: -100...100)
            ),
            blending: number("ColorGradeBlending", default: 100, range: 0...100),
            balance: number("SplitToningBalance", range: -100...100)
        )

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
        number(key, default: 0, range: range)
    }

    /// Like `number(_:range:)`, but for XMP properties whose Adobe default is
    /// not 0 (the parametric split points, `CurveRefineSaturation`) -- an
    /// absent tag means "Adobe's own default", not "zero".
    private func number(_ key: String, default defaultValue: Double, range: ClosedRange<Double>? = nil) -> Double {
        guard let value = Double(properties[key] ?? ""), value.isFinite else { return defaultValue }
        guard let range else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Like `number(_:default:range:)`, but tries several XMP property names
    /// in order and returns the first one present -- for a slider that Adobe
    /// has written under more than one name across versions (`docs/
    /// PHASE2_C2_C3.md`'s C2 item 1: Color Grading's Shadow/Highlight
    /// Hue/Saturation are the same values as the pre-Color-Grading Split
    /// Toning tags).
    private func numberPreferring(
        _ keys: [String], default defaultValue: Double = 0, range: ClosedRange<Double>? = nil
    ) -> Double {
        for key in keys {
            guard let value = Double(properties[key] ?? ""), value.isFinite else { continue }
            guard let range else { return value }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        return defaultValue
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

    /// `docs/PHASE2_DEVELOP_PIPELINE.md`'s "対応状況の表示" table.
    private func compatibilityItems() -> [CompatibilityItem] {
        // Phase2 C1: real, measured models (`ToneOps`) -- promoted out of
        // "approximate" now that they are no longer clean-room guesses.
        let supportedScalars = Set([
            "Exposure2012", "Contrast2012", "Whites2012", "Blacks2012",
            "ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights",
            "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit"
        ])
        // Phase2 C2: real, measured models (`ColorOps`, linear ProPhoto) --
        // promoted out of "approximate" (Vibrance/Saturation) or out of the
        // OKLCh clean-room guess (HSL, handled via `isHSL` below).
        // `ShadowTint` and `ColorGrade{Midtone,Global}Lum` are handled by
        // their own branches below, not this set.
        let supportedColorScalars = Set([
            "Vibrance", "Saturation",
            "RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation",
            "ColorGradeShadowHue", "ColorGradeShadowSat", "ColorGradeShadowLum",
            "ColorGradeMidtoneHue", "ColorGradeMidtoneSat",
            "ColorGradeHighlightHue", "ColorGradeHighlightSat", "ColorGradeHighlightLum",
            "ColorGradeGlobalHue", "ColorGradeGlobalSat",
            "ColorGradeBlending",
            "SplitToningShadowHue", "SplitToningShadowSaturation",
            "SplitToningHighlightHue", "SplitToningHighlightSaturation",
            "SplitToningBalance"
        ])
        // Phase2 C3 promoted Highlights2012/Shadows2012 out of this set (see
        // the dedicated branch above) -- only the tone-curve preset name
        // itself (never a rendering input) remains a "近似" placeholder.
        let approximate = Set([
            "ToneCurveName2012"
        ])
        // Retained (parsed, kept on `EditSettings`) but never applied to rendering.
        let unsupported = Set([
            "IncrementalTemperature", "IncrementalTint",
            "Sharpness", "SharpenRadius",
            "SharpenDetail", "SharpenEdgeMasking", "LuminanceSmoothing",
            "ColorNoiseReduction", "ColorNoiseReductionDetail", "ColorNoiseReductionSmoothness",
            "AutoLateralCA", "LensProfileEnable", "LensProfileSetup"
        ])
        let absoluteWhiteBalanceKeys = Set(["WhiteBalance", "Temperature", "Tint"])

        var items: [CompatibilityItem] = []
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            let isHSL = key.hasPrefix("HueAdjustment") || key.hasPrefix("SaturationAdjustment") || key.hasPrefix("LuminanceAdjustment")
            let level: CompatibilityLevel
            let note: String
            if key == "ToneCurveName2012", sequences.isEmpty {
                level = .metadata
                note = "名称のみ保持（曲線点なし）"
            } else if key == "CameraProfile" {
                if value == "Adobe Standard" || value == "Adobe Color" {
                    level = .supported
                    note = "Adobe DCP + Adobe Colorのベースレンダリングに対応"
                } else {
                    level = .unsupported
                    note = "Adobe Standard/Adobe Color以外のカメラプロファイルは未対応"
                }
            } else if key == "CurveRefineSaturation" {
                if let parsed = Double(value), abs(parsed - 100) <= 1e-9 {
                    level = .supported
                    note = "既定値100に対応（DNGスプライン点カーブ＋RGBTone色相保持）"
                } else {
                    level = .unsupported
                    note = "100以外は式が未同定のため値を保持するのみ（100として描画）"
                }
            } else if absoluteWhiteBalanceKeys.contains(key) {
                level = .supported
                note = "RAWの絶対ホワイトバランスとして適用（非RAWは値の保持のみ）"
            } else if key == "ShadowTint" {
                level = .supported
                note = "実測で効果ゼロと確認済み（何もしない演算として対応）"
            } else if key == "ColorGradeMidtoneLum" || key == "ColorGradeGlobalLum" {
                level = .unsupported
                note = "参照実装に測定式が無いため値を保持するのみ（Photo Bench未実装）"
            } else if key == "Highlights2012" || key == "Shadows2012" {
                // Phase2 C3: real, measured local-Laplacian model
                // (`SpatialToneOps`/`SpatialToneProcessor`) -- promoted out
                // of "approximate" now that it is a fitted model (with a
                // reported residual) rather than a clean-room guess.
                level = .supported
                note = "実測局所ラプラシアンフィルタ（リニアProPhoto空間、cube外の空間処理）で対応"
            } else if key == "Texture" || key == "Clarity2012" {
                // Phase2 C4: real, measured per-level multiscale gain model
                // (`.photobench/phase2/detail/model.md`'s "Model L") --
                // promoted out of "unsupported". Same Ln chain/cube-外 as
                // Highlights/Shadows, just a linear per-band gain instead of
                // a remap.
                level = .supported
                note = "実測段別ゲインフィルタ（リニアProPhoto空間、cube外の空間処理）で対応"
            } else if key == "Dehaze" {
                // Phase2 C4: real, measured global log2輝度カーブ＋彩度倍率
                // (空間成分は実測で確認できず不採用、model.md §3) -- pointwise
                // なのでcube P/P1に焼く(`ToneOps.dehaze`)。
                level = .supported
                note = "実測トーンカーブ＋彩度倍率（cube Pに焼き込み）で対応"
            } else if supportedScalars.contains(key) {
                level = .supported
                note = key.hasPrefix("Parametric")
                    ? "実測フィットの窓関数（sRGB符号化空間）で対応"
                    : "実測フィット式（sRGB符号化空間、Exposureのみリニア）で対応"
            } else if supportedColorScalars.contains(key) {
                level = .supported
                note = "実測フィット式（リニアProPhoto空間、cube Q）で対応"
            } else if isHSL {
                level = .supported
                note = "実測8帯モデル（cos²クロスフェード、リニアProPhoto、cube Q）で対応"
            } else if approximate.contains(key) {
                level = .approximate
                note = "Photo Benchの処理へ近似変換"
            } else if unsupported.contains(key) {
                level = .unsupported
                note = "値を保持するのみ（Photo Bench未実装）"
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
                level: .supported,
                note: "DNGスプライン＋RGBTone色相保持（sRGB符号化空間）で対応"
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

    private static let metadataKeys: Set<String> = [
        "Version", "ProcessVersion", "UUID", "Name", "ShortName", "SortName",
        "PresetType", "CameraModelRestriction", "Copyright", "ContactInfo", "Description",
        "HasSettings", "Cluster", "Group", "Stubbed", "RequiresRGBTables",
        "SupportsAmount", "SupportsAmount2", "SupportsColor", "SupportsHighDynamicRange",
        "SupportsMonochrome", "SupportsNormalDynamicRange", "SupportsOutputReferred",
        "SupportsSceneReferred"
    ]
}

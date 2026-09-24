import Foundation
import PhotoCore

/// A NIHO preset compiled into the engine. The XMP text is generated from
/// the repository's root preset files by `scripts/generate-builtin-presets.py`
/// into `BuiltinPresetData.swift`; nothing is read from disk at run time.
struct BuiltinPreset: Equatable, Sendable {
    let id: String
    let name: String
    /// The repository-root XMP file the text was generated from.
    let sourceFileName: String
    let xmp: String
}

enum BuiltinPresets {
    static var result: BuiltinPresetsResult {
        BuiltinPresetsResult(presets: all.map { .init(id: $0.id, name: $0.name, xmp: $0.xmp) })
    }
}

/// `presetSettings`: `XMPPresetParser` plus `XMPPreset.applying(to:)`, the
/// Photo Bench app's own preset path (a Lightroom-style patch: only the
/// controls the XMP carries replace `base`'s).
enum PresetSettingsService {
    static func apply(_ params: PresetSettingsParams) throws -> PresetSettingsResult {
        let data = Data(params.xmp.utf8)
        let preset: XMPPreset
        do {
            preset = try XMPPresetParser.parse(data: data, fallbackName: XMPPresetNameReader.name(in: data) ?? "")
        } catch {
            throw EngineError(.presetInvalid, "XMP を読めません: \(describe(error))")
        }
        guard !preset.rawProperties.isEmpty || !preset.settings.toneCurves.isEmpty else {
            throw EngineError(.presetInvalid, "XMP に Camera Raw の設定がありません")
        }
        let name = preset.rawProperties["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? preset.name
        // The same "未対応" items the app counts when a preset is applied.
        let unsupported = preset.compatibility.filter { $0.level == .unsupported }.map(\.property)
        return PresetSettingsResult(
            name: name,
            settings: preset.applying(to: params.base ?? .neutral),
            unsupported: unsupported
        )
    }
}

/// The preset's own name, `crs:Name` of the top-level description
/// (Lightroom writes it as an `rdf:Alt` whose `x-default` item is the name;
/// a nested `crs:Look` has a name of its own). `XMPPresetParser` keeps only
/// simple properties, so this reads the language alternative itself.
final class XMPPresetNameReader: NSObject, XMLParserDelegate {
    private var nameDepth: Int?
    private var depth = 0
    private var descriptionDepth = 0
    private var itemLanguage: String?
    private var itemText: String?
    private var names: [(language: String?, text: String)] = []

    static func name(in data: Data) -> String? {
        let reader = XMPPresetNameReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let chosen = reader.names.first { $0.language == "x-default" } ?? reader.names.first
        return chosen.map(\.text)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        let qualified = qName ?? elementName
        if qualified == "rdf:Description" {
            descriptionDepth += 1
        }
        if nameDepth == nil, qualified == "crs:Name", descriptionDepth == 1 {
            nameDepth = depth
        } else if nameDepth != nil, qualified == "rdf:li" {
            itemLanguage = attributeDict["xml:lang"]
            itemText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if itemText != nil { itemText? += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let qualified = qName ?? elementName
        if qualified == "rdf:li", let text = itemText {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names.append((itemLanguage, trimmed)) }
            itemText = nil
            itemLanguage = nil
        }
        if depth == nameDepth { nameDepth = nil }
        if qualified == "rdf:Description" { descriptionDepth -= 1 }
        depth -= 1
    }
}

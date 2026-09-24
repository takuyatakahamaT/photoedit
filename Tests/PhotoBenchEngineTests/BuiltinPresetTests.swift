import Foundation
import PhotoCore
import Testing
@testable import PhotoBenchEngine

/// The presets compiled into the engine are exactly the repository's XMP
/// files (regenerate with `scripts/generate-builtin-presets.py`), and
/// `presetSettings` gives what the app's own preset path gives.
struct BuiltinPresetTests {
    @Test func embeddedTextMatchesTheRepositoryFiles() throws {
        #expect(BuiltinPresets.all.map(\.sourceFileName) == [
            "niho-preset bluesky2.xmp", "niho-priset_colorful.xmp", "niho-preset night.xmp", "niho-preset pastel.xmp"
        ])
        for preset in BuiltinPresets.all {
            let file = try Data(contentsOf: projectRoot.appendingPathComponent(preset.sourceFileName))
            #expect(
                Data(preset.xmp.utf8) == file,
                "\(preset.sourceFileName) changed; run scripts/generate-builtin-presets.py"
            )
        }
    }

    @Test func presetSettingsMatchesTheAppsPresetPath() throws {
        var base = EditSettings.neutral
        base.exposure = -0.3
        base.texture = 5
        for preset in BuiltinPresets.all {
            let result = try PresetSettingsService.apply(PresetSettingsParams(xmp: preset.xmp, base: base))
            let parsed = try XMPPresetParser.parse(url: projectRoot.appendingPathComponent(preset.sourceFileName))
            #expect(result.settings == parsed.applying(to: base), "\(preset.id)")
            #expect(result.unsupported == parsed.compatibility.filter { $0.level == .unsupported }.map(\.property))
            #expect(result.name == preset.sourceFileName.replacingOccurrences(of: ".xmp", with: ""))
        }
        let colorful = try PresetSettingsService.apply(PresetSettingsParams(xmp: BuiltinPresets.all[1].xmp, base: nil))
        #expect(colorful.unsupported.contains("LensProfileEnable"))
        #expect(colorful.settings.contrast == -37)
    }
}

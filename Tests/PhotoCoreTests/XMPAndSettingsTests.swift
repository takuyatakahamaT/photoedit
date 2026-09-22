import Foundation
import Testing
@testable import PhotoCore

struct XMPAndSettingsTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func parsesColorfulToneAndAsShotWhiteBalance() throws {
        let preset = try parse("niho-priset_colorful.xmp")

        #expect(preset.settings.highlights == -88)
        #expect(preset.settings.shadows == 37)
        #expect(preset.settings.whites == -53)
        #expect(preset.settings.blacks == 95)
        #expect(preset.settings.whiteBalance.mode == .asShot)
        #expect(preset.settings.whiteBalance.temperature == nil)
        #expect(preset.settings.whiteBalance.tint == nil)
        #expect(preset.compatibility.contains {
            // Phase2 C3: Highlights2012/Shadows2012 moved from clean-room
            // approximation to `SpatialToneOps`'s measured local-Laplacian
            // model -- see `docs/PHASE2_C2_C3.md`'s C3 section.
            $0.property == "Highlights2012"
                && $0.level == .supported
                && $0.note.contains("局所ラプラシアン")
        })
        #expect(preset.compatibility.contains {
            // Phase2 C1: Exposure2012 moved from clean-room approximation to
            // `ToneOps`'s measured model -- see `docs/PHASE2_DEVELOP_PIPELINE.md`.
            $0.property == "Exposure2012"
                && $0.level == .supported
        })
        #expect(preset.compatibility.contains {
            // Phase2 C1: absolute white balance (RAW) is now implemented, so
            // the "WhiteBalance" mode key itself is reported supported
            // regardless of whether this particular preset is As Shot or
            // Custom (`XMPPresetParser.compatibilityItems`).
            $0.property == "WhiteBalance" && $0.level == .supported
        })
    }

    @Test func parsesNightAbsoluteCustomWhiteBalance() throws {
        let preset = try parse("niho-preset night.xmp")

        #expect(preset.settings.highlights == -87)
        #expect(preset.settings.shadows == 44)
        #expect(preset.settings.whites == -83)
        #expect(preset.settings.blacks == 89)
        #expect(preset.settings.whiteBalance.mode == .custom)
        #expect(preset.settings.whiteBalance.temperature == 6_214)
        #expect(preset.settings.whiteBalance.tint == 13)
        #expect(preset.settings.whiteBalance.incrementalTemperature == nil)
        #expect(preset.settings.whiteBalance.incrementalTint == nil)
        #expect(preset.compatibility.contains {
            // Phase2 C2: Split Toning (folded into Color Grading) moved from
            // unimplemented to `ColorOps`'s measured model.
            $0.property == "SplitToningShadowSaturation"
                && $0.value == "13"
                && $0.level == .supported
        })
        #expect(preset.compatibility.contains {
            // Phase2 C2: Camera Calibration moved from unimplemented to
            // `ColorOps.calibrationMatrix`'s measured 3x3 matrix.
            $0.property == "GreenHue" && $0.value == "+19" && $0.level == .supported
        })
    }

    @Test func parsesPastelAsShotWhiteBalance() throws {
        let preset = try parse("niho-preset pastel.xmp")

        #expect(preset.settings.highlights == -44)
        #expect(preset.settings.shadows == 41)
        #expect(preset.settings.whites == -30)
        #expect(preset.settings.blacks == 53)
        #expect(preset.settings.whiteBalance == .asShot)
        #expect(preset.compatibility.contains {
            // Phase2 C1: ParametricShadows/Darks/Lights/Highlights moved to
            // `ToneOps.parametric`, a measured model, so this is now supported.
            $0.property == "ParametricShadows"
                && $0.value == "-43"
                && $0.level == .supported
        })
    }

    @Test func preservesExplicitZeroIncrementalCustomWhiteBalance() throws {
        let preset = try parse("niho-preset bluesky2.xmp")

        #expect(preset.settings.highlights == -59)
        #expect(preset.settings.shadows == 20)
        #expect(preset.settings.whites == 6)
        #expect(preset.settings.blacks == 90)
        #expect(preset.settings.whiteBalance.mode == .custom)
        #expect(preset.settings.whiteBalance.temperature == nil)
        #expect(preset.settings.whiteBalance.tint == nil)
        #expect(preset.settings.whiteBalance.incrementalTemperature == 0)
        #expect(preset.settings.whiteBalance.incrementalTint == 0)
    }

    @Test func decodesLegacyEditSettingsJSONWithNewDefaults() throws {
        let legacyJSON = Data(
            #"{"exposure":0.25,"contrast":-12,"vibrance":9,"saturation":3,"toneCurves":[],"hsl":[]}"#.utf8
        )

        let settings = try JSONDecoder().decode(EditSettings.self, from: legacyJSON)

        #expect(settings.exposure == 0.25)
        #expect(settings.contrast == -12)
        #expect(settings.highlights == 0)
        #expect(settings.shadows == 0)
        #expect(settings.whites == 0)
        #expect(settings.blacks == 0)
        #expect(settings.whiteBalance == .asShot)
    }

    @Test func decodesLegacyEditSettingsJSONWithUnknownReferenceLookKey() throws {
        let legacyJSON = Data(
            #"""
            {"exposure":0.4,"contrast":-8,"saturation":5,"relativeTemperature":12,"referenceLook":"niho-bluesky2-reference-20260922-v3"}
            """#.utf8
        )

        let settings = try JSONDecoder().decode(EditSettings.self, from: legacyJSON)

        #expect(settings.exposure == 0.4)
        #expect(settings.contrast == -8)
        #expect(settings.saturation == 5)
        #expect(settings.relativeTemperature == 12)
        #expect(settings.whiteBalance == .asShot)
    }

    @Test func rejectsNonFiniteXMPNumbersAndClampsOutOfRangeControls() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchXMPTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("hostile.xmp")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description
              xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
              crs:Exposure2012="99"
              crs:Contrast2012="-999"
              crs:Highlights2012="NaN"
              crs:Shadows2012="Infinity"
              crs:Whites2012="101"
              crs:Blacks2012="-101"
              crs:WhiteBalance="Custom"
              crs:Temperature="NaN"
              crs:Tint="13" />
          </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(xml.utf8).write(to: url, options: .atomic)

        let preset = try XMPPresetParser.parse(url: url)

        #expect(preset.settings.exposure == 5)
        #expect(preset.settings.contrast == -100)
        #expect(preset.settings.highlights == 0)
        #expect(preset.settings.shadows == 0)
        #expect(preset.settings.whites == 100)
        #expect(preset.settings.blacks == -100)
        #expect(preset.settings.whiteBalance.temperature == nil)
        #expect(preset.settings.whiteBalance.tint == 13)
    }

    @Test func appliesPartialPresetWithoutResettingUnspecifiedEdits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchPartialXMPTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("partial.xmp")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description
              xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
              crs:Exposure2012="0.75"
              crs:SaturationAdjustmentBlue="0" />
          </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(xml.utf8).write(to: url, options: .atomic)

        let preset = try XMPPresetParser.parse(url: url)
        var base = EditSettings(
            exposure: -0.5,
            contrast: 42,
            highlights: -30,
            saturation: 18,
            whiteBalance: WhiteBalanceSettings(mode: .custom, temperature: 5_500, tint: 7),
            hsl: [.blue: HSLAdjustment(hue: 12, saturation: 45, luminance: -8)]
        )
        base = preset.applying(to: base)

        #expect(base.exposure == 0.75)
        #expect(base.contrast == 42)
        #expect(base.highlights == -30)
        #expect(base.saturation == 18)
        #expect(base.whiteBalance.temperature == 5_500)
        #expect(base.hsl[.blue]?.hue == 12)
        #expect(base.hsl[.blue]?.saturation == 0)
        #expect(base.hsl[.blue]?.luminance == -8)
    }

    @Test func parsesSimpleElementPropertiesAsATruthfulPartialPreset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchElementXMPTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("element-form.xmp")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
              <crs:Exposure2012> 0.56 </crs:Exposure2012>
              <crs:Saturation>0</crs:Saturation>
              <crs:SaturationAdjustmentBlue>0</crs:SaturationAdjustmentBlue>
              <crs:FutureRenderingControl>17</crs:FutureRenderingControl>
              <crs:ToneCurvePV2012>
                <rdf:Seq>
                  <rdf:li>0, 0</rdf:li>
                  <rdf:li>255, 255</rdf:li>
                </rdf:Seq>
              </crs:ToneCurvePV2012>
              <crs:Look>
                <rdf:Description>
                  <crs:Name>Adobe Color</crs:Name>
                  <crs:Amount>1</crs:Amount>
                </rdf:Description>
              </crs:Look>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(xml.utf8).write(to: url, options: .atomic)

        let preset = try XMPPresetParser.parse(url: url)
        let base = EditSettings(
            exposure: -0.25,
            contrast: 42,
            highlights: -30,
            saturation: 18,
            whiteBalance: WhiteBalanceSettings(mode: .custom, temperature: 5_500, tint: 7),
            hsl: [.blue: HSLAdjustment(hue: 12, saturation: 45, luminance: -8)]
        )
        let applied = preset.applying(to: base)

        #expect(preset.rawProperties["Exposure2012"] == "0.56")
        #expect(preset.rawProperties["Saturation"] == "0")
        #expect(preset.rawProperties["SaturationAdjustmentBlue"] == "0")
        #expect(preset.rawProperties["FutureRenderingControl"] == "17")
        #expect(preset.rawProperties["Look"] == nil)
        #expect(preset.rawProperties["ToneCurvePV2012"] == nil)
        #expect(applied.exposure == 0.56)
        #expect(applied.saturation == 0)
        #expect(applied.contrast == 42)
        #expect(applied.highlights == -30)
        #expect(applied.whiteBalance.temperature == 5_500)
        #expect(applied.hsl[.blue]?.hue == 12)
        #expect(applied.hsl[.blue]?.saturation == 0)
        #expect(applied.hsl[.blue]?.luminance == -8)
        #expect(preset.settings.toneCurves.first?.points.count == 2)
        #expect(preset.compatibility.contains {
            $0.property == "FutureRenderingControl"
                && $0.value == "17"
                && $0.level == .unsupported
                && $0.note.contains("未認識")
        })
        #expect(preset.compatibility.contains {
            $0.property == "Look.Name"
                && $0.value == "Adobe Color"
                && $0.level == .unsupported
        })
        #expect(preset.compatibility.contains {
            $0.property == "Look.Amount"
                && $0.value == "1"
                && $0.level == .unsupported
        })
    }

    private func parse(_ filename: String) throws -> XMPPreset {
        try XMPPresetParser.parse(url: projectRoot.appendingPathComponent(filename))
    }
}

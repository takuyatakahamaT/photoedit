import Foundation
import PhotoBenchAppSupport
import PhotoCore
import Testing

struct XMPPresetApplicationTests {
    @Test func metadataOnlyXMPChangesKeepRenderSettingsAndExposureChangesAreApplied() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoBenchStore(rootDirectory: root)
        let source = try updatedPresetData()
        let sourceText = try #require(String(data: source, encoding: .utf8))
        let metadataText = sourceText
            .replacingOccurrences(
                of: "51F3D9E42A5743BDB7E0E322AE97EBA0",
                with: "7E98F4F638E24631A39419AFFC204BE1"
            )
            .replacingOccurrences(
                of: "niho-preset bluesky2",
                with: "bluesky2 alternate"
            )
        let exposureText = sourceText.replacingOccurrences(
            of: "crs:Exposure2012=\"+0.79\"",
            with: "crs:Exposure2012=\"+1.79\""
        )
        #expect(metadataText != sourceText)
        #expect(exposureText != sourceText)

        let original = try store.registerPreset(data: source, name: "bluesky2 original")
        let metadataVariant = try store.registerPreset(
            data: Data(metadataText.utf8),
            name: "a different preset name"
        )
        let exposureVariant = try store.registerPreset(
            data: Data(exposureText.utf8),
            name: "same settings except exposure"
        )
        #expect(original.id != metadataVariant.id)
        #expect(original.id != exposureVariant.id)
        #expect(original.preset.name != metadataVariant.preset.name)
        #expect(original.preset.settings == metadataVariant.preset.settings)

        let base = PhotoEditSnapshot(settings: EditSettings(exposure: -0.4, saturation: 12))
        let originalApplication = base.applying(preset: original)
        let metadataApplication = base.applying(preset: metadataVariant)
        let exposureApplication = base.applying(preset: exposureVariant)

        #expect(originalApplication.settings == metadataApplication.settings)
        #expect(originalApplication.settings.exposure == original.preset.settings.exposure)
        #expect(exposureApplication.settings.exposure == exposureVariant.preset.settings.exposure)
        #expect(exposureApplication.settings.exposure != originalApplication.settings.exposure)
        #expect(exposureApplication.settings != originalApplication.settings)
        #expect(!originalApplication.applyApproximateXMPColor)
    }

    @Test func oldAndModifiedDigestsUseTheOrdinaryXMPPatch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoBenchStore(rootDirectory: root)
        let updatedData = try updatedPresetData()
        let oldData = try xmpData("niho-preset bluesky2.xmp")

        var changedData = updatedData
        changedData.append(Data("\n".utf8))
        let cases = [
            try store.registerPreset(data: oldData, name: "bluesky2（更新XMP）"),
            try store.registerPreset(data: changedData, name: "bluesky2（更新XMP）"),
            try updatedPreset(in: store)
        ]
        #expect(cases[0].id != PhotoEditSnapshot.bluesky2ReferencePresetID)
        #expect(cases[1].id != PhotoEditSnapshot.bluesky2ReferencePresetID)

        let settings = EditSettings(exposure: 0.4, saturation: 8)
        let base = PhotoEditSnapshot(settings: settings)
        for stored in cases {
            let applied = base.applying(preset: stored)
            #expect(applied.settings == stored.preset.applying(to: settings))
            #expect(applied.appliedPresetID == stored.id)
            #expect(!applied.applyApproximateXMPColor)
        }
    }

    @Test func seedVersionTwoAddsUpdatedPresetWithoutRemovingTheExistingFourOrEdits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoBenchStore(rootDirectory: root)
        let existingNames = [
            "niho-priset_colorful.xmp",
            "niho-preset bluesky2.xmp",
            "niho-preset night.xmp",
            "niho-preset pastel.xmp"
        ]
        let oldSeeds = try existingNames.map { name in
            BuiltInPresetSeed(name: name, data: try xmpData(name))
        }
        try store.seedBuiltInPresets(oldSeeds, version: 1)
        let beforeUpgrade = try store.listPresets()
        #expect(beforeUpgrade.count == 4)
        let oldIDs = Set(beforeUpgrade.map(\.id))
        let saved = try #require(beforeUpgrade.first)
        let photo = URL(fileURLWithPath: "/private/photos/preexisting-edit.jpg")
        let oldSnapshot = PhotoEditSnapshot(
            settings: saved.preset.applying(to: .neutral),
            appliedPresetID: saved.id,
            appliedPreset: saved.preset
        )
        try store.saveEdit(oldSnapshot, for: photo)

        var newSeeds = oldSeeds
        newSeeds.append(BuiltInPresetSeed(
            name: "bluesky2-updated.xmp",
            data: try updatedPresetData()
        ))
        try store.seedBuiltInPresets(newSeeds, version: 2)

        let afterUpgrade = try store.listPresets()
        #expect(afterUpgrade.count == 5)
        #expect(oldIDs.isSubset(of: Set(afterUpgrade.map(\.id))))
        #expect(afterUpgrade.contains { $0.id == PhotoEditSnapshot.bluesky2ReferencePresetID })
        #expect(try store.loadEdit(for: photo)?.snapshot == oldSnapshot)
    }

    private func updatedPreset(in store: PhotoBenchStore) throws -> StoredXMPPreset {
        try store.registerPreset(data: updatedPresetData(), name: "arbitrary-registration-name")
    }

    private func updatedPresetData() throws -> Data {
        let data = try xmpData("bluesky2-updated.xmp")
        #expect(PhotoBenchStore.sha256Hex(data) == PhotoEditSnapshot.bluesky2ReferencePresetID)
        return data
    }

    private func xmpData(_ name: String) throws -> Data {
        try Data(contentsOf: projectRoot().appendingPathComponent(name))
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchXMPPresetApplicationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

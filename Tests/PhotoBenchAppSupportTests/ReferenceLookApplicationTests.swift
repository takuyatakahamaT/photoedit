import Foundation
import PhotoBenchAppSupport
import PhotoCore
import Testing

struct ReferenceLookApplicationTests {
    @Test func updatedPresetDigestUsesItsXMPPatchAndDoesNotSelectAReferenceLook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoBenchStore(rootDirectory: root)
        let stored = try updatedPreset(in: store)
        #expect(stored.id == PhotoEditSnapshot.bluesky2ReferencePresetID)

        let base = PhotoEditSnapshot(settings: EditSettings(
            exposure: 1.2,
            saturation: -18,
            relativeTemperature: 24,
            relativeTint: -11,
            referenceLook: .bluesky2September2026
        ))
        var expectedBase = base.settings
        expectedBase.referenceLook = nil

        let applied = base.applying(preset: stored)
        #expect(applied.settings == stored.preset.applying(to: expectedBase))
        #expect(applied.settings.referenceLook == nil)
        #expect(applied.appliedPresetID == stored.id)
        #expect(applied.appliedPreset == stored.preset)
        #expect(!applied.applyApproximateXMPColor)
    }

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

        let base = PhotoEditSnapshot(settings: EditSettings(
            exposure: -0.4,
            saturation: 12,
            referenceLook: .bluesky2September2026V3
        ))
        let originalApplication = base.applying(preset: original)
        let metadataApplication = base.applying(preset: metadataVariant)
        let exposureApplication = base.applying(preset: exposureVariant)

        #expect(originalApplication.settings == metadataApplication.settings)
        #expect(originalApplication.settings.referenceLook == nil)
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

        var settings = EditSettings(exposure: 0.4, saturation: 8)
        settings.referenceLook = .bluesky2September2026
        let base = PhotoEditSnapshot(settings: settings)
        for stored in cases {
            let applied = base.applying(preset: stored)
            var expectedBase = settings
            expectedBase.referenceLook = nil
            #expect(applied.settings == stored.preset.applying(to: expectedBase))
            #expect(applied.settings.referenceLook == nil)
            #expect(applied.appliedPresetID == stored.id)
            #expect(!applied.applyApproximateXMPColor)
        }
    }

    @Test func xmpPresetApplicationClearsSavedReferenceLook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoBenchStore(rootDirectory: root)
        let updated = try updatedPreset(in: store)
        let colorful = try store.registerPreset(
            data: xmpData("niho-priset_colorful.xmp"),
            name: "colorful"
        )
        let referenceBase = PhotoEditSnapshot(
            settings: EditSettings(referenceLook: .bluesky2September2026)
        )

        let updatedXMPApplication = referenceBase.applying(preset: updated)
        var fallbackBase = referenceBase.settings
        fallbackBase.referenceLook = nil
        #expect(updatedXMPApplication.settings == updated.preset.applying(to: fallbackBase))
        #expect(updatedXMPApplication.settings.referenceLook == nil)
        #expect(!updatedXMPApplication.applyApproximateXMPColor)

        let otherPreset = referenceBase.applying(preset: colorful)
        #expect(otherPreset.settings.referenceLook == nil)
        #expect(otherPreset.appliedPresetID == colorful.id)
        #expect(!otherPreset.applyApproximateXMPColor)
    }

    @Test func xmpApplicationAndSavedReferenceLooksPersistAndHistoryUndoRedoRestoreThem() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoBenchStore(rootDirectory: root)
        let stored = try updatedPreset(in: store)
        let snapshot = PhotoEditSnapshot.neutral.applying(preset: stored)
        let photo = URL(fileURLWithPath: "/private/photos/reference-look.jpg")
        try store.saveEdit(snapshot, for: photo)
        let restored = try PhotoBenchStore(rootDirectory: root).loadEdit(for: photo)?.snapshot
        #expect(restored == snapshot)
        #expect(restored?.settings.referenceLook == nil)
        #expect(restored?.settings == stored.preset.applying(to: .neutral))

        let previousSnapshot = PhotoEditSnapshot(
            settings: EditSettings(referenceLook: .bluesky2September2026)
        )
        let previousV3Snapshot = PhotoEditSnapshot(
            settings: EditSettings(referenceLook: .bluesky2September2026V3)
        )
        let previousPhoto = URL(fileURLWithPath: "/private/photos/reference-look-v2.jpg")
        let previousV3Photo = URL(fileURLWithPath: "/private/photos/reference-look-v3.jpg")
        try store.saveEdit(previousSnapshot, for: previousPhoto)
        try store.saveEdit(previousV3Snapshot, for: previousV3Photo)
        let restoredPrevious = try PhotoBenchStore(rootDirectory: root)
            .loadEdit(for: previousPhoto)?.snapshot
        let restoredPreviousV3 = try PhotoBenchStore(rootDirectory: root)
            .loadEdit(for: previousV3Photo)?.snapshot
        #expect(restoredPrevious == previousSnapshot)
        #expect(restoredPrevious?.settings.referenceLook == .bluesky2September2026)
        #expect(restoredPreviousV3 == previousV3Snapshot)
        #expect(restoredPreviousV3?.settings.referenceLook == .bluesky2September2026V3)

        var history = PhotoEditHistory()
        history.record(before: previousSnapshot, after: previousV3Snapshot)
        history.record(before: previousV3Snapshot, after: snapshot)
        #expect(history.undo(current: snapshot) == previousV3Snapshot)
        #expect(history.undo(current: previousV3Snapshot) == previousSnapshot)
        #expect(history.redo(current: previousSnapshot) == previousV3Snapshot)
        #expect(history.redo(current: previousV3Snapshot) == snapshot)
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
            .appendingPathComponent("PhotoBenchReferenceLookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

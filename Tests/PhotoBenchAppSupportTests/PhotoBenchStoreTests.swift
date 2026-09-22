import Foundation
import PhotoBenchAppSupport
import PhotoCore
import Testing

struct PhotoBenchStoreTests {
    @Test func editRoundTripsAcrossStoreRecreationAndKeepsPhotoIdentitySeparate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstPhoto = URL(fileURLWithPath: "/private/photos/one.jpg")
        let secondPhoto = URL(fileURLWithPath: "/private/photos/two.jpg")
        let firstStore = PhotoBenchStore(rootDirectory: root)
        var firstSettings = EditSettings.neutral
        firstSettings.exposure = 1.25
        firstSettings.saturation = -14
        firstSettings.relativeTemperature = 48
        firstSettings.relativeTint = -21
        let firstSnapshot = PhotoEditSnapshot(settings: firstSettings, applyApproximateXMPColor: false)
        var secondSettings = EditSettings.neutral
        secondSettings.exposure = -0.75
        let secondSnapshot = PhotoEditSnapshot(settings: secondSettings)

        try firstStore.saveEdit(firstSnapshot, for: firstPhoto)
        try firstStore.saveEdit(secondSnapshot, for: secondPhoto)

        let relaunchedStore = PhotoBenchStore(rootDirectory: root)
        #expect(try relaunchedStore.loadEdit(for: firstPhoto)?.snapshot == firstSnapshot)
        #expect(try relaunchedStore.loadEdit(for: secondPhoto)?.snapshot == secondSnapshot)
        #expect(PhotoBenchStore.photoID(for: firstPhoto) != PhotoBenchStore.photoID(for: secondPhoto))
        #expect(relaunchedStore.editRecordURL(for: firstPhoto).lastPathComponent == "\(PhotoBenchStore.photoID(for: firstPhoto)).json")
    }

    @Test func corruptUnknownSchemaAndMismatchedPhotoIDAreNeverOverwritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoBenchStore(rootDirectory: root)

        let cases: [(String, String)] = [
            ("corrupt.jpg", "{not json"),
            ("unknown.jpg", "{\"schemaVersion\":99,\"photoID\":\"placeholder\"}"),
            ("mismatch.jpg", "{\"schemaVersion\":1,\"photoID\":\"another-photo\"}")
        ]
        for (filename, contents) in cases {
            let photo = URL(fileURLWithPath: "/private/photos/\(filename)")
            let recordURL = store.editRecordURL(for: photo)
            try FileManager.default.createDirectory(
                at: recordURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let original = Data(contents.utf8)
            try original.write(to: recordURL)

            #expect(throws: PhotoBenchStoreError.self) {
                try store.loadEdit(for: photo)
            }
            #expect(throws: PhotoBenchStoreError.self) {
                try store.saveEdit(.neutral, for: photo)
            }
            #expect(try Data(contentsOf: recordURL) == original)
        }
    }

    @Test func duplicatePresetImportSurvivesRelaunchAndDeletionPreservesAppliedSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try xmpFixtureData()
        let seed = BuiltInPresetSeed(name: "colorful", data: source)
        let firstStore = PhotoBenchStore(rootDirectory: root)

        try firstStore.seedBuiltInPresets([seed], version: 1)
        let imported = try firstStore.registerPreset(data: source, name: "renamed-import")
        #expect(imported.id == PhotoBenchStore.sha256Hex(source))
        #expect(imported.name == "colorful")
        #expect(try firstStore.listPresets().count == 1)

        let photo = URL(fileURLWithPath: "/private/photos/applied.jpg")
        var editedSettings = imported.preset.applying(to: .neutral)
        editedSettings.exposure += 0.25
        let snapshot = PhotoEditSnapshot(
            settings: editedSettings,
            appliedPresetID: imported.id,
            appliedPreset: imported.preset,
            applyApproximateXMPColor: false
        )
        try firstStore.saveEdit(snapshot, for: photo)

        let relaunchedStore = PhotoBenchStore(rootDirectory: root)
        #expect(try relaunchedStore.listPresets().first == imported)
        try relaunchedStore.deletePreset(id: imported.id)
        #expect(try relaunchedStore.listPresets().isEmpty)
        #expect(try relaunchedStore.loadEdit(for: photo)?.snapshot == snapshot)

        try relaunchedStore.seedBuiltInPresets([seed], version: 1)
        try relaunchedStore.seedBuiltInPresets([seed], version: 2)
        #expect(try relaunchedStore.listPresets().isEmpty)
        #expect(try relaunchedStore.loadEdit(for: photo)?.appliedPreset?.rawProperties == imported.preset.rawProperties)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func xmpFixtureData() throws -> Data {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("niho-priset_colorful.xmp")
        return try Data(contentsOf: fileURL)
    }
}

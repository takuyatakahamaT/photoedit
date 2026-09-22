import CryptoKit
import Foundation
import PhotoCore

public struct PhotoEditSnapshot: Codable, Equatable, Sendable {
    public var settings: EditSettings
    public var appliedPresetID: String?
    public var appliedPreset: XMPPreset?
    public var applyApproximateXMPColor: Bool

    public init(
        settings: EditSettings = .neutral,
        appliedPresetID: String? = nil,
        appliedPreset: XMPPreset? = nil,
        applyApproximateXMPColor: Bool = false
    ) {
        self.settings = settings
        self.appliedPresetID = appliedPresetID
        self.appliedPreset = appliedPreset
        self.applyApproximateXMPColor = applyApproximateXMPColor
    }

    public static let neutral = PhotoEditSnapshot()
}

public struct PhotoEditRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let photoID: String
    public let settings: EditSettings
    public let appliedPresetID: String?
    public let appliedPreset: XMPPreset?
    public let applyApproximateXMPColor: Bool

    public init(photoID: String, snapshot: PhotoEditSnapshot) {
        schemaVersion = Self.currentSchemaVersion
        self.photoID = photoID
        settings = snapshot.settings
        appliedPresetID = snapshot.appliedPresetID
        appliedPreset = snapshot.appliedPreset
        applyApproximateXMPColor = snapshot.applyApproximateXMPColor
    }

    public var snapshot: PhotoEditSnapshot {
        PhotoEditSnapshot(
            settings: settings,
            appliedPresetID: appliedPresetID,
            appliedPreset: appliedPreset,
            applyApproximateXMPColor: applyApproximateXMPColor
        )
    }
}

public struct StoredXMPPreset: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let sourceData: Data
    public let preset: XMPPreset
    public let isBuiltIn: Bool

    fileprivate init(
        id: String,
        name: String,
        sourceData: Data,
        preset: XMPPreset,
        isBuiltIn: Bool
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.sourceData = sourceData
        self.preset = preset
        self.isBuiltIn = isBuiltIn
    }

    fileprivate func markingBuiltIn() -> StoredXMPPreset {
        StoredXMPPreset(
            id: id,
            name: name,
            sourceData: sourceData,
            preset: preset,
            isBuiltIn: true
        )
    }
}

public extension PhotoEditSnapshot {
    /// Identifies the updated bluesky2 XMP preset for its UI label. This digest
    /// does not select a rendering path.
    static let bluesky2ReferencePresetID = "01383daec2d7ba46bc0cf857e597ee85e6fab636c14c01c837fbf350eacbb054"

    /// Applies every newly selected preset through the same XMP patch path.
    func applying(preset storedPreset: StoredXMPPreset) -> PhotoEditSnapshot {
        PhotoEditSnapshot(
            settings: storedPreset.preset.applying(to: settings),
            appliedPresetID: storedPreset.id,
            appliedPreset: storedPreset.preset,
            applyApproximateXMPColor: false
        )
    }
}

public struct BuiltInPresetSeed: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum PhotoBenchStoreError: LocalizedError, Equatable {
    case corruptEditRecord(String)
    case unsupportedEditSchema(Int)
    case mismatchedPhotoID(expected: String, actual: String)
    case corruptPreset(String)
    case unsupportedPresetSchema(Int)
    case mismatchedPresetID(expected: String, actual: String)
    case invalidPresetID
    case corruptSeedState(String)
    case unsupportedSeedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .corruptEditRecord(reason): "編集データを読み込めません: \(reason)"
        case let .unsupportedEditSchema(version): "未対応の編集データ形式です（schema \(version)）。元データを保護するため保存を停止しました。"
        case let .mismatchedPhotoID(expected, actual):
            "編集データの写真IDが一致しません（期待値 \(expected)、記録値 \(actual)）。元データを保護するため保存を停止しました。"
        case let .corruptPreset(reason): "XMPプリセットライブラリを読み込めません: \(reason)"
        case let .unsupportedPresetSchema(version): "未対応のプリセットデータ形式です（schema \(version)）。"
        case let .mismatchedPresetID(expected, actual): "プリセットIDが一致しません（期待値 \(expected)、記録値 \(actual)）。"
        case .invalidPresetID: "プリセットIDが不正です。"
        case let .corruptSeedState(reason): "標準プリセットの登録状態を読み込めません: \(reason)"
        case let .unsupportedSeedSchema(version): "未対応の標準プリセット登録状態です（schema \(version)）。"
        }
    }
}

/// Stores small, versioned edit records and XMP presets only inside the app's
/// Application Support area. The root is injectable so tests never touch a
/// real user library.
public final class PhotoBenchStore {
    public static let builtInSeedSchemaVersion = 1

    public let rootDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public static func applicationSupport(fileManager: FileManager = .default) -> PhotoBenchStore {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return PhotoBenchStore(
            rootDirectory: supportDirectory.appendingPathComponent("PhotoBench", isDirectory: true),
            fileManager: fileManager
        )
    }

    public static func photoID(for photoURL: URL) -> String {
        sha256Hex(Data(photoURL.standardizedFileURL.path.utf8))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func editRecordURL(for photoURL: URL) -> URL {
        editsDirectory.appendingPathComponent(Self.photoID(for: photoURL) + ".json")
    }

    public func loadEdit(for photoURL: URL) throws -> PhotoEditRecord? {
        let expectedID = Self.photoID(for: photoURL)
        let url = editRecordURL(for: photoURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PhotoBenchStoreError.corruptEditRecord(error.localizedDescription)
        }

        let header: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PhotoBenchStoreError.corruptEditRecord("JSONのトップレベルがオブジェクトではありません。")
            }
            header = dictionary
        } catch let error as PhotoBenchStoreError {
            throw error
        } catch {
            throw PhotoBenchStoreError.corruptEditRecord(error.localizedDescription)
        }

        guard let schemaVersion = header["schemaVersion"] as? Int else {
            throw PhotoBenchStoreError.corruptEditRecord("schemaVersionがありません。")
        }
        guard schemaVersion == PhotoEditRecord.currentSchemaVersion else {
            throw PhotoBenchStoreError.unsupportedEditSchema(schemaVersion)
        }
        guard let actualID = header["photoID"] as? String else {
            throw PhotoBenchStoreError.corruptEditRecord("photoIDがありません。")
        }
        guard actualID == expectedID else {
            throw PhotoBenchStoreError.mismatchedPhotoID(expected: expectedID, actual: actualID)
        }

        do {
            let record = try decoder.decode(PhotoEditRecord.self, from: data)
            guard record.schemaVersion == PhotoEditRecord.currentSchemaVersion else {
                throw PhotoBenchStoreError.unsupportedEditSchema(record.schemaVersion)
            }
            guard record.photoID == expectedID else {
                throw PhotoBenchStoreError.mismatchedPhotoID(expected: expectedID, actual: record.photoID)
            }
            return record
        } catch let error as PhotoBenchStoreError {
            throw error
        } catch {
            throw PhotoBenchStoreError.corruptEditRecord(error.localizedDescription)
        }
    }

    public func saveEdit(_ snapshot: PhotoEditSnapshot, for photoURL: URL) throws {
        try ensureDirectories()
        // A failed or incompatible read must never turn into a neutral record
        // that replaces the user's only copy of the existing edit.
        if fileManager.fileExists(atPath: editRecordURL(for: photoURL).path) {
            _ = try loadEdit(for: photoURL)
        }
        let record = PhotoEditRecord(photoID: Self.photoID(for: photoURL), snapshot: snapshot)
        try writeAtomically(record, to: editRecordURL(for: photoURL))
    }

    public func listPresets() throws -> [StoredXMPPreset] {
        try fileManager.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: presetsDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch {
            throw PhotoBenchStoreError.corruptPreset(error.localizedDescription)
        }
        return try urls.map(readStoredPreset(at:)).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    @discardableResult
    public func registerPreset(data: Data, name: String) throws -> StoredXMPPreset {
        try fileManager.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        let id = Self.sha256Hex(data)
        let destination = presetURL(for: id)
        if fileManager.fileExists(atPath: destination.path) {
            return try readStoredPreset(at: destination)
        }

        let displayName = name.isEmpty ? "無題のプリセット" : name
        let parsed = try XMPPresetParser.parse(data: data, fallbackName: displayName)
        let stored = StoredXMPPreset(
            id: id,
            name: displayName,
            sourceData: data,
            preset: parsed,
            isBuiltIn: false
        )
        try writeAtomically(stored, to: destination)
        return stored
    }

    public func seedBuiltInPresets(_ seeds: [BuiltInPresetSeed], version: Int) throws {
        guard version > 0 else { return }
        try fileManager.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)

        var state = try loadSeedState() ?? SeedState()
        guard state.seedVersion < version else { return }

        for seed in seeds {
            let id = Self.sha256Hex(seed.data)
            state.installedPresetIDs.insert(id)
            guard !state.suppressedPresetIDs.contains(id) else { continue }

            let destination = presetURL(for: id)
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try readStoredPreset(at: destination)
                if !existing.isBuiltIn {
                    try writeAtomically(existing.markingBuiltIn(), to: destination)
                }
            } else {
                let name = seed.name.isEmpty ? "無題のプリセット" : seed.name
                let parsed = try XMPPresetParser.parse(data: seed.data, fallbackName: name)
                let stored = StoredXMPPreset(
                    id: id,
                    name: name,
                    sourceData: seed.data,
                    preset: parsed,
                    isBuiltIn: true
                )
                try writeAtomically(stored, to: destination)
            }
        }

        state.seedVersion = version
        try saveSeedState(state)
    }

    public func deletePreset(id: String) throws {
        guard isValidPresetID(id) else { throw PhotoBenchStoreError.invalidPresetID }
        let destination = presetURL(for: id)
        var state = try loadSeedState() ?? SeedState()
        if state.installedPresetIDs.contains(id), !state.suppressedPresetIDs.contains(id) {
            state.suppressedPresetIDs.insert(id)
            // Record the tombstone first so a later launch cannot restore the
            // bundled preset if removing its separate file fails.
            try saveSeedState(state)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }

    private struct SeedState: Codable {
        var schemaVersion = PhotoBenchStore.builtInSeedSchemaVersion
        var seedVersion = 0
        var installedPresetIDs: Set<String> = []
        var suppressedPresetIDs: Set<String> = []
    }

    private var editsDirectory: URL {
        rootDirectory.appendingPathComponent("Edits", isDirectory: true)
    }

    private var presetsDirectory: URL {
        rootDirectory.appendingPathComponent("Presets", isDirectory: true)
    }

    private var metadataDirectory: URL {
        rootDirectory.appendingPathComponent("Metadata", isDirectory: true)
    }

    private var seedStateURL: URL {
        metadataDirectory.appendingPathComponent("preset-seed-state.json")
    }

    private func presetURL(for id: String) -> URL {
        presetsDirectory.appendingPathComponent(id + ".json")
    }

    private func isValidPresetID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: editsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
    }

    private func readStoredPreset(at url: URL) throws -> StoredXMPPreset {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PhotoBenchStoreError.corruptPreset(error.localizedDescription)
        }

        do {
            let preset = try decoder.decode(StoredXMPPreset.self, from: data)
            guard preset.schemaVersion == StoredXMPPreset.currentSchemaVersion else {
                throw PhotoBenchStoreError.unsupportedPresetSchema(preset.schemaVersion)
            }
            let expectedID = Self.sha256Hex(preset.sourceData)
            guard preset.id == expectedID, preset.id == url.deletingPathExtension().lastPathComponent else {
                throw PhotoBenchStoreError.mismatchedPresetID(expected: expectedID, actual: preset.id)
            }
            return preset
        } catch let error as PhotoBenchStoreError {
            throw error
        } catch {
            throw PhotoBenchStoreError.corruptPreset(error.localizedDescription)
        }
    }

    private func loadSeedState() throws -> SeedState? {
        guard fileManager.fileExists(atPath: seedStateURL.path) else { return nil }
        do {
            let state = try decoder.decode(SeedState.self, from: Data(contentsOf: seedStateURL))
            guard state.schemaVersion == Self.builtInSeedSchemaVersion else {
                throw PhotoBenchStoreError.unsupportedSeedSchema(state.schemaVersion)
            }
            return state
        } catch let error as PhotoBenchStoreError {
            throw error
        } catch {
            throw PhotoBenchStoreError.corruptSeedState(error.localizedDescription)
        }
    }

    private func saveSeedState(_ state: SeedState) throws {
        try fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try writeAtomically(state, to: seedStateURL)
    }

    private func writeAtomically<Value: Encodable>(_ value: Value, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

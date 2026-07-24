import Foundation
import PhotoBenchCalibrationSupport
import Testing

@Suite("Historical calibration manifest resolution")
struct HistoricalCalibrationManifestResolverTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func exactCurrentFileIsAccepted() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let original = try productionManifestData()
        let manifestURL = try writeManifest(original, root: sandbox)
        let suiteID = try decodedSuiteID(original)

        let resolved = try HistoricalCalibrationManifestResolver.resolve(
            root: sandbox,
            manifestPath: "calibration/manifest-v4.json",
            expectedSHA256: SHA256Digest.data(original),
            expectedSuiteID: suiteID,
            archiveSnapshotURL: nil
        )

        #expect(resolved.data == original)
        #expect(resolved.source == .currentFile)
        #expect(try Data(contentsOf: manifestURL) == original)
    }

    @Test func historicalProcessingAndRAWProfileDoNotDependOnCurrentBuild() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let historical = try changingProcessingCompatibility(
            in: productionManifestData()
        )
        _ = try writeManifest(historical, root: sandbox)
        let decoded = try JSONDecoder().decode(
            CalibrationManifest.self,
            from: historical
        )

        #expect(throws: CalibrationManifestError.self) {
            try CalibrationManifestLoader.validateStructure(decoded)
        }
        let resolved = try HistoricalCalibrationManifestResolver.resolve(
            root: sandbox,
            manifestPath: "calibration/manifest-v4.json",
            expectedSHA256: SHA256Digest.data(historical),
            expectedSuiteID: decoded.suiteID,
            archiveSnapshotURL: nil
        )

        #expect(resolved.data == historical)
        #expect(resolved.source == .currentFile)
        #expect(resolved.manifest.processing.fingerprint.rawDecode == "historical-raw-v7")
        #expect(resolved.manifest.rawProfile.id == "historical-dc-s5-profile")
    }

    @Test func editedCurrentFileFallsBackAcrossGitHistory() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let original = try productionManifestData()
        let changed = try changingDescription(in: original)
        _ = try writeManifest(original, root: sandbox)
        try runGit(["init", "--quiet"], root: sandbox)
        try runGit(["add", "calibration/manifest-v4.json"], root: sandbox)
        try commit("original", root: sandbox)
        _ = try writeManifest(changed, root: sandbox)
        try runGit(["add", "calibration/manifest-v4.json"], root: sandbox)
        try commit("changed", root: sandbox)

        let resolved = try HistoricalCalibrationManifestResolver.resolve(
            root: sandbox,
            manifestPath: "calibration/manifest-v4.json",
            expectedSHA256: SHA256Digest.data(original),
            expectedSuiteID: try decodedSuiteID(original),
            archiveSnapshotURL: nil
        )

        #expect(resolved.data == original)
        if case let .gitRevision(revision) = resolved.source {
            #expect(revision.count == 40 || revision.count == 64)
        } else {
            Issue.record("Git revision source was expected")
        }
        #expect(try Data(contentsOf: sandbox.appendingPathComponent(
            "calibration/manifest-v4.json"
        )) == changed)
    }

    @Test func archiveSnapshotTakesPrecedenceOverChangedCurrentFile() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let original = try productionManifestData()
        let changedManifest = try writeManifest(
            try changingDescription(in: original),
            root: sandbox
        )
        let relocatedCurrent = sandbox.appendingPathComponent("relocated-current.json")
        try FileManager.default.moveItem(at: changedManifest, to: relocatedCurrent)
        try FileManager.default.createSymbolicLink(
            at: changedManifest,
            withDestinationURL: relocatedCurrent
        )
        let archive = sandbox.appendingPathComponent(
            ".photobench/calibration-archives/run-1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: archive,
            withIntermediateDirectories: true
        )
        let snapshot = archive.appendingPathComponent("source-manifest.json")
        try original.write(to: snapshot)

        let resolved = try HistoricalCalibrationManifestResolver.resolve(
            root: sandbox,
            manifestPath: "calibration/manifest-v4.json",
            expectedSHA256: SHA256Digest.data(original),
            expectedSuiteID: try decodedSuiteID(original),
            archiveSnapshotURL: snapshot
        )

        #expect(resolved.data == original)
        #expect(resolved.source == .archiveSnapshot)
    }

    @Test func invalidPresentArchiveSnapshotFailsClosed() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let original = try productionManifestData()
        _ = try writeManifest(original, root: sandbox)
        let archive = sandbox.appendingPathComponent(
            ".photobench/calibration-archives/run-1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: archive,
            withIntermediateDirectories: true
        )
        let snapshot = archive.appendingPathComponent("source-manifest.json")
        let invalid = Data("not the recorded manifest".utf8)
        try invalid.write(to: snapshot)

        #expect(throws: CalibrationManifestError.self) {
            _ = try HistoricalCalibrationManifestResolver.resolve(
                root: sandbox,
                manifestPath: "calibration/manifest-v4.json",
                expectedSHA256: SHA256Digest.data(original),
                expectedSuiteID: try decodedSuiteID(original),
                archiveSnapshotURL: snapshot
            )
        }
        #expect(try Data(contentsOf: snapshot) == invalid)
        #expect(try Data(contentsOf: sandbox.appendingPathComponent(
            "calibration/manifest-v4.json"
        )) == original)
    }

    @Test func immutableWriterNeverReplacesExistingEvidence() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let archive = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/calibration-archives/run-1",
            inside: sandbox
        )
        let destination = archive.appendingPathComponent("source-manifest.json")
        let original = Data("original evidence".utf8)
        try ImmutableCalibrationEvidenceWriter.writeNew(
            original,
            to: destination,
            inside: sandbox
        )

        #expect(try Data(contentsOf: destination) == original)
        #expect(throws: CalibrationManifestError.self) {
            try ImmutableCalibrationEvidenceWriter.writeNew(
                Data("replacement".utf8),
                to: destination,
                inside: sandbox
            )
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    private func productionManifestData() throws -> Data {
        try Data(contentsOf: projectRoot.appendingPathComponent(
            "calibration/manifest-v4.json"
        ))
    }

    private func decodedSuiteID(_ data: Data) throws -> String {
        try JSONDecoder().decode(CalibrationManifest.self, from: data).suiteID
    }

    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoBenchHistoricalManifestTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @discardableResult
    private func writeManifest(_ data: Data, root: URL) throws -> URL {
        let directory = root.appendingPathComponent("calibration", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let destination = directory.appendingPathComponent("manifest-v4.json")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func changingDescription(in data: Data) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["description"] = "historical resolver changed-current sentinel"
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) + Data("\n".utf8)
    }

    private func changingProcessingCompatibility(in data: Data) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var processing = try #require(object["processing"] as? [String: Any])
        var fingerprint = try #require(processing["fingerprint"] as? [String: Any])
        fingerprint["rawDecode"] = "historical-raw-v7"
        fingerprint["renderPipeline"] = "historical-render-v7"
        processing["fingerprint"] = fingerprint
        object["processing"] = processing
        var profile = try #require(object["rawProfile"] as? [String: Any])
        profile["id"] = "historical-dc-s5-profile"
        profile["boostAmount"] = 0.75
        profile["extendedDynamicRangeAmount"] = 1.25
        object["rawProfile"] = profile
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) + Data("\n".utf8)
    }

    private func commit(_ message: String, root: URL) throws {
        try runGit(
            [
                "-c", "user.name=PhotoBench Tests",
                "-c", "user.email=photobench-tests@example.invalid",
                "commit", "--quiet", "-m", message
            ],
            root: root
        )
    }

    private func runGit(_ arguments: [String], root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CalibrationManifestError.invalid(
                "test Git command failed: \(String(data: data, encoding: .utf8) ?? "")"
            )
        }
    }
}

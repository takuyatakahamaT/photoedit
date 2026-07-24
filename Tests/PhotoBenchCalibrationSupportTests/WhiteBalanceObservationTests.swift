import Foundation
import PhotoBenchCalibrationSupport
import PhotoCore
import Testing

@Suite("White-balance observation support")
struct WhiteBalanceObservationTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func productionObservationManifestIsDevelopmentOnlyAndExpandsExactly18Candidates() throws {
        let loaded = try WhiteBalanceObservationManifestLoader.load(root: projectRoot)
        let manifest = loaded.manifest
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.adoptionStatus == .exploratoryObservationOnly)
        #expect(manifest.scenes.count == 2)
        #expect(manifest.scenes.allSatisfy { $0.fold == "development" })
        #expect(
            manifest.candidatePlan.temperatureMiredOffsets
                == WhiteBalanceObservationManifestLoader.requiredTemperatureMiredOffsets
        )
        #expect(
            manifest.candidatePlan.tintOffsets
                == WhiteBalanceObservationManifestLoader.requiredTintOffsets
        )
        #expect(
            manifest.candidatePlan.corners
                == WhiteBalanceObservationManifestLoader.requiredCorners
        )
        #expect(
            manifest.processing.sourceFiles
                == WhiteBalanceObservationManifestLoader.requiredSourceFiles
        )
        #expect(loaded.verifiedInputs.count == 4)

        let source = RAWNeutralValues(
            temperatureKelvin: 4_000,
            tint: 10,
            chromaticityX: 0.4,
            chromaticityY: 0.4
        )
        let candidates = try WhiteBalanceObservationManifestLoader.candidates(
            plan: manifest.candidatePlan,
            source: source
        )
        #expect(candidates.count == 18)
        #expect(Set(candidates.map(\.id)).count == 18)
        #expect(candidates.first?.id == "as-shot")
        #expect(candidates.dropFirst().first?.id == "custom-center")
        #expect(candidates.filter { $0.kind == .temperatureAxis }.count == 6)
        #expect(candidates.filter { $0.kind == .tintAxis }.count == 6)
        #expect(candidates.filter { $0.kind == .corner }.count == 4)
        #expect(candidates.first?.customWhiteBalance == nil)
        #expect(candidates.dropFirst().first?.customWhiteBalance?.temperatureKelvin == 4_000)
        #expect(candidates.dropFirst().first?.customWhiteBalance?.tint == 10)
    }

    @Test func manifestRejectsOffsetOrderCornerAndCandidateCountTampering() throws {
        let reordered = try mutatedManifest { object in
            var plan = object["candidatePlan"] as! [String: Any]
            plan["temperatureMiredOffsets"] = [-60, -100, -30, 0, 30, 60, 100]
            object["candidatePlan"] = plan
        }
        #expect(throws: CalibrationManifestError.self) {
            try WhiteBalanceObservationManifestLoader.validateStructure(reordered)
        }

        let changedCorner = try mutatedManifest { object in
            var plan = object["candidatePlan"] as! [String: Any]
            var corners = plan["corners"] as! [[String: Any]]
            corners[0]["tintOffset"] = -30
            plan["corners"] = corners
            object["candidatePlan"] = plan
        }
        #expect(throws: CalibrationManifestError.self) {
            try WhiteBalanceObservationManifestLoader.validateStructure(changedCorner)
        }

        let wrongCount = try mutatedManifest { object in
            var plan = object["candidatePlan"] as! [String: Any]
            plan["expectedCandidateCountPerScene"] = 17
            object["candidatePlan"] = plan
        }
        #expect(throws: CalibrationManifestError.self) {
            try WhiteBalanceObservationManifestLoader.validateStructure(wrongCount)
        }
    }

    @Test func loaderRejectsTamperedBaseManifestHash() throws {
        let sandbox = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/tests/wb-manifest-\(UUID().uuidString.lowercased())",
            inside: projectRoot
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let destination = sandbox.appendingPathComponent("manifest.json")
        let source = projectRoot.appendingPathComponent(
            WhiteBalanceObservationManifestLoader.defaultRelativePath
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any]
        )
        var base = object["baseCalibrationManifest"] as! [String: Any]
        base["sha256"] = String(repeating: "0", count: 64)
        object["baseCalibrationManifest"] = base
        try JSONSerialization.data(withJSONObject: object).write(to: destination)

        #expect(throws: CalibrationManifestError.self) {
            _ = try WhiteBalanceObservationManifestLoader.load(
                root: projectRoot,
                manifestURL: destination
            )
        }
    }

    @Test func observationOutputRejectsHostileSymlinksExistingRunsAndExistingFiles() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchWBOutput-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outputLink = root.appendingPathComponent(".photobench")
        try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: outside)
        let firstID = UUID().uuidString.lowercased()
        #expect(throws: CalibrationManifestError.self) {
            _ = try WhiteBalanceObservationOutput.prepareNewRunDirectory(
                runID: firstID,
                root: root
            )
        }

        try FileManager.default.removeItem(at: outputLink)
        let run = try WhiteBalanceObservationOutput.prepareNewRunDirectory(
            runID: firstID,
            root: root
        )
        #expect(throws: CalibrationManifestError.self) {
            _ = try WhiteBalanceObservationOutput.prepareNewRunDirectory(
                runID: firstID,
                root: root
            )
        }

        let victim = outside.appendingPathComponent("victim.json")
        try Data("unchanged".utf8).write(to: victim)
        let outputFile = run.appendingPathComponent("run.json")
        try FileManager.default.createSymbolicLink(at: outputFile, withDestinationURL: victim)
        #expect(throws: CalibrationManifestError.self) {
            _ = try WhiteBalanceObservationOutput.prepareNewFile(
                named: "run.json",
                in: run,
                root: root
            )
        }
        #expect(try Data(contentsOf: victim) == Data("unchanged".utf8))
    }

    @Test func incompleteSentinelIsExplicitAndCodable() throws {
        let sentinel = WhiteBalanceObservationIncompleteSentinel(
            runID: UUID().uuidString.lowercased(),
            startedAtUTC: "2026-07-24T00:00:00Z",
            manifestSHA256: String(repeating: "a", count: 64)
        )
        let decoded = try JSONDecoder().decode(
            WhiteBalanceObservationIncompleteSentinel.self,
            from: JSONEncoder().encode(sentinel)
        )
        #expect(decoded == sentinel)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.status == "incomplete")
    }

    @Test func immutableJSONWriterPublishesOnceAndNeverMutatesExistingEvidence() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchWBImmutableJSON-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let run = try WhiteBalanceObservationOutput.prepareNewRunDirectory(
            runID: UUID().uuidString.lowercased(),
            root: root
        )
        let destination = run.appendingPathComponent("run.json")
        let first = WhiteBalanceObservationIncompleteSentinel(
            runID: UUID().uuidString.lowercased(),
            startedAtUTC: "2026-07-24T00:00:00Z",
            manifestSHA256: String(repeating: "a", count: 64)
        )
        try WhiteBalanceObservationOutput.writeNewJSON(
            first,
            to: destination,
            root: root
        )
        let published = try Data(contentsOf: destination)

        let second = WhiteBalanceObservationIncompleteSentinel(
            runID: UUID().uuidString.lowercased(),
            startedAtUTC: "2026-07-24T01:00:00Z",
            manifestSHA256: String(repeating: "b", count: 64)
        )
        #expect(throws: CalibrationManifestError.self) {
            try WhiteBalanceObservationOutput.writeNewJSON(
                second,
                to: destination,
                root: root
            )
        }
        #expect(try Data(contentsOf: destination) == published)
    }

    @Test func sourceFingerprintCoversProductionRenderingAndObservationEntrypoints() throws {
        let production = try CalibrationManifestLoader.load(root: projectRoot)
        let observation = try WhiteBalanceObservationManifestLoader.load(root: projectRoot)
        #expect(
            observation.manifest.processing.sourceFiles
                == production.manifest.processing.sourceFiles
                    + WhiteBalanceObservationManifestLoader.observationOnlySourceFiles
        )

        let fileManager = FileManager.default
        var expected = Set(production.manifest.processing.sourceFiles)
        expected.formUnion(WhiteBalanceObservationManifestLoader.observationOnlySourceFiles)
        for relativeDirectory in [
            "Sources/PhotoCore",
            "Sources/PhotoBenchCalibrationSupport"
        ] {
            let files = try fileManager.contentsOfDirectory(
                at: projectRoot.appendingPathComponent(relativeDirectory),
                includingPropertiesForKeys: nil
            )
            for file in files where file.pathExtension == "swift" {
                expected.insert("\(relativeDirectory)/\(file.lastPathComponent)")
            }
        }
        #expect(Set(observation.manifest.processing.sourceFiles) == expected)
    }

    private func mutatedManifest(
        _ mutation: (inout [String: Any]) -> Void
    ) throws -> WhiteBalanceObservationManifest {
        let url = projectRoot.appendingPathComponent(
            WhiteBalanceObservationManifestLoader.defaultRelativePath
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        mutation(&object)
        return try JSONDecoder().decode(
            WhiteBalanceObservationManifest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}

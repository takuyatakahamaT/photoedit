import CryptoKit
import Foundation
import PhotoCore

public struct CalibrationManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let suiteID: String
    public let description: String
    public let expectedEnvironment: ExpectedEnvironment
    public let processing: ProcessingSpecification
    public let preset: PresetFixture
    public let comparison: ComparisonSpecification
    public let rawProfile: RAWProfileSpecification
    public let diagnostics: DiagnosticSpecification
    public let legacyCandidates: [CalibrationCandidateDefinition]
    public let stageMatrix: [CalibrationCandidateDefinition]
    public let qualityGate: QualityGateSpecification
    public let previewParity: PreviewParitySpecification?
    public let canonicalSettleGate: CanonicalSettleGateSpecification?
    public let benchmark: BenchmarkSpecification
    public let scenes: [CalibrationScene]
}

public struct ExpectedEnvironment: Codable, Equatable, Sendable {
    public let macOSVersion: String
    public let macOSBuild: String
    public let architecture: String
    public let hardwareModel: String
    public let metalDevice: String
    public let rawDecoderBackend: String
}

public struct ProcessingSpecification: Codable, Equatable, Sendable {
    public let fingerprint: PhotoCoreProcessingFingerprint
    public let sourceFiles: [String]
}

public struct HashedFixture: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
}

public struct PresetFixture: Codable, Equatable, Sendable {
    public let file: HashedFixture
    public let uuid: String
    public let cameraRawVersion: String
    public let processVersion: String
}

public struct ComparisonSpecification: Codable, Equatable, Sendable {
    public let maxDimension: Int
    public let outputFormat: String
    public let outputColorSpace: String
    public let bitsPerChannel: Int
    public let referenceSoftware: String
    public let referenceWhiteBalance: String
    public let orientationPolicy: String
    public let cropPolicy: String
}

public struct RAWProfileSpecification: Codable, Equatable, Sendable {
    public let id: String
    public let boostAmount: Double
    public let extendedDynamicRangeAmount: Double
}

public struct DiagnosticSpecification: Codable, Equatable, Sendable {
    public let boostAmounts: [Double]
    public let extendedDynamicRangeAmounts: [Double]
}

public struct CalibrationCandidateDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let rawLabel: String
    public let lightroomInputLabel: String
}

public struct QualityGateSpecification: Codable, Equatable, Sendable {
    public let routes: [QualityGateRoute]
    public let meanDeltaEMaximumIncrease: Double
    public let meanEVAbsoluteErrorMaximumIncrease: Double
    public let newSharedPlateauMaximumArea: Double
}

public struct QualityGateRoute: Codable, Equatable, Sendable {
    public let id: String
    public let basicLabel: String
    public let fullLabel: String
}

public struct PreviewParitySpecification: Codable, Equatable, Sendable {
    /// Schema v2 only: both the RAW decode ceiling and final artifact ceiling.
    public let maxDimension: Int?
    /// Schema v3 only: the common final artifact ceiling for every decode route.
    public let outputMaxDimension: Int?
    /// Schema v3 only: ordered RAW decode ceilings compared with the full decode.
    public let candidateDecodeMaximumDimensions: [Int]?
    /// Schema v3 only: the morphology contract for spatial plateau comparison.
    public let plateauSpatialTolerance: PreviewParityPlateauSpatialTolerance?
    public let settingsStageIDs: [String]
    public let baselineDecodeIntent: String
    public let candidateDecodeIntent: String
    public let thresholds: PreviewParityThresholds
}

public struct PreviewParityPlateauSpatialTolerance: Codable, Equatable, Sendable {
    public let radiusPixels: Int
    public let structuringElement: String
}

public struct PreviewParityThresholds: Codable, Equatable, Sendable {
    public let meanDeltaEMaximum: Double
    /// Schema v3 only: P95 after the analyzer's preregistered spatial blur.
    public let blurredDeltaE2000P95Maximum: Double?
    public let meanEVAbsoluteDriftMaximum: Double
    /// Schema v2 only: exact-coordinate shared plateau set difference.
    public let newSharedPlateauMaximumArea: Double?
    /// Schema v3 only: positive shared plateau area growth, independent of translation.
    public let netSharedPlateauAreaIncreaseMaximum: Double?
    /// Schema v3 only: candidate plateau outside the dilated reference plateau.
    public let spatiallyDistinctNewSharedPlateauMaximumArea: Double?
}

/// Schema v4's production-preview settle contract. It reuses the full-decode
/// preview-parity artifacts rather than creating a second render route.
public struct CanonicalSettleGateSpecification: Codable, Equatable, Sendable {
    public let outputMaxDimension: Int
    public let downsamplingFilter: String
    public let inputAspectRatio: Double
    public let workingColorSpace: String
    public let outputTransformPlacement: String
    public let baselineStageID: String
    public let candidateStageID: String
    public let thresholds: CanonicalSettleThresholds
}

public struct CanonicalSettleThresholds: Codable, Equatable, Sendable {
    public let completeClipNormalizedMinimum: Double
    public let nearClipNormalizedMinimum: Double
    public let completeClipMaximumPixelCountIncrease: Int
    public let nearClipMaximumPixelCountIncrease: Int
    public let newSharedPlateauMaximumArea: Double
}

public struct BenchmarkSpecification: Codable, Equatable, Sendable {
    public let sceneID: String
    public let previewMaxDimension: Int
    public let jpegQuality: Double
    public let warmupIterations: Int
    public let measuredIterations: Int
    public let processFreshIterations: Int
    public let thresholdsMilliseconds: BenchmarkThresholds
}

public struct BenchmarkThresholds: Codable, Equatable, Sendable {
    public let processFreshLowResolutionPreviewP95: Double
    public let warmSliderEngineP95: Double
    public let warmHighQualityPreviewP95: Double
    public let fullResolutionJPEGExportP95: Double
}

public struct CalibrationScene: Codable, Equatable, Sendable {
    public let id: String
    public let sceneGroup: String
    public let fold: String
    public let lighting: String
    public let capture: CaptureSpecification
    public let raw: HashedFixture
    public let lightroomBefore: HashedFixture
    public let lightroomAfter: HashedFixture
}

public struct CaptureSpecification: Codable, Equatable, Sendable {
    public let cameraMake: String
    public let cameraModel: String
    public let lensModel: String
    public let iso: Int
    public let exposureTime: String
    public let fNumber: Double
    public let exposureCompensation: Double
    public let sourceWhiteBalance: String
    public let lightroomColorTemperature: Int
    public let width: Int
    public let height: Int
    public let rawBitsPerSample: Int
}

public struct VerifiedFile: Codable, Equatable, Sendable {
    public let role: String
    public let path: String
    public let sha256: String
    public let byteCount: UInt64

    public init(role: String, path: String, sha256: String, byteCount: UInt64) {
        self.role = role
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public struct LoadedCalibrationManifest: Sendable {
    public let manifest: CalibrationManifest
    public let root: URL
    public let manifestURL: URL
    public let manifestSHA256: String
    public let verifiedInputs: [VerifiedFile]

    public init(
        manifest: CalibrationManifest,
        root: URL,
        manifestURL: URL,
        manifestSHA256: String,
        verifiedInputs: [VerifiedFile]
    ) {
        self.manifest = manifest
        self.root = root
        self.manifestURL = manifestURL
        self.manifestSHA256 = manifestSHA256
        self.verifiedInputs = verifiedInputs
    }

    public func resolve(_ relativePath: String) throws -> URL {
        try CalibrationManifestLoader.resolve(relativePath, inside: root)
    }

    public func verifyInputsAgain() throws -> [VerifiedFile] {
        try CalibrationManifestLoader.verifyFixtureFiles(manifest, root: root)
    }

    public func verifyManifestAgain() throws -> String {
        let digest = try SHA256Digest.file(manifestURL)
        guard digest == manifestSHA256 else {
            throw CalibrationManifestError.hashMismatch(
                path: manifestURL.path,
                expected: manifestSHA256,
                actual: digest
            )
        }
        return digest
    }
}

public enum CalibrationManifestError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalid(String)
    case pathEscapesRoot(String)
    case missingFile(String)
    case hashMismatch(path: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "未対応の校正manifest schemaです: \(version)"
        case let .invalid(message):
            "校正manifestが不正です: \(message)"
        case let .pathEscapesRoot(path):
            "校正manifestのpathがプロジェクト外を指しています: \(path)"
        case let .missingFile(path):
            "校正入力が見つかりません: \(path)"
        case let .hashMismatch(path, expected, actual):
            "校正入力のSHA-256が一致しません: \(path) expected=\(expected) actual=\(actual)"
        }
    }
}

public enum CalibrationManifestLoader {
    public static let defaultRelativePath = "calibration/manifest-v4.json"

    private static let requiredLegacyCandidateIDs: Set<String> = [
        "exposure-only", "tone-base", "basic-legacy", "full-current"
    ]
    private static let requiredStageIDs: Set<String> = [
        "tone-base",
        "tone-plus-vibrance",
        "tone-plus-global-saturation",
        "tone-plus-global-curve",
        "tone-plus-rgb-curves",
        "tone-plus-all-curves",
        "tone-plus-mixer-hue",
        "tone-plus-mixer-saturation",
        "tone-plus-mixer-luminance",
        "tone-plus-all-mixer",
        "tone-plus-curves-mixer",
        "full-current"
    ]
    private static let requiredBoostAmounts = [
        0.0, 0.25, 0.5, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0
    ]
    private static let requiredEDRAmounts = [0.0, 1.0, 2.0]
    private static let requiredPreviewParitySettings = [
        "neutral", "basic-legacy", "full-current"
    ]
    private static let requiredLegacyCandidates: [String: (raw: String, lightroom: String)] = [
        "exposure-only": ("xmp-exposure-only", "lr-input-xmp-exposure-only"),
        "tone-base": ("xmp-tone", "lr-input-xmp-tone"),
        "basic-legacy": ("xmp-basic", "lr-input-xmp-basic"),
        "full-current": ("xmp-full-current", "lr-input-xmp-full-current")
    ]

    public static func load(
        root: URL,
        manifestURL explicitManifestURL: URL? = nil
    ) throws -> LoadedCalibrationManifest {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let requestedManifestURL: URL
        if let explicitManifestURL {
            requestedManifestURL = explicitManifestURL.isFileURL
                ? explicitManifestURL.standardizedFileURL
                : normalizedRoot.appendingPathComponent(explicitManifestURL.path)
        } else {
            requestedManifestURL = normalizedRoot.appendingPathComponent(defaultRelativePath)
        }
        let manifestURL = requestedManifestURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = normalizedRoot.path.hasSuffix("/")
            ? normalizedRoot.path
            : normalizedRoot.path + "/"
        guard manifestURL.path.hasPrefix(rootPrefix) else {
            throw CalibrationManifestError.pathEscapesRoot(requestedManifestURL.path)
        }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CalibrationManifestError.missingFile(
                manifestURL.path.replacingOccurrences(of: normalizedRoot.path + "/", with: "")
            )
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CalibrationManifest.self, from: data)
        try validateStructure(manifest)
        try validateExpectedEnvironment(manifest.expectedEnvironment)
        let verifiedInputs = try verifyFixtureFiles(manifest, root: normalizedRoot)
        return LoadedCalibrationManifest(
            manifest: manifest,
            root: normalizedRoot,
            manifestURL: manifestURL,
            manifestSHA256: SHA256Digest.data(data),
            verifiedInputs: verifiedInputs
        )
    }

    public static func validateStructure(_ manifest: CalibrationManifest) throws {
        guard [1, 2, 3, 4].contains(manifest.schemaVersion) else {
            throw CalibrationManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        switch manifest.schemaVersion {
        case 1:
            guard manifest.previewParity == nil else {
                throw CalibrationManifestError.invalid(
                    "schema v1にはpreviewParityを指定できません"
                )
            }
        case 2:
            guard manifest.previewParity != nil else {
                throw CalibrationManifestError.invalid(
                    "schema v2にはpreviewParityが必要です"
                )
            }
        case 3:
            guard manifest.previewParity != nil else {
                throw CalibrationManifestError.invalid(
                    "schema v3にはpreviewParityが必要です"
                )
            }
            guard manifest.canonicalSettleGate == nil else {
                throw CalibrationManifestError.invalid(
                    "schema v3にはcanonicalSettleGateを指定できません"
                )
            }
        case 4:
            guard manifest.previewParity != nil,
                  manifest.canonicalSettleGate != nil
            else {
                throw CalibrationManifestError.invalid(
                    "schema v4にはpreviewParityとcanonicalSettleGateが必要です"
                )
            }
        default:
            preconditionFailure("schema version guardとswitchが不整合です")
        }
        try requireText(manifest.suiteID, field: "suiteID")
        try requireText(manifest.description, field: "description")
        for (field, value) in [
            ("expectedEnvironment.macOSVersion", manifest.expectedEnvironment.macOSVersion),
            ("expectedEnvironment.macOSBuild", manifest.expectedEnvironment.macOSBuild),
            ("expectedEnvironment.architecture", manifest.expectedEnvironment.architecture),
            ("expectedEnvironment.hardwareModel", manifest.expectedEnvironment.hardwareModel),
            ("expectedEnvironment.metalDevice", manifest.expectedEnvironment.metalDevice),
            ("expectedEnvironment.rawDecoderBackend", manifest.expectedEnvironment.rawDecoderBackend)
        ] {
            try requireText(value, field: field)
        }
        let fingerprint = manifest.processing.fingerprint
        let currentFingerprint = PhotoCoreProcessingFingerprint.current
        let sharedFingerprintMatches = fingerprint.basicTone == currentFingerprint.basicTone
            && fingerprint.toneCurve == currentFingerprint.toneCurve
            && fingerprint.colorMixer == currentFingerprint.colorMixer
            && fingerprint.outputTransform == currentFingerprint.outputTransform
        let fingerprintMatches: Bool
        if manifest.schemaVersion == 1 {
            fingerprintMatches = sharedFingerprintMatches
                && fingerprint.rawDecode
                    == PhotoCoreProcessingFingerprint.legacyRawDecodeIdentifier
                && fingerprint.renderPipeline
                    == RenderEngine.legacyProcessingIdentifier
        } else if manifest.schemaVersion <= 3 {
            fingerprintMatches = fingerprint
                == PhotoCoreProcessingFingerprint.legacyCurrentRawDecode
        } else {
            fingerprintMatches = fingerprint == currentFingerprint
        }
        guard fingerprintMatches else {
            throw CalibrationManifestError.invalid(
                "processing fingerprintがschemaのPhotoCore契約と一致しません"
            )
        }
        guard manifest.comparison.maxDimension == 1_500,
              manifest.comparison.outputFormat == "RGBA16 sRGB TIFF",
              manifest.comparison.outputColorSpace == "sRGB IEC61966-2.1",
              manifest.comparison.bitsPerChannel == 16,
              manifest.comparison.referenceSoftware == "Adobe Lightroom 9.3 (Macintosh)",
              manifest.comparison.referenceWhiteBalance == "As Shot",
              manifest.comparison.orientationPolicy
                  == "Photo Bench normalizes source orientation before comparison",
              manifest.comparison.cropPolicy
                  == "full frame; no analyzer-side resize or registration"
        else {
            throw CalibrationManifestError.invalid(
                "schema v1 comparison contractが固定条件と一致しません"
            )
        }
        let expectedRAWProfile = RAWCalibrationProfile.panasonicDCS5Lightroom93
        guard manifest.rawProfile.id == expectedRAWProfile.id,
              manifest.rawProfile.boostAmount.isFinite,
              manifest.rawProfile.extendedDynamicRangeAmount.isFinite,
              abs(
                  manifest.rawProfile.boostAmount
                      - Double(expectedRAWProfile.configuration.boostAmount)
              ) < 0.000_001,
              abs(
                  manifest.rawProfile.extendedDynamicRangeAmount
                      - Double(expectedRAWProfile.configuration.extendedDynamicRangeAmount)
              ) < 0.000_001
        else {
            throw CalibrationManifestError.invalid(
                "schema v1 rawProfileが現行DC-S5 profileと一致しません"
            )
        }
        guard manifest.diagnostics.boostAmounts == requiredBoostAmounts,
              manifest.diagnostics.extendedDynamicRangeAmounts == requiredEDRAmounts
        else {
            throw CalibrationManifestError.invalid(
                "schema v1 diagnostics matrixが固定条件と一致しません"
            )
        }
        try validateHash(manifest.preset.file.sha256, field: "preset.file.sha256")
        try validateRelativePath(manifest.preset.file.path)
        try requireText(manifest.preset.uuid, field: "preset.uuid")
        try requireText(manifest.preset.cameraRawVersion, field: "preset.cameraRawVersion")
        try requireText(manifest.preset.processVersion, field: "preset.processVersion")

        let legacyIDs = Set(manifest.legacyCandidates.map(\.id))
        guard legacyIDs == requiredLegacyCandidateIDs,
              legacyIDs.count == manifest.legacyCandidates.count
        else {
            throw CalibrationManifestError.invalid(
                "legacyCandidatesはv1必須4段を重複なく含める必要があります"
            )
        }
        let stageIDs = Set(manifest.stageMatrix.map(\.id))
        guard stageIDs == requiredStageIDs,
              stageIDs.count == manifest.stageMatrix.count
        else {
            throw CalibrationManifestError.invalid(
                "stageMatrixはv1必須12段を重複なく含める必要があります"
            )
        }
        let candidates = manifest.legacyCandidates + manifest.stageMatrix
        try validateCandidateLabels(candidates)
        for candidate in manifest.legacyCandidates {
            guard let expected = requiredLegacyCandidates[candidate.id],
                  candidate.rawLabel == expected.raw,
                  candidate.lightroomInputLabel == expected.lightroom
            else {
                throw CalibrationManifestError.invalid(
                    "schema v1 legacy candidate labelが固定条件と一致しません: \(candidate.id)"
                )
            }
        }
        for candidate in manifest.stageMatrix {
            guard candidate.rawLabel == "xmp-stage-\(candidate.id)",
                  candidate.lightroomInputLabel == "lr-input-xmp-stage-\(candidate.id)"
            else {
                throw CalibrationManifestError.invalid(
                    "schema v1 stage candidate labelが固定条件と一致しません: \(candidate.id)"
                )
            }
        }

        guard !manifest.scenes.isEmpty else {
            throw CalibrationManifestError.invalid("scenesが空です")
        }
        let sceneIDs = Set(manifest.scenes.map(\.id))
        guard sceneIDs.count == manifest.scenes.count else {
            throw CalibrationManifestError.invalid("scene idが重複しています")
        }
        var fixturePaths: [String] = [manifest.preset.file.path]
        for scene in manifest.scenes {
            try requireSafeIdentifier(scene.id, field: "scene.id")
            try requireText(scene.sceneGroup, field: "scene.sceneGroup")
            guard ["train", "holdout", "development"].contains(scene.fold) else {
                throw CalibrationManifestError.invalid(
                    "scene \(scene.id) のfoldはtrain/holdout/developmentのいずれかです"
                )
            }
            try requireText(scene.lighting, field: "scene.lighting")
            guard scene.capture.iso > 0,
                  scene.capture.fNumber > 0,
                  scene.capture.width > 0,
                  scene.capture.height > 0,
                  scene.capture.rawBitsPerSample > 0
            else {
                throw CalibrationManifestError.invalid(
                    "scene \(scene.id) のcapture metadataが不正です"
                )
            }
            for fixture in [scene.raw, scene.lightroomBefore, scene.lightroomAfter] {
                try validateRelativePath(fixture.path)
                try validateHash(fixture.sha256, field: fixture.path)
                fixturePaths.append(fixture.path)
            }
        }
        guard Set(fixturePaths).count == fixturePaths.count else {
            throw CalibrationManifestError.invalid("入力fixture pathが重複しています")
        }
        let benchmarkSceneExists = manifest.scenes.contains {
            $0.id == manifest.benchmark.sceneID
        }
        guard benchmarkSceneExists else {
            throw CalibrationManifestError.invalid("benchmark.sceneIDがscenesにありません")
        }
        guard manifest.benchmark.previewMaxDimension > 0,
              (0...1).contains(manifest.benchmark.jpegQuality),
              manifest.benchmark.warmupIterations > 0,
              manifest.benchmark.measuredIterations >= 3,
              manifest.benchmark.processFreshIterations >= 20,
              manifest.benchmark.thresholdsMilliseconds.processFreshLowResolutionPreviewP95.isFinite,
              manifest.benchmark.thresholdsMilliseconds.warmSliderEngineP95.isFinite,
              manifest.benchmark.thresholdsMilliseconds.warmHighQualityPreviewP95.isFinite,
              manifest.benchmark.thresholdsMilliseconds.fullResolutionJPEGExportP95.isFinite,
              manifest.benchmark.thresholdsMilliseconds.processFreshLowResolutionPreviewP95 > 0,
              manifest.benchmark.thresholdsMilliseconds.warmSliderEngineP95 > 0,
              manifest.benchmark.thresholdsMilliseconds.warmHighQualityPreviewP95 > 0,
              manifest.benchmark.thresholdsMilliseconds.fullResolutionJPEGExportP95 > 0
        else {
            throw CalibrationManifestError.invalid("benchmark設定が不正です")
        }
        try validatePreviewParity(manifest)
        try validateCanonicalSettle(manifest)
        let artifactPaths = expectedArtifactRelativePaths(for: manifest)
        // The supported macOS deployment may use a case-insensitive volume.
        // Reject case-only aliases conservatively even on a case-sensitive one.
        let comparableArtifactPaths = artifactPaths.map { $0.lowercased() }
        guard Set(comparableArtifactPaths).count == comparableArtifactPaths.count else {
            throw CalibrationManifestError.invalid(
                "校正artifact output pathがsceneとlabelの合成後に重複しています"
            )
        }
        let expectedQualityRoutes: [String: (basic: String, full: String)] = [
            "raw": ("xmp-basic", "xmp-full-current"),
            "lr-input": ("lr-input-xmp-basic", "lr-input-xmp-full-current")
        ]
        guard manifest.qualityGate.routes.count == expectedQualityRoutes.count,
              Set(manifest.qualityGate.routes.map(\.id)) == Set(expectedQualityRoutes.keys)
        else {
            throw CalibrationManifestError.invalid("qualityGate.routesはRAW/LR-inputの2経路が必要です")
        }
        let legacyLabels = Set(
            manifest.legacyCandidates.flatMap { [$0.rawLabel, $0.lightroomInputLabel] }
        )
        for route in manifest.qualityGate.routes {
            try requireSafeIdentifier(route.id, field: "qualityGate.route.id")
            guard let expected = expectedQualityRoutes[route.id],
                  route.basicLabel == expected.basic,
                  route.fullLabel == expected.full,
                  legacyLabels.contains(route.basicLabel),
                  legacyLabels.contains(route.fullLabel)
            else {
                throw CalibrationManifestError.invalid(
                    "qualityGate \(route.id) が未定義候補を参照しています"
                )
            }
        }
        let thresholds = manifest.qualityGate
        guard thresholds.meanDeltaEMaximumIncrease.isFinite,
              thresholds.meanEVAbsoluteErrorMaximumIncrease.isFinite,
              thresholds.newSharedPlateauMaximumArea.isFinite,
              thresholds.meanDeltaEMaximumIncrease >= 0,
              thresholds.meanEVAbsoluteErrorMaximumIncrease >= 0,
              thresholds.newSharedPlateauMaximumArea >= 0
        else {
            throw CalibrationManifestError.invalid("qualityGate閾値は0以上が必要です")
        }
        guard Set(manifest.processing.sourceFiles).count == manifest.processing.sourceFiles.count else {
            throw CalibrationManifestError.invalid("processing.sourceFilesが重複しています")
        }
        for path in manifest.processing.sourceFiles {
            try validateRelativePath(path)
        }
        guard !manifest.processing.sourceFiles.isEmpty else {
            throw CalibrationManifestError.invalid("processing.sourceFilesが空です")
        }
    }

    public static func verifyFixtureFiles(
        _ manifest: CalibrationManifest,
        root: URL
    ) throws -> [VerifiedFile] {
        var fixtures: [(role: String, fixture: HashedFixture)] = [
            ("preset", manifest.preset.file)
        ]
        for scene in manifest.scenes {
            fixtures.append(("\(scene.id).raw", scene.raw))
            fixtures.append(("\(scene.id).lightroomBefore", scene.lightroomBefore))
            fixtures.append(("\(scene.id).lightroomAfter", scene.lightroomAfter))
        }
        return try fixtures.map { item in
            let url = try resolve(item.fixture.path, inside: root)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CalibrationManifestError.missingFile(item.fixture.path)
            }
            let actual = try SHA256Digest.file(url)
            guard actual == item.fixture.sha256.lowercased() else {
                throw CalibrationManifestError.hashMismatch(
                    path: item.fixture.path,
                    expected: item.fixture.sha256,
                    actual: actual
                )
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return VerifiedFile(
                role: item.role,
                path: item.fixture.path,
                sha256: actual,
                byteCount: UInt64(values.fileSize ?? 0)
            )
        }
    }

    public static func sourceFingerprint(
        _ sourceFiles: [String],
        root: URL
    ) throws -> (sha256: String, files: [VerifiedFile]) {
        let files = try sourceFiles.sorted().map { path in
            let url = try resolve(path, inside: root)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CalibrationManifestError.missingFile(path)
            }
            let digest = try SHA256Digest.file(url)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return VerifiedFile(
                role: "implementationSource",
                path: path,
                sha256: digest,
                byteCount: UInt64(values.fileSize ?? 0)
            )
        }
        let canonical = files.map { "\($0.path)\u{0}\($0.sha256)" }.joined(separator: "\n")
        return (SHA256Digest.data(Data(canonical.utf8)), files)
    }

    public static func resolve(_ relativePath: String, inside root: URL) throws -> URL {
        try validateRelativePath(relativePath)
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = normalizedRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = normalizedRoot.path.hasSuffix("/")
            ? normalizedRoot.path
            : normalizedRoot.path + "/"
        guard candidate.path == normalizedRoot.path || candidate.path.hasPrefix(prefix) else {
            throw CalibrationManifestError.pathEscapesRoot(relativePath)
        }
        return candidate
    }

    /// Creates a deterministic tool-output directory without following any
    /// symbolic-link component. Calibration fixtures may be read through the
    /// canonical resolver above, but generated files must never be redirected
    /// outside the project (or to another in-project location) by a pre-planted
    /// `.photobench` symlink.
    public static func prepareOutputDirectory(
        _ relativePath: String,
        inside root: URL
    ) throws -> URL {
        try validateRelativePath(relativePath)
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        var current = normalizedRoot
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if let attributes = try? fileManager.attributesOfItem(atPath: current.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      current.standardizedFileURL.resolvingSymlinksInPath().path
                          == current.standardizedFileURL.path
                else {
                    throw CalibrationManifestError.invalid(
                        "出力directoryにsymlinkまたは非directoryがあります: \(current.path)"
                    )
                }
            } else {
                do {
                    try fileManager.createDirectory(
                        at: current,
                        withIntermediateDirectories: false
                    )
                } catch {
                    throw CalibrationManifestError.invalid(
                        "出力directoryを安全に作成できません: \(current.path)"
                    )
                }
            }
            try requireContained(current, inside: normalizedRoot)
        }
        return current
    }

    /// Returns a file URL only when its parent is the already-verified output
    /// directory and the destination is absent or an ordinary regular file.
    /// Existing symlinks/directories are rejected before any encoder can write.
    public static func prepareOutputFile(
        named fileName: String,
        in directory: URL,
        inside root: URL
    ) throws -> URL {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\0")
        else {
            throw CalibrationManifestError.pathEscapesRoot(fileName)
        }
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedDirectory = directory.standardizedFileURL
        try requireContained(normalizedDirectory, inside: normalizedRoot)
        guard normalizedDirectory.resolvingSymlinksInPath().path == normalizedDirectory.path,
              let directoryAttributes = try? FileManager.default.attributesOfItem(
                  atPath: normalizedDirectory.path
              ),
              directoryAttributes[.type] as? FileAttributeType == .typeDirectory
        else {
            throw CalibrationManifestError.invalid(
                "出力先の親directoryが安全ではありません: \(directory.path)"
            )
        }
        let destination = normalizedDirectory.appendingPathComponent(fileName)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           attributes[.type] as? FileAttributeType != .typeRegular {
            throw CalibrationManifestError.invalid(
                "出力先にsymlinkまたは非regular fileがあります: \(destination.path)"
            )
        }
        try requireContained(destination, inside: normalizedRoot)
        return destination
    }

    private static func requireContained(_ url: URL, inside root: URL) throws {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = normalizedRoot.path.hasSuffix("/")
            ? normalizedRoot.path
            : normalizedRoot.path + "/"
        guard resolved.path == normalizedRoot.path || resolved.path.hasPrefix(prefix) else {
            throw CalibrationManifestError.pathEscapesRoot(url.path)
        }
    }

    private static func validateExpectedEnvironment(_ expected: ExpectedEnvironment) throws {
        let runtime = RuntimeProvenance.capture(executableURL: nil)
        let checks: [(String, String, String)] = [
            ("macOSVersion", expected.macOSVersion, runtime.macOSVersion),
            ("macOSBuild", expected.macOSBuild, runtime.macOSBuild),
            ("architecture", expected.architecture, runtime.architecture),
            ("hardwareModel", expected.hardwareModel, runtime.hardwareModel),
            ("metalDevice", expected.metalDevice, runtime.metalDevice?.name ?? "none")
        ]
        let mismatches = checks.compactMap { field, wanted, actual in
            wanted == actual ? nil : "\(field): expected=\(wanted), actual=\(actual)"
        }
        guard mismatches.isEmpty else {
            throw CalibrationManifestError.invalid(
                "実行環境が固定条件と一致しません（\(mismatches.joined(separator: ", "))）"
            )
        }
    }

    private static func validateCandidateLabels(
        _ candidates: [CalibrationCandidateDefinition]
    ) throws {
        for candidate in candidates {
            try requireSafeIdentifier(candidate.id, field: "candidate.id")
            try requireSafeIdentifier(candidate.rawLabel, field: "candidate.rawLabel")
            try requireSafeIdentifier(
                candidate.lightroomInputLabel,
                field: "candidate.lightroomInputLabel"
            )
        }
        let raw = candidates.map(\.rawLabel)
        let lightroom = candidates.map(\.lightroomInputLabel)
        guard Set(raw).count == raw.count,
              Set(lightroom).count == lightroom.count,
              Set(raw).isDisjoint(with: Set(lightroom))
        else {
            throw CalibrationManifestError.invalid("candidate output labelが重複しています")
        }
    }

    /// Expands every TIFF artifact path with the same directory, scene, label,
    /// and three-digit diagnostic naming rules used by PhotoBenchCalibration.
    public static func expectedArtifactRelativePaths(
        for manifest: CalibrationManifest
    ) -> [String] {
        var paths: [String] = []
        let candidates = manifest.legacyCandidates + manifest.stageMatrix
        for scene in manifest.scenes {
            paths.append(
                ".photobench/calibration/references/\(scene.id)-lightroom-before.tif"
            )
            paths.append(
                ".photobench/calibration/references/\(scene.id)-lightroom-after.tif"
            )
            for amount in manifest.diagnostics.boostAmounts {
                let label = threeDigitDiagnosticLabel(amount)
                paths.append(
                    ".photobench/calibration/renders/\(scene.id)-boost-\(label).tif"
                )
            }
            for amount in manifest.diagnostics.extendedDynamicRangeAmounts {
                let label = threeDigitDiagnosticLabel(amount)
                for candidateLabel in [
                    "edr-\(label)",
                    "xmp-basic-edr-\(label)",
                    "xmp-full-edr-\(label)"
                ] {
                    paths.append(
                        ".photobench/calibration/renders/\(scene.id)-\(candidateLabel).tif"
                    )
                }
            }
            for candidate in candidates {
                for label in [candidate.rawLabel, candidate.lightroomInputLabel] {
                    paths.append(
                        ".photobench/calibration/renders/\(scene.id)-\(label).tif"
                    )
                }
            }
            if let previewParity = manifest.previewParity {
                switch manifest.schemaVersion {
                case 2:
                    for stageID in previewParity.settingsStageIDs {
                        for decodeRoute in ["full-decode", "scaled-decode"] {
                            paths.append(
                                ".photobench/calibration/renders/\(scene.id)-preview-parity-\(stageID)-\(decodeRoute).tif"
                            )
                        }
                    }
                case 3, 4:
                    guard let outputMaxDimension = previewParity.outputMaxDimension,
                          let candidateDimensions = previewParity.candidateDecodeMaximumDimensions
                    else {
                        continue
                    }
                    for stageID in previewParity.settingsStageIDs {
                        paths.append(
                            ".photobench/calibration/renders/\(scene.id)-preview-parity-\(stageID)-full-decode-to-\(outputMaxDimension).tif"
                        )
                        for candidateDimension in candidateDimensions {
                            paths.append(
                                ".photobench/calibration/renders/\(scene.id)-preview-parity-\(stageID)-decode-\(candidateDimension)-to-\(outputMaxDimension).tif"
                            )
                        }
                    }
                default:
                    break
                }
            }
        }
        return paths
    }

    private static func threeDigitDiagnosticLabel(_ value: Double) -> String {
        String(format: "%03d", Int((value * 100).rounded()))
    }

    private static func validatePreviewParity(_ manifest: CalibrationManifest) throws {
        guard let previewParity = manifest.previewParity else {
            return
        }
        guard previewParity.settingsStageIDs == requiredPreviewParitySettings else {
            throw CalibrationManifestError.invalid(
                "previewParity.settingsStageIDsはneutral/basic-legacy/full-currentの固定順が必要です"
            )
        }
        guard previewParity.baselineDecodeIntent == "full-resolution",
              previewParity.candidateDecodeIntent == "interactive-preview"
        else {
            throw CalibrationManifestError.invalid(
                "previewParity decode intentが固定契約と一致しません"
            )
        }

        let thresholds = previewParity.thresholds
        guard thresholds.meanDeltaEMaximum.isFinite,
              thresholds.meanEVAbsoluteDriftMaximum.isFinite,
              (0...1).contains(thresholds.meanDeltaEMaximum),
              (0...0.02).contains(thresholds.meanEVAbsoluteDriftMaximum)
        else {
            throw CalibrationManifestError.invalid(
                "previewParity共通閾値が固定上限を超えるか不正です"
            )
        }

        switch manifest.schemaVersion {
        case 2:
            guard let maxDimension = previewParity.maxDimension,
                  maxDimension == manifest.benchmark.previewMaxDimension,
                  previewParity.outputMaxDimension == nil,
                  previewParity.candidateDecodeMaximumDimensions == nil,
                  previewParity.plateauSpatialTolerance == nil,
                  thresholds.blurredDeltaE2000P95Maximum == nil,
                  let newSharedPlateauMaximumArea = thresholds.newSharedPlateauMaximumArea,
                  newSharedPlateauMaximumArea.isFinite,
                  (0...0.000_1).contains(newSharedPlateauMaximumArea),
                  thresholds.netSharedPlateauAreaIncreaseMaximum == nil,
                  thresholds.spatiallyDistinctNewSharedPlateauMaximumArea == nil
            else {
                throw CalibrationManifestError.invalid(
                    "schema v2 previewParityが単一2560px decode契約と一致しません"
                )
            }
        case 3, 4:
            guard previewParity.maxDimension == nil,
                  let outputMaxDimension = previewParity.outputMaxDimension,
                  outputMaxDimension == 2_560,
                  outputMaxDimension == manifest.benchmark.previewMaxDimension,
                  let candidateDimensions = previewParity.candidateDecodeMaximumDimensions,
                  candidateDimensions == [3_072, 3_840],
                  Set(candidateDimensions).count == candidateDimensions.count,
                  candidateDimensions.allSatisfy({ $0 > outputMaxDimension }),
                  manifest.scenes.allSatisfy({ scene in
                      candidateDimensions.allSatisfy({
                          $0 <= max(scene.capture.width, scene.capture.height)
                      })
                  }),
                  let spatialTolerance = previewParity.plateauSpatialTolerance,
                  spatialTolerance.radiusPixels == 1,
                  spatialTolerance.structuringElement == "square-3x3",
                  thresholds.newSharedPlateauMaximumArea == nil,
                  let blurredDeltaE2000P95Maximum = thresholds.blurredDeltaE2000P95Maximum,
                  blurredDeltaE2000P95Maximum.isFinite,
                  (0...2).contains(blurredDeltaE2000P95Maximum),
                  let netAreaMaximum = thresholds.netSharedPlateauAreaIncreaseMaximum,
                  netAreaMaximum.isFinite,
                  (0...0.000_1).contains(netAreaMaximum),
                  let spatiallyDistinctMaximum =
                      thresholds.spatiallyDistinctNewSharedPlateauMaximumArea,
                  spatiallyDistinctMaximum.isFinite,
                  (0...0.000_1).contains(spatiallyDistinctMaximum)
            else {
                throw CalibrationManifestError.invalid(
                    "schema v3/v4 previewParityが二段decode・Lanczos出力・plateau空間許容契約と一致しません"
                )
            }
        default:
            throw CalibrationManifestError.invalid(
                "previewParityを指定できるのはschema v2-v4だけです"
            )
        }
    }

    private static func validateCanonicalSettle(
        _ manifest: CalibrationManifest
    ) throws {
        guard let gate = manifest.canonicalSettleGate else {
            guard manifest.schemaVersion < 4 else {
                throw CalibrationManifestError.invalid(
                    "schema v4にはcanonicalSettleGateが必要です"
                )
            }
            return
        }
        guard manifest.schemaVersion == 4 else {
            throw CalibrationManifestError.invalid(
                "canonicalSettleGateを指定できるのはschema v4だけです"
            )
        }
        let exactCompleteClipThreshold = 1 - 0.5 / 65_535.0
        guard gate.outputMaxDimension == 2_560,
              gate.outputMaxDimension == manifest.previewParity?.outputMaxDimension,
              gate.downsamplingFilter == "CILanczosScaleTransform",
              gate.inputAspectRatio == 1,
              gate.workingColorSpace == "extended-linear-sRGB",
              gate.outputTransformPlacement == "after-downsampling",
              gate.baselineStageID == "basic-legacy",
              gate.candidateStageID == "full-current",
              abs(
                  gate.thresholds.completeClipNormalizedMinimum
                      - exactCompleteClipThreshold
              ) < 0.000_000_000_001,
              gate.thresholds.nearClipNormalizedMinimum == 0.999,
              gate.thresholds.completeClipMaximumPixelCountIncrease == 0,
              gate.thresholds.nearClipMaximumPixelCountIncrease == 0,
              gate.thresholds.newSharedPlateauMaximumArea == 0.0005
        else {
            throw CalibrationManifestError.invalid(
                "schema v4 canonicalSettleGateが固定production契約と一致しません"
            )
        }
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !NSString(string: path).isAbsolutePath,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !path.contains("\0")
        else {
            throw CalibrationManifestError.pathEscapesRoot(path)
        }
    }

    private static func validateHash(_ value: String, field: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.count == 64,
              value == value.lowercased(),
              value.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw CalibrationManifestError.invalid("\(field)はlowercase SHA-256ではありません")
        }
    }

    private static func requireText(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalibrationManifestError.invalid("\(field)が空です")
        }
    }

    private static func requireSafeIdentifier(_ value: String, field: String) throws {
        try requireText(value, field: field)
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
        )
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CalibrationManifestError.invalid("\(field)に未対応文字があります: \(value)")
        }
    }
}

public enum SHA256Digest {
    public static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func data(_ data: Data) -> String {
        hex(CryptoKit.SHA256.hash(data: data))
    }

    public static func encodable<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return data(try encoder.encode(value))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

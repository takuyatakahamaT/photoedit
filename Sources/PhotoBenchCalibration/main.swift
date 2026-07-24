import CoreImage
import Foundation
import ImageIO
import PhotoBenchCalibrationSupport
import PhotoCore

private struct CalibrationArguments {
    let root: URL
    let manifestURL: URL?

    init(_ arguments: [String]) throws {
        var rootPath: String?
        var manifestPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--manifest" {
                guard index + 1 < arguments.count else {
                    throw CalibrationManifestError.invalid("--manifestにpathが必要です")
                }
                manifestPath = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--") {
                throw CalibrationManifestError.invalid("未対応の引数です: \(argument)")
            } else if rootPath == nil {
                rootPath = argument
                index += 1
            } else {
                throw CalibrationManifestError.invalid("余分な引数です: \(argument)")
            }
        }
        root = URL(
            fileURLWithPath: rootPath ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        if let manifestPath {
            manifestURL = NSString(string: manifestPath).isAbsolutePath
                ? URL(fileURLWithPath: manifestPath)
                : root.appendingPathComponent(manifestPath)
        } else {
            manifestURL = nil
        }
    }
}

private struct PreviewParityCandidatePlan {
    let decodeMaximumDimension: Int
    let artifactSuffix: String
    let decodeRoute: String
}

private struct PreviewParityRenderPlan {
    let outputMaxDimension: Int
    let baselineArtifactSuffix: String
    let candidates: [PreviewParityCandidatePlan]
    let downsamplingFilter: TIFFDownsamplingFilter
}

@main
enum PhotoBenchCalibration {
    static func main() throws {
        let arguments = try CalibrationArguments(Array(CommandLine.arguments.dropFirst()))
        let loaded = try CalibrationManifestLoader.load(
            root: arguments.root,
            manifestURL: arguments.manifestURL
        )
        let manifest = loaded.manifest
        let presetURL = try loaded.resolve(manifest.preset.file.path)
        let preset = try XMPPresetParser.parse(url: presetURL)
        try validatePreset(preset, manifest: manifest)
        try validateRAWProfile(manifest.rawProfile)

        let outputRoot = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/calibration",
            inside: loaded.root
        )
        let renderDirectory = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/calibration/renders",
            inside: loaded.root
        )
        let referenceDirectory = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/calibration/references",
            inside: loaded.root
        )
        let runsDirectory = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/calibration/runs",
            inside: loaded.root
        )
        let runManifestURL = try CalibrationManifestLoader.prepareOutputFile(
            named: "run-manifest.json",
            in: outputRoot,
            inside: loaded.root
        )
        let runID = UUID().uuidString.lowercased()
        let archivedRunManifestURL = try CalibrationManifestLoader.prepareOutputFile(
            named: "\(runID).json",
            in: runsDirectory,
            inside: loaded.root
        )
        let startedAt = ISO8601Timestamp.now()
        let runtime = try RuntimeProvenance.captureCurrentExecutable()
        let source = try CalibrationManifestLoader.sourceFingerprint(
            manifest.processing.sourceFiles,
            root: loaded.root
        )
        let manifestReference = ManifestRunReference(
            path: relativePath(loaded.manifestURL, root: loaded.root),
            sha256: loaded.manifestSHA256,
            suiteID: manifest.suiteID
        )
        let running = CalibrationRunManifest(
            status: "running",
            runID: runID,
            startedAtUTC: startedAt,
            manifest: manifestReference,
            runtime: runtime,
            processing: .current,
            sourceFingerprintSHA256: source.sha256,
            sourceFiles: source.files,
            verifiedInputs: loaded.verifiedInputs
        )
        try AtomicJSONWriter.write(running, to: runManifestURL)
        try AtomicJSONWriter.write(running, to: archivedRunManifestURL)

        let renderer = RenderEngine()
        var decodes: [CalibrationDecodeRecord] = []
        var artifacts: [CalibrationArtifact] = []
        var headroomRecords: [EDRHeadroomRecord] = []
        let neutralHash = try SHA256Digest.encodable(EditSettings.neutral)

        print("Calibration suite: \(manifest.suiteID)")
        print("Manifest SHA-256: \(loaded.manifestSHA256)")
        print("Output: \(outputRoot.path)")

        for scene in manifest.scenes {
            let beforeURL = try loaded.resolve(scene.lightroomBefore.path)
            let afterURL = try loaded.resolve(scene.lightroomAfter.path)
            for (label, sourceURL) in [("before", beforeURL), ("after", afterURL)] {
                let decoded = try CoreImageDecoder().decode(url: sourceURL)
                try validateLightroomReference(decoded, scene: scene, manifest: manifest)
                let destination = try CalibrationManifestLoader.prepareOutputFile(
                    named: "\(scene.id)-lightroom-\(label).tif",
                    in: referenceDirectory,
                    inside: loaded.root
                )
                let milliseconds = try renderer.exportTIFF(
                    decoded: decoded,
                    settings: .neutral,
                    destination: destination,
                    maxDimension: CGFloat(manifest.comparison.maxDimension)
                )
                let artifact = try makeArtifact(
                    role: "normalized-reference-\(label)",
                    sceneID: scene.id,
                    route: nil,
                    candidateGroup: nil,
                    candidateID: nil,
                    label: nil,
                    destination: destination,
                    root: loaded.root,
                    milliseconds: milliseconds,
                    settings: .neutral,
                    settingsSHA256: neutralHash
                )
                artifacts.append(artifact)
                printTiming(artifact)
            }
        }

        for scene in manifest.scenes {
            let rawURL = try loaded.resolve(scene.raw.path)
            for amount in manifest.diagnostics.boostAmounts {
                let configuration = RAWDecodeConfiguration(boostAmount: Float(amount))
                let decoded = try CoreImageDecoder(rawConfiguration: configuration).decode(url: rawURL)
                try validateRAW(decoded, scene: scene, manifest: manifest, requireProfile: false)
                let label = threeDigitLabel(amount)
                let destination = try CalibrationManifestLoader.prepareOutputFile(
                    named: "\(scene.id)-boost-\(label).tif",
                    in: renderDirectory,
                    inside: loaded.root
                )
                let milliseconds = try renderer.exportTIFF(
                    decoded: decoded,
                    settings: .neutral,
                    destination: destination,
                    maxDimension: CGFloat(manifest.comparison.maxDimension)
                )
                let artifact = try makeArtifact(
                    role: "diagnostic-candidate",
                    sceneID: scene.id,
                    route: "raw",
                    candidateGroup: "boost",
                    candidateID: label,
                    label: "boost-\(label)",
                    destination: destination,
                    root: loaded.root,
                    milliseconds: milliseconds,
                    settings: .neutral,
                    settingsSHA256: neutralHash
                )
                artifacts.append(artifact)
                printTiming(artifact)
            }
        }

        let basicSettings = try CalibrationStageFactory.settings(
            for: "basic-legacy",
            preset: preset
        )
        let fullSettings = try CalibrationStageFactory.settings(
            for: "full-current",
            preset: preset
        )
        let basicHash = try SHA256Digest.encodable(basicSettings)
        let fullHash = try SHA256Digest.encodable(fullSettings)
        for scene in manifest.scenes {
            let rawURL = try loaded.resolve(scene.raw.path)
            for amount in manifest.diagnostics.extendedDynamicRangeAmounts {
                let configuration = RAWDecodeConfiguration(
                    boostAmount: Float(manifest.rawProfile.boostAmount),
                    extendedDynamicRangeAmount: Float(amount)
                )
                let decoded = try CoreImageDecoder(rawConfiguration: configuration).decode(url: rawURL)
                try validateRAW(decoded, scene: scene, manifest: manifest, requireProfile: false)
                let edrLabel = threeDigitLabel(amount)
                let headroom = try extendedHeadroomSummary(decoded: decoded)
                headroomRecords.append(
                    EDRHeadroomRecord(
                        sceneID: scene.id,
                        amount: amount,
                        maximumChannel: Double(headroom.maximumChannel),
                        extendedChannelPixelFraction: headroom.extendedChannelPixelFraction,
                        maximumLuminance: Double(headroom.maximumLuminance),
                        extendedLuminancePixelFraction: headroom.extendedLuminancePixelFraction
                    )
                )
                print(
                    "\(scene.id)-edr-\(edrLabel) RAW headroom: "
                        + "max channel=\(String(format: "%.5f", headroom.maximumChannel)), "
                        + "channel >1=\(String(format: "%.5f%%", headroom.extendedChannelPixelFraction * 100)), "
                        + "max Y=\(String(format: "%.5f", headroom.maximumLuminance)), "
                        + "Y >1=\(String(format: "%.5f%%", headroom.extendedLuminancePixelFraction * 100))"
                )
                let candidates: [(id: String, label: String, settings: EditSettings, hash: String)] = [
                    ("neutral", "edr-\(edrLabel)", .neutral, neutralHash),
                    ("basic-legacy", "xmp-basic-edr-\(edrLabel)", basicSettings, basicHash),
                    ("full-current", "xmp-full-edr-\(edrLabel)", fullSettings, fullHash)
                ]
                for candidate in candidates {
                    let destination = try CalibrationManifestLoader.prepareOutputFile(
                        named: "\(scene.id)-\(candidate.label).tif",
                        in: renderDirectory,
                        inside: loaded.root
                    )
                    let milliseconds = try renderer.exportTIFF(
                        decoded: decoded,
                        settings: candidate.settings,
                        destination: destination,
                        maxDimension: CGFloat(manifest.comparison.maxDimension)
                    )
                    let artifact = try makeArtifact(
                        role: "diagnostic-candidate",
                        sceneID: scene.id,
                        route: "raw",
                        candidateGroup: "edr",
                        candidateID: candidate.id,
                        label: candidate.label,
                        destination: destination,
                        root: loaded.root,
                        milliseconds: milliseconds,
                        settings: candidate.settings,
                        settingsSHA256: candidate.hash
                    )
                    artifacts.append(artifact)
                    printTiming(artifact)
                }
            }
        }

        let candidateGroups: [(name: String, definitions: [CalibrationCandidateDefinition])] = [
            ("legacy", manifest.legacyCandidates),
            ("stage-matrix", manifest.stageMatrix)
        ]
        for scene in manifest.scenes {
            let rawURL = try loaded.resolve(scene.raw.path)
            let beforeURL = try loaded.resolve(scene.lightroomBefore.path)
            let rawDecoder = CoreImageDecoder()
            let rawDecoded = try rawDecoder.decode(url: rawURL, intent: .fullResolution)
            try validateRAW(rawDecoded, scene: scene, manifest: manifest, requireProfile: true)
            decodes.append(decodeRecord(sceneID: scene.id, route: "raw", decoded: rawDecoded))

            let lightroomDecoded = try CoreImageDecoder().decode(url: beforeURL)
            try validateLightroomReference(lightroomDecoded, scene: scene, manifest: manifest)
            decodes.append(
                decodeRecord(sceneID: scene.id, route: "lr-input", decoded: lightroomDecoded)
            )

            if let previewParity = manifest.previewParity {
                let parityPlan = try previewParityRenderPlan(
                    manifest: manifest,
                    specification: previewParity
                )
                let parityStages = try previewParity.settingsStageIDs.map { stageID in
                    let settings = try CalibrationStageFactory.settings(
                        for: stageID,
                        preset: preset
                    )
                    return (
                        stageID: stageID,
                        settings: settings,
                        settingsHash: try SHA256Digest.encodable(settings)
                    )
                }
                decodes.append(
                    decodeRecord(
                        sceneID: scene.id,
                        route: "preview-parity-full-resolution",
                        decoded: rawDecoded
                    )
                )
                for stage in parityStages {
                    let artifact = try renderPreviewParityArtifact(
                        decoded: rawDecoded,
                        sceneID: scene.id,
                        stageID: stage.stageID,
                        suffix: parityPlan.baselineArtifactSuffix,
                        role: "preview-parity-baseline",
                        route: "preview-parity-full-resolution",
                        settings: stage.settings,
                        settingsHash: stage.settingsHash,
                        outputMaxDimension: parityPlan.outputMaxDimension,
                        downsamplingFilter: parityPlan.downsamplingFilter,
                        renderer: renderer,
                        renderDirectory: renderDirectory,
                        root: loaded.root
                    )
                    artifacts.append(artifact)
                    printTiming(artifact)
                }

                // Decode and materialize one candidate at a time. Keeping both RAW
                // CI graphs alive would distort the memory profile of the formal run.
                for candidate in parityPlan.candidates {
                    try autoreleasepool {
                        let previewDecoded = try rawDecoder.decode(
                            url: rawURL,
                            intent: .interactivePreview(
                                maxDimension: candidate.decodeMaximumDimension
                            )
                        )
                        try validatePreviewRAW(
                            previewDecoded,
                            scene: scene,
                            manifest: manifest,
                            specification: previewParity,
                            requestedDecodeMaximumDimension: candidate.decodeMaximumDimension
                        )
                        decodes.append(
                            decodeRecord(
                                sceneID: scene.id,
                                route: candidate.decodeRoute,
                                decoded: previewDecoded
                            )
                        )
                        for stage in parityStages {
                            let artifact = try renderPreviewParityArtifact(
                                decoded: previewDecoded,
                                sceneID: scene.id,
                                stageID: stage.stageID,
                                suffix: candidate.artifactSuffix,
                                role: "preview-parity-candidate",
                                route: candidate.decodeRoute,
                                settings: stage.settings,
                                settingsHash: stage.settingsHash,
                                outputMaxDimension: parityPlan.outputMaxDimension,
                                downsamplingFilter: parityPlan.downsamplingFilter,
                                renderer: renderer,
                                renderDirectory: renderDirectory,
                                root: loaded.root
                            )
                            artifacts.append(artifact)
                            printTiming(artifact)
                        }
                    }
                }
            }

            for group in candidateGroups {
                for definition in group.definitions {
                    let settings = try CalibrationStageFactory.settings(
                        for: definition.id,
                        preset: preset
                    )
                    let settingsHash = try SHA256Digest.encodable(settings)
                    for (route, decoded, label) in [
                        ("raw", rawDecoded, definition.rawLabel),
                        ("lr-input", lightroomDecoded, definition.lightroomInputLabel)
                    ] {
                        let destination = try CalibrationManifestLoader.prepareOutputFile(
                            named: "\(scene.id)-\(label).tif",
                            in: renderDirectory,
                            inside: loaded.root
                        )
                        let milliseconds = try renderer.exportTIFF(
                            decoded: decoded,
                            settings: settings,
                            destination: destination,
                            maxDimension: CGFloat(manifest.comparison.maxDimension)
                        )
                        let artifact = try makeArtifact(
                            role: "comparison-candidate",
                            sceneID: scene.id,
                            route: route,
                            candidateGroup: group.name,
                            candidateID: definition.id,
                            label: label,
                            destination: destination,
                            root: loaded.root,
                            milliseconds: milliseconds,
                            settings: settings,
                            settingsSHA256: settingsHash
                        )
                        artifacts.append(artifact)
                        printTiming(artifact)
                    }
                }
            }
        }

        let postflightInputs = try loaded.verifyInputsAgain()
        guard postflightInputs == loaded.verifiedInputs else {
            throw CalibrationManifestError.invalid(
                "校正実行中に入力のサイズまたはhashが変わりました"
            )
        }
        let postflightSource = try CalibrationManifestLoader.sourceFingerprint(
            manifest.processing.sourceFiles,
            root: loaded.root
        )
        guard postflightSource.sha256 == source.sha256,
              postflightSource.files == source.files
        else {
            throw CalibrationManifestError.invalid(
                "校正実行中に処理sourceのサイズまたはhashが変わりました"
            )
        }
        _ = try loaded.verifyManifestAgain()
        let runtimeEnd = try RuntimeProvenance.captureCurrentExecutable()
        guard runtimeEnd.executableSHA256 == runtime.executableSHA256 else {
            throw CalibrationManifestError.invalid(
                "校正実行中に実行binaryのSHA-256が変わりました"
            )
        }
        let completed = CalibrationRunManifest(
            status: "complete",
            runID: runID,
            startedAtUTC: startedAt,
            completedAtUTC: ISO8601Timestamp.now(),
            manifest: manifestReference,
            runtime: runtime,
            processing: .current,
            sourceFingerprintSHA256: source.sha256,
            postflightSourceFingerprintSHA256: postflightSource.sha256,
            sourceFiles: source.files,
            verifiedInputs: loaded.verifiedInputs,
            postflightVerifiedInputs: postflightInputs,
            decodes: decodes,
            artifacts: artifacts,
            edrHeadroom: headroomRecords
        )
        try AtomicJSONWriter.write(completed, to: runManifestURL)
        try AtomicJSONWriter.write(completed, to: archivedRunManifestURL)
        print("Calibration run complete: \(runID)")
        print("Run manifest: \(runManifestURL.path)")
        print("Archived run manifest: \(archivedRunManifestURL.path)")
    }

    private static func validatePreset(
        _ preset: XMPPreset,
        manifest: CalibrationManifest
    ) throws {
        guard preset.cameraRawVersion == manifest.preset.cameraRawVersion else {
            throw CalibrationManifestError.invalid(
                "XMP Camera Raw version不一致: expected=\(manifest.preset.cameraRawVersion), actual=\(preset.cameraRawVersion ?? "nil")"
            )
        }
        guard preset.processVersion == manifest.preset.processVersion else {
            throw CalibrationManifestError.invalid(
                "XMP ProcessVersion不一致: expected=\(manifest.preset.processVersion), actual=\(preset.processVersion ?? "nil")"
            )
        }
        guard preset.rawProperties["UUID"] == manifest.preset.uuid else {
            throw CalibrationManifestError.invalid(
                "XMP UUID不一致: expected=\(manifest.preset.uuid), actual=\(preset.rawProperties["UUID"] ?? "nil")"
            )
        }
    }

    private static func validateRAWProfile(_ specification: RAWProfileSpecification) throws {
        let expected = RAWCalibrationProfile.panasonicDCS5Lightroom93
        guard specification.id == expected.id,
              abs(specification.boostAmount - Double(expected.configuration.boostAmount)) < 0.000_001,
              abs(
                  specification.extendedDynamicRangeAmount
                      - Double(expected.configuration.extendedDynamicRangeAmount)
              ) < 0.000_001
        else {
            throw CalibrationManifestError.invalid(
                "manifest rawProfileが現行DC-S5 profileと一致しません"
            )
        }
    }

    private static func previewParityRenderPlan(
        manifest: CalibrationManifest,
        specification: PreviewParitySpecification
    ) throws -> PreviewParityRenderPlan {
        switch manifest.schemaVersion {
        case 2:
            guard let maxDimension = specification.maxDimension else {
                throw CalibrationManifestError.invalid(
                    "schema v2 previewParity.maxDimensionがありません"
                )
            }
            return PreviewParityRenderPlan(
                outputMaxDimension: maxDimension,
                baselineArtifactSuffix: "full-decode",
                candidates: [
                    PreviewParityCandidatePlan(
                        decodeMaximumDimension: maxDimension,
                        artifactSuffix: "scaled-decode",
                        decodeRoute: "preview-parity-interactive-preview"
                    )
                ],
                downsamplingFilter: .affineTransform
            )
        case 3:
            guard let outputMaxDimension = specification.outputMaxDimension,
                  let candidateDimensions = specification.candidateDecodeMaximumDimensions
            else {
                throw CalibrationManifestError.invalid(
                    "schema v3 previewParityの出力またはdecode寸法がありません"
                )
            }
            return PreviewParityRenderPlan(
                outputMaxDimension: outputMaxDimension,
                baselineArtifactSuffix: "full-decode-to-\(outputMaxDimension)",
                candidates: candidateDimensions.map { dimension in
                    PreviewParityCandidatePlan(
                        decodeMaximumDimension: dimension,
                        artifactSuffix: "decode-\(dimension)-to-\(outputMaxDimension)",
                        decodeRoute: "preview-parity-interactive-preview-\(dimension)"
                    )
                },
                downsamplingFilter: .lanczos
            )
        default:
            throw CalibrationManifestError.invalid(
                "previewParity renderはschema v2/v3だけに対応します"
            )
        }
    }

    private static func renderPreviewParityArtifact(
        decoded: DecodedPhoto,
        sceneID: String,
        stageID: String,
        suffix: String,
        role: String,
        route: String,
        settings: EditSettings,
        settingsHash: String,
        outputMaxDimension: Int,
        downsamplingFilter: TIFFDownsamplingFilter,
        renderer: RenderEngine,
        renderDirectory: URL,
        root: URL
    ) throws -> CalibrationArtifact {
        let label = "preview-parity-\(stageID)-\(suffix)"
        let destination = try CalibrationManifestLoader.prepareOutputFile(
            named: "\(sceneID)-\(label).tif",
            in: renderDirectory,
            inside: root
        )
        let milliseconds = try renderer.exportTIFF(
            decoded: decoded,
            settings: settings,
            destination: destination,
            maxDimension: CGFloat(outputMaxDimension),
            downsamplingFilter: downsamplingFilter
        )
        return try makeArtifact(
            role: role,
            sceneID: sceneID,
            route: route,
            candidateGroup: "preview-parity",
            candidateID: stageID,
            label: label,
            destination: destination,
            root: root,
            milliseconds: milliseconds,
            settings: settings,
            settingsSHA256: settingsHash
        )
    }

    private static func validateRAW(
        _ decoded: DecodedPhoto,
        scene: CalibrationScene,
        manifest: CalibrationManifest,
        requireProfile: Bool
    ) throws {
        guard decoded.info.isRAW,
              decoded.info.backend == manifest.expectedEnvironment.rawDecoderBackend,
              decoded.info.intent == .fullResolution,
              decoded.info.requestedMaximumDimension == nil,
              decoded.info.nativeWidth == scene.capture.width,
              decoded.info.nativeHeight == scene.capture.height,
              abs((decoded.info.appliedScaleFactor ?? 0) - 1) < 0.000_001,
              decoded.info.width == scene.capture.width,
              decoded.info.height == scene.capture.height,
              normalized(decoded.info.cameraMake) == normalized(scene.capture.cameraMake),
              normalized(decoded.info.cameraModel) == normalized(scene.capture.cameraModel)
        else {
            throw CalibrationManifestError.invalid(
                "\(scene.id) RAWのdecoder/camera/dimensionがmanifestと一致しません"
            )
        }
        if requireProfile, decoded.info.calibrationID != manifest.rawProfile.id {
            throw CalibrationManifestError.invalid(
                "\(scene.id) RAW profile不一致: expected=\(manifest.rawProfile.id), actual=\(decoded.info.calibrationID ?? "nil")"
            )
        }
    }

    private static func validatePreviewRAW(
        _ decoded: DecodedPhoto,
        scene: CalibrationScene,
        manifest: CalibrationManifest,
        specification: PreviewParitySpecification,
        requestedDecodeMaximumDimension: Int
    ) throws {
        let expectedIntent = ImageDecodeIntent.interactivePreview(
            maxDimension: requestedDecodeMaximumDimension
        )
        let expectedScale = min(
            1,
            Float(requestedDecodeMaximumDimension)
                / Float(max(scene.capture.width, scene.capture.height))
        )
        let outputLongest = max(decoded.info.width, decoded.info.height)
        let sourceAspectRatio = Double(scene.capture.width) / Double(scene.capture.height)
        let outputAspectRatio = Double(decoded.info.width) / Double(decoded.info.height)
        guard decoded.info.isRAW,
              decoded.info.backend == manifest.expectedEnvironment.rawDecoderBackend,
              decoded.info.intent == expectedIntent,
              decoded.info.intent.identifier == specification.candidateDecodeIntent,
              decoded.info.requestedMaximumDimension == requestedDecodeMaximumDimension,
              decoded.info.nativeWidth == scene.capture.width,
              decoded.info.nativeHeight == scene.capture.height,
              let appliedScaleFactor = decoded.info.appliedScaleFactor,
              appliedScaleFactor.isFinite,
              abs(appliedScaleFactor - expectedScale) < 0.000_001,
              decoded.info.width > 0,
              decoded.info.height > 0,
              outputLongest == requestedDecodeMaximumDimension,
              abs(outputAspectRatio - sourceAspectRatio) < 0.002,
              normalized(decoded.info.cameraMake) == normalized(scene.capture.cameraMake),
              normalized(decoded.info.cameraModel) == normalized(scene.capture.cameraModel),
              decoded.info.calibrationID == manifest.rawProfile.id
        else {
            throw CalibrationManifestError.invalid(
                "\(scene.id) preview RAWのintent/decoder/camera/dimension/profileがmanifestと一致しません"
            )
        }
    }

    private static func validateLightroomReference(
        _ decoded: DecodedPhoto,
        scene: CalibrationScene,
        manifest: CalibrationManifest
    ) throws {
        let tiff = decoded.metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let software = tiff?[kCGImagePropertyTIFFSoftware as String] as? String
        guard !decoded.info.isRAW,
              decoded.info.width == scene.capture.width,
              decoded.info.height == scene.capture.height,
              software == manifest.comparison.referenceSoftware
        else {
            throw CalibrationManifestError.invalid(
                "\(scene.id) Lightroom TIFFのsoftware/dimensionがmanifestと一致しません"
            )
        }
    }

    private static func decodeRecord(
        sceneID: String,
        route: String,
        decoded: DecodedPhoto
    ) -> CalibrationDecodeRecord {
        CalibrationDecodeRecord(
            sceneID: sceneID,
            route: route,
            backend: decoded.info.backend,
            intent: decoded.info.intent.identifier,
            requestedMaximumDimension: decoded.info.requestedMaximumDimension,
            nativeWidth: decoded.info.nativeWidth,
            nativeHeight: decoded.info.nativeHeight,
            appliedScaleFactor: decoded.info.appliedScaleFactor,
            width: decoded.info.width,
            height: decoded.info.height,
            decoderGraphSetupMilliseconds: decoded.info.durationMilliseconds,
            cameraMake: decoded.info.cameraMake,
            cameraModel: decoded.info.cameraModel,
            calibrationID: decoded.info.calibrationID
        )
    }

    private static func makeArtifact(
        role: String,
        sceneID: String,
        route: String?,
        candidateGroup: String?,
        candidateID: String?,
        label: String?,
        destination: URL,
        root: URL,
        milliseconds: Double,
        settings: EditSettings,
        settingsSHA256: String
    ) throws -> CalibrationArtifact {
        let dimensions = try imageDimensions(destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return CalibrationArtifact(
            role: role,
            sceneID: sceneID,
            route: route,
            candidateGroup: candidateGroup,
            candidateID: candidateID,
            label: label,
            path: relativePath(destination, root: root),
            sha256: try SHA256Digest.file(destination),
            byteCount: UInt64(values.fileSize ?? 0),
            width: dimensions.width,
            height: dimensions.height,
            renderAndEncodeMilliseconds: milliseconds,
            settings: settings,
            settingsSHA256: settingsSHA256
        )
    }

    private static func imageDimensions(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int
        else {
            throw CalibrationManifestError.invalid(
                "生成画像の寸法を確認できません: \(url.lastPathComponent)"
            )
        }
        return (width, height)
    }

    private static func printTiming(_ artifact: CalibrationArtifact) {
        print(
            "\(URL(fileURLWithPath: artifact.path).lastPathComponent): "
                + "\(String(format: "%.1f", artifact.renderAndEncodeMilliseconds)) ms"
        )
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func threeDigitLabel(_ value: Double) -> String {
        String(format: "%03d", Int((value * 100).rounded()))
    }

    private static func extendedHeadroomSummary(
        decoded: DecodedPhoto,
        maxDimension: CGFloat = 600
    ) throws -> (
        maximumChannel: Float,
        extendedChannelPixelFraction: Double,
        maximumLuminance: Float,
        extendedLuminancePixelFraction: Double
    ) {
        let longest = max(decoded.image.extent.width, decoded.image.extent.height)
        let scale = min(1, maxDimension / longest)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let sampled = decoded.image
            .transformed(by: transform)
            .cropped(to: decoded.image.extent.applying(transform).integral)
        let extent = sampled.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        let pixelCount = width * height
        guard pixelCount > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        else {
            throw CalibrationManifestError.invalid("EDR headroomを測定できません")
        }
        var pixels = [SIMD4<Float>](repeating: .zero, count: pixelCount)
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: true
        ])
        context.render(
            sampled,
            toBitmap: &pixels,
            rowBytes: width * MemoryLayout<SIMD4<Float>>.stride,
            bounds: extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )
        let maximumChannel = pixels.reduce(-Float.infinity) { partial, pixel in
            max(partial, pixel.x, pixel.y, pixel.z)
        }
        let extendedChannelCount = pixels.count {
            max($0.x, $0.y, $0.z) > 1.000_1
        }
        let luminances = pixels.map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }
        let maximumLuminance = luminances.max() ?? 0
        let extendedLuminanceCount = luminances.count { $0 > 1.000_1 }
        return (
            maximumChannel,
            Double(extendedChannelCount) / Double(pixelCount),
            maximumLuminance,
            Double(extendedLuminanceCount) / Double(pixelCount)
        )
    }
}

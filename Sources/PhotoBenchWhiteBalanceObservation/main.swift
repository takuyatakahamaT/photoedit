import CoreImage
import Foundation
import ImageIO
import PhotoBenchCalibrationSupport
import PhotoCore

private struct ObservationArguments {
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
        ).standardizedFileURL.resolvingSymlinksInPath()
        if let manifestPath {
            manifestURL = NSString(string: manifestPath).isAbsolutePath
                ? URL(fileURLWithPath: manifestPath)
                : root.appendingPathComponent(manifestPath)
        } else {
            manifestURL = nil
        }
    }
}

private struct ExifToolRunner {
    let executableURL: URL
    let version: String
    let sha256: String

    static func locate() throws -> ExifToolRunner {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(
                contentsOf: path.split(separator: ":").map {
                    URL(fileURLWithPath: String($0)).appendingPathComponent("exiftool")
                }
            )
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/exiftool"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/exiftool"))
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CalibrationManifestError.invalid(
                "metadata二重検査に必要なExifToolが見つかりません"
            )
        }
        let canonical = executable.standardizedFileURL.resolvingSymlinksInPath()
        let version = try run(canonical, arguments: ["-ver"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw CalibrationManifestError.invalid("ExifTool versionを取得できません")
        }
        return ExifToolRunner(
            executableURL: canonical,
            version: version,
            sha256: try SHA256Digest.file(canonical)
        )
    }

    func tags(for url: URL) throws -> [String: Any] {
        try verifyIdentity()
        let output = try Self.run(
            executableURL,
            arguments: ["-j", "-G1", "-s", "-api", "LargeFileSupport=1", url.path]
        )
        try verifyIdentity()
        guard let data = output.data(using: .utf8),
              let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              objects.count == 1,
              let object = objects.first
        else {
            throw CalibrationManifestError.invalid(
                "ExifTool JSONを解釈できません: \(url.lastPathComponent)"
            )
        }
        return object
    }

    func verifyIdentityAndVersion() throws {
        try verifyIdentity()
        let currentVersion = try Self.run(executableURL, arguments: ["-ver"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentVersion == version else {
            throw CalibrationManifestError.invalid(
                "ExifTool versionがrun中に変更されました"
            )
        }
        try verifyIdentity()
    }

    private func verifyIdentity() throws {
        let canonical = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path == executableURL.path,
              FileManager.default.isExecutableFile(atPath: executableURL.path),
              try SHA256Digest.file(executableURL) == sha256
        else {
            throw CalibrationManifestError.invalid(
                "ExifTool executableがrun中に変更されました"
            )
        }
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CalibrationManifestError.invalid(
                "ExifToolが失敗しました（status=\(process.terminationStatus)）: \(message)"
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}

@main
enum PhotoBenchWhiteBalanceObservation {
    static func main() throws {
        let arguments = try ObservationArguments(Array(CommandLine.arguments.dropFirst()))
        let loaded = try WhiteBalanceObservationManifestLoader.load(
            root: arguments.root,
            manifestURL: arguments.manifestURL
        )
        let manifest = loaded.manifest
        let runID = UUID().uuidString.lowercased()
        try requireGitIgnored(
            root: loaded.root,
            runID: runID,
            privateInputPaths: manifest.scenes.flatMap {
                [$0.raw.path, $0.lightroomReference.path]
            }
        )
        let runDirectory = try WhiteBalanceObservationOutput.prepareNewRunDirectory(
            runID: runID,
            root: loaded.root
        )
        let incompleteURL = try WhiteBalanceObservationOutput.prepareNewFile(
            named: ".incomplete.json",
            in: runDirectory,
            root: loaded.root
        )
        let startedAt = ISO8601Timestamp.now()
        try WhiteBalanceObservationOutput.writeNewJSON(
            WhiteBalanceObservationIncompleteSentinel(
                runID: runID,
                startedAtUTC: startedAt,
                manifestSHA256: loaded.manifestSHA256
            ),
            to: incompleteURL,
            root: loaded.root
        )
        let runURL = try WhiteBalanceObservationOutput.prepareNewFile(
            named: "run.json",
            in: runDirectory,
            root: loaded.root
        )

        let runtime = try RuntimeProvenance.captureCurrentExecutable()
        let exifTool = try ExifToolRunner.locate()
        let sourceBefore = try CalibrationManifestLoader.sourceFingerprint(
            manifest.processing.sourceFiles,
            root: loaded.root
        )
        var artifacts: [WhiteBalanceObservationArtifact] = []
        var sceneRecords: [WhiteBalanceObservationSceneRecord] = []
        var setterOrderRecords: [WhiteBalanceObservationSetterOrderRecord] = []
        let renderer = RenderEngine()
        let decoder = CoreImageRAWWhiteBalanceDecoder()

        print("WB observation suite: \(manifest.suiteID)")
        print("Run: \(runID)")
        print("Adoption: \(manifest.adoptionStatus.rawValue)")

        for scene in manifest.scenes {
            let sceneRelative = "\(WhiteBalanceObservationOutput.rootRelativePath)/\(runID)/scenes/\(scene.id)"
            let referenceDirectory = try CalibrationManifestLoader.prepareOutputDirectory(
                "\(sceneRelative)/reference",
                inside: loaded.root
            )
            let candidateDirectory = try CalibrationManifestLoader.prepareOutputDirectory(
                "\(sceneRelative)/candidates",
                inside: loaded.root
            )
            let setterOrderDirectory = try CalibrationManifestLoader.prepareOutputDirectory(
                "\(sceneRelative)/setter-order",
                inside: loaded.root
            )
            let rawURL = try loaded.resolve(scene.raw.path)
            let referenceURL = try loaded.resolve(scene.lightroomReference.path)
            let sourceNeutral = try decoder.observeSourceNeutral(url: rawURL)
            let candidates = try WhiteBalanceObservationManifestLoader.candidates(
                plan: manifest.candidatePlan,
                source: sourceNeutral
            )

            let referenceDecoded = pixelOnly(
                try CoreImageDecoder().decode(url: referenceURL, intent: .fullResolution)
            )
            let normalizedReferenceURL = try WhiteBalanceObservationOutput.prepareNewFile(
                named: "lightroom-as-shot.tif",
                in: referenceDirectory,
                root: loaded.root
            )
            artifacts.append(
                try renderArtifact(
                    renderer: renderer,
                    decoded: referenceDecoded,
                    destination: normalizedReferenceURL,
                    root: loaded.root,
                    contract: manifest.output,
                    exifTool: exifTool,
                    role: "normalized-lightroom-reference",
                    sceneID: scene.id,
                    candidate: nil,
                    requestMode: "lightroom-teacher-as-shot",
                    provenance: nil
                )
            )

            var primaryCenterArtifact: WhiteBalanceObservationArtifact?
            for candidate in candidates {
                let result: RAWWhiteBalanceDecodedPhoto
                if let custom = candidate.customWhiteBalance {
                    result = try decoder.decode(
                        url: rawURL,
                        intent: .fullResolution,
                        whiteBalance: .custom(custom)
                    )
                    try requireSameSourceNeutral(
                        result.provenance.sourceAsShot,
                        expected: sourceNeutral,
                        sceneID: scene.id
                    )
                } else {
                    result = try decoder.decode(
                        url: rawURL,
                        intent: .fullResolution,
                        whiteBalance: .asShot
                    )
                }
                try validateDecoderEvidence(result.provenance, candidate: candidate)
                let destination = try WhiteBalanceObservationOutput.prepareNewFile(
                    named: "\(candidate.id).tif",
                    in: candidateDirectory,
                    root: loaded.root
                )
                let artifact = try renderArtifact(
                    renderer: renderer,
                    decoded: pixelOnly(result.decoded),
                    destination: destination,
                    root: loaded.root,
                    contract: manifest.output,
                    exifTool: exifTool,
                    role: "observation-candidate",
                    sceneID: scene.id,
                    candidate: candidate,
                    requestMode: result.provenance.requestMode,
                    provenance: result.provenance
                )
                artifacts.append(artifact)
                if candidate.kind == .customCenter {
                    primaryCenterArtifact = artifact
                }
                print("\(scene.id) / \(candidate.id)")
            }

            let center = try requireCandidate(candidates, kind: .customCenter)
            let centerRequest = try requireCustomRequest(center)
            let reverse = try decoder.decodeForObservation(
                url: rawURL,
                intent: .fullResolution,
                customWhiteBalance: centerRequest,
                setterOrder: manifest.setterOrder.comparison
            )
            try requireSameSourceNeutral(
                reverse.provenance.sourceAsShot,
                expected: sourceNeutral,
                sceneID: scene.id
            )
            try validateDecoderEvidence(
                reverse.provenance,
                candidate: center,
                expectedSetterOrder: manifest.setterOrder.comparison
            )
            let reverseURL = try WhiteBalanceObservationOutput.prepareNewFile(
                named: "custom-center-tint-then-temperature.tif",
                in: setterOrderDirectory,
                root: loaded.root
            )
            let reverseArtifact = try renderArtifact(
                renderer: renderer,
                decoded: pixelOnly(reverse.decoded),
                destination: reverseURL,
                root: loaded.root,
                contract: manifest.output,
                exifTool: exifTool,
                role: "setter-order-comparison",
                sceneID: scene.id,
                candidate: center,
                requestMode: reverse.provenance.requestMode,
                provenance: reverse.provenance
            )
            artifacts.append(reverseArtifact)
            let primary = try requirePrimaryCenter(primaryCenterArtifact, sceneID: scene.id)
            let primaryData = try Data(
                contentsOf: loaded.root.appendingPathComponent(primary.path)
            )
            let comparisonData = try Data(contentsOf: reverseURL)
            let primaryHash = SHA256Digest.data(primaryData)
            let comparisonHash = SHA256Digest.data(comparisonData)
            guard primaryHash == primary.sha256,
                  comparisonHash == reverseArtifact.sha256
            else {
                throw CalibrationManifestError.invalid(
                    "scene \(scene.id) のsetter-order成果物が記録後に変更されました"
                )
            }
            let byteExact = primaryData == comparisonData
            guard !manifest.setterOrder.exactByteEqualityRequired || byteExact else {
                throw CalibrationManifestError.invalid(
                    "scene \(scene.id) でneutral setter orderがpixel出力を変更しました"
                )
            }
            setterOrderRecords.append(
                WhiteBalanceObservationSetterOrderRecord(
                    sceneID: scene.id,
                    candidateID: center.id,
                    primaryOrder: manifest.setterOrder.primary,
                    comparisonOrder: manifest.setterOrder.comparison,
                    primarySHA256: primaryHash,
                    comparisonSHA256: comparisonHash,
                    byteExact: byteExact
                )
            )
            sceneRecords.append(
                WhiteBalanceObservationSceneRecord(
                    sceneID: scene.id,
                    fold: scene.fold,
                    sourceNeutral: sourceNeutral,
                    teacher: scene.teacher,
                    candidateIDs: candidates.map(\.id)
                )
            )
        }

        let manifestAfter = try loaded.verifyManifestAgain()
        guard manifestAfter == loaded.manifestSHA256 else {
            throw CalibrationManifestError.invalid("WB manifestがrun中に変更されました")
        }
        let baseManifestAfter = try loaded.base.verifyManifestAgain()
        guard baseManifestAfter == loaded.base.manifestSHA256 else {
            throw CalibrationManifestError.invalid("base manifestがrun中に変更されました")
        }
        let verifiedInputsAfter = try loaded.verifyInputsAgain()
        guard verifiedInputsAfter == loaded.verifiedInputs else {
            throw CalibrationManifestError.invalid("WB observation入力がrun中に変更されました")
        }
        let baseInputsAfter = try loaded.base.verifyInputsAgain()
        guard baseInputsAfter == loaded.base.verifiedInputs else {
            throw CalibrationManifestError.invalid("base calibration入力がrun中に変更されました")
        }
        let sourceAfter = try CalibrationManifestLoader.sourceFingerprint(
            manifest.processing.sourceFiles,
            root: loaded.root
        )
        guard sourceAfter == sourceBefore else {
            throw CalibrationManifestError.invalid("WB observation sourceがrun中に変更されました")
        }
        let runtimeAfter = try RuntimeProvenance.captureCurrentExecutable()
        guard runtimeAfter.executableSHA256 == runtime.executableSHA256,
              runtimeAfter.buildConfiguration == runtime.buildConfiguration
        else {
            throw CalibrationManifestError.invalid(
                "WB observation executableがrun中に変更されました"
            )
        }
        try exifTool.verifyIdentityAndVersion()
        guard artifacts.count == manifest.scenes.count * 20,
              sceneRecords.count == manifest.scenes.count,
              setterOrderRecords.count == manifest.scenes.count
        else {
            throw CalibrationManifestError.invalid("WB observation成果物が欠落しています")
        }

        let manifestReference = ManifestRunReference(
            path: relativePath(loaded.manifestURL, root: loaded.root),
            sha256: loaded.manifestSHA256,
            suiteID: manifest.suiteID
        )
        let baseReference = ManifestRunReference(
            path: relativePath(loaded.base.manifestURL, root: loaded.root),
            sha256: loaded.base.manifestSHA256,
            suiteID: loaded.base.manifest.suiteID
        )
        let completed = WhiteBalanceObservationRun(
            runID: runID,
            startedAtUTC: startedAt,
            completedAtUTC: ISO8601Timestamp.now(),
            manifest: manifestReference,
            baseCalibrationManifest: baseReference,
            runtime: runtime,
            exifTool: WhiteBalanceObservationToolProvenance(
                path: exifTool.executableURL.path,
                version: exifTool.version,
                sha256: exifTool.sha256
            ),
            sourceFingerprintSHA256: sourceBefore.sha256,
            postflightSourceFingerprintSHA256: sourceAfter.sha256,
            sourceFiles: sourceBefore.files,
            verifiedInputs: loaded.verifiedInputs,
            postflightVerifiedInputs: verifiedInputsAfter,
            scenes: sceneRecords,
            artifacts: artifacts,
            setterOrderChecks: setterOrderRecords
        )
        guard completed.sceneCount == 2,
              completed.holdoutCount == 0,
              !completed.productionAdoptionAllowed
        else {
            throw CalibrationManifestError.invalid("WB observation adoption gateが不正です")
        }
        // The complete manifest is the last material write. A leftover sentinel
        // makes analyzers reject an interrupted run even if run.json exists.
        try WhiteBalanceObservationOutput.writeNewJSON(
            completed,
            to: runURL,
            root: loaded.root
        )
        try FileManager.default.removeItem(at: incompleteURL)
        print("Complete: \(runURL.path)")
    }

    private static func pixelOnly(_ decoded: DecodedPhoto) -> DecodedPhoto {
        DecodedPhoto(
            sourceURL: decoded.sourceURL,
            image: decoded.image.settingProperties([:]),
            metadata: [:],
            info: decoded.info
        )
    }

    private static func renderArtifact(
        renderer: RenderEngine,
        decoded: DecodedPhoto,
        destination: URL,
        root: URL,
        contract: WhiteBalanceObservationOutputContract,
        exifTool: ExifToolRunner,
        role: String,
        sceneID: String,
        candidate: WhiteBalanceObservationCandidate?,
        requestMode: String,
        provenance: RAWWhiteBalanceDecodeProvenance?
    ) throws -> WhiteBalanceObservationArtifact {
        let milliseconds = try renderer.exportTIFF(
            decoded: decoded,
            settings: .neutral,
            destination: destination,
            maxDimension: CGFloat(contract.maxDimension),
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling,
            allowDestinationReplacement: false
        )
        let audit = try metadataAudit(destination, exifTool: exifTool)
        let dimensions = try imageDimensions(destination)
        guard max(dimensions.width, dimensions.height) == contract.maxDimension else {
            throw CalibrationManifestError.invalid(
                "canonical WB artifactの最大辺が不正です: \(destination.lastPathComponent)"
            )
        }
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return WhiteBalanceObservationArtifact(
            role: role,
            sceneID: sceneID,
            candidateID: candidate?.id,
            candidateKind: candidate?.kind.rawValue,
            requestMode: requestMode,
            temperatureMiredOffset: candidate?.temperatureMiredOffset,
            tintOffset: candidate?.tintOffset,
            requested: candidate?.customWhiteBalance,
            decodeProvenance: provenance,
            path: relativePath(destination, root: root),
            sha256: try SHA256Digest.file(destination),
            byteCount: UInt64(values.fileSize ?? 0),
            width: dimensions.width,
            height: dimensions.height,
            renderAndEncodeMilliseconds: milliseconds,
            metadataAudit: audit
        )
    }

    private static func metadataAudit(
        _ url: URL,
        exifTool: ExifToolRunner
    ) throws -> WhiteBalanceObservationMetadataAudit {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any],
              properties[kCGImagePropertyDepth as String] as? Int == 16,
              properties[kCGImagePropertyColorModel as String] as? String == "RGB",
              let profileName = properties[kCGImagePropertyProfileName as String] as? String,
              profileName == "sRGB IEC61966-2.1"
        else {
            throw CalibrationManifestError.invalid(
                "ImageIOで16-bit canonical sRGB TIFFを確認できません: \(url.lastPathComponent)"
            )
        }
        let imageIOKeys = flattenedPropertyKeys(properties).sorted()
        let forbiddenComponents = Set([
            "exif", "gps", "iptc", "xmp", "makernote", "makernotes", "make", "model",
            "datetime", "artist", "copyright", "imagedescription", "usercomment"
        ])
        let forbiddenImageIO = imageIOKeys.filter { key in
            key.lowercased()
                .split(whereSeparator: { $0 == "." || $0 == "{" || $0 == "}" })
                .contains { component in
                    forbiddenComponents.contains(String(component))
                        || component.hasPrefix("serial")
                        || component.hasPrefix("lens")
                        || component.hasPrefix("camera")
                }
        }
        guard forbiddenImageIO.isEmpty else {
            throw CalibrationManifestError.invalid(
                "ImageIOがsource metadataを検出しました: \(forbiddenImageIO.joined(separator: ", "))"
            )
        }

        let tags = try exifTool.tags(for: url)
        let allowedIFD0 = Set([
            "ImageWidth", "ImageHeight", "BitsPerSample", "Compression",
            "PhotometricInterpretation", "FillOrder", "StripOffsets", "Orientation",
            "SamplesPerPixel", "RowsPerStrip", "StripByteCounts", "PlanarConfiguration",
            "ResolutionUnit", "XResolution", "YResolution", "ExtraSamples", "SampleFormat"
        ])
        let allowedExifIFD = Set(["ColorSpace", "ExifImageWidth", "ExifImageHeight"])
        let allowedComposite = Set(["ImageSize", "Megapixels"])
        var unexpected: [String] = []
        for key in tags.keys where key != "SourceFile" {
            guard let separator = key.firstIndex(of: ":") else {
                unexpected.append(key)
                continue
            }
            let group = String(key[..<separator])
            let name = String(key[key.index(after: separator)...])
            let allowed = group == "ExifTool"
                || group == "System"
                || group == "File"
                || group.hasPrefix("ICC")
                || (group == "IFD0" && allowedIFD0.contains(name))
                || (group == "ExifIFD" && allowedExifIFD.contains(name))
                || (group == "Composite" && allowedComposite.contains(name))
            if !allowed { unexpected.append(key) }
        }
        guard unexpected.isEmpty else {
            throw CalibrationManifestError.invalid(
                "ExifToolがsource metadataを検出しました: \(unexpected.sorted().joined(separator: ", "))"
            )
        }
        guard tags["File:FileType"] as? String == "TIFF",
              String(describing: tags["IFD0:BitsPerSample"] ?? "").hasPrefix("16 16 16 16"),
              tags["ICC_Profile:ProfileDescription"] as? String == "sRGB IEC61966-2.1"
        else {
            throw CalibrationManifestError.invalid(
                "ExifToolのTIFF/ICC contractが不一致です: \(url.lastPathComponent)"
            )
        }
        return WhiteBalanceObservationMetadataAudit(
            imageIOPropertyKeys: imageIOKeys,
            exifToolTagKeys: tags.keys.sorted(),
            iccProfileDescription: profileName,
            sourceMetadataAbsent: true
        )
    }

    private static func flattenedPropertyKeys(
        _ dictionary: [String: Any],
        prefix: String = ""
    ) -> [String] {
        dictionary.flatMap { key, value -> [String] in
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                return [path] + flattenedPropertyKeys(nested, prefix: path)
            }
            return [path]
        }
    }

    private static func imageDimensions(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0,
              height > 0
        else {
            throw CalibrationManifestError.invalid(
                "生成画像の寸法を確認できません: \(url.lastPathComponent)"
            )
        }
        return (width, height)
    }

    private static func validateDecoderEvidence(
        _ provenance: RAWWhiteBalanceDecodeProvenance,
        candidate: WhiteBalanceObservationCandidate,
        expectedSetterOrder: RAWNeutralSetterOrder = .temperatureThenTint
    ) throws {
        if candidate.kind == .asShot {
            guard provenance.processingIdentifier == CoreImageDecoder.processingIdentifier,
                  provenance.requestMode == "as-shot-untouched",
                  !provenance.neutralPropertiesObserved,
                  provenance.requested == nil,
                  provenance.sourceAsShot == nil,
                  provenance.applied == nil,
                  provenance.setterOrder == nil,
                  provenance.decoderVersion == "8"
            else {
                throw CalibrationManifestError.invalid("As Shot非介入契約が崩れました")
            }
        } else {
            let request = try requireCustomRequest(candidate)
            guard provenance.processingIdentifier
                    == CoreImageRAWWhiteBalanceDecoder.customProcessingIdentifier,
                  provenance.requestMode == "custom-core-image-neutral",
                  provenance.neutralPropertiesObserved,
                  provenance.requested == request,
                  provenance.sourceAsShot != nil,
                  let applied = provenance.applied,
                  abs(applied.temperatureKelvin - request.temperatureKelvin) < 0.01,
                  abs(applied.tint - request.tint) < 0.01,
                  provenance.setterOrder == expectedSetterOrder,
                  provenance.decoderVersion == "8",
                  provenance.supportedDecoderVersions.contains("8")
            else {
                throw CalibrationManifestError.invalid(
                    "custom WB decoder provenanceが固定契約と一致しません"
                )
            }
        }
    }

    private static func requireSameSourceNeutral(
        _ actual: RAWNeutralValues?,
        expected: RAWNeutralValues,
        sceneID: String
    ) throws {
        guard actual == expected else {
            throw CalibrationManifestError.invalid(
                "scene \(sceneID) のfresh source neutralがdecode間で変化しました"
            )
        }
    }

    private static func requireCandidate(
        _ candidates: [WhiteBalanceObservationCandidate],
        kind: WhiteBalanceObservationCandidate.Kind
    ) throws -> WhiteBalanceObservationCandidate {
        guard let candidate = candidates.first(where: { $0.kind == kind }) else {
            throw CalibrationManifestError.invalid("必須WB candidateがありません: \(kind.rawValue)")
        }
        return candidate
    }

    private static func requireCustomRequest(
        _ candidate: WhiteBalanceObservationCandidate
    ) throws -> RAWCustomWhiteBalance {
        guard let request = candidate.customWhiteBalance else {
            throw CalibrationManifestError.invalid("custom WB requestがありません")
        }
        return request
    }

    private static func requirePrimaryCenter(
        _ artifact: WhiteBalanceObservationArtifact?,
        sceneID: String
    ) throws -> WhiteBalanceObservationArtifact {
        guard let artifact else {
            throw CalibrationManifestError.invalid(
                "scene \(sceneID) のcustom-center artifactがありません"
            )
        }
        return artifact
    }

    private static func requireGitIgnored(
        root: URL,
        runID: String,
        privateInputPaths: [String]
    ) throws {
        let topLevel = try runGit(
            root: root,
            arguments: ["rev-parse", "--show-toplevel"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: topLevel).standardizedFileURL.resolvingSymlinksInPath()
                == root.standardizedFileURL.resolvingSymlinksInPath()
        else {
            throw CalibrationManifestError.invalid("git top-levelとproject rootが一致しません")
        }
        let trackedPrivateInputs = try runGit(
            root: root,
            arguments: ["ls-files", "--"] + privateInputPaths
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trackedPrivateInputs.isEmpty else {
            throw CalibrationManifestError.invalid(
                "WB observationのprivate RAW/Lightroom fixtureがGit追跡されています"
            )
        }
        let runRelative = "\(WhiteBalanceObservationOutput.rootRelativePath)/\(runID)"
        let probes = [
            "\(runRelative)/.incomplete.json",
            "\(runRelative)/run.json",
            "\(runRelative)/analysis.json",
            "\(runRelative)/scenes/ignore-probe/candidates/ignore-probe.tif"
        ]
        for probe in probes {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = [
                "-C", root.path, "check-ignore", "--quiet", "--", probe
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CalibrationManifestError.invalid(
                    "WB observation出力がgit ignoreされていません: \(probe) "
                        + "（status=\(process.terminationStatus)）"
                )
            }
        }
    }

    private static func runGit(root: URL, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw CalibrationManifestError.invalid(
                "git検査が失敗しました: \(String(decoding: errorData, as: UTF8.self))"
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

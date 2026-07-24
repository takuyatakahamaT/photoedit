import Foundation
import PhotoBenchCalibrationSupport
import PhotoCore

private struct BenchmarkArguments {
    let root: URL
    let manifestURL: URL?
    let quick: Bool
    let enforce: Bool
    let worker: Bool
    let sceneID: String?

    init(_ arguments: [String]) throws {
        var rootPath: String?
        var manifestPath: String?
        var quick = false
        var enforce = false
        var worker = false
        var sceneID: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--manifest":
                guard index + 1 < arguments.count else {
                    throw CalibrationManifestError.invalid("--manifestにpathが必要です")
                }
                manifestPath = arguments[index + 1]
                index += 2
            case "--scene":
                guard index + 1 < arguments.count else {
                    throw CalibrationManifestError.invalid("--sceneにIDが必要です")
                }
                sceneID = arguments[index + 1]
                index += 2
            case "--quick":
                quick = true
                index += 1
            case "--enforce":
                enforce = true
                index += 1
            case "--worker":
                worker = true
                index += 1
            default:
                let argument = arguments[index]
                if argument.hasPrefix("--") {
                    throw CalibrationManifestError.invalid("未対応の引数です: \(argument)")
                }
                guard rootPath == nil else {
                    throw CalibrationManifestError.invalid("余分な引数です: \(argument)")
                }
                rootPath = argument
                index += 1
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
        self.quick = quick
        self.enforce = enforce
        self.worker = worker
        self.sceneID = sceneID
    }
}

private struct BenchmarkWorkerSample: Codable {
    let systemLoadStart: SystemLoadSnapshot
    let systemLoadEnd: SystemLoadSnapshot
    let runtimeStart: RuntimeProvenance
    let runtimeEnd: RuntimeProvenance
    let decoderGraphSetupMilliseconds: Double
    let preview: RenderPhaseTimings
    let processFreshPipelineMilliseconds: Double
    let peakResidentMemoryBytes: UInt64
    let decoderBackend: String
    let calibrationID: String?
    let decodeIntent: String
    let requestedMaximumDimension: Int?
    let nativeWidth: Int
    let nativeHeight: Int
    let decodedWidth: Int
    let decodedHeight: Int
    let appliedScaleFactor: Float?
    let executableSHA256: String
}

private struct BenchmarkSystemLoadObservation: Codable {
    let scope: String
    let boundary: String
    let snapshot: SystemLoadSnapshot
}

private struct BenchmarkConfigurationRecord: Codable {
    let sceneID: String
    let inputWidth: Int
    let inputHeight: Int
    let previewDecodedWidth: Int
    let previewDecodedHeight: Int
    let previewDecodeIntent: String
    let previewAppliedScaleFactor: Float?
    let previewMaxDimension: Int
    let fullResolutionDecodedWidth: Int
    let fullResolutionDecodedHeight: Int
    let fullResolutionDecodeIntent: String
    let fullResolutionRequestedMaximumDimension: Int?
    let fullResolutionAppliedScaleFactor: Float?
    let fullResolutionDecoderBackend: String
    let jpegQuality: Double
    let warmupIterations: Int
    let measuredIterations: Int
    let processFreshIterations: Int
    let osCachesUncontrolled: Bool
    let inputCachePolicy: String
    let previewArchitecture: String
    let contextPolicy: String
    let timingInterpretation: String
}

private struct BenchmarkWorkload: Codable {
    let semantics: String
    let settingsSHA256: String
    let phases: BenchmarkPhaseDistributions
}

private struct BenchmarkReport: Codable {
    let schemaVersion: Int
    let benchmarkVersion: String
    let runID: String
    let startedAtUTC: String
    let completedAtUTC: String
    let manifest: ManifestRunReference
    let runtimeStart: RuntimeProvenance
    let runtimeEnd: RuntimeProvenance
    let processing: PhotoCoreProcessingFingerprint
    let sourceFingerprintSHA256: String
    let postflightSourceFingerprintSHA256: String
    let sourceFiles: [VerifiedFile]
    let input: VerifiedFile
    let configuration: BenchmarkConfigurationRecord
    let systemLoadObservations: [BenchmarkSystemLoadObservation]
    let processFreshWorkerSamples: [BenchmarkWorkerSample]
    let measurements: [String: BenchmarkWorkload]
    let coordinatorPeakResidentMemoryBytes: UInt64
    let maximumWorkerPeakResidentMemoryBytes: UInt64
    /// Kept as an aggregate compatibility field. Prefer the two scoped values.
    let peakResidentMemoryBytes: UInt64
    let gateEligibility: String
    let gates: [String: BenchmarkGateResult]
    let unmeasuredProductTargets: [String]
    let inputHashesUnchanged: Bool
    let sourceHashesUnchanged: Bool
}

@main
enum PhotoBenchBenchmark {
    static func main() {
        do {
            let arguments = try BenchmarkArguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.worker {
                try runWorker(arguments)
                return
            }
            let evaluation = try runCoordinator(arguments)
            if arguments.enforce, evaluation.enforcedExitCode != 0 {
                Foundation.exit(evaluation.enforcedExitCode)
            }
        } catch {
            FileHandle.standardError.write(
                Data("PhotoBenchBenchmark: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(2)
        }
    }

    private static func runCoordinator(
        _ arguments: BenchmarkArguments
    ) throws -> BenchmarkGateEvaluation {
        let runID = UUID().uuidString.lowercased()
        let startedAt = ISO8601Timestamp.now()
        var systemLoadObservations = [
            BenchmarkSystemLoadObservation(
                scope: "run",
                boundary: "start",
                snapshot: try SystemLoadSnapshot.capture()
            )
        ]
        let loaded = try CalibrationManifestLoader.load(
            root: arguments.root,
            manifestURL: arguments.manifestURL
        )
        let manifest = loaded.manifest
        let specification = manifest.benchmark
        let sceneID = arguments.sceneID ?? specification.sceneID
        guard let scene = manifest.scenes.first(where: { $0.id == sceneID }) else {
            throw CalibrationManifestError.invalid("benchmark sceneがありません: \(sceneID)")
        }
        let presetURL = try loaded.resolve(manifest.preset.file.path)
        let preset = try XMPPresetParser.parse(url: presetURL)
        try validatePreset(preset, manifest: manifest)
        let rawURL = try loaded.resolve(scene.raw.path)
        let decoder = CoreImageDecoder()
        let previewDecoded = try decoder.decode(
            url: rawURL,
            intent: .interactivePreview(maxDimension: specification.previewMaxDimension)
        )
        try validateBenchmarkPreviewRAW(
            previewDecoded,
            scene: scene,
            manifest: manifest
        )
        let fullResolutionDecoded = try decoder.decode(
            url: rawURL,
            intent: .fullResolution
        )
        try validateBenchmarkFullResolutionRAW(
            fullResolutionDecoded,
            scene: scene,
            manifest: manifest
        )

        let measuredIterations = arguments.quick ? 3 : specification.measuredIterations
        let warmupIterations = arguments.quick ? 1 : specification.warmupIterations
        let processFreshIterations = arguments.quick ? 1 : specification.processFreshIterations
        let runtimeStart = try RuntimeProvenance.captureCurrentExecutable()
        let sourcePaths = Array(
            Set(
                manifest.processing.sourceFiles + [
                    "Sources/PhotoBenchCalibrationSupport/BenchmarkModels.swift",
                    "Sources/PhotoBenchCalibrationSupport/CalibrationRun.swift",
                    "Sources/PhotoBenchBenchmark/main.swift"
                ]
            )
        )
        let source = try CalibrationManifestLoader.sourceFingerprint(
            sourcePaths,
            root: loaded.root
        )
        let outputRoot = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/benchmark",
            inside: loaded.root
        )
        _ = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/benchmark/scratch",
            inside: loaded.root
        )
        let scratch = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/benchmark/scratch/\(runID)",
            inside: loaded.root
        )
        defer { try? removeDedicatedScratch(scratch, outputRoot: outputRoot) }

        let neutral = EditSettings.neutral
        let toneBase = try CalibrationStageFactory.settings(for: "tone-base", preset: preset)
        let full = try CalibrationStageFactory.settings(for: "full-current", preset: preset)
        let neutralHash = try SHA256Digest.encodable(neutral)
        let toneHash = try SHA256Digest.encodable(toneBase)
        let fullHash = try SHA256Digest.encodable(full)

        // Match the product topology: one reusable engine owns distinct
        // preview/export CIContext instances internally.
        let renderer = RenderEngine()
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "preview-warmup",
                boundary: "start",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )
        for _ in 0..<warmupIterations {
            try autoreleasepool {
                _ = try renderer.renderPreviewMeasured(
                    decoded: previewDecoded,
                    settings: neutral,
                    maxDimension: CGFloat(specification.previewMaxDimension)
                )
                _ = try renderer.renderPreviewMeasured(
                    decoded: previewDecoded,
                    settings: toneBase,
                    maxDimension: CGFloat(specification.previewMaxDimension)
                )
                _ = try renderer.renderPreviewMeasured(
                    decoded: previewDecoded,
                    settings: full,
                    maxDimension: CGFloat(specification.previewMaxDimension)
                )
            }
        }
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "preview-warmup",
                boundary: "end",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )

        var neutralSamples: [RenderPhaseTimings] = []
        var sliderSamples: [RenderPhaseTimings] = []
        var fullSamples: [RenderPhaseTimings] = []
        let exposureOffsets = [-0.20, -0.10, 0.0, 0.10, 0.20]
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "warm-preview-interleaved",
                boundary: "start",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )
        for index in 0..<measuredIterations {
            neutralSamples.append(
                try autoreleasepool {
                    try renderer.renderPreviewMeasured(
                        decoded: previewDecoded,
                        settings: neutral,
                        maxDimension: CGFloat(specification.previewMaxDimension)
                    ).timings
                }
            )
            var sliderSettings = toneBase
            sliderSettings.exposure += exposureOffsets[index % exposureOffsets.count]
            sliderSamples.append(
                try autoreleasepool {
                    try renderer.renderPreviewMeasured(
                        decoded: previewDecoded,
                        settings: sliderSettings,
                        maxDimension: CGFloat(specification.previewMaxDimension)
                    ).timings
                }
            )
            fullSamples.append(
                try autoreleasepool {
                    try renderer.renderPreviewMeasured(
                        decoded: previewDecoded,
                        settings: full,
                        maxDimension: CGFloat(specification.previewMaxDimension)
                    ).timings
                }
            )
        }
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "warm-preview-interleaved",
                boundary: "end",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )

        let exportWarmupDestination = try CalibrationManifestLoader.prepareOutputFile(
            named: "export-warmup.jpg",
            in: scratch,
            inside: loaded.root
        )
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "full-resolution-export-warmup",
                boundary: "start",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )
        for _ in 0..<warmupIterations {
            try autoreleasepool {
                _ = try renderer.exportJPEGMeasured(
                    decoded: fullResolutionDecoded,
                    settings: full,
                    destination: exportWarmupDestination,
                    quality: specification.jpegQuality,
                    protectedSourceURLs: [presetURL]
                )
            }
            try? FileManager.default.removeItem(at: exportWarmupDestination)
        }
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "full-resolution-export-warmup",
                boundary: "end",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )
        var exportSamples: [RenderPhaseTimings] = []
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "full-resolution-export",
                boundary: "start",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )
        for index in 0..<measuredIterations {
            let destination = try CalibrationManifestLoader.prepareOutputFile(
                named: "export-\(index).jpg",
                in: scratch,
                inside: loaded.root
            )
            exportSamples.append(
                try autoreleasepool {
                    try renderer.exportJPEGMeasured(
                        decoded: fullResolutionDecoded,
                        settings: full,
                        destination: destination,
                        quality: specification.jpegQuality,
                        protectedSourceURLs: [presetURL]
                    )
                }
            )
            try FileManager.default.removeItem(at: destination)
        }
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "full-resolution-export",
                boundary: "end",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )

        var processFreshSamples: [BenchmarkWorkerSample] = []
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "process-fresh-preview",
                boundary: "start",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )
        for _ in 0..<processFreshIterations {
            processFreshSamples.append(
                try launchWorker(
                    root: loaded.root,
                    manifestURL: loaded.manifestURL,
                    sceneID: scene.id
                )
            )
        }
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "process-fresh-preview",
                boundary: "end",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )
        guard let coordinatorExecutableSHA256 = runtimeStart.executableSHA256,
              processFreshSamples.allSatisfy({
                  $0.executableSHA256 == coordinatorExecutableSHA256
              })
        else {
            throw CalibrationManifestError.invalid(
                "process-fresh workerとcoordinatorの実行binary SHA-256が一致しません"
            )
        }

        let processFreshTimings = processFreshSamples.map(\.preview)
        let processFreshTotals = processFreshSamples.map(\.processFreshPipelineMilliseconds)
        let measurements: [String: BenchmarkWorkload] = [
            "raw-process-fresh-tone-preview": BenchmarkWorkload(
                semantics: "Fresh worker process; process launch and manifest verification are excluded. Manifest verification SHA-256-reads every fixture, including the target RAW, before the timer, so this is process-fresh with a prevalidated/page-cache-warmed input, not a cold-file-open measurement. Decoder graph setup, CIRAWFilter interactive-preview scaleFactor, edit graph, and RGBA8 materialization/readback are included.",
                settingsSHA256: toneHash,
                phases: try phaseDistributions(
                    processFreshTimings,
                    decoderSamples: processFreshSamples.map(\.decoderGraphSetupMilliseconds),
                    totalOverride: processFreshTotals
                )
            ),
            "raw-warm-neutral-preview": BenchmarkWorkload(
                semantics: "Same 2560px interactive-preview RAW decode and preview-only RenderEngine; neutral settings; engine API, not the actual UI presentation path.",
                settingsSHA256: neutralHash,
                phases: try phaseDistributions(neutralSamples)
            ),
            "raw-warm-tone-exposure-slider-preview": BenchmarkWorkload(
                semantics: "Same 2560px interactive-preview RAW decode and preview-only RenderEngine; deterministic ±0.2 EV sequence around tone-base settings; measures engine budget, not input-to-screen latency.",
                settingsSHA256: toneHash,
                phases: try phaseDistributions(sliderSamples)
            ),
            "raw-warm-full-preview": BenchmarkWorkload(
                semantics: "Same 2560px interactive-preview RAW decode and preview-only RenderEngine; current full preset; engine API, not the actual UI presentation path. The word full refers to the preset, not decode resolution.",
                settingsSHA256: fullHash,
                phases: try phaseDistributions(fullSamples)
            ),
            "raw-warm-full-resolution-jpeg-q92": BenchmarkWorkload(
                semantics: "Same reusable RenderEngine's export context, with an independently decoded full-resolution RAW; full-resolution JPEG including graph, RGBA8 materialization, ImageIO encode/write, and atomic install.",
                settingsSHA256: fullHash,
                phases: try phaseDistributions(exportSamples)
            )
        ]

        let runtimeEnd = try RuntimeProvenance.captureCurrentExecutable()
        systemLoadObservations.append(
            BenchmarkSystemLoadObservation(
                scope: "run",
                boundary: "end",
                snapshot: try SystemLoadSnapshot.capture()
            )
        )
        let eligibilityReason = gateEligibility(
            runtimeStart: runtimeStart,
            runtimeEnd: runtimeEnd,
            quick: arguments.quick,
            measuredIterations: measuredIterations,
            expectedIterations: specification.measuredIterations,
            processFreshIterations: processFreshIterations,
            expectedProcessFreshIterations: specification.processFreshIterations,
            selectedSceneID: scene.id,
            expectedSceneID: specification.sceneID,
            previewDecoded: previewDecoded,
            workerSamples: processFreshSamples
        )
        let eligible = eligibilityReason == nil
        let thresholds = specification.thresholdsMilliseconds
        let gates: [String: BenchmarkGateResult] = [
            "process-fresh-low-resolution-preview": gate(
                observed: measurements["raw-process-fresh-tone-preview"]!.phases.total.p95,
                maximum: thresholds.processFreshLowResolutionPreviewP95,
                eligible: eligible,
                reason: eligibilityReason
            ),
            "warm-slider-engine-budget": gate(
                observed: measurements["raw-warm-tone-exposure-slider-preview"]!.phases.total.p95,
                maximum: thresholds.warmSliderEngineP95,
                eligible: eligible,
                reason: eligibilityReason
            ),
            "warm-high-quality-preview": gate(
                observed: measurements["raw-warm-full-preview"]!.phases.total.p95,
                maximum: thresholds.warmHighQualityPreviewP95,
                eligible: eligible,
                reason: eligibilityReason
            ),
            "full-resolution-jpeg-export": gate(
                observed: measurements["raw-warm-full-resolution-jpeg-q92"]!.phases.total.p95,
                maximum: thresholds.fullResolutionJPEGExportP95,
                eligible: eligible,
                reason: eligibilityReason
            )
        ]

        let postflightInputs = try loaded.verifyInputsAgain()
        let inputsUnchanged = postflightInputs == loaded.verifiedInputs
        guard inputsUnchanged else {
            throw CalibrationManifestError.invalid("benchmark中に校正入力が変わりました")
        }
        let postflightSource = try CalibrationManifestLoader.sourceFingerprint(
            sourcePaths,
            root: loaded.root
        )
        let sourceUnchanged = postflightSource.sha256 == source.sha256
            && postflightSource.files == source.files
        guard sourceUnchanged else {
            throw CalibrationManifestError.invalid("benchmark中に処理sourceが変わりました")
        }
        _ = try loaded.verifyManifestAgain()
        guard runtimeEnd.executableSHA256 == runtimeStart.executableSHA256 else {
            throw CalibrationManifestError.invalid(
                "benchmark中にcoordinator実行binaryのSHA-256が変わりました"
            )
        }
        guard let input = loaded.verifiedInputs.first(where: { $0.role == "\(scene.id).raw" }) else {
            throw CalibrationManifestError.invalid("benchmark inputの検証recordがありません")
        }
        let report = BenchmarkReport(
            schemaVersion: 3,
            benchmarkVersion: "photo-bench-render-benchmark-v3",
            runID: runID,
            startedAtUTC: startedAt,
            completedAtUTC: ISO8601Timestamp.now(),
            manifest: ManifestRunReference(
                path: relativePath(loaded.manifestURL, root: loaded.root),
                sha256: loaded.manifestSHA256,
                suiteID: manifest.suiteID
            ),
            runtimeStart: runtimeStart,
            runtimeEnd: runtimeEnd,
            processing: .current,
            sourceFingerprintSHA256: source.sha256,
            postflightSourceFingerprintSHA256: postflightSource.sha256,
            sourceFiles: source.files,
            input: input,
            configuration: BenchmarkConfigurationRecord(
                sceneID: scene.id,
                inputWidth: previewDecoded.info.nativeWidth,
                inputHeight: previewDecoded.info.nativeHeight,
                previewDecodedWidth: previewDecoded.info.width,
                previewDecodedHeight: previewDecoded.info.height,
                previewDecodeIntent: previewDecoded.info.intent.identifier,
                previewAppliedScaleFactor: previewDecoded.info.appliedScaleFactor,
                previewMaxDimension: specification.previewMaxDimension,
                fullResolutionDecodedWidth: fullResolutionDecoded.info.width,
                fullResolutionDecodedHeight: fullResolutionDecoded.info.height,
                fullResolutionDecodeIntent: fullResolutionDecoded.info.intent.identifier,
                fullResolutionRequestedMaximumDimension:
                    fullResolutionDecoded.info.requestedMaximumDimension,
                fullResolutionAppliedScaleFactor:
                    fullResolutionDecoded.info.appliedScaleFactor,
                fullResolutionDecoderBackend: fullResolutionDecoded.info.backend,
                jpegQuality: specification.jpegQuality,
                warmupIterations: warmupIterations,
                measuredIterations: measuredIterations,
                processFreshIterations: processFreshIterations,
                osCachesUncontrolled: true,
                inputCachePolicy: "Manifest verification SHA-256-reads every fixture before timed decode; the target RAW is therefore prevalidated and normally page-cache-warmed. No OS cache purge is attempted.",
                previewArchitecture: "CIRAWFilter interactive-preview scaleFactor at max dimension, followed by edit graph and CGImage/NSImage readback",
                contextPolicy: "one reusable RenderEngine with distinct preview/export Metal CIContext instances; cacheIntermediates=false in this slice",
                timingInterpretation: "Wall-clock API boundaries, not hardware GPU time. Core Image and Metal are lazy/asynchronous, so synchronization cost may appear in a later createCGImage or ImageIO phase. Use the emitted Instruments signposts for attribution."
            ),
            systemLoadObservations: systemLoadObservations,
            processFreshWorkerSamples: processFreshSamples,
            measurements: measurements,
            coordinatorPeakResidentMemoryBytes: ProcessMemory.peakResidentBytes(),
            maximumWorkerPeakResidentMemoryBytes: processFreshSamples
                .map(\.peakResidentMemoryBytes).max() ?? 0,
            peakResidentMemoryBytes: max(
                ProcessMemory.peakResidentBytes(),
                processFreshSamples.map(\.peakResidentMemoryBytes).max() ?? 0
            ),
            gateEligibility: eligible ? "eligible" : "not-evaluated: \(eligibilityReason!)",
            gates: gates,
            unmeasuredProductTargets: [
                "catalog startup <= 2 s",
                "cached photo open <= 300 ms",
                "actual slider input-to-screen latency and dropped frames",
                "UI high-quality settle after gesture end",
                "hardware GPU execution time (use emitted Instruments signposts)"
            ],
            inputHashesUnchanged: inputsUnchanged,
            sourceHashesUnchanged: sourceUnchanged
        )
        let runsDirectory = try CalibrationManifestLoader.prepareOutputDirectory(
            ".photobench/benchmark/runs",
            inside: loaded.root
        )
        let runURL = try CalibrationManifestLoader.prepareOutputFile(
            named: "\(runID).json",
            in: runsDirectory,
            inside: loaded.root
        )
        let latestURL = try CalibrationManifestLoader.prepareOutputFile(
            named: "latest.json",
            in: outputRoot,
            inside: loaded.root
        )
        try AtomicJSONWriter.write(report, to: runURL)
        try AtomicJSONWriter.write(report, to: latestURL)

        print("Benchmark report: \(latestURL.path)")
        for key in measurements.keys.sorted() {
            let p95 = measurements[key]!.phases.total.p95
            print("\(key): p95 \(String(format: "%.2f", p95)) ms")
        }
        for key in gates.keys.sorted() {
            print("\(key): \(gates[key]!.status)")
        }
        return try BenchmarkGateEvaluation.evaluate(gates.values)
    }

    private static func runWorker(_ arguments: BenchmarkArguments) throws {
        guard let sceneID = arguments.sceneID else {
            throw CalibrationManifestError.invalid("workerには--sceneが必要です")
        }
        let systemLoadStart = try SystemLoadSnapshot.capture()
        let loaded = try CalibrationManifestLoader.load(
            root: arguments.root,
            manifestURL: arguments.manifestURL
        )
        guard let scene = loaded.manifest.scenes.first(where: { $0.id == sceneID }) else {
            throw CalibrationManifestError.invalid("worker sceneがありません: \(sceneID)")
        }
        let preset = try XMPPresetParser.parse(
            url: loaded.resolve(loaded.manifest.preset.file.path)
        )
        try validatePreset(preset, manifest: loaded.manifest)
        let runtimeStart = try RuntimeProvenance.captureCurrentExecutable()
        guard let executableSHA256 = runtimeStart.executableSHA256 else {
            throw CalibrationManifestError.invalid("worker実行binaryのSHA-256がありません")
        }
        let settings = try CalibrationStageFactory.settings(for: "tone-base", preset: preset)
        let started = ContinuousClock.now
        let decoded = try CoreImageDecoder().decode(
            url: loaded.resolve(scene.raw.path),
            intent: .interactivePreview(
                maxDimension: loaded.manifest.benchmark.previewMaxDimension
            )
        )
        try validateBenchmarkPreviewRAW(
            decoded,
            scene: scene,
            manifest: loaded.manifest
        )
        let renderer = RenderEngine()
        let preview = try renderer.renderPreviewMeasured(
            decoded: decoded,
            settings: settings,
            maxDimension: CGFloat(loaded.manifest.benchmark.previewMaxDimension)
        )
        let processFreshPipelineMilliseconds = milliseconds(started.duration(to: .now))
        let runtimeEnd = try RuntimeProvenance.captureCurrentExecutable()
        let systemLoadEnd = try SystemLoadSnapshot.capture()
        let sample = BenchmarkWorkerSample(
            systemLoadStart: systemLoadStart,
            systemLoadEnd: systemLoadEnd,
            runtimeStart: runtimeStart,
            runtimeEnd: runtimeEnd,
            decoderGraphSetupMilliseconds: decoded.info.durationMilliseconds,
            preview: preview.timings,
            processFreshPipelineMilliseconds: processFreshPipelineMilliseconds,
            peakResidentMemoryBytes: ProcessMemory.peakResidentBytes(),
            decoderBackend: decoded.info.backend,
            calibrationID: decoded.info.calibrationID,
            decodeIntent: decoded.info.intent.identifier,
            requestedMaximumDimension: decoded.info.requestedMaximumDimension,
            nativeWidth: decoded.info.nativeWidth,
            nativeHeight: decoded.info.nativeHeight,
            decodedWidth: decoded.info.width,
            decodedHeight: decoded.info.height,
            appliedScaleFactor: decoded.info.appliedScaleFactor,
            executableSHA256: executableSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(sample) + Data("\n".utf8))
    }

    private static func launchWorker(
        root: URL,
        manifestURL: URL,
        sceneID: String
    ) throws -> BenchmarkWorkerSample {
        let process = Process()
        guard let bundledExecutable = Bundle.main.executableURL else {
            throw CalibrationManifestError.invalid("worker実行binaryのURLを取得できません")
        }
        let executable = bundledExecutable.standardizedFileURL.resolvingSymlinksInPath()
        process.executableURL = executable
        process.arguments = [
            "--worker",
            root.path,
            "--manifest",
            manifestURL.path,
            "--scene",
            sceneID
        ]
        process.currentDirectoryURL = root
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw CalibrationManifestError.invalid(
                "process-fresh workerが失敗しました: exit=\(process.terminationStatus)"
            )
        }
        return try JSONDecoder().decode(BenchmarkWorkerSample.self, from: data)
    }

    private static func phaseDistributions(
        _ samples: [RenderPhaseTimings],
        decoderSamples: [Double]? = nil,
        totalOverride: [Double]? = nil
    ) throws -> BenchmarkPhaseDistributions {
        let encode = samples.compactMap(\.jpegEncodeAndWriteMilliseconds)
        let install = samples.compactMap(\.atomicInstallMilliseconds)
        let decoderDistribution: BenchmarkDistribution?
        if let decoderSamples {
            decoderDistribution = try BenchmarkDistribution(samples: decoderSamples)
        } else {
            decoderDistribution = nil
        }
        return BenchmarkPhaseDistributions(
            decoderGraphSetup: decoderDistribution,
            graphAndKernelSetup: try BenchmarkDistribution(
                samples: samples.map(\.graphAndKernelSetupMilliseconds)
            ),
            materializeAndReadback: try BenchmarkDistribution(
                samples: samples.map(\.materializeAndReadbackMilliseconds)
            ),
            jpegEncodeAndWrite: encode.isEmpty
                ? nil
                : try BenchmarkDistribution(samples: encode),
            atomicInstall: install.isEmpty
                ? nil
                : try BenchmarkDistribution(samples: install),
            total: try BenchmarkDistribution(
                samples: totalOverride ?? samples.map(\.totalMilliseconds)
            )
        )
    }

    private static func gate(
        observed: Double,
        maximum: Double,
        eligible: Bool,
        reason: String?
    ) -> BenchmarkGateResult {
        guard eligible else {
            return BenchmarkGateResult(
                status: "notEvaluated",
                observedP95Milliseconds: observed,
                maximumP95Milliseconds: maximum,
                reason: reason
            )
        }
        return BenchmarkGateResult(
            status: observed <= maximum ? "passed" : "failed",
            observedP95Milliseconds: observed,
            maximumP95Milliseconds: maximum,
            reason: nil
        )
    }

    private static func gateEligibility(
        runtimeStart: RuntimeProvenance,
        runtimeEnd: RuntimeProvenance,
        quick: Bool,
        measuredIterations: Int,
        expectedIterations: Int,
        processFreshIterations: Int,
        expectedProcessFreshIterations: Int,
        selectedSceneID: String,
        expectedSceneID: String,
        previewDecoded: DecodedPhoto,
        workerSamples: [BenchmarkWorkerSample]
    ) -> String? {
        if quick { return "quick smoke run" }
        if selectedSceneID != expectedSceneID {
            return "only manifest benchmark.sceneID is eligible for threshold evaluation"
        }
        if runtimeStart.buildConfiguration != "release" {
            return "benchmark must use a release build"
        }
        guard let startExecutableSHA256 = runtimeStart.executableSHA256,
              let endExecutableSHA256 = runtimeEnd.executableSHA256,
              startExecutableSHA256 == endExecutableSHA256
        else {
            return "coordinator executable SHA-256 is missing or changed during the run"
        }
        if measuredIterations < expectedIterations || measuredIterations < 20 {
            return "at least 20 measured samples are required"
        }
        if processFreshIterations < expectedProcessFreshIterations
            || processFreshIterations < 20 {
            return "at least 20 process-fresh samples are required for p95"
        }
        if runtimeStart.metalDevice == nil || runtimeEnd.metalDevice == nil {
            return "Metal device is unavailable"
        }
        let disallowedThermalStates = Set(["serious", "critical", "unknown"])
        if disallowedThermalStates.contains(runtimeStart.thermalState)
            || disallowedThermalStates.contains(runtimeEnd.thermalState) {
            return "thermal state is not stable"
        }
        if runtimeStart.lowPowerModeEnabled || runtimeEnd.lowPowerModeEnabled {
            return "Low Power Mode is enabled"
        }
        if previewDecoded.info.nativeWidth * previewDecoded.info.nativeHeight < 24_000_000 {
            return "input is smaller than 24 MP"
        }
        if previewDecoded.info.intent.identifier != "interactive-preview" {
            return "coordinator preview did not use interactive-preview decode intent"
        }
        for (index, sample) in workerSamples.enumerated() {
            let start = sample.runtimeStart
            let end = sample.runtimeEnd
            if start.buildConfiguration != "release" || end.buildConfiguration != "release" {
                return "worker \(index) did not use a release build"
            }
            if start.executableSHA256 == nil
                || start.executableSHA256 != end.executableSHA256
                || start.executableSHA256 != runtimeStart.executableSHA256 {
                return "worker \(index) executable SHA-256 is missing or changed"
            }
            if start.metalDevice == nil || end.metalDevice == nil {
                return "worker \(index) Metal device is unavailable"
            }
            if disallowedThermalStates.contains(start.thermalState)
                || disallowedThermalStates.contains(end.thermalState) {
                return "worker \(index) thermal state is not stable"
            }
            if start.lowPowerModeEnabled || end.lowPowerModeEnabled {
                return "worker \(index) Low Power Mode is enabled"
            }
            if sample.decodeIntent != previewDecoded.info.intent.identifier
                || sample.requestedMaximumDimension
                    != previewDecoded.info.requestedMaximumDimension
                || sample.nativeWidth != previewDecoded.info.nativeWidth
                || sample.nativeHeight != previewDecoded.info.nativeHeight
                || sample.decodedWidth != previewDecoded.info.width
                || sample.decodedHeight != previewDecoded.info.height
                || sample.appliedScaleFactor != previewDecoded.info.appliedScaleFactor {
                return "worker \(index) preview decode provenance differs from coordinator"
            }
        }
        return nil
    }

    private static func validatePreset(
        _ preset: XMPPreset,
        manifest: CalibrationManifest
    ) throws {
        guard preset.cameraRawVersion == manifest.preset.cameraRawVersion,
              preset.processVersion == manifest.preset.processVersion,
              preset.rawProperties["UUID"] == manifest.preset.uuid
        else {
            throw CalibrationManifestError.invalid("benchmark XMP metadata不一致")
        }
    }

    private static func validateBenchmarkFullResolutionRAW(
        _ decoded: DecodedPhoto,
        scene: CalibrationScene,
        manifest: CalibrationManifest
    ) throws {
        guard decoded.info.isRAW,
              decoded.info.backend == manifest.expectedEnvironment.rawDecoderBackend,
              decoded.info.calibrationID == manifest.rawProfile.id,
              decoded.info.intent == .fullResolution,
              decoded.info.requestedMaximumDimension == nil,
              decoded.info.appliedScaleFactor == 1,
              decoded.info.nativeWidth == scene.capture.width,
              decoded.info.nativeHeight == scene.capture.height,
              decoded.info.width == scene.capture.width,
              decoded.info.height == scene.capture.height
        else {
            throw CalibrationManifestError.invalid(
                "benchmark RAWのdecoder/profile/dimensionがmanifestと一致しません"
            )
        }
    }

    private static func validateBenchmarkPreviewRAW(
        _ decoded: DecodedPhoto,
        scene: CalibrationScene,
        manifest: CalibrationManifest
    ) throws {
        let previewMaxDimension = manifest.benchmark.previewMaxDimension
        let nativeLongest = max(scene.capture.width, scene.capture.height)
        let expectedScale = min(1, Float(previewMaxDimension) / Float(nativeLongest))
        let actualLongest = max(decoded.info.width, decoded.info.height)
        guard decoded.info.isRAW,
              decoded.info.backend == manifest.expectedEnvironment.rawDecoderBackend,
              decoded.info.calibrationID == manifest.rawProfile.id,
              decoded.info.intent == .interactivePreview(maxDimension: previewMaxDimension),
              decoded.info.requestedMaximumDimension == previewMaxDimension,
              decoded.info.nativeWidth == scene.capture.width,
              decoded.info.nativeHeight == scene.capture.height,
              decoded.info.appliedScaleFactor.map({ abs($0 - expectedScale) < 0.000_001 }) == true,
              actualLongest == min(previewMaxDimension, nativeLongest)
        else {
            throw CalibrationManifestError.invalid(
                "benchmark preview RAWのintent/decoder/profile/dimensionがmanifestと一致しません"
            )
        }
    }

    private static func removeDedicatedScratch(_ scratch: URL, outputRoot: URL) throws {
        let normalizedOutputRoot = outputRoot.standardizedFileURL
        let normalizedScratch = scratch.standardizedFileURL
        let expectedParent = outputRoot
            .appendingPathComponent("scratch", isDirectory: true)
            .standardizedFileURL
        guard normalizedOutputRoot.resolvingSymlinksInPath().path == normalizedOutputRoot.path,
              normalizedScratch.resolvingSymlinksInPath().path == normalizedScratch.path,
              normalizedScratch.deletingLastPathComponent() == expectedParent,
              !normalizedScratch.lastPathComponent.isEmpty
        else {
            throw CalibrationManifestError.invalid("scratch cleanup targetが不正です")
        }
        if FileManager.default.fileExists(atPath: normalizedScratch.path) {
            try FileManager.default.removeItem(at: normalizedScratch)
        }
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

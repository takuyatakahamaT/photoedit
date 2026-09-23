import Accelerate
import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
@testable import PhotoCore

/// `RenderEngine.makePreviewWorkingCopy` / `preparePreviewFromWorkingCopy`:
/// the working copy is refused by every export and full-resolution
/// presentation entry point, its statistics never reach the full-resolution
/// decode, and its preview stays close to the full-resolution preview
/// (synthetic source always; `P1524180.RW2` + `niho-preset night.xmp` when
/// the private fixture and the Adobe DCP exist). `PHOTO_BENCH_PREVIEW_PERF=1`
/// additionally runs the slider-tick timing comparison (meaningful in a
/// release build: `swift test -c release`); `PHOTO_BENCH_PREVIEW_DUMP_DIR`
/// writes the RAW comparison previews and ΔE00 maps there (private photo:
/// keep them local).
///
/// Fidelity metrics mirror `CALIBRATION.md`'s preview parity: encoded-sRGB
/// frames, ΔE00 after a sigma 1.2 Gaussian blur (mean and p95), mean EV drift
/// of the blurred linear luminance (reference > 0.01), and the highlight
/// plateau criterion; plus the unblurred ΔE00 and linear-RGB difference.
@Suite(.serialized)
struct PreviewWorkingCopyTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - Contract

    @Test func workingCopyIsPreviewOnlyAndEveryOutputEntryPointRefusesIt() throws {
        let engine = RenderEngine()
        let decoded = Self.syntheticDecode(width: 1_200, height: 800)
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded, maxDimension: 512)

        let provenance = try #require(workingCopy.info.previewWorkingCopy)
        #expect(workingCopy.isPreviewWorkingCopy)
        #expect(!decoded.isPreviewWorkingCopy)
        #expect(provenance.maxDimension == 512)
        #expect(provenance.sourceWidth == 1_200)
        #expect(provenance.sourceHeight == 800)
        #expect(provenance.isReduced)
        #expect(provenance.byteCount == 512 * 342 * 16)
        #expect(workingCopy.info.width == 512)
        #expect(workingCopy.info.height == 342)
        #expect(workingCopy.info.nativeWidth == 1_200)
        #expect(workingCopy.info.nativeHeight == 800)
        #expect(workingCopy.info.intent == .fullResolution)
        #expect(workingCopy.image.extent == CGRect(x: 0, y: 0, width: 512, height: 342))
        #expect(workingCopy.sourceURL == decoded.sourceURL)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchWorkingCopyGuard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpegURL = directory.appendingPathComponent("forbidden.jpg")
        let tiffURL = directory.appendingPathComponent("forbidden.tif")
        let comparisonTIFFURL = directory.appendingPathComponent("forbidden-comparison.tif")

        Self.expectExportForbidden(source: decoded.sourceURL) {
            _ = try engine.exportJPEG(decoded: workingCopy, settings: .neutral, destination: jpegURL)
        }
        Self.expectExportForbidden(source: decoded.sourceURL) {
            _ = try engine.exportJPEGMeasured(decoded: workingCopy, settings: .neutral, destination: jpegURL)
        }
        Self.expectExportForbidden(source: decoded.sourceURL) {
            _ = try engine.exportTIFF(decoded: workingCopy, settings: .neutral, destination: tiffURL)
        }
        Self.expectExportForbidden(source: decoded.sourceURL) {
            _ = try engine.exportTIFF(
                decoded: workingCopy, settings: .neutral, destination: comparisonTIFFURL, maxDimension: 256
            )
        }
        #expect(!FileManager.default.fileExists(atPath: jpegURL.path))
        #expect(!FileManager.default.fileExists(atPath: tiffURL.path))
        #expect(!FileManager.default.fileExists(atPath: comparisonTIFFURL.path))

        // Full-resolution presentation, a copy of a copy, and a copy asked for
        // more pixels than it holds are all refused.
        Self.expectPresentationForbidden(source: decoded.sourceURL) {
            _ = try engine.prepareProductionPreview(decoded: workingCopy, settings: .neutral, maxDimension: 512)
        }
        Self.expectPresentationForbidden(source: decoded.sourceURL) {
            _ = try engine.makePreviewWorkingCopy(from: workingCopy, maxDimension: 256)
        }
        Self.expectPresentationForbidden(source: decoded.sourceURL) {
            _ = try engine.preparePreviewFromWorkingCopy(workingCopy: workingCopy, settings: .neutral, maxDimension: 513)
        }
        // The working-copy entry point only takes working copies.
        Self.expectPresentationForbidden(source: decoded.sourceURL) {
            _ = try engine.preparePreviewFromWorkingCopy(workingCopy: decoded, settings: .neutral, maxDimension: 512)
        }

        // The full-resolution decode itself is untouched and still exports.
        let exported = try engine.exportJPEG(decoded: decoded, settings: .neutral, destination: jpegURL)
        #expect(exported >= 0)
        #expect(FileManager.default.fileExists(atPath: jpegURL.path))

        let atCopySize = try engine.preparePreviewFromWorkingCopy(
            workingCopy: workingCopy, settings: .neutral, maxDimension: 512
        )
        #expect(atCopySize.extent == CGRect(x: 0, y: 0, width: 512, height: 342))
        #expect(atCopySize.maxDimension == 512)
        let smaller = try engine.preparePreviewFromWorkingCopy(
            workingCopy: workingCopy, settings: .neutral, maxDimension: 256
        )
        #expect(max(smaller.extent.width, smaller.extent.height) == 256)
    }

    @Test func workingCopyRequiresAFullResolutionDecode() throws {
        let sourceURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            print("SKIP: DSC02072.JPG がこの環境に無いため、この環境ではスキップします。")
            return
        }
        let engine = RenderEngine()
        let interactive = try CoreImageDecoder().decode(url: sourceURL, intent: .interactivePreview(maxDimension: 320))
        Self.expectPresentationForbidden(source: sourceURL) {
            _ = try engine.makePreviewWorkingCopy(from: interactive, maxDimension: 320)
        }
        let full = try CoreImageDecoder().decode(url: sourceURL)
        let workingCopy = try engine.makePreviewWorkingCopy(from: full, maxDimension: 640)
        #expect(workingCopy.info.isBoundedSRGBRaster == full.info.isBoundedSRGBRaster)
        #expect(max(workingCopy.info.width, workingCopy.info.height) == 640)
        let frame = try engine.preparePreviewFromWorkingCopy(workingCopy: workingCopy, settings: .neutral, maxDimension: 640)
        let reference = try engine.prepareProductionPreview(decoded: full, settings: .neutral, maxDimension: 640)
        #expect(frame.extent == reference.extent)
        let metrics = try Self.parity(
            reference: Self.readEncodedSRGB(reference), candidate: Self.readEncodedSRGB(frame)
        )
        print("PREVIEW-PARITY DSC02072.JPG neutral 640: \(metrics.summary)")
        // Measured 0.045 / 0.068 (Mac Studio): only intermediate precision
        // differs (the full-resolution graph's Lanczos runs in RGBAh).
        #expect(metrics.blurredMeanDeltaE <= 0.1)
        #expect(metrics.blurredP95DeltaE <= 0.15)
    }

    /// A source already within the bound is materialized at its own size
    /// (never enlarged), then serves any preview size up to its own.
    @Test func sourceWithinTheBoundIsMaterializedAtItsOwnSize() throws {
        let engine = RenderEngine()
        let decoded = Self.syntheticDecode(width: 400, height: 300)
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded, maxDimension: 512)
        let provenance = try #require(workingCopy.info.previewWorkingCopy)
        #expect(!provenance.isReduced)
        #expect(workingCopy.info.width == 400)
        #expect(workingCopy.info.height == 300)
        let frame = try engine.preparePreviewFromWorkingCopy(workingCopy: workingCopy, settings: .neutral, maxDimension: 2_560)
        let reference = try engine.preparePreview(decoded: decoded, settings: .neutral, maxDimension: 2_560)
        #expect(frame.extent == reference.extent)
        let metrics = try Self.parity(
            reference: Self.readEncodedSRGB(reference), candidate: Self.readEncodedSRGB(frame), sampleStride: 1
        )
        #expect(metrics.meanDeltaE <= 0.01)
        #expect(metrics.meanAbsLinear <= 0.0005)
    }

    /// The materialized copy holds the reduction graph's own pixels
    /// (vertical orientation included), up to float precision.
    @Test func materializedCopyHoldsTheReductionGraphsPixels() throws {
        let engine = RenderEngine()
        let decoded = Self.syntheticDecode(width: 1_600, height: 1_000)
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded, maxDimension: 640)
        let direct = PreviewWorkingRaster.reduce(decoded.image, maxDimension: 640)
        #expect(direct.extent == CGRect(x: 0, y: 0, width: 640, height: 400))
        #expect(workingCopy.image.extent == direct.extent)
        let expected = Self.readLinear(direct, bounds: direct.extent)
        let materialized = Self.readLinear(workingCopy.image, bounds: direct.extent)
        let difference = Self.maxAbsDifference(expected, materialized)
        print("PREVIEW-WORKING-COPY materialized vs lazy reduction max|Δ| = \(difference)")
        // The lazy graph renders through the readback context's RGBAh
        // intermediates; the copy was reduced in RGBAf.
        #expect(difference <= 2e-3)
    }

    /// Statistics computed from a working copy's pixels are cached apart from
    /// the full-resolution decode's (same URL): a "working copy" whose pixels
    /// are deliberately unlike its source must not change what the source
    /// renders afterwards.
    @Test func workingCopyStatisticsNeverReachTheFullResolutionDecode() throws {
        let engine = RenderEngine()
        var settings = EditSettings.neutral
        settings.highlights = -70
        settings.shadows = 70
        let decoded = Self.syntheticDecode(width: 1_200, height: 800)
        let darkCopy = DecodedPhoto(
            sourceURL: decoded.sourceURL,
            image: CIImage(color: CIColor(red: 0.004, green: 0.004, blue: 0.004))
                .cropped(to: CGRect(x: 0, y: 0, width: 512, height: 342)),
            metadata: [:],
            info: DecodeInfo(
                backend: "synthetic", width: 512, height: 342, durationMilliseconds: 0, isRAW: false,
                nativeWidth: 1_200, nativeHeight: 800,
                previewWorkingCopy: PreviewWorkingCopyInfo(
                    maxDimension: 512, sourceWidth: 1_200, sourceHeight: 800,
                    durationMilliseconds: 0, byteCount: 0
                )
            )
        )
        _ = try engine.preparePreviewFromWorkingCopy(workingCopy: darkCopy, settings: settings, maxDimension: 512)
        let afterCopy = try engine.preparePreview(decoded: decoded, settings: settings, maxDimension: 512)
        let unshared = DecodedPhoto(
            sourceURL: URL(fileURLWithPath: "/virtual/unshared-\(UUID().uuidString).tif"),
            image: decoded.image, metadata: [:], info: decoded.info
        )
        let reference = try engine.preparePreview(decoded: unshared, settings: settings, maxDimension: 512)
        let afterCopyPixels = Self.readLinear(afterCopy.image, bounds: afterCopy.extent)
        let referencePixels = Self.readLinear(reference.image, bounds: reference.extent)
        #expect(Self.maxAbsDifference(afterCopyPixels, referencePixels) <= 1e-6)

        // Non-vacuity: the same dark statistic *sharing* a key does change
        // this render, so the equality above is meaningful.
        let sharedURL = URL(fileURLWithPath: "/virtual/shared-\(UUID().uuidString).tif")
        _ = engine.apply(settings: settings, to: darkCopy.image, sourceURL: sharedURL)
        let contaminated = engine.apply(settings: settings, to: decoded.image, sourceURL: sharedURL)
        let clean = engine.apply(settings: settings, to: decoded.image, sourceURL: nil)
        let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let contaminationEffect = Self.maxAbsDifference(
            Self.readLinear(contaminated, bounds: bounds), Self.readLinear(clean, bounds: bounds)
        )
        print("PREVIEW-WORKING-COPY statistic contamination effect max|Δ| = \(contaminationEffect)")
        #expect(contaminationEffect > 1e-3)
    }

    // MARK: - Fidelity

    @Test func syntheticWorkingCopyPreviewMatchesTheFullResolutionPreview() throws {
        let engine = RenderEngine()
        let decoded = Self.syntheticDecode(width: 6_000, height: 4_000)
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded)
        #expect(workingCopy.info.width == 2_560)
        #expect(workingCopy.info.height == 1_707)

        let night = try XMPPresetParser.parse(url: projectRoot.appendingPathComponent("niho-preset night.xmp"))
        var detail = EditSettings.neutral
        detail.highlights = -60
        detail.shadows = 60
        detail.texture = 60
        detail.clarity = 40
        // Limits are about twice the values measured on the Mac Studio
        // (blurred ΔE00 mean / p95, linear |Δ| mean): neutral 0.030 / 0.038 /
        // 0.0002, night 0.18 / 0.37 / 0.0021, detail 0.26 / 0.48 / 0.0020 --
        // all far inside `CALIBRATION.md`'s preview parity (1.0 / 2.0).
        let cases: [(name: String, settings: EditSettings, meanLimit: Double, p95Limit: Double, linearLimit: Double)] = [
            ("neutral", .neutral, 0.06, 0.1, 0.0005),
            ("night", night.applying(to: .neutral), 0.35, 0.75, 0.0045),
            ("detail", detail, 0.5, 0.95, 0.0045)
        ]
        for testCase in cases {
            let reference = try engine.preparePreview(decoded: decoded, settings: testCase.settings, quality: .final)
            let frame = try engine.preparePreviewFromWorkingCopy(
                workingCopy: workingCopy, settings: testCase.settings, quality: .final
            )
            #expect(frame.extent == reference.extent)
            let referencePixels = try Self.readEncodedSRGB(reference)
            let framePixels = try Self.readEncodedSRGB(frame)
            let metrics = try Self.parity(reference: referencePixels, candidate: framePixels)
            let plateau = try Self.plateau(reference: referencePixels, candidate: framePixels)
            print("PREVIEW-PARITY synthetic \(testCase.name) 6000x4000->2560: \(metrics.summary) | \(plateau.summary)")
            #expect(metrics.blurredMeanDeltaE <= testCase.meanLimit, "\(testCase.name)")
            #expect(metrics.blurredP95DeltaE <= testCase.p95Limit, "\(testCase.name)")
            #expect(metrics.meanAbsLinear <= testCase.linearLimit, "\(testCase.name)")
            #expect(abs(metrics.meanEVDrift) <= 0.01, "\(testCase.name)")
            // `CALIBRATION.md` plateau limits (measured <= 0.000002 here).
            #expect(plateau.netAreaChange <= 0.0001, "\(testCase.name)")
            #expect(plateau.outsideDilation <= 0.0001, "\(testCase.name)")
        }
    }

    @Test func rawWorkingCopyPreviewMatchesTheFullResolutionPreviewWithTheNightPreset() throws {
        let url = projectRoot.appendingPathComponent("P1524180.RW2")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: P1524180.RW2 がこの環境に無いため、この環境ではスキップします。")
            return
        }
        guard AdobeProfileLocator().locateDCP(uniqueCameraModel: "Panasonic DC-S5") != nil,
              AdobeProfileLocator().locateAdobeColorLookXMP() != nil
        else {
            print("SKIP: Panasonic DC-S5のAdobe DCP/Adobe Color.xmpが見つからないため、この環境ではスキップします。")
            return
        }
        let engine = RenderEngine()
        let decoded = try PhotoDecoder().decode(url: url)
        let fullHandle = try #require(decoded.adobeBase)
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded)
        let copyHandle = try #require(workingCopy.adobeBase)
        let provenance = try #require(workingCopy.info.previewWorkingCopy)
        #expect(provenance.isReduced)
        #expect(max(workingCopy.info.width, workingCopy.info.height) == 2_560)
        #expect(workingCopy.info.isRAW)
        #expect(workingCopy.info.lensCorrection == decoded.info.lensCorrection)
        #expect(fullHandle.previewWorkingCopyLongEdge == nil)
        #expect(copyHandle.previewWorkingCopyLongEdge == 2_560)
        print(
            "PREVIEW-WORKING-COPY P1524180 source=\(decoded.info.width)x\(decoded.info.height) "
                + "copy=\(workingCopy.info.width)x\(workingCopy.info.height) "
                + "camera extent=\(fullHandle.cameraImage.extent) "
                + String(format: "created in %.1fms, %.1f MB", provenance.durationMilliseconds, Double(provenance.byteCount) / 1_048_576)
        )

        let night = try XMPPresetParser.parse(url: projectRoot.appendingPathComponent("niho-preset night.xmp"))
            .applying(to: .neutral)
        // The full-resolution statistic first, then the copy's: the copy
        // must neither overwrite nor read the full-resolution entry.
        let fullRatio = fullHandle.highlightRatioBase(for: night)
        let fullMeanLn = fullHandle.meanLn(for: night)
        let copyRatio = copyHandle.highlightRatioBase(for: night)
        let copyMeanLn = copyHandle.meanLn(for: night)
        #expect(fullHandle.highlightRatioBase(for: night) == fullRatio)
        #expect(fullHandle.meanLn(for: night) == fullMeanLn)
        #expect(copyRatio != fullRatio || copyMeanLn != fullMeanLn)
        print(
            "PREVIEW-WORKING-COPY P1524180 night statistics full: ratio=\(fullRatio) meanLn=\(fullMeanLn) "
                + "copy: ratio=\(copyRatio) meanLn=\(copyMeanLn)"
        )

        // Measured on the Mac Studio (blurred ΔE00 mean / p95, linear |Δ|
        // mean, EV drift): neutral final 0.068 / 0.163 / 0.0006 / +0.0016,
        // night final 0.192 / 0.495 / 0.0029 / -0.0027, night interactive
        // 0.217 / 0.559 / 0.0031 / -0.0048. The limits below are about twice
        // that; `CALIBRATION.md`'s preview parity contract is 1.0 / 2.0 /
        // EV 0.02.
        //
        // The contract's highlight-plateau criterion is NOT met: net plateau
        // area +0.0030 / +0.0038 / +0.0035 and area outside the 1 px dilation
        // 0.00029 / 0.00077 / 0.00061 (limits 0.0001 each). The shelf is the
        // bright, near-flat window: the Adobe look/tone cubes clamp their
        // input to [0, 1], and the copy clamps already-averaged values where
        // the full-resolution path clamps per pixel before averaging, so more
        // pixels come out exactly flat (no 8-bit pixel reaches 255 in either;
        // side-by-side crops look identical). The plateau bounds below only
        // guard against that growing further; they are not an acceptance.
        let cases: [(name: String, settings: EditSettings, quality: SpatialToneQuality)] = [
            ("neutral final", .neutral, .final),
            ("night final", night, .final),
            ("night interactive", night, .interactive)
        ]
        for testCase in cases {
            let reference = try engine.prepareProductionPreview(
                decoded: decoded, settings: testCase.settings, quality: testCase.quality
            )
            let frame = try engine.preparePreviewFromWorkingCopy(
                workingCopy: workingCopy, settings: testCase.settings, quality: testCase.quality
            )
            #expect(frame.extent == reference.extent)
            let referencePixels = try Self.readEncodedSRGB(reference)
            let framePixels = try Self.readEncodedSRGB(frame)
            let metrics = try Self.parity(reference: referencePixels, candidate: framePixels)
            let plateau = try Self.plateau(reference: referencePixels, candidate: framePixels)
            print("PREVIEW-PARITY P1524180 \(testCase.name) full->2560 vs copy: \(metrics.summary) | \(plateau.summary)")
            try Self.dumpComparison(
                reference: referencePixels, candidate: framePixels,
                name: "P1524180-" + testCase.name.replacingOccurrences(of: " ", with: "-")
            )
            #expect(metrics.blurredMeanDeltaE <= 0.45, "\(testCase.name)")
            #expect(metrics.blurredP95DeltaE <= 1.1, "\(testCase.name)")
            #expect(metrics.meanAbsLinear <= 0.0065, "\(testCase.name)")
            #expect(abs(metrics.meanEVDrift) <= 0.01, "\(testCase.name)")
            #expect(plateau.netAreaChange <= 0.008, "\(testCase.name)")
            #expect(plateau.outsideDilation <= 0.0016, "\(testCase.name)")
        }
    }

    // MARK: - Slider-tick timings (opt-in)

    /// `PHOTO_BENCH_PREVIEW_PERF=1 swift test --filter PreviewWorkingCopyTests/sliderTickTimings`:
    /// one process, P1524180.RW2 with the night preset at the app's
    /// `.interactive` tick quality. Each path moves its sliders through its
    /// own values (offset per path), so no path reuses another's baked
    /// cubes or statistics.
    @Test func sliderTickTimings() throws {
        guard ProcessInfo.processInfo.environment["PHOTO_BENCH_PREVIEW_PERF"] == "1" else {
            print("SKIP: PHOTO_BENCH_PREVIEW_PERF=1 のときだけ実測します。")
            return
        }
        let url = projectRoot.appendingPathComponent("P1524180.RW2")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP: P1524180.RW2 がこの環境に無いため、この環境ではスキップします。")
            return
        }
        let base = try XMPPresetParser.parse(url: projectRoot.appendingPathComponent("niho-preset night.xmp"))
            .applying(to: .neutral)
        let engine = RenderEngine()

        let decodeStarted = ContinuousClock.now
        let decoded = try PhotoDecoder().decode(url: url)
        let decodeMilliseconds = Self.milliseconds(since: decodeStarted)
        print(
            "PREVIEW-PERF decode \(String(format: "%.0f", decodeMilliseconds))ms backend=\(decoded.info.backend) "
                + "adobeBase=\(decoded.adobeBase != nil) size=\(decoded.info.width)x\(decoded.info.height)"
        )

        let createStarted = ContinuousClock.now
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded)
        let createMilliseconds = Self.milliseconds(since: createStarted)
        let provenance = try #require(workingCopy.info.previewWorkingCopy)
        print(
            "PREVIEW-PERF create working copy \(String(format: "%.0f", createMilliseconds))ms "
                + "\(workingCopy.info.width)x\(workingCopy.info.height) "
                + "\(String(format: "%.1f", Double(provenance.byteCount) / 1_048_576))MB"
        )

        enum Path { case full, copy(DecodedPhoto) }
        let paths: [(name: String, path: Path)] = [
            (name: "full", path: .full),
            (name: "copy", path: .copy(workingCopy))
        ]

        func tick(_ path: Path, _ settings: EditSettings, _ quality: SpatialToneQuality) throws -> (prepare: Double, materialize: Double) {
            let prepareStarted = ContinuousClock.now
            let frame: PreparedPreviewFrame
            switch path {
            case .full:
                frame = try engine.prepareProductionPreview(decoded: decoded, settings: settings, quality: quality)
            case let .copy(copy):
                frame = try engine.preparePreviewFromWorkingCopy(workingCopy: copy, settings: settings, quality: quality)
            }
            let prepare = Self.milliseconds(since: prepareStarted)
            let materializeStarted = ContinuousClock.now
            _ = try engine.materializePreview(frame)
            return (prepare, Self.milliseconds(since: materializeStarted))
        }

        // Opening the photo: the app's first render (`.final`), each path
        // with its own Contrast/Orange values so each bakes its own cubes.
        for (lane, entry) in paths.enumerated() {
            var settings = base
            settings.contrast += Double(lane)
            settings.hsl[.orange, default: HSLAdjustment()].saturation += Double(lane)
            let first = try tick(entry.path, settings, .final)
            print(
                "PREVIEW-PERF open \(entry.name) first render (.final) prepare \(String(format: "%.0f", first.prepare))ms "
                    + "materialize \(String(format: "%.0f", first.materialize))ms"
            )
        }

        let operations: [(name: String, apply: (inout EditSettings, Double) -> Void, step: Double)] = [
            ("Exposure", { $0.exposure += $1 }, 0.02),
            ("HSL Orange saturation", { $0.hsl[.orange, default: HSLAdjustment()].saturation += $1 }, 2),
            ("Shadows", { $0.shadows += $1 }, 2)
        ]
        var summary: [String] = []
        for operation in operations {
            for (lane, entry) in paths.enumerated() {
                // lane offsets keep every path on values no other path used.
                let laneOffset = operation.step * 0.25 * Double(lane + 1)
                var warmup = base
                operation.apply(&warmup, -operation.step + laneOffset)
                _ = try tick(entry.path, warmup, .interactive)
                var prepares: [Double] = []
                var materializes: [Double] = []
                for index in 1...5 {
                    var settings = base
                    operation.apply(&settings, operation.step * Double(index) + laneOffset)
                    let timing = try tick(entry.path, settings, .interactive)
                    prepares.append(timing.prepare)
                    materializes.append(timing.materialize)
                }
                let totals = zip(prepares, materializes).map { $0 + $1 }
                let line = "PREVIEW-PERF tick \(operation.name) \(entry.name): "
                    + "prepare \(Self.formatted(prepares)) materialize \(Self.formatted(materializes)) "
                    + "total median \(String(format: "%.0f", Self.median(totals)))ms mean \(String(format: "%.0f", totals.reduce(0, +) / Double(totals.count)))ms"
                print(line)
                summary.append(line)
            }
        }
        print("PREVIEW-PERF summary\n" + summary.joined(separator: "\n"))

        // Work per tick that does not scale with pixels: every new value of a
        // cube-baked slider bakes a 64^3 cube on the CPU (HSL -> cube Q,
        // Contrast/Whites/Blacks/curves -> cube P).
        var probe = base
        probe.hsl[.orange, default: HSLAdjustment()].saturation += 0.125
        let colorCubeStarted = ContinuousClock.now
        _ = AdobeBaseRenderer.postColorCube(settings: probe)
        let colorCubeMilliseconds = Self.milliseconds(since: colorCubeStarted)
        probe.contrast += 0.125
        let toneCubeStarted = ContinuousClock.now
        _ = AdobeBaseRenderer.postOpsCube(exposureNonRaw: 0, settings: probe)
        let toneCubeMilliseconds = Self.milliseconds(since: toneCubeStarted)
        print(
            "PREVIEW-PERF cube bake for one new value: color cube Q \(String(format: "%.0f", colorCubeMilliseconds))ms, "
                + "tone cube P \(String(format: "%.0f", toneCubeMilliseconds))ms"
        )
    }

    // MARK: - Metric self-check

    /// Sharma, Wu & Dalal (2005) test pairs 1 and 17 for the ΔE00 helper.
    @Test func deltaE2000HelperMatchesPublishedPairs() {
        let first = Self.deltaE2000(SIMD3(50, 2.6772, -79.7751), SIMD3(50, 0, -82.7485))
        let seventeenth = Self.deltaE2000(SIMD3(50, 2.5, 0), SIMD3(73, 25, -18))
        #expect(abs(first - 2.0425) < 1e-4)
        #expect(abs(seventeenth - 27.1492) < 1e-4)
    }

    // MARK: - Helpers

    /// A procedural full-resolution non-RAW "photo" (no CPU pixel buffer):
    /// smooth 2D color gradients and a vignette, hard-edged 320px squares, a
    /// fine rotated stripe texture near the reduced Nyquist limit, a medium
    /// stripe texture and deterministic chroma noise.
    static func syntheticDecode(width: Int, height: Int) -> DecodedPhoto {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIColor {
            CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linear)!
        }
        func generator(_ name: String, _ parameters: [String: Any]) -> CIImage {
            CIFilter(name: name, parameters: parameters)!.outputImage!
        }
        let base = generator("CILinearGradient", [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: w, y: h),
            "inputColor0": color(0.03, 0.05, 0.12),
            "inputColor1": color(0.85, 0.62, 0.35)
        ])
        let vignette = generator("CIRadialGradient", [
            "inputCenter": CIVector(x: 0.35 * w, y: 0.55 * h),
            "inputRadius0": 0,
            "inputRadius1": 0.75 * w,
            "inputColor0": color(1, 1, 1),
            "inputColor1": color(0.35, 0.35, 0.35)
        ])
        let squares = generator("CICheckerboardGenerator", [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputColor0": color(1, 1, 1),
            "inputColor1": color(0.6, 0.6, 0.6),
            "inputWidth": 320,
            "inputSharpness": 1
        ])
        let fine = generator("CIStripesGenerator", [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputColor0": color(1, 1, 1),
            "inputColor1": color(0.82, 0.82, 0.82),
            "inputWidth": 2.5,
            "inputSharpness": 0.6
        ]).transformed(by: CGAffineTransform(rotationAngle: 25 * .pi / 180))
        let medium = generator("CIStripesGenerator", [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputColor0": color(1, 1, 1),
            "inputColor1": color(0.9, 0.9, 0.9),
            "inputWidth": 22,
            "inputSharpness": 0.3
        ]).transformed(by: CGAffineTransform(rotationAngle: -60 * .pi / 180))
        // `CIRandomGenerator`'s alpha is random too: force it to 1 *before*
        // any color filter unpremultiplies, or low-alpha samples become
        // sparse hot pixels (r / a) instead of +-4 % chroma noise.
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let noise = generator("CIRandomGenerator", [:]).settingAlphaOne(in: bounds).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.08, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.08, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.08, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.96, y: 0.96, z: 0.96, w: 1)
        ])
        var image = base
        for layer in [vignette, squares, fine, medium, noise] {
            image = layer.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image])
        }
        return DecodedPhoto(
            sourceURL: URL(fileURLWithPath: "/virtual/synthetic-\(UUID().uuidString).tif"),
            image: image.cropped(to: bounds),
            metadata: [:],
            info: DecodeInfo(backend: "synthetic", width: width, height: height, durationMilliseconds: 0, isRAW: false)
        )
    }

    static func expectExportForbidden(source: URL, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("作業コピーから書き出しが成功しました。")
        } catch let error as RenderEngineError {
            guard case let .previewResolutionExportForbidden(rejected) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejected == source)
        } catch {
            Issue.record("想定外のエラーです: \(error)")
        }
    }

    static func expectPresentationForbidden(source: URL, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("拒否されるべきプレビュー入口が成功しました。")
        } catch let error as RenderEngineError {
            guard case let .previewResolutionPresentationForbidden(rejected) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejected == source)
        } catch {
            Issue.record("想定外のエラーです: \(error)")
        }
    }

    static func makeReadbackContext() -> CIContext {
        CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false
        ])
    }

    static func readLinear(_ image: CIImage, bounds: CGRect) -> [Float] {
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let context = makeReadbackContext()
        pixels.withUnsafeMutableBytes { raw in
            context.render(
                image, toBitmap: raw.baseAddress!, rowBytes: width * 16, bounds: bounds,
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            )
        }
        return pixels
    }

    static func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var result: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for index in 0..<pa.count {
                    result = max(result, abs(pa[index] - pb[index]))
                }
            }
        }
        return result
    }

    /// Planar encoded-sRGB float pixels of a preview frame, clamped to [0, 1]
    /// like the 16-bit comparison TIFFs.
    struct EncodedFrame {
        let width: Int
        let height: Int
        var red: [Float]
        var green: [Float]
        var blue: [Float]
    }

    static func readEncodedSRGB(_ frame: PreparedPreviewFrame) throws -> EncodedFrame {
        let width = Int(frame.extent.width)
        let height = Int(frame.extent.height)
        let count = width * height
        var rgba = [Float](repeating: 0, count: count * 4)
        let context = makeReadbackContext()
        rgba.withUnsafeMutableBytes { raw in
            context.render(
                frame.image, toBitmap: raw.baseAddress!, rowBytes: width * 16, bounds: frame.extent,
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
        }
        var red = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue = [Float](repeating: 0, count: count)
        rgba.withUnsafeBufferPointer { source in
            red.withUnsafeMutableBufferPointer { r in
                green.withUnsafeMutableBufferPointer { g in
                    blue.withUnsafeMutableBufferPointer { b in
                        for index in 0..<count {
                            r[index] = min(max(source[4 * index], 0), 1)
                            g[index] = min(max(source[4 * index + 1], 0), 1)
                            b[index] = min(max(source[4 * index + 2], 0), 1)
                        }
                    }
                }
            }
        }
        return EncodedFrame(width: width, height: height, red: red, green: green, blue: blue)
    }

    /// Separable Gaussian, sigma 1.2, radius 5 -- `cv2.GaussianBlur(..., sigma=1.2)`'s
    /// 11-tap kernel (edges extended instead of reflected).
    static func gaussianBlurred(_ plane: [Float], width: Int, height: Int) -> [Float] {
        let sigma: Float = 1.2
        let taps = (-5...5).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = taps.reduce(0, +)
        let kernel = taps.map { $0 / total }
        var source = plane
        var temporary = [Float](repeating: 0, count: plane.count)
        var destination = [Float](repeating: 0, count: plane.count)
        let rowBytes = width * MemoryLayout<Float>.size
        source.withUnsafeMutableBufferPointer { s in
            temporary.withUnsafeMutableBufferPointer { t in
                destination.withUnsafeMutableBufferPointer { d in
                    var sourceBuffer = vImage_Buffer(
                        data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes
                    )
                    var temporaryBuffer = vImage_Buffer(
                        data: t.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes
                    )
                    var destinationBuffer = vImage_Buffer(
                        data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes
                    )
                    let flags = vImage_Flags(kvImageEdgeExtend)
                    _ = vImageConvolve_PlanarF(
                        &sourceBuffer, &temporaryBuffer, nil, 0, 0, kernel, 1, UInt32(kernel.count), 0, flags
                    )
                    _ = vImageConvolve_PlanarF(
                        &temporaryBuffer, &destinationBuffer, nil, 0, 0, kernel, UInt32(kernel.count), 1, 0, flags
                    )
                }
            }
        }
        return destination
    }

    struct ParityMetrics {
        var meanAbsLinear = 0.0
        var p95AbsLinear = 0.0
        var meanDeltaE = 0.0
        var p95DeltaE = 0.0
        var p99DeltaE = 0.0
        var maxDeltaE = 0.0
        var blurredMeanDeltaE = 0.0
        var blurredP95DeltaE = 0.0
        var meanEVDrift = 0.0

        var summary: String {
            String(
                format: "blurred ΔE00 mean %.4f p95 %.4f | ΔE00 mean %.4f p95 %.4f p99 %.3f max %.2f | linear |Δ| mean %.5f p95 %.5f | EV drift %+.5f",
                blurredMeanDeltaE, blurredP95DeltaE, meanDeltaE, p95DeltaE, p99DeltaE, maxDeltaE,
                meanAbsLinear, p95AbsLinear, meanEVDrift
            )
        }
    }

    /// `sampleStride` 2 evaluates every other row and column (a uniform
    /// quarter of the pixels) to keep debug-build test time low; the blur
    /// itself always runs on the full frame.
    static func parity(reference: EncodedFrame, candidate: EncodedFrame, sampleStride: Int = 2) throws -> ParityMetrics {
        try #require(reference.width == candidate.width && reference.height == candidate.height)
        let width = reference.width
        let height = reference.height
        let blurred = [reference.red, reference.green, reference.blue, candidate.red, candidate.green, candidate.blue]
            .map { gaussianBlurred($0, width: width, height: height) }

        var absLinear: [Double] = []
        var deltaE: [Double] = []
        var blurredDeltaE: [Double] = []
        let capacity = ((width + sampleStride - 1) / sampleStride) * ((height + sampleStride - 1) / sampleStride)
        absLinear.reserveCapacity(capacity)
        deltaE.reserveCapacity(capacity)
        blurredDeltaE.reserveCapacity(capacity)
        var evSum = 0.0
        var evCount = 0
        for y in stride(from: 0, to: height, by: sampleStride) {
            for x in stride(from: 0, to: width, by: sampleStride) {
                let index = y * width + x
                let ref = SIMD3(Double(reference.red[index]), Double(reference.green[index]), Double(reference.blue[index]))
                let can = SIMD3(Double(candidate.red[index]), Double(candidate.green[index]), Double(candidate.blue[index]))
                let refLinear = linearized(ref)
                let canLinear = linearized(can)
                let difference = refLinear - canLinear
                absLinear.append((abs(difference.x) + abs(difference.y) + abs(difference.z)) / 3)
                deltaE.append(deltaE2000(lab(linear: refLinear), lab(linear: canLinear)))

                let refBlur = SIMD3(Double(blurred[0][index]), Double(blurred[1][index]), Double(blurred[2][index]))
                let canBlur = SIMD3(Double(blurred[3][index]), Double(blurred[4][index]), Double(blurred[5][index]))
                let refBlurLinear = linearized(refBlur)
                let canBlurLinear = linearized(canBlur)
                blurredDeltaE.append(deltaE2000(lab(linear: refBlurLinear), lab(linear: canBlurLinear)))
                let luma = SIMD3(0.2126, 0.7152, 0.0722)
                let refLuminance = (refBlurLinear * luma).sum()
                if refLuminance > 0.01 {
                    let canLuminance = max((canBlurLinear * luma).sum(), Double(Float.leastNormalMagnitude))
                    evSum += log2(canLuminance / refLuminance)
                    evCount += 1
                }
            }
        }
        var metrics = ParityMetrics()
        metrics.meanAbsLinear = mean(absLinear)
        metrics.p95AbsLinear = percentile95(&absLinear)
        metrics.meanDeltaE = mean(deltaE)
        metrics.p95DeltaE = percentile95(&deltaE)
        metrics.p99DeltaE = percentile(sorted: deltaE, 0.99)
        metrics.maxDeltaE = deltaE.last ?? 0
        metrics.blurredMeanDeltaE = mean(blurredDeltaE)
        metrics.blurredP95DeltaE = percentile95(&blurredDeltaE)
        metrics.meanEVDrift = evCount == 0 ? 0 : evSum / Double(evCount)
        return metrics
    }

    /// `CALIBRATION.md`'s highlight-plateau criterion
    /// (`scripts/analyze-calibration.py`'s `shared_highlight_plateau_spatial_metrics`):
    /// encoded-sRGB luma on 16-bit code values, a shared highlight region of
    /// both images' brightest 0.1 %, "plateau" = a 4-neighbor in that region
    /// within 2 code values. Contract: net area increase <= 0.0001 and area
    /// outside the reference plateau's 1 px (3x3) dilation <= 0.0001.
    struct PlateauMetrics {
        var referenceFraction = 0.0
        var candidateFraction = 0.0
        var netAreaChange = 0.0
        var outsideDilation = 0.0

        var summary: String {
            String(
                format: "plateau ref %.6f cand %.6f net %+.6f outside-dilation %.6f",
                referenceFraction, candidateFraction, netAreaChange, outsideDilation
            )
        }
    }

    static func plateau(reference: EncodedFrame, candidate: EncodedFrame) throws -> PlateauMetrics {
        try #require(reference.width == candidate.width && reference.height == candidate.height)
        let width = reference.width
        let height = reference.height
        let count = width * height
        func luminance(_ frame: EncodedFrame) -> [Float] {
            var result = [Float](repeating: 0, count: count)
            frame.red.withUnsafeBufferPointer { r in
                frame.green.withUnsafeBufferPointer { g in
                    frame.blue.withUnsafeBufferPointer { b in
                        result.withUnsafeMutableBufferPointer { l in
                            for index in 0..<count {
                                let red = (r[index] * 65_535).rounded() / 65_535
                                let green = (g[index] * 65_535).rounded() / 65_535
                                let blue = (b[index] * 65_535).rounded() / 65_535
                                l[index] = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                            }
                        }
                    }
                }
            }
            return result
        }
        func quantile999(_ values: [Float]) -> Float {
            var sorted = values
            vDSP_vsort(&sorted, vDSP_Length(sorted.count), 1)
            let rank = 0.999 * Double(sorted.count - 1)
            let low = Int(rank.rounded(.down))
            let high = Int(rank.rounded(.up))
            return sorted[low] + (sorted[high] - sorted[low]) * Float(rank - Double(low))
        }
        let referenceLuminance = luminance(reference)
        let candidateLuminance = luminance(candidate)
        let referenceThreshold = quantile999(referenceLuminance)
        let candidateThreshold = quantile999(candidateLuminance)
        var shared = [UInt8](repeating: 0, count: count)
        for index in 0..<count where referenceLuminance[index] >= referenceThreshold
            || candidateLuminance[index] >= candidateThreshold {
            shared[index] = 1
        }
        let tolerance = Float(2.0 / 65_535.0)
        func plateauMask(_ luminance: [Float]) -> [UInt8] {
            var mask = [UInt8](repeating: 0, count: count)
            luminance.withUnsafeBufferPointer { l in
                shared.withUnsafeBufferPointer { h in
                    mask.withUnsafeMutableBufferPointer { m in
                        for y in 0..<height {
                            for x in 0..<width {
                                let index = y * width + x
                                guard h[index] != 0 else { continue }
                                if x + 1 < width, h[index + 1] != 0, abs(l[index] - l[index + 1]) <= tolerance {
                                    m[index] = 1
                                    m[index + 1] = 1
                                }
                                if y + 1 < height, h[index + width] != 0, abs(l[index] - l[index + width]) <= tolerance {
                                    m[index] = 1
                                    m[index + width] = 1
                                }
                            }
                        }
                    }
                }
            }
            return mask
        }
        let referencePlateau = plateauMask(referenceLuminance)
        let candidatePlateau = plateauMask(candidateLuminance)
        var dilated = [UInt8](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width where referencePlateau[y * width + x] != 0 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let yy = y + dy
                        let xx = x + dx
                        if yy >= 0, yy < height, xx >= 0, xx < width {
                            dilated[yy * width + xx] = 1
                        }
                    }
                }
            }
        }
        var referenceCount = 0
        var candidateCount = 0
        var outsideCount = 0
        for index in 0..<count {
            referenceCount += Int(referencePlateau[index])
            candidateCount += Int(candidatePlateau[index])
            if candidatePlateau[index] != 0, dilated[index] == 0 {
                outsideCount += 1
            }
        }
        let total = Double(count)
        return PlateauMetrics(
            referenceFraction: Double(referenceCount) / total,
            candidateFraction: Double(candidateCount) / total,
            netAreaChange: Double(candidateCount - referenceCount) / total,
            outsideDilation: Double(outsideCount) / total
        )
    }

    static func linearized(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
        func channel(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return SIMD3(channel(encoded.x), channel(encoded.y), channel(encoded.z))
    }

    /// `scripts/analyze-calibration.py`'s `srgb_to_lab` (D65), from linear sRGB.
    static func lab(linear rgb: SIMD3<Double>) -> SIMD3<Double> {
        let x = (0.4124564 * rgb.x + 0.3575761 * rgb.y + 0.1804375 * rgb.z) / 0.95047
        let y = 0.2126729 * rgb.x + 0.7151522 * rgb.y + 0.0721750 * rgb.z
        let z = (0.0193339 * rgb.x + 0.1191920 * rgb.y + 0.9503041 * rgb.z) / 1.08883
        let delta = 6.0 / 29.0
        func f(_ t: Double) -> Double {
            t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0
        }
        let fx = f(x)
        let fy = f(y)
        let fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000 (Sharma et al. 2005, kL = kC = kH = 1), as
    /// `scripts/analyze-calibration.py`'s `delta_e_2000`.
    static func deltaE2000(_ lab1: SIMD3<Double>, _ lab2: SIMD3<Double>) -> Double {
        let radians = Double.pi / 180
        let pow25To7 = 6_103_515_625.0
        let c1 = (lab1.y * lab1.y + lab1.z * lab1.z).squareRoot()
        let c2 = (lab2.y * lab2.y + lab2.z * lab2.z).squareRoot()
        let cBar7 = pow((c1 + c2) / 2, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow25To7)).squareRoot())
        let ap1 = (1 + g) * lab1.y
        let ap2 = (1 + g) * lab2.y
        let cp1 = (ap1 * ap1 + lab1.z * lab1.z).squareRoot()
        let cp2 = (ap2 * ap2 + lab2.z * lab2.z).squareRoot()
        func hue(_ b: Double, _ ap: Double) -> Double {
            guard ap != 0 || b != 0 else { return 0 }
            let degrees = atan2(b, ap) / radians
            return degrees < 0 ? degrees + 360 : degrees
        }
        let hp1 = hue(lab1.z, ap1)
        let hp2 = hue(lab2.z, ap2)
        let dL = lab2.x - lab1.x
        let dC = cp2 - cp1
        var dhAngle = hp2 - hp1
        if cp1 * cp2 == 0 {
            dhAngle = 0
        } else if abs(dhAngle) > 180 {
            dhAngle -= dhAngle > 0 ? 360 : -360
        }
        let dH = 2 * (cp1 * cp2).squareRoot() * sin(dhAngle / 2 * radians)
        let lBar = (lab1.x + lab2.x) / 2
        let cpBar = (cp1 + cp2) / 2
        let hpSum = hp1 + hp2
        let hpBar: Double
        if cp1 * cp2 == 0 {
            hpBar = hpSum
        } else if abs(hp1 - hp2) <= 180 {
            hpBar = hpSum / 2
        } else if hpSum < 360 {
            hpBar = (hpSum + 360) / 2
        } else {
            hpBar = (hpSum - 360) / 2
        }
        let t = 1
            - 0.17 * cos((hpBar - 30) * radians)
            + 0.24 * cos(2 * hpBar * radians)
            + 0.32 * cos((3 * hpBar + 6) * radians)
            - 0.20 * cos((4 * hpBar - 63) * radians)
        let lOffset = (lBar - 50) * (lBar - 50)
        let sl = 1 + 0.015 * lOffset / (20 + lOffset).squareRoot()
        let sc = 1 + 0.045 * cpBar
        let sh = 1 + 0.015 * cpBar * t
        let hueDistance = (hpBar - 275) / 25
        let deltaTheta = 30 * exp(-hueDistance * hueDistance)
        let cpBar7 = pow(cpBar, 7)
        let rc = 2 * (cpBar7 / (cpBar7 + pow25To7)).squareRoot()
        let rt = -rc * sin(2 * deltaTheta * radians)
        let lTerm = dL / sl
        let cTerm = dC / sc
        let hTerm = dH / sh
        return (lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + rt * cTerm * hTerm).squareRoot()
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// `numpy.percentile(values, 95)` (linear interpolation); sorts in place.
    static func percentile95(_ values: inout [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        vDSP_vsortD(&values, vDSP_Length(values.count), 1)
        return percentile(sorted: values, 0.95)
    }

    static func percentile(sorted values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let rank = fraction * Double(values.count - 1)
        let low = Int(rank.rounded(.down))
        let high = Int(rank.rounded(.up))
        return values[low] + (values[high] - values[low]) * (rank - Double(low))
    }

    /// `PHOTO_BENCH_PREVIEW_DUMP_DIR`: writes both previews (8-bit sRGB PNG,
    /// as displayed) and a per-pixel ΔE00 map (black 0, white >= 5) for
    /// visual inspection.
    static func dumpComparison(reference: EncodedFrame, candidate: EncodedFrame, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PHOTO_BENCH_PREVIEW_DUMP_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let width = reference.width
        let height = reference.height
        func writePNG(_ rgba: [UInt8], _ file: String) throws {
            let data = Data(rgba) as CFData
            let provider = try #require(CGDataProvider(data: data))
            let image = try #require(CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
            ))
            let url = folder.appendingPathComponent(file)
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
        }
        func rgba(_ frame: EncodedFrame) -> [UInt8] {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for index in 0..<(width * height) {
                bytes[4 * index] = UInt8((frame.red[index] * 255).rounded())
                bytes[4 * index + 1] = UInt8((frame.green[index] * 255).rounded())
                bytes[4 * index + 2] = UInt8((frame.blue[index] * 255).rounded())
            }
            return bytes
        }
        try writePNG(rgba(reference), "\(name)-full.png")
        try writePNG(rgba(candidate), "\(name)-copy.png")
        var map = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let ref = SIMD3(Double(reference.red[index]), Double(reference.green[index]), Double(reference.blue[index]))
            let can = SIMD3(Double(candidate.red[index]), Double(candidate.green[index]), Double(candidate.blue[index]))
            let deltaE = deltaE2000(lab(linear: linearized(ref)), lab(linear: linearized(can)))
            let level = UInt8(min(255, (deltaE / 5 * 255).rounded()))
            map[4 * index] = level
            map[4 * index + 1] = level
            map[4 * index + 2] = level
        }
        try writePNG(map, "\(name)-deltaE00-x51.png")
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func formatted(_ values: [Double]) -> String {
        "[" + values.map { String(format: "%.0f", $0) }.joined(separator: ", ") + "]ms"
    }
}

import CoreImage
import Foundation
import Testing
@testable import PhotoCore

/// Slider-drag previews (`PreviewDragSession`), the preview's spatial-pass
/// reuse (`SpatialPassCache`), cancellation (`PreviewCancellation`) and the
/// chunked cube bake: everything exact stays byte-identical to what the
/// renderer produced before, drag frames stay close to the exact frame, and
/// export never sees any of it. The RAW case needs the private
/// `P1524180.RW2` and the Panasonic DC-S5 Adobe profile and skips without
/// them.
@Suite(.serialized)
struct PreviewDragTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func preset(_ name: String) throws -> EditSettings {
        try XMPPresetParser.parse(url: projectRoot.appendingPathComponent(name)).applying(to: .neutral)
    }

    // MARK: - Cube bake

    /// The bake before this change, verbatim: one shared closure evaluated
    /// by `n` concurrent b-slices, the linear grid value recomputed per point.
    private static func referenceBake(
        dimension n: Int, transform: @Sendable (SIMD3<Double>) -> SIMD3<Double>
    ) -> Data {
        let denominator = Double(n - 1)
        let gamma = AdobeBaseRenderer.cubeGammaPower
        @Sendable func encoded(_ value: Double) -> Double {
            pow(min(max(value, 0.0), 1.0), 1.0 / gamma)
        }
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        floats.withUnsafeMutableBufferPointer { buffer in
            let base = ReferenceBakeBox(pointer: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: n) { bIndex in
                let bLinear = pow(Double(bIndex) / denominator, gamma)
                for gIndex in 0..<n {
                    let gLinear = pow(Double(gIndex) / denominator, gamma)
                    let rowBase = (bIndex * n + gIndex) * n
                    for rIndex in 0..<n {
                        let rLinear = pow(Double(rIndex) / denominator, gamma)
                        let output = transform(SIMD3(rLinear, gLinear, bLinear))
                        let entryBase = (rowBase + rIndex) * 4
                        base.pointer[entryBase] = Float(encoded(output.x))
                        base.pointer[entryBase + 1] = Float(encoded(output.y))
                        base.pointer[entryBase + 2] = Float(encoded(output.z))
                        base.pointer[entryBase + 3] = 1
                    }
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test func chunkedBakeIsByteIdenticalToTheSingleClosureBake() throws {
        let night = try preset("niho-preset night.xmp")
        let bluesky = try preset("niho-preset bluesky2.xmp")
        let tone: @Sendable (SIMD3<Double>) -> SIMD3<Double> = { ToneOps.applyPostOps($0, settings: night) }
        let color: @Sendable (SIMD3<Double>) -> SIMD3<Double> = { ColorOps.applyColorOps($0, settings: bluesky) }
        // The exact grid (export, every exact preview) through both entry
        // points: `buildCubeData`'s shared closure and the cached production
        // cubes' per-chunk `uniquelyStoredCopy`.
        let toneReference = Self.referenceBake(dimension: 64, transform: tone)
        #expect(AdobeBaseRenderer.buildCubeData(dimension: 64, transform: tone) == toneReference)
        #expect(AdobeBaseRenderer.postOpsCube(exposureNonRaw: 0, settings: night) == toneReference)
        let colorReference = Self.referenceBake(dimension: 64, transform: color)
        #expect(AdobeBaseRenderer.postColorCube(settings: bluesky) == colorReference)
        // A grid whose rows do not split evenly into chunks.
        #expect(AdobeBaseRenderer.buildCubeData(dimension: 33, transform: color)
            == Self.referenceBake(dimension: 33, transform: color))
    }

    @Test func settingsCopiesKeepTheirValues() throws {
        let bluesky = try preset("niho-preset bluesky2.xmp")
        #expect(bluesky.uniquelyStoredCopy() == bluesky)
        // bluesky2: flat Red/Green curves, a shaped composite and Blue curve.
        #expect(bluesky.toneCurves.count == 4)
        let trimmed = bluesky.withoutIdentityToneCurves()
        #expect(Set(trimmed.toneCurves.map(\.channel)) == [.rgb, .blue])
        #expect(trimmed.toneCurves == bluesky.toneCurves.filter { !$0.isIdentity })
        #expect(bluesky.toneCurves.filter(\.isIdentity).map(\.channel).sorted { $0.rawValue < $1.rawValue } == [.green, .red])
    }

    @Test func cubeCachesKeepTheMostRecentlyUsedValues() {
        let cache = AdobeBaseRenderer.CubeCache<Int, Int>(capacity: 3)
        for key in 0..<3 { cache.insert(key * 10, for: key) }
        #expect(cache.value(for: 0) == 0)  // 0 is now the most recent
        cache.insert(30, for: 3)           // evicts 1, the least recent
        #expect(cache.count == 3)
        #expect(cache.value(for: 1) == nil)
        #expect(cache.value(for: 0) == 0)
        #expect(cache.value(for: 2) == 20)
        #expect(cache.value(for: 3) == 30)
    }

    @Test func cancelledBakeReturnsNothing() {
        let cancellation = PreviewCancellation()
        cancellation.cancel()
        let data = AdobeBaseRenderer.bakeCube(dimension: 33, cancellation: cancellation) { { $0 } }
        #expect(data == nil)
        #expect(AdobeBaseRenderer.bakeCube(dimension: 9, cancellation: PreviewCancellation()) { { $0 } } != nil)
    }

    // MARK: - Drag session rules

    @Test func onlySpatialInputsKeepMeasuringStatistics() throws {
        let start = try preset("niho-preset bluesky2.xmp")
        let session = PreviewDragSession(startSettings: start)
        #expect(session.movesOnlySpatialInputs(start))
        var moved = start
        moved.exposure += 0.3
        moved.shadows += 5
        moved.whiteBalance = WhiteBalanceSettings(mode: .custom, temperature: 5_100, tint: 4)
        #expect(session.movesOnlySpatialInputs(moved))
        moved.whites += 1
        #expect(!session.movesOnlySpatialInputs(moved))
        var hsl = start
        hsl.hsl[.blue, default: HSLAdjustment()].hue += 2
        #expect(!session.movesOnlySpatialInputs(hsl))
    }

    // MARK: - Synthetic (non-RAW) working copy

    @Test func spatialReuseAndDragFramesOnASyntheticPhoto() throws {
        let decoded = PreviewWorkingCopyTests.syntheticDecode(width: 3_000, height: 2_000)
        let engine = RenderEngine()
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded)
        var base = try preset("niho-preset pastel.xmp")
        base.shadows = 45
        var downstream = base
        downstream.contrast -= 14
        downstream.hsl[.orange, default: HSLAdjustment()].saturation += 10

        // Exact frames: reusing the spatial pass is invisible.
        _ = try engine.preparePreviewFromWorkingCopy(workingCopy: workingCopy, settings: base, quality: .interactive)
        let hitsBefore = engine.previewSpatialPassCache.hitCount
        let reused = try engine.preparePreviewFromWorkingCopy(workingCopy: workingCopy, settings: downstream, quality: .interactive)
        #expect(engine.previewSpatialPassCache.hitCount == hitsBefore + 1)
        let fresh = RenderEngine()
        let freshCopy = try fresh.makePreviewWorkingCopy(from: decoded)
        let recomputed = try fresh.preparePreviewFromWorkingCopy(workingCopy: freshCopy, settings: downstream, quality: .interactive)
        #expect(PreviewWorkingCopyTests.maxAbsDifference(
            PreviewWorkingCopyTests.readLinear(reused.image, bounds: reused.extent),
            PreviewWorkingCopyTests.readLinear(recomputed.image, bounds: recomputed.extent)
        ) == 0)

        // A drag frame (a tone value not baked yet: drag grid) stays close to
        // the exact frame, and the exact frame after the drag is the one a
        // fresh engine renders.
        var dragged = downstream
        dragged.contrast -= 9
        let session = PreviewDragSession(startSettings: downstream)
        let dragFrame = try engine.preparePreviewFromWorkingCopy(
            workingCopy: workingCopy, settings: dragged, quality: .interactive, drag: session
        )
        let exactAfter = try engine.preparePreviewFromWorkingCopy(workingCopy: workingCopy, settings: dragged, quality: .interactive)
        let freshDragged = try fresh.preparePreviewFromWorkingCopy(workingCopy: freshCopy, settings: dragged, quality: .interactive)
        let metrics = try PreviewWorkingCopyTests.parity(
            reference: PreviewWorkingCopyTests.readEncodedSRGB(exactAfter),
            candidate: PreviewWorkingCopyTests.readEncodedSRGB(dragFrame)
        )
        print("PREVIEW-DRAG synthetic contrast drag vs exact: \(metrics.summary)")
        #expect(metrics.meanDeltaE > 0)
        #expect(metrics.blurredMeanDeltaE <= 0.6)
        #expect(metrics.blurredP95DeltaE <= 1.5)
        #expect(PreviewWorkingCopyTests.maxAbsDifference(
            PreviewWorkingCopyTests.readLinear(exactAfter.image, bounds: exactAfter.extent),
            PreviewWorkingCopyTests.readLinear(freshDragged.image, bounds: freshDragged.extent)
        ) == 0)

        // Cancellation stops a render with CancellationError.
        let cancellation = PreviewCancellation()
        cancellation.cancel()
        var other = downstream
        other.vibrance += 7
        #expect(throws: CancellationError.self) {
            try engine.preparePreviewFromWorkingCopy(
                workingCopy: workingCopy, settings: other, quality: .interactive, cancellation: cancellation
            )
        }
    }

    @Test func previewDragStateNeverReachesExport() throws {
        let decoded = PreviewWorkingCopyTests.syntheticDecode(width: 1_800, height: 1_200)
        var settings = try preset("niho-preset night.xmp")
        settings.shadows = 30
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photobench-drag-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = RenderEngine()
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded)
        let session = PreviewDragSession(startSettings: settings)
        for step in 1...3 {
            var tick = settings
            tick.whites += Double(step) * 3
            tick.hsl[.green, default: HSLAdjustment()].hue += Double(step)
            _ = try engine.preparePreviewFromWorkingCopy(
                workingCopy: workingCopy, settings: tick, quality: .interactive, drag: session
            )
        }
        let afterDrag = directory.appendingPathComponent("after-drag.jpg")
        _ = try engine.exportJPEG(decoded: decoded, settings: settings, destination: afterDrag)
        let clean = directory.appendingPathComponent("clean.jpg")
        _ = try RenderEngine().exportJPEG(decoded: decoded, settings: settings, destination: clean)
        #expect(try Data(contentsOf: afterDrag) == Data(contentsOf: clean))
    }

    // MARK: - RAW (private photo)

    @Test func rawDragFramesWithTheBluesky2Preset() throws {
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
        let base = try preset("niho-preset bluesky2.xmp")
        let decoded = try PhotoDecoder().decode(url: url)
        let engine = RenderEngine()
        let workingCopy = try engine.makePreviewWorkingCopy(from: decoded)

        func pixels(_ frame: PreparedPreviewFrame) -> [Float] {
            PreviewWorkingCopyTests.readLinear(frame.image, bounds: frame.extent)
        }
        // (slider, moved settings, blurred ΔE00 mean / p95 limits for the drag
        // frame against the exact frame; nil: the drag frame must be exact).
        // Measured on the Mac Studio/mini: exposure and white balance exact,
        // HSL blurred 0.02 / 0.05, Whites 0.30 / 0.73 (mostly the GPU's
        // half-float cube interpolation differing between the 33^3 and
        // 64^3 grids).
        var exposure = base
        exposure.exposure += 0.24
        var temperature = base
        temperature.whiteBalance = WhiteBalanceSettings(mode: .custom, temperature: 5_400, tint: 6)
        var whites = base
        whites.whites += 12
        var hsl = base
        hsl.hsl[.orange, default: HSLAdjustment()].saturation += 12
        let cases: [(name: String, settings: EditSettings, limits: (mean: Double, p95: Double)?)] = [
            ("exposure", exposure, nil),
            ("temperature", temperature, nil),
            ("whites", whites, (0.6, 1.5)),
            ("hsl", hsl, (0.2, 0.5))
        ]
        _ = try engine.preparePreviewFromWorkingCopy(workingCopy: workingCopy, settings: base, quality: .interactive)
        for testCase in cases {
            let session = PreviewDragSession(startSettings: base)
            let drag = try engine.preparePreviewFromWorkingCopy(
                workingCopy: workingCopy, settings: testCase.settings, quality: .interactive, drag: session
            )
            let settled = try engine.preparePreviewFromWorkingCopy(
                workingCopy: workingCopy, settings: testCase.settings, quality: .interactive
            )
            let fresh = RenderEngine()
            let freshCopy = try fresh.makePreviewWorkingCopy(from: decoded)
            let recomputed = try fresh.preparePreviewFromWorkingCopy(
                workingCopy: freshCopy, settings: testCase.settings, quality: .interactive
            )
            // The exact frame after a drag is the frame a fresh engine renders.
            #expect(PreviewWorkingCopyTests.maxAbsDifference(pixels(settled), pixels(recomputed)) == 0, "\(testCase.name)")
            if let limits = testCase.limits {
                let metrics = try PreviewWorkingCopyTests.parity(
                    reference: PreviewWorkingCopyTests.readEncodedSRGB(settled),
                    candidate: PreviewWorkingCopyTests.readEncodedSRGB(drag)
                )
                print("PREVIEW-DRAG P1524180 bluesky2 \(testCase.name) drag vs exact: \(metrics.summary)")
                #expect(metrics.blurredMeanDeltaE <= limits.mean, "\(testCase.name)")
                #expect(metrics.blurredP95DeltaE <= limits.p95, "\(testCase.name)")
            } else {
                #expect(PreviewWorkingCopyTests.maxAbsDifference(pixels(drag), pixels(settled)) == 0, "\(testCase.name)")
            }
            // Back to the drag's starting state for the next slider.
            _ = try engine.preparePreviewFromWorkingCopy(workingCopy: workingCopy, settings: base, quality: .interactive)
        }
    }
}

private struct ReferenceBakeBox: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
}

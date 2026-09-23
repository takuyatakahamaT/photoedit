import CoreImage
import Foundation

/// Builds and caches the GPU (`CIColorCube`-based) rendering graph for the
/// phase1 Adobe DCP + "Adobe Color" base-rendering pipeline
/// (`docs/PHASE1_BASE_RENDERING.md` B2 "GPU実装は「3D LUT」を段ごとに焼く").
///
/// `AdobeProfile/AdobeColorMath.swift` (B1) is the CPU reference this file's
/// cube tables sample from; the two are expected to agree to within roughly
/// 0.15 ΔE00 (`Tests/PhotoCoreTests/AdobeBaseRendererTests.swift`), not
/// exactly, because of two deliberate GPU-only simplifications documented in
/// the design doc:
///   1. Each cube's `CIColorCube` clamps its own input to [0,1] internally
///      (a real Core Image limitation, not a bug here).
///   2. Because of (1), this renderer additionally clips every cube's own
///      *output* to [0,1] before re-encoding it for storage, and clips Stage
///      M's output to >= 0 before the first gamma encode (`pow` of a
///      negative base is NaN) -- whereas the CPU reference
///      (`AdobeColorMath.evaluate`) only clips starting at Stage T
///      (`RGBTone.apply` pins its own input to [0,1]), letting small
///      negative/over-1 values from Stage M/H/L survive further through the
///      pipeline than this GPU path does. Phase1 accepts this (SDR-only)
///      simplification; a later phase revisits it for HDR/highlight work.
public enum AdobeBaseRenderer {
    /// 64^3 grid points per cube, matching the design doc's cost/quality
    /// tradeoff (262,144 points x 3 cubes, generated once per profile and
    /// cached).
    public static let cubeDimension = 64

    /// The transfer curve cube data is encoded/decoded with, so 64 grid
    /// steps have enough resolution in the shadows (ProPhoto's own gamma is
    /// close to this; see `docs/PHASE1_BASE_RENDERING.md`'s "入力の符号化").
    static let cubeGammaPower = 1.8

    // MARK: - Cache key

    /// Identifies one "baked cube set" so repeated decodes of photos that
    /// share a camera profile (the common case: every RAW from the same
    /// camera model) do not regenerate the same ~3 x 262,144-point tables.
    /// `dcpIdentity`/`lookIdentity` are caller-supplied stand-ins for a true
    /// content digest (in practice, the resolved `.dcp`/`.xmp` file paths
    /// from `AdobeProfileLocator` -- adequate here because a profile file's
    /// content does not change during a process's lifetime) rather than
    /// hashing `DCPProfile`/`AdobeLookXMP` (neither is `Hashable`, and B1's
    /// files are otherwise left alone).
    public struct CacheKey: Hashable, Sendable {
        public var dcpIdentity: String
        public var lookIdentity: String
        public var variant: ToneCurveVariant
        // Not `private`: `AdobeBaseRenderer`'s caching methods split this
        // one caller-facing key into the two finer-grained keys the cube
        // data actually depends on (see `cachedCubes`'s doc comment).
        var whiteXMicros: Int
        var whiteYMicros: Int
        var exposureEVMicros: Int

        public init(
            dcpIdentity: String,
            lookIdentity: String,
            whiteXY: ChromaticityXY,
            exposureEV: Double,
            variant: ToneCurveVariant
        ) {
            self.dcpIdentity = dcpIdentity
            self.lookIdentity = lookIdentity
            self.variant = variant
            // Rounded to 1e-6 in chromaticity / 1e-6 EV: coarser than any
            // meaningful difference between two white points or exposures,
            // fine enough that two calls for "the same photo" always hit.
            self.whiteXMicros = Int((whiteXY.x * 1_000_000).rounded())
            self.whiteYMicros = Int((whiteXY.y * 1_000_000).rounded())
            self.exposureEVMicros = Int((exposureEV * 1_000_000).rounded())
        }
    }

    /// The three baked 3D LUTs (`CIColorCube` `inputCubeData`), gamma-encoded
    /// per `docs/PHASE1_BASE_RENDERING.md`'s "入力の符号化". `hueSat` is
    /// `nil` when the DCP has no `ProfileHueSatMap` (Stage H becomes a no-op,
    /// matching `AdobeColorMath.evaluate`'s early return semantics).
    struct CubeSet: Sendable {
        var hueSat: BakedCube?
        var look: Data
        var tone: Data
    }

    /// One baked `CIColorCube` table and the grid it was baked on.
    struct BakedCube: Sendable {
        var data: Data
        var dimension: Int
    }

    /// Grid for a tone cube (P/P1/P2) baked for a slider-drag frame
    /// (`PreviewDragSession`) when its exact `cubeDimension` bake is not
    /// cached: 33^3 = 35,937 points instead of 262,144.
    /// `PHOTO_BENCH_DRAG_CUBE_DIMENSION` (2...64) overrides it for
    /// measurements; the app never sets it.
    public static let dragCubeDimension: Int = {
        guard let raw = ProcessInfo.processInfo.environment["PHOTO_BENCH_DRAG_CUBE_DIMENSION"],
              let value = Int(raw), (2...cubeDimension).contains(value)
        else { return 33 }
        return value
    }()

    /// A lock-protected, least-recently-used-bounded cache for the cubes that
    /// depend on slider values (P, P1, P2, Q, and H per white point). Every
    /// new slider value bakes a new cube (4 MB at 64^3); with drag frames
    /// rendering a few dozen values per second, an unbounded dictionary
    /// would grow by tens of MB per second of dragging. Eviction only means
    /// a later request for that value bakes it again: identical data.
    final class CubeCache<Key: Hashable, Value>: @unchecked Sendable {
        static var defaultCapacity: Int { 24 }

        private let lock = NSLock()
        private let capacity: Int
        private var storage: [Key: (value: Value, lastUse: UInt64)] = [:]
        private var clock: UInt64 = 0

        init(capacity: Int = defaultCapacity) {
            self.capacity = max(1, capacity)
        }

        func value(for key: Key) -> Value? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = storage[key] else { return nil }
            clock &+= 1
            storage[key] = (entry.value, clock)
            return entry.value
        }

        func insert(_ value: Value, for key: Key) {
            lock.lock()
            defer { lock.unlock() }
            clock &+= 1
            storage[key] = (value, clock)
            while storage.count > capacity,
                  let oldest = storage.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                storage.removeValue(forKey: oldest)
            }
        }

        func removeAll() {
            lock.lock()
            storage.removeAll()
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage.count
        }
    }

    /// Stage M's image plus everything `image(userExposureEV:)` needs to run
    /// the remaining stages. Phase1 only ever calls `image(userExposureEV: 0)`
    /// (`DecodedPhoto.image`'s value); the parameter exists now so phase2/3
    /// can insert user exposure between Stage H and Stage L without changing
    /// this type's shape (`docs/PHASE1_BASE_RENDERING.md`'s
    /// `DecodedPhoto.adobeBase` note).
    public struct Handle: Sendable {
        /// Mirrors `docs/PHASE1_BASE_RENDERING.md`'s per-stage checkpoints
        /// (collapsing DCP-look/Adobe-look into one "look" cube and
        /// ACR3-tone/point-curve into one "tone" cube, matching how the GPU
        /// graph actually bakes them -- see `CubeSet`). Used by
        /// `photobench-render --stage` to stop the graph early for
        /// debugging; production code always wants `.full`.
        public enum Stage: String, CaseIterable, Sendable {
            case matrix, huesat, exposure, look, tone, full
        }

        /// Camera RGB (nil-colorspace numeric values) -> linear ProPhoto,
        /// immediately after Stage M's "clip negative, keep highlights"
        /// clamp. This is the per-photo half of the graph; `cubes` (and the
        /// exposure/final-matrix stages `image(userExposureEV:)` appends) are
        /// shared across every photo using the same camera profile.
        public let stageMImage: CIImage
        /// Camera RGB (as-shot-white-balanced, pre-Stage-M) straight from the
        /// decoder. Retained (rather than only `stageMImage`) so
        /// `image(settings:)` can redo Stage M with a different
        /// `combinedMatrix` when phase2 C1's absolute white balance (XMP
        /// `WhiteBalance == Custom`) picks a white point other than as-shot.
        let cameraImage: CIImage
        let assets: AdobeBaseAssets
        let cubes: CubeSet
        let variant: ToneCurveVariant
        /// This handle's cache identity, retained so `image(settings:)` can
        /// look up (or bake) a *different* white point's H/L/TC cubes
        /// through the same `dcpIdentity`/`lookIdentity`-keyed cache
        /// `makeHandle` used, rather than introducing a second cache.
        let cacheKey: CacheKey
        /// `nil` for a decoder-built handle; the reduced `cameraImage`'s long
        /// edge for a preview working copy (`downscaled(maxDimension:
        /// using:)`). Cubes depend only on the profile, so the copy
        /// shares `cacheKey` and every cube cache; the adaptive statistics
        /// are read off the pixels, so `StatsCacheKey` carries this too and a
        /// working-copy statistic is never served to a full-resolution export.
        let previewWorkingCopyLongEdge: Int?

        /// Stage H -> Stage E (exposure) -> Stage L -> Stage T+C -> Stage M's
        /// ProPhoto -> the app's extended-linear-sRGB working space (negative
        /// values and values over 1 both preserved: see `RenderStage.final`'s
        /// documentation in `AdobeColorMath.swift`).
        public func image(userExposureEV: Double = 0) -> CIImage {
            image(through: .full, userExposureEV: userExposureEV)
        }

        /// As `image(userExposureEV:)`, but stops after `stage` instead of
        /// always running the whole pipeline.
        public func image(through stage: Stage, userExposureEV: Double = 0) -> CIImage {
            AdobeBaseRenderer.applyRemainingStages(
                to: stageMImage, assets: assets, cubes: cubes,
                userEV: userExposureEV, variant: variant, through: stage
            )
        }

        /// Phase2 C1/C2's full RAW edit pipeline: WB rebalance (Custom only)
        /// -> Stage M/H (re-interpolated at the new white point, Custom
        /// only) -> Stage E (`baselineEV + settings.exposure`) -> Stage L ->
        /// Stage T+C -> **cube P** (`ToneOps.applyPostOps`, Contrast/Whites/
        /// Blacks/Parametric/Point curve) -> **Camera Calibration**
        /// (`ColorOps.calibrationMatrix`, an exact `CIColorMatrix` kept
        /// separate from cube Q -- see `applyCalibration` and
        /// `postColorCube`'s doc comments; order per `CalibrationOrder`) ->
        /// **cube Q** (`ColorOps.applyColorOps`, Vibrance/Saturation/HSL/
        /// Color Grading) -> ProPhoto -> the app's working space. `docs/PHASE2_DEVELOP_PIPELINE.md` C1 item 4,
        /// `docs/PHASE2_C2_C3.md` C2 item 3.
        ///
        /// When `settings.whiteBalance` is not a valid `.custom` (missing
        /// temperature/tint, or a degenerate xy `AdobeColorSpec`/`HueSatMap`
        /// can't re-derive a matrix/table for), this silently falls back to
        /// the as-shot white this handle was built with rather than throwing
        /// -- a renderer has no good way to surface a mid-slider XMP error,
        /// and as-shot is always a safe answer.
        public func image(settings: EditSettings, quality: SpatialToneQuality = .final) -> CIImage {
            // `.standard` carries no cancellation token, so nothing can throw.
            try! image(settings: settings, quality: quality, options: .standard)
        }

        /// `image(settings:quality:)` with the interactive preview's options
        /// (`PreviewRenderOptions`). Throws `CancellationError` only once
        /// `options.cancellation` is cancelled.
        func image(settings: EditSettings, quality: SpatialToneQuality, options: PreviewRenderOptions) throws -> CIImage {
            AdobeBaseRenderer.applyMatrix(
                DNGColorSpace.proPhotoToSRGBLinear,
                to: try imagePreMatrix(settings: settings, quality: quality, options: options)
            )
        }

        /// `image(settings:)` minus the final ProPhoto -> working-space
        /// matrix -- split out so `highlightRatioBase(for:)` (round2 set A,
        /// `.photobench/phase2/spatial-adaptive/model.md` §6/§7) can render
        /// the same pipeline (through cube Q/Calibration) for a
        /// Highlights/Shadows/Texture/Clarity-zeroed settings value and read
        /// off the still-linear-ProPhoto result, without duplicating this
        /// whole function. Every other caller of the old `image(settings:)`
        /// body is unaffected -- this is a pure extraction, not a behavior
        /// change (`image(settings:)` above wraps it with the exact matrix
        /// call the extracted code used to end with).
        ///
        /// `options` (`.standard` everywhere but the interactive preview):
        /// the cube grid for cubes not cached at the exact size, a drag
        /// session's frozen statistics, the preview's spatial-pass cache and
        /// cancellation. With `.standard` the graph is exactly the one this
        /// function built before those options existed.
        private func imagePreMatrix(
            settings: EditSettings, quality: SpatialToneQuality, options: PreviewRenderOptions
        ) throws -> CIImage {
            try options.checkCancellation()
            var effectiveAssets = assets
            if settings.whiteBalance.mode == .custom,
               let temperature = settings.whiteBalance.temperature,
               let tint = settings.whiteBalance.tint {
                let newWhiteXY = DNGTemperature.xy(fromTemperature: temperature, tint: tint)
                if let rebalanced = PreviewDiagnostics.measure("wb", { try? assets.rebalanced(toWhiteXY: newWhiteXY) }) {
                    effectiveAssets = rebalanced
                }
            }

            let stageM = AdobeBaseRenderer.applyStageM(to: cameraImage, matrix: effectiveAssets.combinedMatrix)
            guard let effectiveCubes = AdobeBaseRenderer.cachedCubes(
                for: effectiveAssets,
                key: CacheKey(
                    dcpIdentity: cacheKey.dcpIdentity, lookIdentity: cacheKey.lookIdentity,
                    whiteXY: effectiveAssets.whiteXY, exposureEV: effectiveAssets.baselineEV, variant: variant
                ),
                variant: variant,
                cancellation: options.cancellation
            ) else {
                throw CancellationError()
            }
            let order = SpatialOrder.currentForRAW
            let needsSpatial = SpatialToneOps.needsSpatial(settings)
            // round2 set A (`.photobench/phase2/spatial-adaptive/model.md`):
            // computed (and cached, see `highlightRatioBase()`'s doc
            // comment) only when a spatial pass will actually run.
            let stats = needsSpatial ? try spatialStatistics(for: settings, quality: quality, options: options) : nil

            // [S] at `.preTone` reads Stage E's output: this handle's camera
            // pixels, the effective white (Stage M's matrix and cube H) and
            // the exposure. Only that order uses the preview's spatial-pass
            // cache; the experiment orders always recompute.
            let spatialInputParameters = [effectiveAssets.whiteXY.x, effectiveAssets.whiteXY.y, settings.exposure]
            func spatial(_ input: CIImage, cached: Bool = false) throws -> CIImage {
                try options.checkCancellation()
                return AdobeBaseRenderer.spatialPass(
                    settings: settings, to: input, source: cameraImage,
                    inputParameters: spatialInputParameters, adaptiveStats: stats, path: .raw,
                    quality: quality, cache: cached ? options.spatialCache : nil
                )
            }
            func postOps() throws -> BakedCube {
                try AdobeBaseRenderer.postOpsCube(exposureNonRaw: 0, settings: settings, options: options)
            }

            var image: CIImage
            if needsSpatial && order == .preTone {
                // `.preTone` (today's RAW default, `SpatialOrder`'s doc
                // comment): stop right after Stage E, run [S] there, then
                // finish Stage L/T by hand (mirroring `applyRemainingStages`'s
                // own tail).
                image = AdobeBaseRenderer.applyRemainingStages(
                    to: stageM, assets: effectiveAssets, cubes: effectiveCubes,
                    userEV: settings.exposure, variant: variant, through: .exposure
                )
                image = try spatial(image, cached: true)
                image = AdobeBaseRenderer.applyCube(effectiveCubes.look, to: image)
                image = AdobeBaseRenderer.applyCube(effectiveCubes.tone, to: image)
            } else {
                image = AdobeBaseRenderer.applyRemainingStages(
                    to: stageM, assets: effectiveAssets, cubes: effectiveCubes,
                    userEV: settings.exposure, variant: variant, through: .tone
                )
            }

            // `.preTone` (today's RAW production default, see `SpatialOrder`'s
            // doc comment) already ran [S] above, so it only needs cube P
            // unsplit here, same as `.sP1P2`/`.p1P2S`. The other cases
            // (`.p1SP2` -- the old shared default, `.p1P2S`, `.postQ`) exist
            // to measure the C4-era full-recipe darkness regression under a
            // different [S] position and remain reachable via the env var.
            if needsSpatial {
                switch order {
                case .preTone:
                    if ToneOps.needsPostOps(settings) {
                        image = AdobeBaseRenderer.applyCube(try postOps(), to: image)
                    }
                case .sP1P2:
                    image = try spatial(image)
                    if ToneOps.needsPostOps(settings) {
                        image = AdobeBaseRenderer.applyCube(try postOps(), to: image)
                    }
                case .p1P2S, .postQ:
                    if ToneOps.needsPostOps(settings) {
                        image = AdobeBaseRenderer.applyCube(try postOps(), to: image)
                    }
                    if order == .p1P2S {
                        image = try spatial(image)
                    }
                    // `.postQ`: [S] deferred to after cube Q/Calibration below.
                case .p1SP2:
                    if ToneOps.needsContrastOrDehaze(settings) {
                        image = AdobeBaseRenderer.applyCube(
                            try AdobeBaseRenderer.postOpsCubeP1(
                                exposureNonRaw: 0, contrast: settings.contrast, dehaze: settings.dehaze, options: options
                            ),
                            to: image
                        )
                    }
                    image = try spatial(image)
                    if ToneOps.needsPostOpsAfterContrast(settings) {
                        image = AdobeBaseRenderer.applyCube(
                            try AdobeBaseRenderer.postOpsCubeP2(settings: settings, options: options), to: image
                        )
                    }
                }
            } else if ToneOps.needsPostOps(settings) {
                image = AdobeBaseRenderer.applyCube(try postOps(), to: image)
            }
            if CalibrationOrder.calibrationFirst {
                if ColorOps.needsCalibration(settings.calibration) {
                    image = AdobeBaseRenderer.applyCalibration(ColorOps.calibrationMatrix(settings.calibration), to: image)
                }
                if ColorOps.needsColorOps(settings) {
                    image = AdobeBaseRenderer.applyCube(
                        try AdobeBaseRenderer.postColorCube(settings: settings, options: options), to: image
                    )
                }
            } else {
                if ColorOps.needsColorOps(settings) {
                    image = AdobeBaseRenderer.applyCube(
                        try AdobeBaseRenderer.postColorCube(settings: settings, options: options), to: image
                    )
                }
                if ColorOps.needsCalibration(settings.calibration) {
                    image = AdobeBaseRenderer.applyCalibration(ColorOps.calibrationMatrix(settings.calibration), to: image)
                }
            }
            if needsSpatial && order == .postQ {
                image = try spatial(image)
            }
            return image
        }

        /// The adaptive statistics a spatial pass at `settings` uses: those
        /// of `settings` itself, or, inside a drag session, those frozen at
        /// the session's starting settings (`PreviewDragSession`).
        private func spatialStatistics(
            for settings: EditSettings, quality: SpatialToneQuality, options: PreviewRenderOptions
        ) throws -> SpatialAdaptiveStats.Stats {
            guard let session = options.dragSession, PreviewDragSession.freezesStatistics,
                  !session.movesOnlySpatialInputs(settings)
            else {
                return try adaptiveStats(for: settings, quality: quality, options: options)
            }
            return try session.statistics(source: cameraImage, quality: quality) {
                try adaptiveStats(for: session.startSettings, quality: quality, options: options.forStatistics)
            }
        }

        /// round2 set A refit (`.photobench/phase2/spatial-adaptive/model.md`
        /// §6/§7): `highlightRatioBase` is no longer computed from a
        /// *neutral* rendering -- §6 found that once Exposure/Contrast/
        /// Whites/Blacks are non-zero, the statistic needs to be taken
        /// *after* those apply (the point where Highlights/Shadows'
        /// local-Laplacian remap actually sees the image, "preHS") to stay
        /// predictive, which makes it depend on `settings` (everything
        /// except Highlights/Shadows/Texture/Clarity themselves -- moving
        /// *those* four never changes what "preHS" looks like, so they are
        /// zeroed out of the cache key, not just left as-is, to avoid
        /// recomputing on every Highlights/Shadows drag). Renders
        /// `imagePreMatrix(settings:)` (through cube Q/Calibration, still
        /// linear ProPhoto) for that zeroed settings value, downscaled to a
        /// fixed 750px long edge (matching preview/export so both see the
        /// same value regardless of what resolution they actually render
        /// at). Cached per `(cacheKey, zeroedSettings)` -- `Handle` itself
        /// is an immutable `Sendable` struct, so this follows the file's
        /// established static-dictionary-plus-lock caching pattern
        /// (`cachedCubes`) rather than instance storage; the cache is
        /// unbounded, same as this file's other settings-keyed caches
        /// (`postOpsCache` etc.). `PHOTO_BENCH_SPATIAL_DIAG=1` prints the
        /// computed ratio and its wall-clock cost to stderr, same
        /// convention as `SpatialToneProcessor`'s own diagnostics -- this is
        /// the number to watch for whether recomputing on most non-H/S/
        /// Texture/Clarity slider moves is actually cheap enough.
        public func highlightRatioBase(for settings: EditSettings) -> Double {
            // `.standard` carries no cancellation token, so nothing can throw.
            try! adaptiveStats(for: settings, options: .standard).highlightRatioBase
        }

        /// `model.md` §10: `SpatialAdaptiveLaw.sShift`'s input -- see
        /// `SpatialAdaptiveStats.Stats.meanLn`'s doc comment. Shares
        /// `highlightRatioBase(for:)`'s exact cache/preHS-render (both are
        /// read off the same `SpatialAdaptiveStats.Stats` value), so calling
        /// both for the same `settings` costs one preHS render, not two.
        public func meanLn(for settings: EditSettings) -> Double {
            try! adaptiveStats(for: settings, options: .standard).meanLn
        }

        /// A preview working copy of this handle (`PreviewWorkingCopyInfo`):
        /// `cameraImage` -- camera RGB the decoder already demosaiced, as-shot
        /// white balanced, lens corrected and oriented at full resolution --
        /// reduced to at most `maxDimension` on its long edge by the
        /// full-resolution preview's own final Lanczos step
        /// (`PreviewWorkingRaster.reduce`) and materialized once as numeric
        /// (`colorSpace` nil) RGBA float pixels. Stage M is redone on those
        /// pixels; assets, cubes, variant and `cacheKey` stay shared, so every
        /// setting (a custom white balance re-running Stage M included)
        /// renders through the identical graph, just on fewer pixels. `nil`
        /// when the materialization fails.
        func downscaled(maxDimension: CGFloat, using raster: PreviewWorkingRaster) -> Handle? {
            guard let reduced = raster.materialize(
                PreviewWorkingRaster.reduce(cameraImage, maxDimension: maxDimension),
                taggedAs: nil
            ) else {
                return nil
            }
            return Handle(
                stageMImage: AdobeBaseRenderer.applyStageM(to: reduced, matrix: assets.combinedMatrix),
                cameraImage: reduced, assets: assets, cubes: cubes, variant: variant, cacheKey: cacheKey,
                previewWorkingCopyLongEdge: Int(max(reduced.extent.width, reduced.extent.height))
            )
        }

        /// `options`: only its cancellation matters -- the "preHS" render
        /// always uses exact cubes (`PreviewRenderOptions.forStatistics`), so
        /// the cached statistic is the same whichever caller computed it.
        private func adaptiveStats(
            for settings: EditSettings, quality: SpatialToneQuality = .final, options: PreviewRenderOptions
        ) throws -> SpatialAdaptiveStats.Stats {
            var zeroed = settings
            zeroed.highlights = 0
            zeroed.shadows = 0
            zeroed.texture = 0
            zeroed.clarity = 0
            let key = AdobeBaseRenderer.StatsCacheKey(
                identity: cacheKey, settings: zeroed, quality: quality,
                previewWorkingCopyLongEdge: previewWorkingCopyLongEdge
            )

            AdobeBaseRenderer.statsCacheLock.lock()
            if let cached = AdobeBaseRenderer.statsCache[key] {
                AdobeBaseRenderer.statsCacheLock.unlock()
                return cached
            }
            AdobeBaseRenderer.statsCacheLock.unlock()

            let diagnosticsEnabled = ProcessInfo.processInfo.environment["PHOTO_BENCH_SPATIAL_DIAG"] != nil
            let startTime = diagnosticsEnabled ? DispatchTime.now() : nil
            let stats = try PreviewDiagnostics.measure("stats") { () throws -> SpatialAdaptiveStats.Stats in
                let preHSImage = try imagePreMatrix(settings: zeroed, quality: quality, options: options.forStatistics)
                let longEdge = AdobeBaseRenderer.highlightRatioBaseLongEdge(for: quality)
                return SpatialAdaptiveStats.computeStats(
                    image: preHSImage, longEdge: longEdge, lumaWeights: SpatialToneOps.ppLuma
                )
            }
            if let startTime {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000
                // kS/sShift are not printed here (only ratio/meanLn, the raw
                // inputs) since which law consumes them depends on
                // `SpatialAdaptiveVersion.current`, resolved downstream in
                // `applySpatialToneOps`'s own diagnostic line -- printing a
                // law here too would risk showing a stale/wrong-version
                // value next to that one.
                let message = "AdobeBaseRenderer.Handle.adaptiveStats: quality=\(quality) ratio=\(stats.highlightRatioBase) "
                    + "meanLn=\(stats.meanLn) (\(String(format: "%.2f", elapsedMs))ms)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }

            AdobeBaseRenderer.statsCacheLock.lock()
            AdobeBaseRenderer.statsCache[key] = stats
            AdobeBaseRenderer.statsCacheLock.unlock()
            return stats
        }
    }

    /// `Handle.highlightRatioBase(for:)`/`meanLn(for:)`'s cache key: a photo
    /// identity plus the (Highlights/Shadows/Texture/Clarity-zeroed)
    /// settings that can change what its "preHS" rendering looks like, plus
    /// `quality` (owner-reported preview sluggishness fix) -- an
    /// `.interactive`-resolution statistic must never be served back to a
    /// later `.final` (export) request, so it gets its own cache slot rather
    /// than sharing `.final`'s.
    struct StatsCacheKey: Hashable {
        var identity: CacheKey
        var settings: EditSettings
        var quality: SpatialToneQuality
        /// `Handle.previewWorkingCopyLongEdge`: keeps a preview working
        /// copy's statistic (computed from its reduced pixels) apart from the
        /// full-resolution decode's, which export reads.
        var previewWorkingCopyLongEdge: Int? = nil
    }

    /// Fixed long edge `Handle.highlightRatioBase()`/`RenderEngine`'s non-RAW
    /// equivalent both downscale to before computing the statistic -- a
    /// preview decode and a full export decode of the same photo must see
    /// the same `highlightRatioBase` (`model.md` §6 item 2), which a
    /// resolution derived from the *caller's own* current render size would
    /// not guarantee. `.interactive` halves this (owner-reported preview
    /// sluggishness: this render -- not just `SpatialToneProcessor.apply`
    /// itself -- is a meaningful share of one slider-drag update's cost) --
    /// the law's inputs are already smooth well below 750px, so the
    /// resulting kH/kS/shift are expected to move very little; measured and
    /// reported alongside the `.interactive`/`.final` `apply()` timing.
    static func highlightRatioBaseLongEdge(for quality: SpatialToneQuality) -> Double {
        quality == .interactive ? highlightRatioBaseLongEdge / 2 : highlightRatioBaseLongEdge
    }
    static let highlightRatioBaseLongEdge = 750.0
    private static let statsCacheLock = NSLock()
    nonisolated(unsafe) private static var statsCache: [StatsCacheKey: SpatialAdaptiveStats.Stats] = [:]

    /// Cube H depends on the DCP and the photo's white point (it is the
    /// CCT-interpolated `ProfileHueSatMap`); cubes L and TC depend only on
    /// the DCP and "Adobe Color" look files (`DCPProfile.lookTableData`,
    /// `AdobeLookXMP.lookTableData/toneCurvePoints`, ACR3's fixed table) and
    /// `variant` -- never on white point or exposure (Stage E is a runtime
    /// `CIExposureAdjust`, not baked into any cube). Splitting the cache
    /// along this line, rather than one entry per `CacheKey` as a whole,
    /// means opening a second, third, ... photo from the *same camera* (the
    /// common case) only rebuilds cube H -- L and TC are byte-identical and
    /// reused. Measured cost of rebuilding all 3 (release build, DC-S5, this
    /// machine): ~500ms; splitting cuts a same-camera photo's cache-miss
    /// cost roughly to cube H's share of that.
    private struct HueSatCacheKey: Hashable { var dcpIdentity: String; var whiteXMicros: Int; var whiteYMicros: Int }
    private struct LookToneCacheKey: Hashable { var dcpIdentity: String; var lookIdentity: String; var variant: ToneCurveVariant }
    /// Wraps `BakedCube?` so a cache hit (key present) and a "computed, and
    /// the answer is no cube needed" result (`cube == nil`) are both a single
    /// level of `Optional` at the call site -- a `[K: BakedCube?]`
    /// dictionary's own `V?` lookup result would otherwise be `BakedCube??`,
    /// which is correct but easy to misread.
    private struct HueSatCube { var cube: BakedCube? }
    private struct LookToneCubes { var look: Data; var tone: Data }

    private static let cacheLock = NSLock()
    /// Per white point, so bounded like the settings-dependent cubes (a
    /// white balance drag bakes one per rendered value).
    private static let hueSatCache = CubeCache<HueSatCacheKey, HueSatCube>()
    nonisolated(unsafe) private static var lookToneCache: [LookToneCacheKey: LookToneCubes] = [:]

    /// Phase2 C1 Stage P cube key: every `ToneOps.applyPostOps` input plus
    /// the non-RAW-only `exposureNonRaw` EV (always 0 for the RAW path,
    /// which applies its own `Exposure2012` at Stage E instead) --
    /// `docs/PHASE2_DEVELOP_PIPELINE.md` C1 item 4's "P に関わる設定値の
    /// ハッシュ". A RAW photo and a non-RAW photo with the same P-relevant
    /// settings and `exposureNonRaw == 0` legitimately share one cube.
    /// `dimension` (every settings-dependent cube key has it): the grid the
    /// cube was baked on, `cubeDimension` or, for a drag frame's tone cube,
    /// `dragCubeDimension`.
    private struct PostOpsCacheKey: Hashable {
        var exposureNonRaw: Double
        var contrast: Double
        var dehaze: Double
        var whites: Double
        var blacks: Double
        var parametricShadows: Double
        var parametricDarks: Double
        var parametricLights: Double
        var parametricHighlights: Double
        var parametricShadowSplit: Double
        var parametricMidtoneSplit: Double
        var parametricHighlightSplit: Double
        var toneCurves: [ToneCurve]
        var dimension: Int
    }

    private static let postOpsCache = CubeCache<PostOpsCacheKey, Data>()

    /// Phase2 C3/C4: cube P1's key when the spatial pass
    /// (`SpatialToneOps`/`SpatialToneProcessor`: Highlights/Shadows/Texture/
    /// Clarity) is active and cube P must therefore be split
    /// (`docs/PHASE2_C2_C3.md`'s C3 section) -- exposure (non-RAW only),
    /// contrast, and (Phase2 C4) dehaze are the `ToneOps` P steps that run
    /// *before* the spatial pass (`ToneOps.applyContrastAndDehaze`).
    private struct PostOpsP1CacheKey: Hashable {
        var exposureNonRaw: Double
        var contrast: Double
        var dehaze: Double
        var dimension: Int
    }

    private static let postOpsP1Cache = CubeCache<PostOpsP1CacheKey, Data>()

    /// Cube P2's key: `PostOpsCacheKey` minus `exposureNonRaw`/`contrast`/
    /// `dehaze` (cube P1's own key) -- Whites/Blacks/Parametric/Point curve,
    /// which run *after* the spatial pass.
    private struct PostOpsP2CacheKey: Hashable {
        var whites: Double
        var blacks: Double
        var parametricShadows: Double
        var parametricDarks: Double
        var parametricLights: Double
        var parametricHighlights: Double
        var parametricShadowSplit: Double
        var parametricMidtoneSplit: Double
        var parametricHighlightSplit: Double
        var toneCurves: [ToneCurve]
        var dimension: Int
    }

    private static let postOpsP2Cache = CubeCache<PostOpsP2CacheKey, Data>()

    /// Phase2 C2 Stage Q cube key: every `ColorOps.applyColorOps` input.
    /// Camera Calibration is deliberately **not** part of this key (or this
    /// cube) -- it is applied afterward as its own `CIColorMatrix`
    /// (`applyCalibration`), so a calibration-only slider change never
    /// invalidates cube Q (`docs/PHASE2_C2_C3.md`'s C2 item 3).
    private struct ColorOpsCacheKey: Hashable {
        var vibrance: Double
        var saturation: Double
        var hsl: [HSLBand: HSLAdjustment]
        var colorGrading: ColorGradingSettings
        var dimension: Int
    }

    private static let colorOpsCache = CubeCache<ColorOpsCacheKey, Data>()

    /// Builds a `Handle` for one decoded photo: applies Stage M to
    /// `cameraImage` immediately, and looks up (or bakes and caches) the
    /// shared H/L/TC cube set for `cacheKey`.
    public static func makeHandle(
        cameraImage: CIImage,
        assets: AdobeBaseAssets,
        cacheKey: CacheKey,
        variant: ToneCurveVariant = .production
    ) -> Handle {
        let stageMImage = applyStageM(to: cameraImage, matrix: assets.combinedMatrix)
        // No cancellation token: the lookup always completes.
        let cubes = cachedCubes(for: assets, key: cacheKey, variant: variant)!
        return Handle(
            stageMImage: stageMImage, cameraImage: cameraImage, assets: assets, cubes: cubes,
            variant: variant, cacheKey: cacheKey, previewWorkingCopyLongEdge: nil
        )
    }

    /// Clears every cached cube. Exposed for tests/tools; production code
    /// never needs to call this (cube data is small and bounded by the
    /// number of distinct camera profiles opened in the process).
    static func clearCache() {
        hueSatCache.removeAll()
        cacheLock.lock()
        lookToneCache.removeAll()
        cacheLock.unlock()
        postOpsCache.removeAll()
        postOpsP1Cache.removeAll()
        postOpsP2Cache.removeAll()
        colorOpsCache.removeAll()
    }

    /// Bakes (or reuses) cube P: `ToneOps.applyPostOps(settings:)`, optionally
    /// preceded by `ToneOps.exposureNonRaw` (`exposureNonRaw != 0`, non-RAW
    /// callers only -- `Handle.image(settings:)` always passes 0, since RAW's
    /// `Exposure2012` is the separate Stage E linear gain). Composing both
    /// into one cube, rather than baking/applying two cubes in sequence, is
    /// both cheaper (one `concurrentPerform` bake, one `CIColorCube` pass)
    /// and more accurate (one quantization round trip instead of two).
    static func postOpsCube(exposureNonRaw: Double, settings: EditSettings) -> Data {
        // `.standard`: exact grid, no cancellation token, so this cannot throw.
        try! postOpsCube(exposureNonRaw: exposureNonRaw, settings: settings, options: .standard).data
    }

    /// `postOpsCube(exposureNonRaw:settings:)` under the preview's
    /// `options` (see `settingsCube`).
    static func postOpsCube(
        exposureNonRaw: Double, settings: EditSettings, options: PreviewRenderOptions
    ) throws -> BakedCube {
        let dimension = options.toneCubeDimension
        let bakeSettings = dimension == cubeDimension ? settings : settings.withoutIdentityToneCurves()
        return try settingsCube(
            "P", cache: postOpsCache, dimension: dimension, options: options,
            key: { dimension in
                PostOpsCacheKey(
                    exposureNonRaw: exposureNonRaw,
                    contrast: settings.contrast, dehaze: settings.dehaze, whites: settings.whites, blacks: settings.blacks,
                    parametricShadows: settings.parametricShadows, parametricDarks: settings.parametricDarks,
                    parametricLights: settings.parametricLights, parametricHighlights: settings.parametricHighlights,
                    parametricShadowSplit: settings.parametricShadowSplit,
                    parametricMidtoneSplit: settings.parametricMidtoneSplit,
                    parametricHighlightSplit: settings.parametricHighlightSplit,
                    toneCurves: settings.toneCurves,
                    dimension: dimension
                )
            },
            makeTransform: {
                // Per chunk: its own settings storage and point-curve splines.
                let prepared = ToneOps.PreparedPostOps(settings: bakeSettings.uniquelyStoredCopy())
                return { value in
                    let afterExposure = exposureNonRaw == 0 ? value : ToneOps.exposureNonRaw(value, ev: exposureNonRaw)
                    return prepared.apply(afterExposure)
                }
            }
        )
    }

    /// Phase2 C3/C4: cube P1 (exposureNonRaw -> Contrast -> Dehaze), used
    /// instead of the single `postOpsCube` when `SpatialToneOps.needsSpatial(
    /// settings)` -- the spatial pass (Highlights/Shadows/Texture/Clarity)
    /// runs on cube P1's (linear ProPhoto) output, before cube P2
    /// (`postOpsCubeP2`). Bakes to the exact same values `postOpsCube`'s own
    /// leading `applyContrastAndDehaze(exposureNonRaw(...))` computation
    /// would, so splitting the cube never changes the no-spatial-op
    /// (single-cube) path's numeric result -- `ToneOpsTests`/
    /// `AdobeBaseRendererTests` cover this equivalence.
    static func postOpsCubeP1(exposureNonRaw: Double, contrast: Double, dehaze: Double) -> Data {
        // `.standard`: exact grid, no cancellation token, so this cannot throw.
        try! postOpsCubeP1(exposureNonRaw: exposureNonRaw, contrast: contrast, dehaze: dehaze, options: .standard).data
    }

    static func postOpsCubeP1(
        exposureNonRaw: Double, contrast: Double, dehaze: Double, options: PreviewRenderOptions
    ) throws -> BakedCube {
        try settingsCube(
            "P1", cache: postOpsP1Cache, dimension: options.toneCubeDimension, options: options,
            key: { PostOpsP1CacheKey(exposureNonRaw: exposureNonRaw, contrast: contrast, dehaze: dehaze, dimension: $0) },
            makeTransform: {
                { value in
                    let afterExposure = exposureNonRaw == 0 ? value : ToneOps.exposureNonRaw(value, ev: exposureNonRaw)
                    return ToneOps.dehaze(ToneOps.contrast(afterExposure, amount: contrast), amount: dehaze)
                }
            }
        )
    }

    /// Phase2 C3: cube P2 (Whites -> Blacks -> Parametric -> Point curve),
    /// the other half of the H/S-spatial-active split -- see
    /// `postOpsCubeP1`'s doc comment.
    static func postOpsCubeP2(settings: EditSettings) -> Data {
        // `.standard`: exact grid, no cancellation token, so this cannot throw.
        try! postOpsCubeP2(settings: settings, options: .standard).data
    }

    static func postOpsCubeP2(settings: EditSettings, options: PreviewRenderOptions) throws -> BakedCube {
        let dimension = options.toneCubeDimension
        let bakeSettings = dimension == cubeDimension ? settings : settings.withoutIdentityToneCurves()
        return try settingsCube(
            "P2", cache: postOpsP2Cache, dimension: dimension, options: options,
            key: { dimension in
                PostOpsP2CacheKey(
                    whites: settings.whites, blacks: settings.blacks,
                    parametricShadows: settings.parametricShadows, parametricDarks: settings.parametricDarks,
                    parametricLights: settings.parametricLights, parametricHighlights: settings.parametricHighlights,
                    parametricShadowSplit: settings.parametricShadowSplit,
                    parametricMidtoneSplit: settings.parametricMidtoneSplit,
                    parametricHighlightSplit: settings.parametricHighlightSplit,
                    toneCurves: settings.toneCurves,
                    dimension: dimension
                )
            },
            makeTransform: {
                let prepared = ToneOps.PreparedPostOps(settings: bakeSettings.uniquelyStoredCopy())
                return { value in prepared.applyAfterContrast(value) }
            }
        )
    }

    /// Bakes (or reuses) cube Q: `ColorOps.applyColorOps` (Vibrance ->
    /// Saturation -> HSL -> Color Grading). Camera Calibration is excluded on
    /// purpose -- see `ColorOpsCacheKey`'s and `applyCalibration`'s doc
    /// comments.
    static func postColorCube(settings: EditSettings) -> Data {
        // `.standard`: exact grid, no cancellation token, so this cannot throw.
        try! postColorCube(settings: settings, options: .standard).data
    }

    /// Always the exact grid, drag frames included: with the per-chunk
    /// settings copy the bake takes 15-20 ms on the Mac mini.
    static func postColorCube(settings: EditSettings, options: PreviewRenderOptions) throws -> BakedCube {
        try settingsCube(
            "Q", cache: colorOpsCache, dimension: cubeDimension, options: options,
            key: { dimension in
                ColorOpsCacheKey(
                    vibrance: settings.vibrance, saturation: settings.saturation,
                    hsl: settings.hsl, colorGrading: settings.colorGrading, dimension: dimension
                )
            },
            makeTransform: {
                let settings = settings.uniquelyStoredCopy()
                return { value in ColorOps.applyColorOps(value, settings: settings) }
            }
        )
    }

    /// One settings-dependent cube (P, P1, P2 or Q). At the exact grid
    /// (`dimension == cubeDimension`, every caller but a drag frame's tone
    /// cube) this is the long-standing look-up-or-bake. A smaller `dimension`
    /// still takes the exact cube whenever it is already cached, and
    /// otherwise looks up or bakes that grid. Throws `CancellationError`
    /// (caching nothing) when `options.cancellation` stops the bake.
    private static func settingsCube<Key: Hashable>(
        _ label: String,
        cache: CubeCache<Key, Data>,
        dimension: Int,
        options: PreviewRenderOptions,
        key: (Int) -> Key,
        makeTransform: @Sendable () -> (SIMD3<Double>) -> SIMD3<Double>
    ) throws -> BakedCube {
        if dimension != cubeDimension, let exact = cache.value(for: key(cubeDimension)) {
            return BakedCube(data: exact, dimension: cubeDimension)
        }
        let cacheKey = key(dimension)
        if let cached = cache.value(for: cacheKey) {
            return BakedCube(data: cached, dimension: dimension)
        }
        try options.checkCancellation()
        guard let data = PreviewDiagnostics.measure("cube.\(label)(\(dimension))", {
            bakeCube(dimension: dimension, cancellation: options.cancellation, makeTransform: makeTransform)
        }) else {
            throw CancellationError()
        }
        cache.insert(data, for: cacheKey)
        return BakedCube(data: data, dimension: dimension)
    }

    /// `nil` only when `cancellation` stopped a bake.
    private static func cachedCubes(
        for assets: AdobeBaseAssets, key: CacheKey, variant: ToneCurveVariant,
        cancellation: PreviewCancellation? = nil
    ) -> CubeSet? {
        let hueSatKey = HueSatCacheKey(
            dcpIdentity: key.dcpIdentity, whiteXMicros: key.whiteXMicros, whiteYMicros: key.whiteYMicros
        )
        let lookToneKey = LookToneCacheKey(
            dcpIdentity: key.dcpIdentity, lookIdentity: key.lookIdentity, variant: variant
        )

        let cachedHueSat = hueSatCache.value(for: hueSatKey)
        cacheLock.lock()
        let cachedLookTone = lookToneCache[lookToneKey]
        cacheLock.unlock()

        let hueSat: HueSatCube
        if let cachedHueSat {
            hueSat = cachedHueSat
        } else {
            guard let baked = PreviewDiagnostics.measure("cube.H(\(cubeDimension))", {
                buildHueSatCube(assets: assets, cancellation: cancellation)
            }) else {
                return nil
            }
            hueSat = baked
            hueSatCache.insert(baked, for: hueSatKey)
        }
        let lookTone = cachedLookTone ?? PreviewDiagnostics.measure("cube.LT(\(cubeDimension))") {
            buildLookToneCubes(assets: assets, variant: variant)
        }
        if cachedLookTone == nil {
            cacheLock.lock()
            lookToneCache[lookToneKey] = lookTone
            cacheLock.unlock()
        }

        return CubeSet(hueSat: hueSat.cube, look: lookTone.look, tone: lookTone.tone)
    }

    // MARK: - CPU cube-table construction

    /// Bakes cube H from `assets.huesatTable` via the same public
    /// `AdobeProfile` function (`HueSatMap.apply`) the CPU reference
    /// (`AdobeColorMath.evaluate`) calls at Stage H. `cube == nil` when the
    /// DCP has no `ProfileHueSatMap` (Stage H becomes a no-op); `nil` only
    /// when `cancellation` stopped the bake.
    private static func buildHueSatCube(
        assets: AdobeBaseAssets, cancellation: PreviewCancellation? = nil
    ) -> HueSatCube? {
        guard let table = assets.huesatTable else { return HueSatCube(cube: nil) }
        guard let data = bakeCube(dimension: cubeDimension, cancellation: cancellation, makeTransform: {
            { HueSatMap.apply($0, table: table) }
        }) else {
            return nil
        }
        return HueSatCube(cube: BakedCube(data: data, dimension: cubeDimension))
    }

    /// Bakes cubes L and TC from `assets`' look/tone tables, via the same
    /// public `AdobeProfile` functions the CPU reference calls at Stages
    /// L/T/C.
    private static func buildLookToneCubes(
        assets: AdobeBaseAssets, variant: ToneCurveVariant
    ) -> LookToneCubes {
        let look = buildCubeData { input -> SIMD3<Double> in
            var value = input
            if let dcpLook = assets.dcpLookTable {
                value = HueSatMap.apply(value, table: dcpLook)
            }
            return HueSatMap.apply(value, table: assets.adobeLookTable)
        }
        let tone = buildCubeData { input -> SIMD3<Double> in
            let afterACR3 = RGBTone.apply(input, curve: ACR3DefaultToneCurve.evaluate)
            return applyToneCurveVariant(afterACR3, variant: variant, spline: assets.toneCurveSpline)
        }
        return LookToneCubes(look: look, tone: tone)
    }

    /// Bakes all three stage cubes fresh (bypassing the cache). Exposed for
    /// tests that want to exercise cube generation directly.
    static func buildCubes(assets: AdobeBaseAssets, variant: ToneCurveVariant) -> CubeSet {
        let lookTone = buildLookToneCubes(assets: assets, variant: variant)
        return CubeSet(
            hueSat: buildHueSatCube(assets: assets)?.cube, look: lookTone.look, tone: lookTone.tone
        )
    }

    /// `docs/PHASE1_BASE_RENDERING.md` 注1's variant "a"/"b"/"c", reimplemented
    /// here (rather than calling B1's `AdobeColorMath.evaluate`, which always
    /// starts a fresh evaluation from `cameraRGB * combinedMatrix`) because a
    /// cube's `transform` closure needs to run only the *local* stage on an
    /// already-upstream value. This mirrors `AdobeColorMath`'s private
    /// `applyToneCurveVariantA` and its `.lookToneCurve` cases exactly, using
    /// only that file's public API (`DNGColorSpace.srgbEncode/srgbDecode`,
    /// `RGBTone.apply`, `DNGSpline.evaluate`).
    static func applyToneCurveVariant(
        _ value: SIMD3<Double>, variant: ToneCurveVariant, spline: DNGSpline
    ) -> SIMD3<Double> {
        variant.apply(value, spline: spline)
    }

    /// Bakes one `dimension`^3 `CIColorCube` `inputCubeData` blob: for each
    /// grid point, decodes the gamma-encoded grid coordinate back to linear,
    /// runs `transform`, clips the result to [0,1] (see this type's doc
    /// comment for why), and re-encodes for storage. Red varies fastest, then
    /// green, then blue, matching `CIColorCube`'s documented `inputCubeData`
    /// ordering.
    static func buildCubeData(
        dimension: Int = AdobeBaseRenderer.cubeDimension,
        transform: @Sendable (SIMD3<Double>) -> SIMD3<Double>
    ) -> Data {
        withoutActuallyEscaping(transform) { transform in
            // No cancellation token: the bake always completes.
            bakeCube(dimension: dimension, cancellation: nil, makeTransform: { transform })!
        }
    }

    /// `buildCubeData`'s implementation. The grid's (b, g) rows are split into
    /// chunks that run concurrently; each chunk calls `makeTransform` once and
    /// evaluates only the closure it got. A transform over `EditSettings`
    /// should capture a `uniquelyStoredCopy()` made inside `makeTransform`:
    /// the chunks then never retain and release the same collection storage
    /// (on the Mac mini that contention was about 70% of a cube Q bake).
    /// Every grid point is computed exactly as before (same linear sample,
    /// same transform, same encode), so the data is byte-identical to the
    /// single-closure bake. `nil` (nothing returned) when `cancellation` is
    /// cancelled before every chunk ran.
    static func bakeCube(
        dimension n: Int,
        cancellation: PreviewCancellation?,
        makeTransform: @Sendable () -> (SIMD3<Double>) -> SIMD3<Double>
    ) -> Data? {
        let denominator = Double(n - 1)
        let linear = (0..<n).map { pow(Double($0) / denominator, cubeGammaPower) }
        let rowCount = n * n
        let rowsPerChunk = max(1, n / 8)
        let chunkCount = (rowCount + rowsPerChunk - 1) / rowsPerChunk
        let skippedChunks = PreviewCancellation()
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        floats.withUnsafeMutableBufferPointer { buffer in
            linear.withUnsafeBufferPointer { linearBuffer in
                // Neither `UnsafeMutableBufferPointer` nor the raw pointer it
                // wraps is `Sendable`; `UnsafeSendableBox` documents (rather
                // than silently papers over) that this is safe here
                // specifically because each chunk writes only its own rows'
                // disjoint slice (`row*n*4..<(row+1)*n*4`) and only reads the
                // shared linear table, so concurrent access never races.
                guard let base = buffer.baseAddress, let linearBase = linearBuffer.baseAddress else { return }
                let box = UnsafeSendableBox(pointer: base)
                let linearBox = UnsafeSendableBox(pointer: UnsafeMutablePointer(mutating: linearBase))
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    if cancellation?.isCancelled == true {
                        skippedChunks.cancel()
                        return
                    }
                    let transform = makeTransform()
                    let base = box.pointer
                    let linear = linearBox.pointer
                    let firstRow = chunk * rowsPerChunk
                    for row in firstRow..<min(firstRow + rowsPerChunk, rowCount) {
                        let bLinear = linear[row / n]
                        let gLinear = linear[row % n]
                        let rowBase = row * n
                        for rIndex in 0..<n {
                            let output = transform(SIMD3(linear[rIndex], gLinear, bLinear))
                            let entryBase = (rowBase + rIndex) * 4
                            base[entryBase] = Float(encodedComponent(output.x))
                            base[entryBase + 1] = Float(encodedComponent(output.y))
                            base[entryBase + 2] = Float(encodedComponent(output.z))
                            base[entryBase + 3] = 1
                        }
                    }
                }
            }
        }
        guard !skippedChunks.isCancelled else { return nil }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func encodedComponent(_ value: Double) -> Double {
        let clipped = min(max(value, 0.0), 1.0)
        return pow(clipped, 1.0 / cubeGammaPower)
    }

    // MARK: - CIImage graph stages

    /// Stage M: camera RGB -> linear ProPhoto via `matrix`, then clip
    /// negative components to 0 (an out-of-gamut cross-talk artifact, not
    /// scene-referred signal) while leaving highlights (already mostly
    /// bounded by LibRaw's own `highlight=0` clip) unclamped.
    static func applyStageM(to image: CIImage, matrix: Matrix3x3) -> CIImage {
        let transformed = applyMatrix(matrix, to: image)
        return transformed.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1.0e6, y: 1.0e6, z: 1.0e6, w: 1)
        ])
    }

    private static func applyRemainingStages(
        to stageMImage: CIImage, assets: AdobeBaseAssets, cubes: CubeSet,
        userEV: Double, variant: ToneCurveVariant, through stage: Handle.Stage
    ) -> CIImage {
        var image = stageMImage
        guard stage != .matrix else { return image }

        if let hueSat = cubes.hueSat {
            image = applyCube(hueSat, to: image)
        }
        guard stage != .huesat else { return image }

        image = image.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: assets.baselineEV + userEV
        ])
        guard stage != .exposure else { return image }

        image = applyCube(cubes.look, to: image)
        guard stage != .look else { return image }

        image = applyCube(cubes.tone, to: image)
        guard stage != .tone else { return image }

        return applyMatrix(DNGColorSpace.proPhotoToSRGBLinear, to: image)
    }

    /// Wraps one cube application with its own gamma encode/decode pair
    /// (`docs/PHASE1_BASE_RENDERING.md`'s "cube の前後に CIGammaAdjust").
    /// Consecutive cubes each pay this round trip rather than sharing one
    /// encode/decode across stages; the redundant pair between two adjacent
    /// cubes is a no-op past float rounding, and cube generation/evaluation
    /// is cheap enough that the simpler, literal structure wins.
    static func applyCube(_ cube: BakedCube, to image: CIImage) -> CIImage {
        applyCube(cube.data, to: image, dimension: cube.dimension)
    }

    static func applyCube(
        _ data: Data, to image: CIImage, dimension: Int = AdobeBaseRenderer.cubeDimension
    ) -> CIImage {
        let encoded = image.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": 1.0 / cubeGammaPower
        ])
        let cubed = encoded.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data
        ])
        return cubed.applyingFilter("CIGammaAdjust", parameters: ["inputPower": cubeGammaPower])
    }

    /// Not `private`: `RenderEngine`'s non-RAW Stage P path (a different file
    /// in this module) reuses this for its working-space <-> ProPhoto round
    /// trip instead of duplicating the `CIColorMatrix` parameter plumbing.
    static func applyMatrix(_ matrix: Matrix3x3, to image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: matrix[0, 0], y: matrix[0, 1], z: matrix[0, 2], w: 0),
            "inputGVector": CIVector(x: matrix[1, 0], y: matrix[1, 1], z: matrix[1, 2], w: 0),
            "inputBVector": CIVector(x: matrix[2, 0], y: matrix[2, 1], z: matrix[2, 2], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    /// Phase2 C2 Camera Calibration: `y = clip(M@x, 0, 1)`
    /// (`ColorOps.calibrationMatrix` / `color_model.apply_calibration`), as
    /// an exact `CIColorMatrix` rather than a baked cube -- unlike cube P/Q,
    /// a 3x3 matrix has no LUT quantization error to trade away, and keeping
    /// it standalone means a calibration-only slider change never
    /// invalidates cube Q's cache (`docs/PHASE2_C2_C3.md`'s C2 item 3). The
    /// full [0,1] `CIColorClamp` (both bounds, unlike `applyStageM`'s
    /// min-only clamp) matches the Python reference's own `np.clip(y, 0, 1)`.
    static func applyCalibration(_ matrix: Matrix3x3, to image: CIImage) -> CIImage {
        applyMatrix(matrix, to: image).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
    }

    /// Phase2 C3/C4: Highlights2012 -> Shadows2012 -> Texture -> Clarity2012's
    /// spatial (local-Laplacian/multiscale-gain) pass, run between cube P1
    /// and cube P2 (`docs/PHASE2_C2_C3.md`'s C3 section, extended by Phase2
    /// C4's `.photobench/phase2/detail/model.md`) whenever
    /// `SpatialToneOps.needsSpatial(settings)`. `image` must already be
    /// **linear ProPhoto** -- cube P1's own `applyCube` output (which itself
    /// decodes/re-encodes the cube's internal gamma), or, on the non-RAW
    /// path, the working-space -> ProPhoto matrix's direct output. `scalePx`
    /// is derived from `image`'s own extent (the resolution this call is
    /// *actually* processing at, already reflecting any decode-time
    /// downscale -- see `SpatialToneOps.scalePx(forLongEdge:)`'s doc comment
    /// on why no separate `appliedScaleFactor` correction is needed), so the
    /// RAW path here, the non-RAW path (`RenderEngine.applyNonRAWStageP`),
    /// preview decodes, and export decodes all agree on the same physical
    /// detail scale through this one shared call site.
    /// `highlightRatioBase`: the per-photo statistic (`SpatialAdaptiveStats`/
    /// `SpatialAdaptiveLaw`, `.photobench/phase2/spatial-adaptive/model.md`)
    /// this call's `SpatialGainScale.current(highlightRatioBase:)` resolution
    /// uses to pick an image-adaptive kS; `nil` (no statistic available,
    /// e.g. a caller with no cached-per-photo context) falls back to
    /// `.productionDefault`'s fixed kS. `Handle.image(settings:)` (RAW) and
    /// `RenderEngine.applyNonRAWStageP`/`Q` (non-RAW) each resolve their own
    /// cached value and pass it in; this is the one and only place that
    /// consumes it, matching `SpatialGainScale.current`'s own doc comment.
    /// `applySpatialToneOps`, reusing `cache`'s previous result when this
    /// call would read exactly the same input and parameters
    /// (`SpatialPassCache.Key`). `source` is the pixels `image` was derived
    /// from (the working copy's camera image or input image) and
    /// `inputParameters` every value that turned them into `image`. `nil`
    /// cache (export, experiment orders): always recomputes.
    static func spatialPass(
        settings: EditSettings, to image: CIImage, source: CIImage, inputParameters: [Double],
        adaptiveStats: SpatialAdaptiveStats.Stats?, path: SpatialAdaptivePath,
        quality: SpatialToneQuality, cache: SpatialPassCache?
    ) -> CIImage {
        guard let cache else {
            return applySpatialToneOps(settings: settings, to: image, adaptiveStats: adaptiveStats, path: path, quality: quality)
        }
        let key = SpatialPassCache.Key(
            source: ObjectIdentifier(source), extent: image.extent, path: path, inputParameters: inputParameters,
            highlights: settings.highlights, shadows: settings.shadows,
            texture: settings.texture, clarity: settings.clarity,
            quality: quality, stats: adaptiveStats
        )
        if let reused = cache.output(for: key) {
            if PreviewDiagnostics.isEnabled {
                PreviewDiagnostics.record("spatial.reused", milliseconds: 0)
            }
            return reused
        }
        let output = applySpatialToneOps(settings: settings, to: image, adaptiveStats: adaptiveStats, path: path, quality: quality)
        cache.store(output, for: key, source: source)
        return output
    }

    static func applySpatialToneOps(
        settings: EditSettings, to image: CIImage,
        adaptiveStats: SpatialAdaptiveStats.Stats? = nil, path: SpatialAdaptivePath = .raw,
        quality: SpatialToneQuality = .final
    ) -> CIImage {
        let longEdge = max(image.extent.width, image.extent.height)
        let scalePx = SpatialToneOps.scalePx(forLongEdge: Double(longEdge))
        // This is the one and only production call site that resolves
        // `SpatialShift.current`/`SpatialGainScale.current` (env vars,
        // falling back to `path`'s adaptive law) -- see those types' doc
        // comments; everything below takes the result as an explicit
        // parameter.
        let shift = SpatialShift.current(stats: adaptiveStats, path: path)
        let gainScale = SpatialGainScale.current(stats: adaptiveStats, path: path)
        if ProcessInfo.processInfo.environment["PHOTO_BENCH_SPATIAL_DIAG"] != nil {
            let statsText: String
            switch path {
            case .raw:
                statsText = "highlightRatioBase=\(adaptiveStats.map { String($0.highlightRatioBase) } ?? "nil")"
                    + " meanLn=\(adaptiveStats.map { String($0.meanLn) } ?? "nil")"
            case .nonRAW:
                statsText = "baseHighlightRatio=\(adaptiveStats.map { String($0.highlightRatioBase) } ?? "nil")"
                    + " fullHighlightRatio=\(adaptiveStats.map { String($0.fullHighlightRatio) } ?? "nil")"
                    + " fullP90=\(adaptiveStats.map { String($0.fullP90) } ?? "nil")"
            }
            // `version` (the v2/shift-refit/shift-v2ks switch) is a RAW-only
            // concept (`SpatialAdaptiveVersion`'s doc comment) -- omitted
            // for `.nonRAW` so this line never implies non-RAW respects it.
            var message = "AdobeBaseRenderer.applySpatialToneOps: path=\(path.rawValue) quality=\(quality)"
            if path == .raw {
                message += " version=\(SpatialAdaptiveVersion.current.rawValue)"
            }
            message += " \(statsText)"
            message += " kH=\(gainScale.highlightsPos) kS=\(gainScale.shadowsPos) shift.highlights=\(shift.highlights) shift.shadows=\(shift.shadows)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        guard let output = PreviewDiagnostics.measure("spatial", {
            try? SpatialToneProcessor.apply(
                to: image, highlights: settings.highlights, shadows: settings.shadows, scalePx: scalePx,
                texture: settings.texture, clarity: settings.clarity,
                gainScale: gainScale, shift: shift, quality: quality
            )
        }) else {
            preconditionFailure("Photo BenchのHighlights/Shadows空間処理カーネルを画像へ適用できませんでした。")
        }
        return output
    }
}

/// Documents, at the type level, a deliberate opt-out of pointer
/// `Sendable`-checking for `AdobeBaseRenderer.buildCubeData`'s
/// `concurrentPerform` loop: each concurrent iteration writes only its own
/// disjoint slice of the wrapped buffer (see the call site's comment), so
/// the underlying data race the compiler cannot otherwise prove absent does
/// not actually occur.
private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
}

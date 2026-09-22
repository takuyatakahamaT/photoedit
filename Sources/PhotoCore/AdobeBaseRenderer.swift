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
        var hueSat: Data?
        var look: Data
        var tone: Data
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
        let assets: AdobeBaseAssets
        let cubes: CubeSet
        let variant: ToneCurveVariant

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
    }

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
    /// Wraps `Data?` so a cache hit (key present) and a "computed, and the
    /// answer is no cube needed" result (`data == nil`) are both a single
    /// level of `Optional` at the call site -- a `[K: Data?]` dictionary's
    /// own `V?` lookup result would otherwise be `Data??`, which is correct
    /// but easy to misread.
    private struct HueSatCube { var data: Data? }
    private struct LookToneCubes { var look: Data; var tone: Data }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var hueSatCache: [HueSatCacheKey: HueSatCube] = [:]
    nonisolated(unsafe) private static var lookToneCache: [LookToneCacheKey: LookToneCubes] = [:]

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
        let cubes = cachedCubes(for: assets, key: cacheKey, variant: variant)
        return Handle(stageMImage: stageMImage, assets: assets, cubes: cubes, variant: variant)
    }

    /// Clears every cached cube. Exposed for tests/tools; production code
    /// never needs to call this (cube data is small and bounded by the
    /// number of distinct camera profiles opened in the process).
    static func clearCache() {
        cacheLock.lock()
        hueSatCache.removeAll()
        lookToneCache.removeAll()
        cacheLock.unlock()
    }

    private static func cachedCubes(
        for assets: AdobeBaseAssets, key: CacheKey, variant: ToneCurveVariant
    ) -> CubeSet {
        let hueSatKey = HueSatCacheKey(
            dcpIdentity: key.dcpIdentity, whiteXMicros: key.whiteXMicros, whiteYMicros: key.whiteYMicros
        )
        let lookToneKey = LookToneCacheKey(
            dcpIdentity: key.dcpIdentity, lookIdentity: key.lookIdentity, variant: variant
        )

        cacheLock.lock()
        let cachedHueSat = hueSatCache[hueSatKey]
        let cachedLookTone = lookToneCache[lookToneKey]
        cacheLock.unlock()

        let hueSat = cachedHueSat ?? HueSatCube(data: buildHueSatCube(assets: assets))
        let lookTone = cachedLookTone ?? buildLookToneCubes(assets: assets, variant: variant)

        if cachedHueSat == nil || cachedLookTone == nil {
            cacheLock.lock()
            if cachedHueSat == nil { hueSatCache[hueSatKey] = hueSat }
            if cachedLookTone == nil { lookToneCache[lookToneKey] = lookTone }
            cacheLock.unlock()
        }

        return CubeSet(hueSat: hueSat.data, look: lookTone.look, tone: lookTone.tone)
    }

    // MARK: - CPU cube-table construction

    /// Bakes cube H from `assets.huesatTable` via the same public
    /// `AdobeProfile` function (`HueSatMap.apply`) the CPU reference
    /// (`AdobeColorMath.evaluate`) calls at Stage H. `nil` when the DCP has
    /// no `ProfileHueSatMap` (Stage H becomes a no-op).
    private static func buildHueSatCube(assets: AdobeBaseAssets) -> Data? {
        guard let table = assets.huesatTable else { return nil }
        return buildCubeData { HueSatMap.apply($0, table: table) }
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
            hueSat: buildHueSatCube(assets: assets), look: lookTone.look, tone: lookTone.tone
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

    /// Bakes one `cubeDimension`^3 `CIColorCube` `inputCubeData` blob: for
    /// each grid point, decodes the gamma-encoded grid coordinate back to
    /// linear, runs `transform`, clips the result to [0,1] (see this type's
    /// doc comment for why), and re-encodes for storage. Red varies fastest,
    /// then green, then blue, matching `CIColorCube`'s documented
    /// `inputCubeData` ordering.
    static func buildCubeData(
        dimension: Int = AdobeBaseRenderer.cubeDimension,
        transform: @Sendable (SIMD3<Double>) -> SIMD3<Double>
    ) -> Data {
        let n = dimension
        let denominator = Double(n - 1)
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        floats.withUnsafeMutableBufferPointer { buffer in
            // Neither `UnsafeMutableBufferPointer` nor the raw pointer it
            // wraps is `Sendable`; `UnsafeSendableBox` documents (rather than
            // silently papers over) that this is safe here specifically
            // because each outer iteration (`bIndex`) writes only its own
            // disjoint slice (`rowBase..<rowBase+n*4` for every `gIndex`), so
            // concurrent writes through the shared pointer never race.
            guard let base = buffer.baseAddress else { return }
            let box = UnsafeSendableBox(pointer: base)
            DispatchQueue.concurrentPerform(iterations: n) { bIndex in
                let base = box.pointer
                let bLinear = pow(Double(bIndex) / denominator, cubeGammaPower)
                for gIndex in 0..<n {
                    let gLinear = pow(Double(gIndex) / denominator, cubeGammaPower)
                    let rowBase = (bIndex * n + gIndex) * n
                    for rIndex in 0..<n {
                        let rLinear = pow(Double(rIndex) / denominator, cubeGammaPower)
                        let output = transform(SIMD3(rLinear, gLinear, bLinear))
                        let entryBase = (rowBase + rIndex) * 4
                        base[entryBase] = Float(encodedComponent(output.x))
                        base[entryBase + 1] = Float(encodedComponent(output.y))
                        base[entryBase + 2] = Float(encodedComponent(output.z))
                        base[entryBase + 3] = 1
                    }
                }
            }
        }
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

    private static func applyMatrix(_ matrix: Matrix3x3, to image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: matrix[0, 0], y: matrix[0, 1], z: matrix[0, 2], w: 0),
            "inputGVector": CIVector(x: matrix[1, 0], y: matrix[1, 1], z: matrix[1, 2], w: 0),
            "inputBVector": CIVector(x: matrix[2, 0], y: matrix[2, 1], z: matrix[2, 2], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
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

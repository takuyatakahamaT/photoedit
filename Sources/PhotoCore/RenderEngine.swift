import AppKit
import CoreImage
import Foundation
import ImageIO
import Metal
import os
import UniformTypeIdentifiers

public struct RenderedPreview: @unchecked Sendable {
    public let image: NSImage
    public let durationMilliseconds: Double

    public init(image: NSImage, durationMilliseconds: Double) {
        self.image = image
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Wall-clock phase timings for the exact production render path. Core Image
/// is lazy, so runtime kernel work may occur during materialization even when
/// the graph was assembled earlier. These names deliberately avoid claiming
/// hardware GPU time; Instruments signposts are emitted for deeper profiling.
public struct RenderPhaseTimings: Codable, Equatable, Sendable {
    public let graphAndKernelSetupMilliseconds: Double
    public let materializeAndReadbackMilliseconds: Double
    public let jpegEncodeAndWriteMilliseconds: Double?
    public let atomicInstallMilliseconds: Double?
    public let totalMilliseconds: Double

    public init(
        graphAndKernelSetupMilliseconds: Double,
        materializeAndReadbackMilliseconds: Double,
        jpegEncodeAndWriteMilliseconds: Double? = nil,
        atomicInstallMilliseconds: Double? = nil,
        totalMilliseconds: Double
    ) {
        self.graphAndKernelSetupMilliseconds = graphAndKernelSetupMilliseconds
        self.materializeAndReadbackMilliseconds = materializeAndReadbackMilliseconds
        self.jpegEncodeAndWriteMilliseconds = jpegEncodeAndWriteMilliseconds
        self.atomicInstallMilliseconds = atomicInstallMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

public struct MeasuredRenderedPreview: @unchecked Sendable {
    public let image: NSImage
    public let timings: RenderPhaseTimings

    public init(image: NSImage, timings: RenderPhaseTimings) {
        self.image = image
        self.timings = timings
    }
}

/// Immutable Core Image graph shared by the legacy bitmap fallback and the
/// direct Metal presentation path. Building the graph and materializing it are
/// deliberately separate: the production UI can hand the graph to a drawable
/// without first reading RGBA pixels back to the CPU.
public struct PreparedPreviewFrame: @unchecked Sendable {
    public let image: CIImage
    public let extent: CGRect
    public let sourceURL: URL
    public let graphAndKernelSetupMilliseconds: Double
    public let maxDimension: CGFloat

    public init(
        image: CIImage,
        extent: CGRect,
        sourceURL: URL,
        graphAndKernelSetupMilliseconds: Double,
        maxDimension: CGFloat
    ) {
        self.image = image
        self.extent = extent
        self.sourceURL = sourceURL
        self.graphAndKernelSetupMilliseconds = graphAndKernelSetupMilliseconds
        self.maxDimension = maxDimension
    }
}

public struct PreviewAspectFitGeometry: Equatable, Sendable {
    public let scale: CGFloat
    public let origin: CGPoint
    public let destinationSize: CGSize

    public init(scale: CGFloat, origin: CGPoint, destinationSize: CGSize) {
        self.scale = scale
        self.origin = origin
        self.destinationSize = destinationSize
    }

    public static func fitting(source: CGRect, destinationSize: CGSize) -> Self? {
        guard source.width.isFinite, source.height.isFinite,
              destinationSize.width.isFinite, destinationSize.height.isFinite,
              source.width > 0, source.height > 0,
              destinationSize.width > 0, destinationSize.height > 0
        else {
            return nil
        }
        let scale = min(
            destinationSize.width / source.width,
            destinationSize.height / source.height
        )
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        return Self(
            scale: scale,
            origin: CGPoint(
                x: (destinationSize.width - fitted.width) / 2,
                y: (destinationSize.height - fitted.height) / 2
            ),
            destinationSize: destinationSize
        )
    }
}

/// Pure state machine for the direct preview mailbox. It bounds queued work to
/// one in-flight revision and one latest pending revision. Superseded pending
/// revisions are observable instead of silently disappearing from metrics.
public struct LatestPreviewQueueState: Equatable, Sendable {
    public private(set) var latestID: UInt64?
    public private(set) var pendingID: UInt64?
    public private(set) var inFlightID: UInt64?

    public init() {}

    /// Returns the pending request that was coalesced, if any. Duplicate or
    /// out-of-order submissions are ignored.
    @discardableResult
    public mutating func submit(_ id: UInt64) -> UInt64? {
        if let latestID, id <= latestID { return nil }
        let superseded = pendingID
        latestID = id
        pendingID = id
        return superseded
    }

    /// Atomically claims the expected pending revision. A stale view update
    /// cannot accidentally move a different pending revision in flight.
    @discardableResult
    public mutating func beginPending(_ expectedID: UInt64) -> Bool {
        guard inFlightID == nil, pendingID == expectedID else { return false }
        self.pendingID = nil
        inFlightID = expectedID
        return true
    }

    @discardableResult
    public mutating func finish(_ id: UInt64) -> Bool {
        guard inFlightID == id else { return false }
        inFlightID = nil
        return true
    }

    /// Resize/display moves need the current image rendered again without
    /// manufacturing a new user-input revision.
    public mutating func resubmitLatest() {
        guard let latestID else { return }
        pendingID = latestID
    }
}

public enum MetalPreviewRendererError: LocalizedError {
    case commandQueueUnavailable
    case commandBufferUnavailable
    case incompatibleTexture
    case invalidGeometry
    case renderTaskCreationFailed

    public var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            "Metalの描画キューを作成できません。"
        case .commandBufferUnavailable:
            "Metalの描画コマンドを作成できません。"
        case .incompatibleTexture:
            "表示先のMetalテクスチャ形式がプレビュー契約と一致しません。"
        case .invalidGeometry:
            "プレビューの表示寸法が不正です。"
        case .renderTaskCreationFailed:
            "Core ImageのMetal描画タスクを開始できません。"
        }
    }
}

/// One long-lived, Metal-backed Core Image context per preview surface.
/// Export continues to use RenderEngine's isolated cache-free context.
public final class MetalPreviewRenderer: @unchecked Sendable {
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let context: CIContext

    public static var isSupported: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        context = CIContext(
            mtlCommandQueue: commandQueue,
            options: [
                .workingColorSpace: CGColorSpace(
                    name: CGColorSpace.extendedLinearSRGB
                ) as Any,
                .outputColorSpace: Self.outputColorSpace,
                // Keep the acceptance route cache-free until repeated-photo
                // RSS and eviction gates exist. Export is independently
                // cache-free as well.
                .cacheIntermediates: false,
                .highQualityDownsample: true,
                .name: "PhotoBench.InteractivePreview"
            ]
        )
    }

    public func makeCommandBuffer() throws -> any MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalPreviewRendererError.commandBufferUnavailable
        }
        commandBuffer.label = "PhotoBench.DirectPreview"
        return commandBuffer
    }

    /// Encodes an opaque, SDR sRGB aspect-fit frame. No CPU pixel readback is
    /// performed. The caller owns commit/present and the drawable lifecycle.
    @discardableResult
    public func encodeAspectFit(
        frame: PreparedPreviewFrame,
        to texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws -> CIRenderTask {
        guard texture.textureType == .type2D,
              texture.pixelFormat == Self.pixelFormat,
              texture.width > 0, texture.height > 0
        else {
            throw MetalPreviewRendererError.incompatibleTexture
        }
        let destinationSize = CGSize(width: texture.width, height: texture.height)
        guard let geometry = PreviewAspectFitGeometry.fitting(
            source: frame.extent,
            destinationSize: destinationSize
        ) else {
            throw MetalPreviewRendererError.invalidGeometry
        }

        let cropped = frame.image.cropped(to: frame.extent)
        let normalized = cropped.transformed(
            by: CGAffineTransform(
                translationX: -frame.extent.minX,
                y: -frame.extent.minY
            )
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: geometry.scale, y: geometry.scale)
        )
        let destination = CIRenderDestination(
            mtlTexture: texture,
            commandBuffer: commandBuffer
        )
        destination.colorSpace = Self.outputColorSpace
        destination.alphaMode = .none
        destination.isFlipped = false
        destination.isDithered = false
        destination.isClamped = true
        _ = try context.startTask(toClear: destination)
        let task = try context.startTask(
            toRender: scaled,
            from: scaled.extent,
            to: destination,
            at: geometry.origin
        )
        return task
    }

    public func clearCaches() {
        context.clearCaches()
    }
}

public enum RenderEngineError: LocalizedError {
    case sourceOverwriteForbidden(URL)
    case destinationIsDirectory(URL)
    case renderFailed(URL)
    case previewResolutionExportForbidden(URL)
    case previewResolutionPresentationForbidden(URL)

    public var errorDescription: String? {
        switch self {
        case let .sourceOverwriteForbidden(url):
            "原本は上書きできません。別の保存先を選んでください: \(url.lastPathComponent)"
        case let .destinationIsDirectory(url):
            "フォルダ自体には書き出せません。フォルダ内のファイル名を指定してください: \(url.lastPathComponent)"
        case let .renderFailed(url):
            "画像をレンダーできません: \(url.lastPathComponent)"
        case let .previewResolutionExportForbidden(url):
            "縮小プレビューから原寸書き出しはできません。原本を再読み込みしてください: \(url.lastPathComponent)"
        case let .previewResolutionPresentationForbidden(url):
            "本番表示には原寸デコードが必要です。縮小RAW候補は校正不合格のため使用できません: \(url.lastPathComponent)"
        }
    }
}

/// Controls the explicit final resize used by previews and comparison TIFFs.
public enum TIFFDownsamplingFilter: Sendable {
    case affineTransform
    case lanczos
}

/// Locates the bounded sRGB output transform relative to an optional resize.
/// Production rendering uses `afterDownsampling`: all edits and Lanczos run in
/// extended-linear sRGB, then the bounded transform is the terminal color
/// operation. The legacy case exists only to reproduce schema v1-v3 evidence.
public enum OutputTransformPlacement: Equatable, Sendable {
    case legacyBeforeDownsampling
    case afterDownsampling
}

struct PreparedOutputGraph: @unchecked Sendable {
    let image: CIImage
    let extent: CGRect
}

public final class RenderEngine: @unchecked Sendable {
    public static let processingIdentifier =
        "extended-linear-srgb-edits-resize-before-final-srgb-v1"
    public static let legacyProcessingIdentifier =
        "extended-linear-srgb-edits-final-srgb-then-resize-v1"
    private static let performanceLog = OSLog(
        subsystem: "life.niho.photobench",
        category: "render"
    )
    /// Preview and export must never share an intermediate cache. Both remain
    /// uncached in this slice; a later preview-only cache can be enabled without
    /// changing export output or hash stability.
    private let previewContext: CIContext
    private let exportContext: CIContext
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let kernelCacheLock = NSLock()
    private var cachedCurveKernel: (key: [ToneCurve], kernel: CIColorKernel)?
    private var cachedMixerKernel: (key: [HSLBand: HSLAdjustment], kernel: CIColorKernel)?

    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            let options: [CIContextOption: Any] = [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .cacheIntermediates: false
            ]
            previewContext = CIContext(mtlDevice: device, options: options)
            exportContext = CIContext(mtlDevice: device, options: options)
        } else {
            let options: [CIContextOption: Any] = [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .cacheIntermediates: false
            ]
            previewContext = CIContext(options: options)
            exportContext = CIContext(options: options)
        }
        precondition(previewContext !== exportContext)
    }

    var hasIsolatedPreviewAndExportContexts: Bool {
        previewContext !== exportContext
    }

    public func renderPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> RenderedPreview {
        let measured = try renderPreviewMeasured(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension
        )
        return RenderedPreview(
            image: measured.image,
            durationMilliseconds: measured.timings.totalMilliseconds
        )
    }

    public func renderPreviewMeasured(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> MeasuredRenderedPreview {
        let totalStarted = ContinuousClock.now
        let frame = try preparePreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension
        )

        let materialized = try materializePreview(frame)
        let timings = RenderPhaseTimings(
            graphAndKernelSetupMilliseconds: frame.graphAndKernelSetupMilliseconds,
            materializeAndReadbackMilliseconds: materialized.durationMilliseconds,
            totalMilliseconds: Self.milliseconds(totalStarted.duration(to: .now))
        )
        return MeasuredRenderedPreview(image: materialized.image, timings: timings)
    }

    /// Builds the exact preview graph used by both presentation routes. This
    /// general API remains available to benchmark/calibration paths that
    /// intentionally exercise an interactive decode candidate.
    public func preparePreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> PreparedPreviewFrame {
        guard maxDimension.isFinite, maxDimension > 0 else {
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        os_signpost(.begin, log: Self.performanceLog, name: "PreviewGraph")
        let graphStarted = ContinuousClock.now
        let output = try makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        let image = output.image
        let extent = output.extent
        let graphMilliseconds = Self.milliseconds(graphStarted.duration(to: .now))
        os_signpost(.end, log: Self.performanceLog, name: "PreviewGraph")

        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0
        else {
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        return PreparedPreviewFrame(
            image: image,
            extent: extent,
            sourceURL: decoded.sourceURL,
            graphAndKernelSetupMilliseconds: graphMilliseconds,
            maxDimension: maxDimension
        )
    }

    /// Fail-closed entry point for the production UI. Preview-scale RAW
    /// candidates remain calibration-only until a candidate passes the formal
    /// parity gate.
    public func prepareProductionPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> PreparedPreviewFrame {
        guard decoded.info.intent == .fullResolution,
              decoded.info.requestedMaximumDimension == nil,
              !decoded.info.isRAW || decoded.info.appliedScaleFactor == 1
        else {
            throw RenderEngineError.previewResolutionPresentationForbidden(
                decoded.sourceURL
            )
        }
        return try preparePreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension
        )
    }

    /// Existing CPU bitmap path retained as the default and one-way runtime
    /// fallback until the direct route passes visible-window acceptance gates.
    public func materializePreview(
        _ frame: PreparedPreviewFrame
    ) throws -> RenderedPreview {
        os_signpost(.begin, log: Self.performanceLog, name: "PreviewMaterialize")
        let materializeStarted = ContinuousClock.now
        guard let cgImage = previewContext.createCGImage(
            frame.image,
            from: frame.extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else {
            os_signpost(.end, log: Self.performanceLog, name: "PreviewMaterialize")
            throw RenderEngineError.renderFailed(frame.sourceURL)
        }
        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: frame.extent.width, height: frame.extent.height)
        )
        let materializeMilliseconds = Self.milliseconds(
            materializeStarted.duration(to: .now)
        )
        os_signpost(.end, log: Self.performanceLog, name: "PreviewMaterialize")
        return RenderedPreview(
            image: nsImage,
            durationMilliseconds: materializeMilliseconds
        )
    }

    public func exportJPEG(
        decoded: DecodedPhoto,
        settings: EditSettings,
        destination: URL,
        quality: Double = 0.92,
        protectedSourceURLs: [URL] = []
    ) throws -> Double {
        try exportJPEGMeasured(
            decoded: decoded,
            settings: settings,
            destination: destination,
            quality: quality,
            protectedSourceURLs: protectedSourceURLs
        ).totalMilliseconds
    }

    public func exportJPEGMeasured(
        decoded: DecodedPhoto,
        settings: EditSettings,
        destination: URL,
        quality: Double = 0.92,
        protectedSourceURLs: [URL] = []
    ) throws -> RenderPhaseTimings {
        try Self.requireFullResolutionDecodeForExport(decoded)
        let protectedSources = [decoded.sourceURL] + protectedSourceURLs
        guard !Self.isExistingDirectory(destination) else {
            throw RenderEngineError.destinationIsDirectory(destination)
        }
        guard !Self.destinationAliasesAnySource(
            destination,
            sources: protectedSources
        ) else {
            throw RenderEngineError.sourceOverwriteForbidden(destination)
        }
        let totalStarted = ContinuousClock.now

        os_signpost(.begin, log: Self.performanceLog, name: "JPEGGraph")
        let graphStarted = ContinuousClock.now
        let output = try makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: nil,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        let image = output.image
        let graphMilliseconds = Self.milliseconds(graphStarted.duration(to: .now))
        os_signpost(.end, log: Self.performanceLog, name: "JPEGGraph")

        os_signpost(.begin, log: Self.performanceLog, name: "JPEGMaterialize")
        let materializeStarted = ContinuousClock.now
        guard let cgImage = exportContext.createCGImage(
            image,
            from: image.extent.integral,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else {
            os_signpost(.end, log: Self.performanceLog, name: "JPEGMaterialize")
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        let materializeMilliseconds = Self.milliseconds(
            materializeStarted.duration(to: .now)
        )
        os_signpost(.end, log: Self.performanceLog, name: "JPEGMaterialize")

        os_signpost(.begin, log: Self.performanceLog, name: "JPEGEncode")
        let encodeStarted = ContinuousClock.now
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            guard let imageDestination = CGImageDestinationCreateWithURL(
                temporary as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            var properties = Self.safeJPEGMetadata(
                from: decoded.metadata,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height
            )
            properties[kCGImageDestinationLossyCompressionQuality as String] = min(max(quality, 0), 1)
            properties[kCGImagePropertyOrientation as String] = 1
            properties[kCGImageDestinationEmbedThumbnail as String] = true
            CGImageDestinationAddImage(imageDestination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(imageDestination) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            os_signpost(.end, log: Self.performanceLog, name: "JPEGEncode")
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let encodeMilliseconds = Self.milliseconds(encodeStarted.duration(to: .now))
        os_signpost(.end, log: Self.performanceLog, name: "JPEGEncode")

        os_signpost(.begin, log: Self.performanceLog, name: "JPEGInstall")
        let installStarted = ContinuousClock.now
        do {
            try Self.installAtomically(
                temporary: temporary,
                destination: destination,
                protectedSources: protectedSources
            )
        } catch {
            os_signpost(.end, log: Self.performanceLog, name: "JPEGInstall")
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let installMilliseconds = Self.milliseconds(installStarted.duration(to: .now))
        os_signpost(.end, log: Self.performanceLog, name: "JPEGInstall")
        return RenderPhaseTimings(
            graphAndKernelSetupMilliseconds: graphMilliseconds,
            materializeAndReadbackMilliseconds: materializeMilliseconds,
            jpegEncodeAndWriteMilliseconds: encodeMilliseconds,
            atomicInstallMilliseconds: installMilliseconds,
            totalMilliseconds: Self.milliseconds(totalStarted.duration(to: .now))
        )
    }

    /// Lightroom基準TIFFと同じsRGBで、量子化誤差を抑えた16bit比較用TIFFを書き出す。
    /// 比較を高速化する場合だけmaxDimensionを指定し、本番書き出しではnilを使う。
    public func exportTIFF(
        decoded: DecodedPhoto,
        settings: EditSettings,
        destination: URL,
        maxDimension: CGFloat? = nil,
        downsamplingFilter: TIFFDownsamplingFilter = .affineTransform,
        outputTransformPlacement: OutputTransformPlacement = .afterDownsampling,
        protectedSourceURLs: [URL] = []
    ) throws -> Double {
        if maxDimension == nil {
            try Self.requireFullResolutionDecodeForExport(decoded)
        }
        let protectedSources = [decoded.sourceURL] + protectedSourceURLs
        guard !Self.isExistingDirectory(destination) else {
            throw RenderEngineError.destinationIsDirectory(destination)
        }
        guard !Self.destinationAliasesAnySource(
            destination,
            sources: protectedSources
        ) else {
            throw RenderEngineError.sourceOverwriteForbidden(destination)
        }
        let started = ContinuousClock.now
        let output = try makeOutputGraph(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension,
            downsamplingFilter: downsamplingFilter,
            outputTransformPlacement: outputTransformPlacement
        )
        let image = output.image

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            try exportContext.writeTIFFRepresentation(
                of: image,
                to: temporary,
                format: .RGBA16,
                colorSpace: outputColorSpace,
                options: [:]
            )
            try Self.installAtomically(
                temporary: temporary,
                destination: destination,
                protectedSources: protectedSources
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    /// Full-size output must never inherit an interactive decode. The app
    /// is required to reopen the protected source with `.fullResolution`.
    /// Calibration TIFFs remain allowed when an explicit comparison dimension
    /// is supplied, because those artifacts intentionally exercise both paths.
    private static func requireFullResolutionDecodeForExport(
        _ decoded: DecodedPhoto
    ) throws {
        guard decoded.info.intent == .fullResolution,
              decoded.info.requestedMaximumDimension == nil
        else {
            throw RenderEngineError.previewResolutionExportForbidden(decoded.sourceURL)
        }
        guard decoded.info.nativeWidth > 0, decoded.info.nativeHeight > 0 else {
            throw RenderEngineError.previewResolutionExportForbidden(decoded.sourceURL)
        }
        guard let imageWidth = CoreImageDecoder.validatedPixelDimension(
            decoded.image.extent.width
        ), let imageHeight = CoreImageDecoder.validatedPixelDimension(
            decoded.image.extent.height
        ) else {
            throw RenderEngineError.previewResolutionExportForbidden(decoded.sourceURL)
        }
        guard decoded.info.width == decoded.info.nativeWidth,
              decoded.info.height == decoded.info.nativeHeight,
              imageWidth == decoded.info.nativeWidth,
              imageHeight == decoded.info.nativeHeight
        else {
            throw RenderEngineError.previewResolutionExportForbidden(decoded.sourceURL)
        }
        if decoded.info.isRAW, decoded.info.appliedScaleFactor != 1 {
            throw RenderEngineError.previewResolutionExportForbidden(decoded.sourceURL)
        }
    }

    static func installAtomically(
        temporary: URL,
        destination: URL,
        protectedSources: [URL]
    ) throws {
        // Re-check immediately before replacement as well. The early public API
        // guard avoids needless rendering, while this prevents a destination
        // file or parent-directory alias introduced during a long render from
        // redirecting the final install onto a protected original.
        guard !isExistingDirectory(destination) else {
            throw RenderEngineError.destinationIsDirectory(destination)
        }
        guard !destinationAliasesAnySource(destination, sources: protectedSources) else {
            throw RenderEngineError.sourceOverwriteForbidden(destination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Rejects path aliases before any temporary output is created. A textual
    /// URL comparison is insufficient on the default case-insensitive APFS and
    /// also misses symlinks and hard links to the original.
    static func destinationAliasesSource(_ destination: URL, source: URL) -> Bool {
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        if resolvedSource.path.compare(
            resolvedDestination.path,
            options: [.caseInsensitive, .literal]
        ) == .orderedSame {
            return true
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: resolvedSource.path),
              fileManager.fileExists(atPath: resolvedDestination.path),
              let sourceIdentifier = try? resolvedSource.resourceValues(
                  forKeys: [.fileResourceIdentifierKey]
              ).fileResourceIdentifier as? NSObject,
              let destinationIdentifier = try? resolvedDestination.resourceValues(
                  forKeys: [.fileResourceIdentifierKey]
              ).fileResourceIdentifier as? NSObject
        else {
            return false
        }
        return sourceIdentifier.isEqual(destinationIdentifier)
    }

    static func destinationAliasesAnySource(_ destination: URL, sources: [URL]) -> Bool {
        sources.contains { destinationAliasesSource(destination, source: $0) }
    }

    private static func safeJPEGMetadata(
        from source: [String: Any],
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [String: Any] {
        var result: [String: Any] = [:]

        var exif = source[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = pixelWidth
        exif[kCGImagePropertyExifPixelYDimension as String] = pixelHeight
        exif[kCGImagePropertyExifColorSpace as String] = 1 // sRGB
        result[kCGImagePropertyExifDictionary as String] = exif
        if let exifAux = source[kCGImagePropertyExifAuxDictionary as String] {
            result[kCGImagePropertyExifAuxDictionary as String] = exifAux
        }
        if let gps = source[kCGImagePropertyGPSDictionary as String] {
            result[kCGImagePropertyGPSDictionary as String] = gps
        }

        if let sourceTIFF = source[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            let allowedKeys = [
                kCGImagePropertyTIFFMake as String,
                kCGImagePropertyTIFFModel as String,
                kCGImagePropertyTIFFDateTime as String,
                kCGImagePropertyTIFFArtist as String,
                kCGImagePropertyTIFFSoftware as String,
                kCGImagePropertyTIFFCopyright as String
            ]
            var tiff = sourceTIFF.filter { allowedKeys.contains($0.key) }
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        } else {
            result[kCGImagePropertyTIFFDictionary as String] = [
                kCGImagePropertyTIFFOrientation as String: 1
            ]
        }

        return result
    }

    func apply(settings: EditSettings, to source: CIImage) -> CIImage {
        var image = source

        if settings.exposure != 0,
           let filter = CIFilter(name: "CIExposureAdjust", parameters: [
               kCIInputImageKey: image,
               kCIInputEVKey: settings.exposure
           ]), let output = filter.outputImage {
            image = output
        }

        if BasicToneModel.isActive(settings) {
            guard let output = BasicToneModel.kernel.apply(extent: image.extent, arguments: [
               image,
               Float(settings.contrast),
               Float(settings.highlights),
               Float(settings.shadows),
               Float(settings.whites),
               Float(settings.blacks)
            ]) else {
                preconditionFailure("Photo Benchの基本階調カーネルを画像へ適用できませんでした。")
            }
            image = output
        }

        if !settings.toneCurves.isEmpty {
            let kernel = toneCurveKernel(for: settings.toneCurves)
            guard let output = kernel.apply(extent: image.extent, arguments: [image]) else {
                preconditionFailure("Photo Benchのトーンカーブを画像へ適用できませんでした。")
            }
            image = output
        }

        if PerceptualColorMixer.isActive(settings.hsl) {
            let kernel = mixerKernel(for: settings.hsl)
            guard let output = kernel.apply(extent: image.extent, arguments: [image]) else {
                preconditionFailure("Photo Benchのカラーミキサーを画像へ適用できませんでした。")
            }
            image = output
        }

        if settings.vibrance != 0,
           let filter = CIFilter(name: "CIVibrance", parameters: [
               kCIInputImageKey: image,
               "inputAmount": settings.vibrance / 100
           ]), let output = filter.outputImage {
            image = output
        }

        if settings.saturation != 0,
           let filter = CIFilter(name: "CIColorControls", parameters: [
               kCIInputImageKey: image,
               kCIInputContrastKey: 1,
               kCIInputSaturationKey: max(0, 1 + settings.saturation / 100)
           ]), let output = filter.outputImage {
            image = output
        }

        return image
    }

    /// Kept module-internal so tests can exercise the real RAW/raster branch
    /// together with the final shoulder and gamut transform.
    func applyForOutput(decoded: DecodedPhoto, settings: EditSettings) -> CIImage {
        let working = apply(settings: settings, to: decoded.image)
        return applyOutputTransformIfRequired(
            to: working,
            info: decoded.info,
            settings: settings
        )
    }

    /// Builds the sole production output graph. Core Image remains lazy, but
    /// the dependency graph fixes the semantic order and preserves float HDR
    /// headroom without an intermediate bitmap materialization.
    func makeOutputGraph(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat?,
        downsamplingFilter: TIFFDownsamplingFilter,
        outputTransformPlacement: OutputTransformPlacement
    ) throws -> PreparedOutputGraph {
        if let maxDimension {
            guard maxDimension.isFinite, maxDimension > 0 else {
                throw RenderEngineError.renderFailed(decoded.sourceURL)
            }
        }

        var image = apply(settings: settings, to: decoded.image)
        if outputTransformPlacement == .legacyBeforeDownsampling {
            image = applyOutputTransformIfRequired(
                to: image,
                info: decoded.info,
                settings: settings
            )
        }
        image = resize(
            image,
            maxDimension: maxDimension,
            downsamplingFilter: downsamplingFilter,
            outputTransformPlacement: outputTransformPlacement
        )
        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0
        else {
            throw RenderEngineError.renderFailed(decoded.sourceURL)
        }
        image = image.cropped(to: extent)
        if outputTransformPlacement == .afterDownsampling {
            image = applyOutputTransformIfRequired(
                to: image,
                info: decoded.info,
                settings: settings
            ).cropped(to: extent)
        }
        return PreparedOutputGraph(image: image, extent: extent)
    }

    private func resize(
        _ image: CIImage,
        maxDimension: CGFloat?,
        downsamplingFilter: TIFFDownsamplingFilter,
        outputTransformPlacement: OutputTransformPlacement
    ) -> CIImage {
        guard let maxDimension else { return image }
        let longest = max(image.extent.width, image.extent.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        switch downsamplingFilter {
        case .affineTransform:
            return image.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
        case .lanczos:
            if outputTransformPlacement == .legacyBeforeDownsampling {
                // Preserve schema v1-v3 byte semantics. Historical evidence
                // sampled transparent black outside the finite image extent.
                return image.applyingFilter(
                    "CILanczosScaleTransform",
                    parameters: [
                        kCIInputScaleKey: scale,
                        kCIInputAspectRatioKey: 1
                    ]
                )
            }
            // Lanczos reads beyond the finite image extent. Extend the edge
            // pixels before filtering so an opaque photo is not mixed with
            // transparent black at its boundary, then restore the exact
            // finite scaled extent for the remainder of the graph.
            let scaledExtent = image.extent.applying(
                CGAffineTransform(scaleX: scale, y: scale)
            ).integral
            return image.clampedToExtent().applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1
                ]
            ).cropped(to: scaledExtent)
        }
    }

    private func applyOutputTransformIfRequired(
        to image: CIImage,
        info: DecodeInfo,
        settings: EditSettings
    ) -> CIImage {
        Self.requiresOutputTransform(info: info, settings: settings)
            ? SRGBOutputTransform.apply(to: image)
            : image
    }

    /// Separates the branch contract from rendering so the RAW disjunct can be
    /// tested independently of the decoder invariant that RAW is unbounded.
    static func requiresOutputTransform(info: DecodeInfo, settings: EditSettings) -> Bool {
        info.isRAW
            || !info.isBoundedSRGBRaster
            || settings.hasActiveColorEdits()
    }

    private func toneCurveKernel(for curves: [ToneCurve]) -> CIColorKernel {
        kernelCacheLock.lock()
        let cached = cachedCurveKernel
        kernelCacheLock.unlock()
        if cached?.key == curves { return cached!.kernel }

        guard let kernel = ToneCurveModel.makeKernel(curves: curves) else {
            preconditionFailure("Photo Benchのトーンカーブカーネルをコンパイルできませんでした。")
        }
        kernelCacheLock.lock()
        cachedCurveKernel = (curves, kernel)
        kernelCacheLock.unlock()
        return kernel
    }

    private func mixerKernel(for hsl: [HSLBand: HSLAdjustment]) -> CIColorKernel {
        kernelCacheLock.lock()
        let cached = cachedMixerKernel
        kernelCacheLock.unlock()
        if cached?.key == hsl { return cached!.kernel }

        guard let kernel = PerceptualColorMixer.makeKernel(adjustments: hsl) else {
            preconditionFailure("Photo Benchのカラーミキサーカーネルをコンパイルできませんでした。")
        }
        kernelCacheLock.lock()
        cachedMixerKernel = (hsl, kernel)
        kernelCacheLock.unlock()
        return kernel
    }
}

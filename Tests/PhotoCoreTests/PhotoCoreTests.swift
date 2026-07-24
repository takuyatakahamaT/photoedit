import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
@testable import PhotoCore

struct PhotoCoreTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func scansJPEGAndLumixRAWWithoutGeneratedFolders() throws {
        let assets = try PhotoLibrary.scan(root: projectRoot)
        #expect(assets.contains { $0.filename == "P1524180.RW2" && $0.kind == .raw })
        #expect(assets.contains { $0.filename == "DSC02072.JPG" && $0.kind == .jpeg })
        #expect(!assets.contains { $0.url.path.contains("/exports/") })
    }

    @Test func parsesTheReferenceXMP() throws {
        let preset = try XMPPresetParser.parse(url: projectRoot.appendingPathComponent("niho-priset_colorful.xmp"))
        #expect(preset.name == "niho-priset_colorful")
        #expect(preset.processVersion == "11.0")
        #expect(preset.cameraRawVersion == "17.0")
        #expect(preset.settings.exposure == 0.56)
        #expect(preset.settings.contrast == -37)
        #expect(preset.settings.toneCurves.count == 4)
        #expect(preset.settings.hsl[.orange]?.saturation == -13)
        #expect(preset.compatibility.contains { $0.property == "LensProfileEnable" && $0.level == .unsupported })
        #expect(preset.rawProperties["Copyright"] == "")
        #expect(preset.rawProperties["Amount"] == nil)
        #expect(preset.rawProperties["Whites2012"] == "-53")
        #expect(preset.compatibility.contains {
            $0.property == "Look.Name"
                && $0.value == "Adobe Color"
                && $0.level == .unsupported
        })
    }

    @Test func decodesFullResolutionLumixRAWWhenFixtureExists() throws {
        let url = projectRoot.appendingPathComponent("P1524180.RW2")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let decoded = try CoreImageDecoder().decode(url: url)
        #expect(decoded.info.isRAW)
        #expect(decoded.info.backend == "Core Image RAW 8")
        #expect(decoded.info.width == 6_000)
        #expect(decoded.info.height == 4_000)
        #expect(decoded.info.nativeWidth == 6_000)
        #expect(decoded.info.nativeHeight == 4_000)
        #expect(decoded.info.intent == .fullResolution)
        #expect(decoded.info.requestedMaximumDimension == nil)
        #expect(decoded.info.appliedScaleFactor == 1)
        #expect(decoded.info.cameraModel == "DC-S5")
        #expect(decoded.info.calibrationID == RAWCalibrationProfile.panasonicDCS5Lightroom93.id)
        #expect(!decoded.info.isBoundedSRGBRaster)
    }

    @Test func decodesInteractiveLumixRAWAtTheRequestedPreviewDimension() throws {
        let url = projectRoot.appendingPathComponent("P1524180.RW2")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let decoded = try CoreImageDecoder().decode(
            url: url,
            intent: .interactivePreview(maxDimension: 2_560)
        )

        #expect(decoded.info.isRAW)
        #expect(decoded.info.intent == .interactivePreview(maxDimension: 2_560))
        #expect(decoded.info.requestedMaximumDimension == 2_560)
        #expect(decoded.info.nativeWidth == 6_000)
        #expect(decoded.info.nativeHeight == 4_000)
        #expect(decoded.info.width == 2_560)
        #expect(decoded.info.height == 1_707)
        let scale = try #require(decoded.info.appliedScaleFactor)
        #expect(abs(scale - Float(2_560.0 / 6_000.0)) < 0.000_001)
    }

    @Test func rejectsNonPositiveInteractivePreviewDimensions() throws {
        let url = projectRoot.appendingPathComponent("P1524180.RW2")
        for invalidDimension in [0, -1] {
            do {
                _ = try CoreImageDecoder().decode(
                    url: url,
                    intent: .interactivePreview(maxDimension: invalidDimension)
                )
                Issue.record("無効なプレビュー寸法 \(invalidDimension) を受理しました。")
            } catch let error as ImageDecoderError {
                guard case let .invalidPreviewMaximumDimension(value) = error else {
                    Issue.record("想定外のImageDecoderErrorです: \(error)")
                    continue
                }
                #expect(value == invalidDimension)
            }
        }
    }

    @Test func rejectsInvalidFrameworkPixelDimensionsBeforeIntegerConversion() {
        #expect(CoreImageDecoder.validatedPixelDimension(6_000) == 6_000)
        #expect(CoreImageDecoder.validatedPixelDimension(0) == nil)
        #expect(CoreImageDecoder.validatedPixelDimension(-1) == nil)
        #expect(CoreImageDecoder.validatedPixelDimension(.nan) == nil)
        #expect(CoreImageDecoder.validatedPixelDimension(.infinity) == nil)
    }

    @Test func rasterPreviewIntentKeepsTheExistingImageIODecodePath() throws {
        let url = projectRoot.appendingPathComponent("DSC02072.JPG")
        let full = try CoreImageDecoder().decode(url: url)
        let preview = try CoreImageDecoder().decode(
            url: url,
            intent: .interactivePreview(maxDimension: 320)
        )

        #expect(preview.info.backend == "ImageIO")
        #expect(preview.info.width == full.info.width)
        #expect(preview.info.height == full.info.height)
        #expect(preview.info.nativeWidth == full.info.nativeWidth)
        #expect(preview.info.nativeHeight == full.info.nativeHeight)
        #expect(preview.info.intent == .interactivePreview(maxDimension: 320))
        #expect(preview.info.appliedScaleFactor == nil)
    }

    @Test func fullSizeExportGuardAlsoCoversFutureRasterThumbnailDecodes() throws {
        let sourceURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        let preview = try CoreImageDecoder().decode(
            url: sourceURL,
            intent: .interactivePreview(maxDimension: 320)
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchRasterPreviewGuard-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            _ = try RenderEngine().exportJPEG(
                decoded: preview,
                settings: .neutral,
                destination: destination
            )
            Issue.record("interactive raster decodeから原寸書き出しが成功しました。")
        } catch let error as RenderEngineError {
            guard case let .previewResolutionExportForbidden(rejectedSource) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejectedSource == sourceURL)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func refusesFullSizeExportsFromInteractiveRAWDecodes() throws {
        let sourceURL = projectRoot.appendingPathComponent("P1524180.RW2")
        let decoded = try CoreImageDecoder().decode(
            url: sourceURL,
            intent: .interactivePreview(maxDimension: 320)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchPreviewExportGuard-\(UUID().uuidString)")
        let jpegURL = directory.appendingPathComponent("forbidden.jpg")
        let tiffURL = directory.appendingPathComponent("forbidden.tif")
        defer { try? FileManager.default.removeItem(at: directory) }

        for operation in [
            { try RenderEngine().exportJPEG(
                decoded: decoded,
                settings: .neutral,
                destination: jpegURL
            ) },
            { try RenderEngine().exportTIFF(
                decoded: decoded,
                settings: .neutral,
                destination: tiffURL
            ) }
        ] {
            do {
                _ = try operation()
                Issue.record("縮小RAWから原寸書き出しが成功しました。")
            } catch let error as RenderEngineError {
                guard case let .previewResolutionExportForbidden(rejectedSource) = error else {
                    Issue.record("想定外のRenderEngineErrorです: \(error)")
                    continue
                }
                #expect(rejectedSource == sourceURL)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: jpegURL.path))
        #expect(!FileManager.default.fileExists(atPath: tiffURL.path))
    }

    @Test func fullSizeExportRejectsForgedFullIntentWithPreviewDimensions() throws {
        let sourceURL = URL(fileURLWithPath: "/virtual/forged-preview.rw2")
        let previewExtent = CGRect(x: 0, y: 0, width: 2_560, height: 1_707)
        let forged = DecodedPhoto(
            sourceURL: sourceURL,
            image: CIImage(color: .gray).cropped(to: previewExtent),
            metadata: [:],
            info: DecodeInfo(
                backend: "test",
                width: 2_560,
                height: 1_707,
                durationMilliseconds: 0,
                isRAW: true,
                intent: .fullResolution,
                nativeWidth: 6_000,
                nativeHeight: 4_000,
                appliedScaleFactor: 1
            )
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchForgedFullGuard-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            _ = try RenderEngine().exportJPEG(
                decoded: forged,
                settings: .neutral,
                destination: destination
            )
            Issue.record("原寸intentを偽装した縮小画像から書き出しが成功しました。")
        } catch let error as RenderEngineError {
            guard case let .previewResolutionExportForbidden(rejectedSource) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejectedSource == sourceURL)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func fullSizeExportRejectsUnknownNativeDimensions() throws {
        let sourceURL = URL(fileURLWithPath: "/virtual/unknown-native-dimensions.rw2")
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let forged = DecodedPhoto(
            sourceURL: sourceURL,
            image: CIImage(color: .gray).cropped(to: extent),
            metadata: [:],
            info: DecodeInfo(
                backend: "test",
                width: 64,
                height: 64,
                durationMilliseconds: 0,
                isRAW: true,
                intent: .fullResolution,
                nativeWidth: 0,
                nativeHeight: 0,
                appliedScaleFactor: 1
            )
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchUnknownNativeGuard-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            _ = try RenderEngine().exportJPEG(
                decoded: forged,
                settings: .neutral,
                destination: destination
            )
            Issue.record("原寸サイズ不明の画像から原寸書き出しが成功しました。")
        } catch let error as RenderEngineError {
            guard case let .previewResolutionExportForbidden(rejectedSource) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejectedSource == sourceURL)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func fullSizeExportRejectsNonFiniteImageExtentBeforeIntegerConversion() throws {
        let sourceURL = URL(fileURLWithPath: "/virtual/non-finite-extent.rw2")
        let forged = DecodedPhoto(
            sourceURL: sourceURL,
            image: CIImage(color: .gray),
            metadata: [:],
            info: DecodeInfo(
                backend: "test",
                width: 6_000,
                height: 4_000,
                durationMilliseconds: 0,
                isRAW: true,
                intent: .fullResolution,
                nativeWidth: 6_000,
                nativeHeight: 4_000,
                appliedScaleFactor: 1
            )
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchNonFiniteExtentGuard-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            _ = try RenderEngine().exportJPEG(
                decoded: forged,
                settings: .neutral,
                destination: destination
            )
            Issue.record("非有限extentの画像から原寸書き出しが成功しました。")
        } catch let error as RenderEngineError {
            guard case let .previewResolutionExportForbidden(rejectedSource) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejectedSource == sourceURL)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func renderEngineIsolatesPreviewAndExportContexts() {
        #expect(RenderEngine().hasIsolatedPreviewAndExportContexts)
    }

    @Test func rawDecoderPreservesLuminanceHeadroomBeforeTheSDROutputTransform() throws {
        let url = projectRoot.appendingPathComponent("P1524180.RW2")
        let decoded = try CoreImageDecoder().decode(url: url)
        let scale = 600 / max(decoded.image.extent.width, decoded.image.extent.height)
        let sampled = decoded.image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        ).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let pixelCount = 600 * 400
        var pixels = [SIMD4<Float>](repeating: .zero, count: pixelCount)
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: true
        ])
        context.render(
            sampled,
            toBitmap: &pixels,
            rowBytes: 600 * MemoryLayout<SIMD4<Float>>.stride,
            bounds: sampled.extent,
            format: .RGBAf,
            colorSpace: colorSpace
        )
        let luminances = pixels.map {
            0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z
        }
        let maximumLuminance = luminances.max() ?? 0
        let extendedLuminancePixelCount = luminances.count { $0 > 1.000_1 }
        #expect(maximumLuminance > 1.1)
        #expect(extendedLuminancePixelCount > 0)
    }

    @Test func parsesEveryBundledXMPPreset() throws {
        let names = [
            "niho-priset_colorful.xmp",
            "niho-preset bluesky2.xmp",
            "niho-preset night.xmp",
            "niho-preset pastel.xmp"
        ]
        for name in names {
            let preset = try XMPPresetParser.parse(url: projectRoot.appendingPathComponent(name))
            #expect(preset.processVersion == "11.0")
            #expect(preset.cameraRawVersion == "17.0")
            #expect(!preset.compatibility.isEmpty)
        }
    }

    @Test func exportsSixteenBitSRGBTiffForCalibration() throws {
        let sourceURL = projectRoot.appendingPathComponent("P1524180.RW2")
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchTIFFTests-\(UUID().uuidString)", isDirectory: true)
        let outputURL = outputDirectory.appendingPathComponent("calibration.tif")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let decoded = try CoreImageDecoder().decode(url: sourceURL)
        _ = try RenderEngine().exportTIFF(
            decoded: decoded,
            settings: .neutral,
            destination: outputURL,
            maxDimension: 300
        )

        let source = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 300)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 200)
        #expect(properties[kCGImagePropertyDepth as String] as? Int == 16)
        #expect(properties[kCGImagePropertyProfileName as String] as? String == "sRGB IEC61966-2.1")
    }

    @Test func rendersJPEGWithoutChangingTheSource() throws {
        let url = projectRoot.appendingPathComponent("DSC02072.JPG")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let before = try Data(contentsOf: url)
        let decoded = try CoreImageDecoder().decode(url: url)
        let preview = try RenderEngine().renderPreview(
            decoded: decoded,
            settings: EditSettings(exposure: 0.25, contrast: 10),
            maxDimension: 640
        )
        #expect(preview.image.size.width > 0)
        let after = try Data(contentsOf: url)
        #expect(before == after)
    }

    @Test func measuredRenderAPIsExposeProductionPhaseTimings() throws {
        let sourceURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        try #require(FileManager.default.fileExists(atPath: sourceURL.path))
        let decoded = try CoreImageDecoder().decode(url: sourceURL)
        let renderer = RenderEngine()

        let preview = try renderer.renderPreviewMeasured(
            decoded: decoded,
            settings: EditSettings(exposure: 0.1, contrast: 5),
            maxDimension: 320
        )
        #expect(preview.image.size.width > 0)
        #expect(preview.timings.graphAndKernelSetupMilliseconds >= 0)
        #expect(preview.timings.materializeAndReadbackMilliseconds >= 0)
        #expect(preview.timings.jpegEncodeAndWriteMilliseconds == nil)
        #expect(preview.timings.atomicInstallMilliseconds == nil)
        #expect(preview.timings.totalMilliseconds >= preview.timings.materializeAndReadbackMilliseconds)

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchMeasuredRenderTests-\(UUID().uuidString)")
        let destination = outputDirectory.appendingPathComponent("measured.jpg")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let export = try renderer.exportJPEGMeasured(
            decoded: decoded,
            settings: .neutral,
            destination: destination,
            quality: 0.92
        )
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(export.graphAndKernelSetupMilliseconds >= 0)
        #expect(export.materializeAndReadbackMilliseconds >= 0)
        #expect((export.jpegEncodeAndWriteMilliseconds ?? -1) >= 0)
        #expect((export.atomicInstallMilliseconds ?? -1) >= 0)
        #expect(export.totalMilliseconds >= export.materializeAndReadbackMilliseconds)
    }

    @Test func productionPreviewRequiresAFullResolutionDecode() throws {
        let sourceURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        let previewDecode = try CoreImageDecoder().decode(
            url: sourceURL,
            intent: .interactivePreview(maxDimension: 320)
        )
        let renderer = RenderEngine()

        do {
            _ = try renderer.prepareProductionPreview(
                decoded: previewDecode,
                settings: .neutral,
                maxDimension: 320
            )
            Issue.record("縮小decode intentがproduction previewへ接続されました。")
        } catch let error as RenderEngineError {
            guard case let .previewResolutionPresentationForbidden(rejected) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejected == sourceURL)
        }

        let fullDecode = try CoreImageDecoder().decode(url: sourceURL)
        let frame = try renderer.prepareProductionPreview(
            decoded: fullDecode,
            settings: .neutral,
            maxDimension: 320
        )
        #expect(max(frame.extent.width, frame.extent.height) <= 320)
        #expect(frame.graphAndKernelSetupMilliseconds >= 0)
    }

    @Test func previewAspectFitGeometryRejectsInvalidSizesAndCentersPixels() throws {
        let geometry = try #require(
            PreviewAspectFitGeometry.fitting(
                source: CGRect(x: 10, y: 20, width: 4, height: 2),
                destinationSize: CGSize(width: 10, height: 10)
            )
        )
        #expect(geometry.scale == 2.5)
        #expect(geometry.origin == CGPoint(x: 0, y: 2.5))
        #expect(geometry.destinationSize == CGSize(width: 10, height: 10))
        #expect(PreviewAspectFitGeometry.fitting(
            source: .zero,
            destinationSize: CGSize(width: 10, height: 10)
        ) == nil)
        #expect(PreviewAspectFitGeometry.fitting(
            source: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1),
            destinationSize: CGSize(width: 10, height: 10)
        ) == nil)
        #expect(PreviewAspectFitGeometry.fitting(
            source: CGRect(x: 0, y: 0, width: 1, height: 1),
            destinationSize: CGSize(width: 0, height: 10)
        ) == nil)
    }

    @Test func latestPreviewQueueKeepsOneInFlightAndOnlyTheNewestPending() {
        var queue = LatestPreviewQueueState()
        #expect(queue.submit(1) == nil)
        // A stale view update cannot claim a different revision or mutate the
        // mailbox before the expected request is available.
        let claimedWrongPending = queue.beginPending(2)
        #expect(!claimedWrongPending)
        #expect(queue.pendingID == 1)
        #expect(queue.inFlightID == nil)
        let claimedFirst = queue.beginPending(1)
        #expect(claimedFirst)
        #expect(queue.inFlightID == 1)
        #expect(queue.submit(2) == nil)
        #expect(queue.submit(3) == 2)
        #expect(queue.pendingID == 3)
        let claimedWhileBusy = queue.beginPending(3)
        #expect(!claimedWhileBusy)
        let finishedWrongID = queue.finish(2)
        #expect(!finishedWrongID)
        #expect(queue.inFlightID == 1)
        #expect(queue.pendingID == 3)
        let finishedFirst = queue.finish(1)
        #expect(finishedFirst)
        let claimedLatest = queue.beginPending(3)
        #expect(claimedLatest)
        let finishedLatest = queue.finish(3)
        #expect(finishedLatest)
        #expect(queue.inFlightID == nil)
        #expect(queue.pendingID == nil)

        // Stale SwiftUI updates cannot move the queue backwards.
        #expect(queue.submit(2) == nil)
        #expect(queue.latestID == 3)
        queue.resubmitLatest()
        let claimedResubmission = queue.beginPending(3)
        #expect(claimedResubmission)
    }

    @Test func latestPreviewQueueCoalescesResizeAndReentrantSubmissions() {
        var queue = LatestPreviewQueueState()
        #expect(queue.submit(10) == nil)
        let claimedInitial = queue.beginPending(10)
        #expect(claimedInitial)

        // A resize can request the same latest revision once, while a newer
        // edit still replaces that pending resize rather than adding work.
        queue.resubmitLatest()
        #expect(queue.pendingID == 10)
        #expect(queue.submit(11) == 10)
        #expect(queue.submit(12) == 11)
        #expect(queue.pendingID == 12)

        // Duplicate and out-of-order SwiftUI updates never move the mailbox
        // backwards or disturb the current in-flight revision.
        #expect(queue.submit(12) == nil)
        #expect(queue.submit(9) == nil)
        #expect(queue.inFlightID == 10)
        #expect(queue.pendingID == 12)
        #expect(queue.latestID == 12)

        let finishedInitial = queue.finish(10)
        #expect(finishedInitial)
        let claimedNewest = queue.beginPending(12)
        #expect(claimedNewest)
        let finishedNewest = queue.finish(12)
        #expect(finishedNewest)
        #expect(queue.pendingID == nil)
        #expect(queue.inFlightID == nil)
    }

    @Test func directMetalPreviewPreservesChannelsOrientationAndOpaqueLetterbox() throws {
        guard let renderer = MetalPreviewRenderer() else {
            Issue.record("このMacでMetal preview rendererを作成できません。")
            return
        }
        let sourceExtent = CGRect(x: 7, y: 11, width: 2, height: 2)
        let clear = CIImage(color: .clear).cropped(to: sourceExtent)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 7, y: 11, width: 1, height: 1))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 8, y: 11, width: 1, height: 1))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 7, y: 12, width: 1, height: 1))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 8, y: 12, width: 1, height: 1))
        let source = white.composited(
            over: blue.composited(over: green.composited(over: red.composited(over: clear)))
        )
        let frame = PreparedPreviewFrame(
            image: source,
            extent: sourceExtent,
            sourceURL: URL(fileURLWithPath: "/synthetic/asymmetric.png"),
            graphAndKernelSetupMilliseconds: 0,
            maxDimension: 2
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalPreviewRenderer.pixelFormat,
            width: 8,
            height: 12,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try renderer.makeCommandBuffer()
        _ = try renderer.encodeAspectFit(
            frame: frame,
            to: texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var bytes = [UInt8](repeating: 0, count: 8 * 12 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: 8 * 4,
                from: MTLRegionMake2D(0, 0, 8, 12),
                mipmapLevel: 0
            )
        }
        func rgba(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let offset = (y * 8 + x) * 4
            return (bytes[offset + 2], bytes[offset + 1], bytes[offset], bytes[offset + 3])
        }
        #expect(rgba(x: 2, y: 0) == (0, 0, 0, 255))
        #expect(rgba(x: 5, y: 11) == (0, 0, 0, 255))
        let bottomLeft = rgba(x: 1, y: 3)
        let bottomRight = rgba(x: 6, y: 3)
        let topLeft = rgba(x: 1, y: 8)
        let topRight = rgba(x: 6, y: 8)
        #expect(bottomLeft.0 > 180 && bottomLeft.1 < 5 && bottomLeft.2 < 5)
        #expect(bottomRight.1 > 180 && bottomRight.0 < 5 && bottomRight.2 < 5)
        #expect(topLeft.2 > 180 && topLeft.0 < 5 && topLeft.1 < 5)
        #expect(topRight.0 > 180 && topRight.1 > 180 && topRight.2 > 180)
        #expect([bottomLeft.3, bottomRight.3, topLeft.3, topRight.3].allSatisfy { $0 == 255 })
    }

    @Test func directMetalNativeExtentMatchesLegacyBitmapWithinOneLSB() throws {
        guard let metalRenderer = MetalPreviewRenderer() else {
            Issue.record("このMacでMetal preview rendererを作成できません。")
            return
        }
        let sourceURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        let decoded = try CoreImageDecoder().decode(url: sourceURL)
        let renderEngine = RenderEngine()
        let frame = try renderEngine.prepareProductionPreview(
            decoded: decoded,
            settings: EditSettings(exposure: 0.15, contrast: 7),
            maxDimension: 128
        )
        let width = Int(frame.extent.width)
        let height = Int(frame.extent.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalPreviewRenderer.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(metalRenderer.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try metalRenderer.makeCommandBuffer()
        _ = try metalRenderer.encodeAspectFit(
            frame: frame,
            to: texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        var direct = [UInt8](repeating: 0, count: width * height * 4)
        direct.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        let fallback = try renderEngine.materializePreview(frame).image
        var proposedRect = CGRect(x: 0, y: 0, width: width, height: height)
        let legacyCGImage = try #require(
            fallback.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )
        let legacyTexture = try #require(
            metalRenderer.device.makeTexture(descriptor: descriptor)
        )
        let legacyFrame = PreparedPreviewFrame(
            image: CIImage(cgImage: legacyCGImage),
            extent: CGRect(x: 0, y: 0, width: width, height: height),
            sourceURL: sourceURL,
            graphAndKernelSetupMilliseconds: 0,
            maxDimension: 128
        )
        let legacyCommandBuffer = try metalRenderer.makeCommandBuffer()
        _ = try metalRenderer.encodeAspectFit(
            frame: legacyFrame,
            to: legacyTexture,
            commandBuffer: legacyCommandBuffer
        )
        legacyCommandBuffer.commit()
        legacyCommandBuffer.waitUntilCompleted()
        #expect(legacyCommandBuffer.status == .completed)
        var legacy = [UInt8](repeating: 0, count: width * height * 4)
        legacy.withUnsafeMutableBytes { buffer in
            legacyTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        let maxChannelDifference = zip(direct, legacy).reduce(0) { current, pair in
            max(current, abs(Int(pair.0) - Int(pair.1)))
        }
        let flippedDifference = (0..<height).reduce(0) { current, y in
            (0..<(width * 4)).reduce(current) { rowCurrent, byteOffset in
                let directIndex = y * width * 4 + byteOffset
                let legacyIndex = (height - 1 - y) * width * 4 + byteOffset
                return max(rowCurrent, abs(Int(direct[directIndex]) - Int(legacy[legacyIndex])))
            }
        }
        #expect(maxChannelDifference <= 1)
        #expect(flippedDifference > 1)
    }

    @Test func refusesToOverwriteTheOriginalWithAnExplicitError() throws {
        let url = projectRoot.appendingPathComponent("DSC02072.JPG")
        let decoded = try CoreImageDecoder().decode(url: url)

        do {
            _ = try RenderEngine().exportJPEG(
                decoded: decoded,
                settings: .neutral,
                destination: url
            )
            Issue.record("原本と同じURLへの書き出しが成功してしまいました。")
        } catch let error as RenderEngineError {
            switch error {
            case let .sourceOverwriteForbidden(destination):
                #expect(destination.standardizedFileURL == url.standardizedFileURL)
                #expect(error.localizedDescription.contains("原本は上書きできません"))
            case .destinationIsDirectory:
                Issue.record("原本保護ではなく保存先フォルダのエラーとして報告されました。")
            case .renderFailed:
                Issue.record("原本保護ではなくレンダー失敗として報告されました。")
            case .previewResolutionExportForbidden:
                Issue.record("原本保護ではなくプレビュー解像度のエラーとして報告されました。")
            case .previewResolutionPresentationForbidden:
                Issue.record("原本保護ではなく本番表示解像度のエラーとして報告されました。")
            }
        } catch {
            Issue.record("専用エラーではありません: \(error)")
        }
    }

    @Test func reportsPreviewRenderFailuresAndRejectsUnknownExportDimensions() throws {
        let sourceURL = URL(fileURLWithPath: "/virtual/unrenderable.jpg")
        let decoded = DecodedPhoto(
            sourceURL: sourceURL,
            image: CIImage.empty(),
            metadata: [:],
            info: DecodeInfo(
                backend: "test",
                width: 0,
                height: 0,
                durationMilliseconds: 0,
                isRAW: false
            )
        )
        let renderer = RenderEngine()

        do {
            _ = try renderer.renderPreview(decoded: decoded, settings: .neutral)
            Issue.record("空画像のプレビューが成功してしまいました。")
        } catch let error as RenderEngineError {
            guard case let .renderFailed(rejectedSource) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejectedSource == sourceURL)
            #expect(error.localizedDescription.contains("画像をレンダーできません"))
        } catch {
            Issue.record("専用エラーではありません: \(error)")
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBench-unrenderable-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            _ = try renderer.exportJPEG(
                decoded: decoded,
                settings: .neutral,
                destination: destination
            )
            Issue.record("空画像のJPEG書き出しが成功してしまいました。")
        } catch let error as RenderEngineError {
            guard case let .previewResolutionExportForbidden(rejectedSource) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejectedSource == sourceURL)
        } catch {
            Issue.record("専用エラーではありません: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func removesTemporaryJPEGWhenAtomicInstallationFails() throws {
        let sourceURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchJPEGCleanupTests-\(UUID().uuidString)", isDirectory: true)
        var destination = directory.appendingPathComponent("blocked-output.jpg")
        defer {
            var mutableValues = URLResourceValues()
            mutableValues.isUserImmutable = false
            try? destination.setResourceValues(mutableValues)
            try? FileManager.default.removeItem(at: directory)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalDestinationData = Data("immutable existing output".utf8)
        try originalDestinationData.write(to: destination)
        var immutableValues = URLResourceValues()
        immutableValues.isUserImmutable = true
        try destination.setResourceValues(immutableValues)
        let decoded = try CoreImageDecoder().decode(url: sourceURL)

        do {
            _ = try RenderEngine().exportJPEG(
                decoded: decoded,
                settings: .neutral,
                destination: destination
            )
            Issue.record("不変ファイルをJPEGで置換できてしまい、設置失敗を再現できませんでした。")
        } catch {
            // The installation error is expected; this test verifies cleanup.
        }

        let remainingTemporaryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".")
                && $0.lastPathComponent.hasSuffix("-\(destination.lastPathComponent)")
        }
        #expect(remainingTemporaryFiles.isEmpty)
        #expect(try Data(contentsOf: destination) == originalDestinationData)
    }

    @Test func refusesJPEGAndTIFFExportToExistingNonEmptyDirectories() throws {
        let sourceURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchDirectoryDestinationTests-\(UUID().uuidString)", isDirectory: true)
        let jpegDestination = root.appendingPathComponent("output.jpg", isDirectory: true)
        let tiffDestination = root.appendingPathComponent("output.tif", isDirectory: true)
        let sentinelData = Data("directory contents must survive".utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        for destination in [jpegDestination, tiffDestination] {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try sentinelData.write(to: destination.appendingPathComponent("sentinel.txt"))
        }
        let decoded = try CoreImageDecoder().decode(url: sourceURL)
        let renderer = RenderEngine()

        for (destination, format) in [(jpegDestination, "jpeg"), (tiffDestination, "tiff")] {
            do {
                if format == "jpeg" {
                    _ = try renderer.exportJPEG(
                        decoded: decoded,
                        settings: .neutral,
                        destination: destination
                    )
                } else {
                    _ = try renderer.exportTIFF(
                        decoded: decoded,
                        settings: .neutral,
                        destination: destination,
                        maxDimension: 100
                    )
                }
                Issue.record("既存フォルダへの\(format.uppercased())書き出しが成功してしまいました。")
            } catch let error as RenderEngineError {
                guard case let .destinationIsDirectory(rejectedDestination) = error else {
                    Issue.record("想定外のRenderEngineErrorです: \(error)")
                    continue
                }
                #expect(rejectedDestination == destination)
                #expect(error.localizedDescription.contains("フォルダ自体には書き出せません"))
            } catch {
                Issue.record("専用エラーではありません: \(error)")
            }

            let sentinel = destination.appendingPathComponent("sentinel.txt")
            #expect(try Data(contentsOf: sentinel) == sentinelData)
            let directoryContents = try FileManager.default.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil
            )
            #expect(directoryContents.map(\.lastPathComponent) == ["sentinel.txt"])
        }

        let hiddenTemporaryOutputs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".")
                && ($0.lastPathComponent.hasSuffix("-\(jpegDestination.lastPathComponent)")
                    || $0.lastPathComponent.hasSuffix("-\(tiffDestination.lastPathComponent)"))
        }
        #expect(hiddenTemporaryOutputs.isEmpty)
    }

    @Test func detectsCaseSymlinkAndHardLinkAliasesOfTheOriginal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchAliasTests-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("original.jpg")
        let caseAlias = directory.appendingPathComponent("ORIGINAL.JPG")
        let symlinkAlias = directory.appendingPathComponent("symlink.jpg")
        let hardLinkAlias = directory.appendingPathComponent("hardlink.jpg")
        let distinct = directory.appendingPathComponent("distinct.jpg")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source, options: .atomic)
        try FileManager.default.createSymbolicLink(at: symlinkAlias, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardLinkAlias)

        #expect(RenderEngine.destinationAliasesSource(caseAlias, source: source))
        #expect(RenderEngine.destinationAliasesSource(symlinkAlias, source: source))
        #expect(RenderEngine.destinationAliasesSource(hardLinkAlias, source: source))
        #expect(!RenderEngine.destinationAliasesSource(distinct, source: source))
    }

    @Test func refusesJPEGExportOverAnotherProtectedLibrarySourceAndItsHardLink() throws {
        let decodedURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchProtectedJPEGTests-\(UUID().uuidString)", isDirectory: true)
        let protectedSource = directory.appendingPathComponent("another-library-source.jpg")
        let hardLinkAlias = directory.appendingPathComponent("another-library-source-alias.jpg")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalData = Data("protected-library-source".utf8)
        try originalData.write(to: protectedSource, options: .atomic)
        try FileManager.default.linkItem(at: protectedSource, to: hardLinkAlias)
        let decoded = try CoreImageDecoder().decode(url: decodedURL)

        for destination in [protectedSource, hardLinkAlias] {
            do {
                _ = try RenderEngine().exportJPEG(
                    decoded: decoded,
                    settings: .neutral,
                    destination: destination,
                    protectedSourceURLs: [protectedSource]
                )
                Issue.record("別のライブラリ原本またはそのハードリンクへのJPEG書き出しが成功してしまいました。")
            } catch let error as RenderEngineError {
                guard case let .sourceOverwriteForbidden(rejectedDestination) = error else {
                    Issue.record("想定外のRenderEngineErrorです: \(error)")
                    continue
                }
                #expect(rejectedDestination == destination)
            } catch {
                Issue.record("専用エラーではありません: \(error)")
            }
            #expect(try Data(contentsOf: protectedSource) == originalData)
        }
    }

    @Test func refusesTIFFExportOverASymlinkToAnotherProtectedLibrarySource() throws {
        let decodedURL = projectRoot.appendingPathComponent("DSC02072.JPG")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchProtectedTIFFTests-\(UUID().uuidString)", isDirectory: true)
        let protectedSource = directory.appendingPathComponent("another-library-source.tif")
        let symlinkAlias = directory.appendingPathComponent("another-library-source-alias.tif")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalData = Data("protected-library-source".utf8)
        try originalData.write(to: protectedSource, options: .atomic)
        try FileManager.default.createSymbolicLink(at: symlinkAlias, withDestinationURL: protectedSource)
        let decoded = try CoreImageDecoder().decode(url: decodedURL)

        do {
            _ = try RenderEngine().exportTIFF(
                decoded: decoded,
                settings: .neutral,
                destination: symlinkAlias,
                maxDimension: 100,
                protectedSourceURLs: [protectedSource]
            )
            Issue.record("別のライブラリ原本へのシンボリックリンクを介したTIFF書き出しが成功してしまいました。")
        } catch let error as RenderEngineError {
            guard case let .sourceOverwriteForbidden(rejectedDestination) = error else {
                Issue.record("想定外のRenderEngineErrorです: \(error)")
                return
            }
            #expect(rejectedDestination == symlinkAlias)
        } catch {
            Issue.record("専用エラーではありません: \(error)")
        }
        #expect(try Data(contentsOf: protectedSource) == originalData)
    }

    @Test func atomicInstallRechecksParentSymlinkAgainstProtectedSource() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchInstallRaceTests-\(UUID().uuidString)")
        let protectedDirectory = sandbox.appendingPathComponent("protected", isDirectory: true)
        let selectedDirectory = sandbox.appendingPathComponent("selected", isDirectory: true)
        let protectedSource = protectedDirectory.appendingPathComponent("original.jpg")
        let destination = selectedDirectory.appendingPathComponent("original.jpg")
        let temporary = sandbox.appendingPathComponent("encoded-temporary.jpg")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(
            at: protectedDirectory,
            withIntermediateDirectories: true
        )
        let originalData = Data("protected-original".utf8)
        try originalData.write(to: protectedSource)
        try Data("new-render".utf8).write(to: temporary)
        try FileManager.default.createSymbolicLink(
            at: selectedDirectory,
            withDestinationURL: protectedDirectory
        )

        do {
            try RenderEngine.installAtomically(
                temporary: temporary,
                destination: destination,
                protectedSources: [protectedSource]
            )
            Issue.record("install直前に導入された親symlinkから原本を上書きできました。")
        } catch let error as RenderEngineError {
            guard case .sourceOverwriteForbidden = error else {
                Issue.record("期待した原本保護エラーではありません: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: protectedSource) == originalData)
    }

    @Test func exportsLumixRAWAtOriginalResolutionWithoutChangingTheSource() throws {
        let sourceURL = projectRoot.appendingPathComponent("P1524180.RW2")
        try #require(FileManager.default.fileExists(atPath: sourceURL.path))
        let sourceBefore = try Data(contentsOf: sourceURL)
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBenchTests-\(UUID().uuidString)", isDirectory: true)
        let outputURL = outputDirectory.appendingPathComponent("lumix-export.jpg")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let decoded = try CoreImageDecoder().decode(url: sourceURL)
        let duration = try RenderEngine().exportJPEG(
            decoded: decoded,
            settings: EditSettings(exposure: 0.1),
            destination: outputURL
        )

        let sourceAfter = try Data(contentsOf: sourceURL)
        #expect(sourceBefore == sourceAfter)
        #expect(duration > 0)
        let exportedSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil)
        let properties = exportedSource.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any]
        }
        #expect(properties?[kCGImagePropertyPixelWidth as String] as? Int == 6_000)
        #expect(properties?[kCGImagePropertyPixelHeight as String] as? Int == 4_000)
        #expect(properties?[kCGImagePropertyOrientation as String] as? Int == 1)
        let tiff = properties?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        #expect(tiff?[kCGImagePropertyTIFFOrientation as String] as? Int == 1)
        let exif = properties?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(exif?[kCGImagePropertyExifPixelXDimension as String] as? Int == 6_000)
        #expect(exif?[kCGImagePropertyExifPixelYDimension as String] as? Int == 4_000)
        #expect(exif?[kCGImagePropertyExifColorSpace as String] as? Int == 1)
        #expect(properties?["{Raw}"] == nil)
    }
}

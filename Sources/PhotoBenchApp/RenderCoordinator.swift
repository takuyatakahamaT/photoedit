import Foundation
import PhotoCore

actor RenderCoordinator {
    private let renderer = RenderEngine()

    func prepareProductionPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560,
        quality: SpatialToneQuality = .final
    ) throws -> PreparedPreviewFrame {
        try Task.checkCancellation()
        let frame = try renderer.prepareProductionPreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension,
            quality: quality
        )
        try Task.checkCancellation()
        return frame
    }

    /// Reduces the full-resolution decode once into the preview working copy
    /// every preview render then uses (`RenderEngine.makePreviewWorkingCopy`).
    func makePreviewWorkingCopy(
        from decoded: DecodedPhoto,
        maxDimension: CGFloat = 2_560
    ) throws -> DecodedPhoto {
        try Task.checkCancellation()
        let workingCopy = try renderer.makePreviewWorkingCopy(
            from: decoded,
            maxDimension: maxDimension
        )
        try Task.checkCancellation()
        return workingCopy
    }

    /// `drag`: a slider-drag approximation (`PreviewDragSession`). Cancelling
    /// the calling task stops the render at its next step or cube-bake chunk
    /// (`PreviewCancellation`), so a superseded exact render does not hold
    /// this actor for its full duration.
    func preparePreviewFromWorkingCopy(
        workingCopy: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560,
        quality: SpatialToneQuality = .final,
        drag: PreviewDragSession? = nil
    ) async throws -> PreparedPreviewFrame {
        try Task.checkCancellation()
        let cancellation = PreviewCancellation()
        let frame = try await withTaskCancellationHandler {
            // Core Image/Metal objects this render autoreleases (the spatial
            // pass's textures among them) are freed per frame, not whenever
            // the executor thread happens to drain.
            try autoreleasepool {
                try renderer.preparePreviewFromWorkingCopy(
                    workingCopy: workingCopy,
                    settings: settings,
                    maxDimension: maxDimension,
                    quality: quality,
                    drag: drag,
                    cancellation: cancellation
                )
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return frame
    }

    func materializePreview(
        _ frame: PreparedPreviewFrame
    ) throws -> RenderedPreview {
        try Task.checkCancellation()
        return try autoreleasepool { try renderer.materializePreview(frame) }
    }

    func renderPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> RenderedPreview {
        try Task.checkCancellation()
        return try renderer.renderPreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension
        )
    }

    func exportJPEG(
        decoded: DecodedPhoto,
        settings: EditSettings,
        destination: URL,
        protectedSourceURLs: [URL] = []
    ) throws -> Double {
        try Task.checkCancellation()
        return try renderer.exportJPEG(
            decoded: decoded,
            settings: settings,
            destination: destination,
            protectedSourceURLs: protectedSourceURLs
        )
    }
}

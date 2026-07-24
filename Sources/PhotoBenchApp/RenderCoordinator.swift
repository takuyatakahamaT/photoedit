import Foundation
import PhotoCore

actor RenderCoordinator {
    private let renderer = RenderEngine()

    func prepareProductionPreview(
        decoded: DecodedPhoto,
        settings: EditSettings,
        maxDimension: CGFloat = 2_560
    ) throws -> PreparedPreviewFrame {
        try Task.checkCancellation()
        let frame = try renderer.prepareProductionPreview(
            decoded: decoded,
            settings: settings,
            maxDimension: maxDimension
        )
        try Task.checkCancellation()
        return frame
    }

    func materializePreview(
        _ frame: PreparedPreviewFrame
    ) throws -> RenderedPreview {
        try Task.checkCancellation()
        return try renderer.materializePreview(frame)
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

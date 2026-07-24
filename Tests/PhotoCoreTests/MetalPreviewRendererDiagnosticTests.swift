import Metal
import Testing
@testable import PhotoCore

struct MetalPreviewRendererDiagnosticTests {
    @Test func nativeMetalClearProducesOpaqueMagenta() throws {
        guard let renderer = MetalPreviewRenderer() else {
            Issue.record("このMacでMetal preview rendererを作成できません。")
            return
        }
        let texture = try makeTexture(renderer: renderer)
        let commandBuffer = try renderer.makeCommandBuffer()

        try renderer.encodeDiagnosticMetalClear(
            to: texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        #expect(commandBuffer.status == .completed)
        expectOpaqueMagenta(readBytes(texture: texture), width: texture.width)
    }

    @Test func coreImageSolidProducesOpaqueMagenta() throws {
        guard let renderer = MetalPreviewRenderer() else {
            Issue.record("このMacでMetal preview rendererを作成できません。")
            return
        }
        let texture = try makeTexture(renderer: renderer)
        let commandBuffer = try renderer.makeCommandBuffer()

        _ = try renderer.encodeDiagnosticCISolid(
            to: texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        #expect(commandBuffer.status == .completed)
        expectOpaqueMagenta(readBytes(texture: texture), width: texture.width)
    }

    @Test func probesRejectTexturesOutsideTheProductionContract() throws {
        guard let renderer = MetalPreviewRenderer() else {
            Issue.record("このMacでMetal preview rendererを作成できません。")
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 4,
            height: 3,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))

        do {
            try renderer.encodeDiagnosticMetalClear(
                to: texture,
                commandBuffer: try renderer.makeCommandBuffer()
            )
            Issue.record("native Metal probeが不適合テクスチャを受理しました。")
        } catch MetalPreviewRendererError.incompatibleTexture {
            // Expected.
        }

        do {
            _ = try renderer.encodeDiagnosticCISolid(
                to: texture,
                commandBuffer: try renderer.makeCommandBuffer()
            )
            Issue.record("Core Image probeが不適合テクスチャを受理しました。")
        } catch MetalPreviewRendererError.incompatibleTexture {
            // Expected.
        }
    }

    private func makeTexture(renderer: MetalPreviewRenderer) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalPreviewRenderer.pixelFormat,
            width: 4,
            height: 3,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        return try #require(renderer.device.makeTexture(descriptor: descriptor))
    }

    private func readBytes(texture: any MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func expectOpaqueMagenta(_ bytes: [UInt8], width: Int) {
        let pixels = bytes.count / 4
        for pixel in 0..<pixels {
            let offset = pixel * 4
            let blue = bytes[offset]
            let green = bytes[offset + 1]
            let red = bytes[offset + 2]
            let alpha = bytes[offset + 3]
            #expect(
                red >= 250 && green <= 1 && blue >= 250 && alpha == 255,
                "pixel=\(pixel % width),\(pixel / width) BGRA=\(blue),\(green),\(red),\(alpha)"
            )
        }
    }
}

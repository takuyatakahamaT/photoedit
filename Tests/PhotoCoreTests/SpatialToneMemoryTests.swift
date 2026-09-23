import CoreImage
import Foundation
import Metal
import Testing
@testable import PhotoCore

/// Memory guards for `SpatialToneProcessor`'s GPU path (2026-09-24). One
/// `apply()` used to keep every intermediate alive until the call ended --
/// Shadows' discretization sweep alone allocated a fresh pyramid per step,
/// about 100 full-size planes in total -- and the texture pool then kept
/// every shape it had ever seen for the life of the process.
struct SpatialToneMemoryTests {
    static let hasMetal = MTLCreateSystemDefaultDevice() != nil

    private static func gradient(width: Int, height: Int) throws -> CIImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let value = 0.02 + 0.9 * Float(x) / Float(width) * Float(y + 1) / Float(height)
                pixels[base] = value
                pixels[base + 1] = value * 0.8
                pixels[base + 2] = value * 0.6
            }
        }
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        return CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: bytesPerRow,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace
        )
    }

    @Test(.enabled(if: hasMetal))
    func oneCallHoldsOnlyAFewPlanesAtOnce() throws {
        let width = 1_024
        let height = 768
        let measured = try SpatialToneProcessor.applyGPUMeasuringMemory(
            to: Self.gradient(width: width, height: height),
            highlights: -60, shadows: 50,
            scalePx: SpatialToneOps.scalePx(forLongEdge: Double(width)),
            texture: 30, clarity: 30, quality: .final
        )
        let plane = width * height * MemoryLayout<Float>.size
        // The rgba32Float input alone is 4 planes. Before intermediates were
        // reused within the call, this call held about 100.
        #expect(measured.peakBytes >= 4 * plane)
        #expect(measured.peakBytes <= 24 * plane, "held \(measured.peakBytes / plane) planes")
    }

    @Test(.enabled(if: hasMetal))
    func poolReusesTheLatestCallsShapesAndDropsTheRest() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = SpatialToneProcessor.TexturePool()
        let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let landscape = (0..<3).map { _ in
            pool.checkout(device: device, width: 64, height: 48, format: .r32Float, usage: usage)
        }
        pool.checkin(landscape)
        #expect(pool.pooledBytes == landscape.reduce(0) { $0 + $1.allocatedSize })

        let portrait = pool.checkout(device: device, width: 48, height: 64, format: .r32Float, usage: usage)
        pool.checkin([portrait])
        #expect(pool.pooledBytes == portrait.allocatedSize)

        // The same shape as the latest call is reused ...
        let reused = pool.checkout(device: device, width: 48, height: 64, format: .r32Float, usage: usage)
        #expect(reused === portrait)
        // ... while the earlier shape was dropped when the other one checked in.
        let again = pool.checkout(device: device, width: 64, height: 48, format: .r32Float, usage: usage)
        #expect(!landscape.contains { $0 === again })
    }
}

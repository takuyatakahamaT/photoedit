import CryptoKit
import Foundation
import Testing
@testable import PhotoCore

struct RAWWhiteBalanceDecoderTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func expectSameDecodeSemantics(_ lhs: DecodeInfo, _ rhs: DecodeInfo) {
        #expect(lhs.backend == rhs.backend)
        #expect(lhs.width == rhs.width)
        #expect(lhs.height == rhs.height)
        #expect(lhs.isRAW == rhs.isRAW)
        #expect(lhs.isBoundedSRGBRaster == rhs.isBoundedSRGBRaster)
        #expect(lhs.cameraMake == rhs.cameraMake)
        #expect(lhs.cameraModel == rhs.cameraModel)
        #expect(lhs.calibrationID == rhs.calibrationID)
        #expect(lhs.calibrationLabel == rhs.calibrationLabel)
        #expect(lhs.intent == rhs.intent)
        #expect(lhs.requestedMaximumDimension == rhs.requestedMaximumDimension)
        #expect(lhs.nativeWidth == rhs.nativeWidth)
        #expect(lhs.nativeHeight == rhs.nativeHeight)
        #expect(lhs.appliedScaleFactor == rhs.appliedScaleFactor)
    }

    @Test func customValueValidationFailsClosedAndNormalizesSignedZero() throws {
        for value in [
            Double.nan,
            Double.infinity,
            -Double.infinity,
            Double.leastNonzeroMagnitude,
            -Double.leastNonzeroMagnitude,
            1_999,
            50_001
        ] {
            #expect(throws: RAWWhiteBalanceDecoderError.self) {
                _ = try RAWCustomWhiteBalance(temperatureKelvin: value, tint: 0)
            }
        }
        for value in [
            Double.nan,
            Double.infinity,
            -Double.infinity,
            Double.leastNonzeroMagnitude,
            -Double.leastNonzeroMagnitude,
            -151,
            151
        ] {
            #expect(throws: RAWWhiteBalanceDecoderError.self) {
                _ = try RAWCustomWhiteBalance(temperatureKelvin: 5_000, tint: value)
            }
        }

        let minimum = try RAWCustomWhiteBalance(temperatureKelvin: 2_000, tint: -150)
        let maximum = try RAWCustomWhiteBalance(temperatureKelvin: 50_000, tint: 150)
        let signedZero = try RAWCustomWhiteBalance(temperatureKelvin: 5_000, tint: -0.0)
        #expect(minimum.temperatureKelvin == 2_000)
        #expect(maximum.temperatureKelvin == 50_000)
        #expect(signedZero.tint == 0)
        #expect(signedZero.tint.sign == .plus)

        let invalidJSON = Data(#"{"temperatureKelvin":1000,"tint":0}"#.utf8)
        #expect(throws: RAWWhiteBalanceDecoderError.self) {
            _ = try JSONDecoder().decode(RAWCustomWhiteBalance.self, from: invalidJSON)
        }
    }

    @Test func asShotWrapperDelegatesWithoutObservingNeutralProperties() throws {
        let raw = projectRoot.appendingPathComponent("P1524180.RW2")
        try #require(FileManager.default.fileExists(atPath: raw.path))
        let legacy = try CoreImageDecoder().decode(url: raw, intent: .fullResolution)
        let wrapped = try CoreImageRAWWhiteBalanceDecoder().decode(
            url: raw,
            intent: .fullResolution,
            whiteBalance: .asShot
        )

        #expect(wrapped.provenance.requestMode == "as-shot-untouched")
        #expect(wrapped.provenance.processingIdentifier == CoreImageDecoder.processingIdentifier)
        #expect(!wrapped.provenance.neutralPropertiesObserved)
        #expect(wrapped.provenance.requested == nil)
        #expect(wrapped.provenance.sourceAsShot == nil)
        #expect(wrapped.provenance.applied == nil)
        #expect(wrapped.provenance.setterOrder == nil)
        expectSameDecodeSemantics(wrapped.decoded.info, legacy.info)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBench-AsShot-Invariance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let legacyTIFF = temporary.appendingPathComponent("legacy.tif")
        let wrappedTIFF = temporary.appendingPathComponent("wrapped.tif")
        let renderer = RenderEngine()
        _ = try renderer.exportTIFF(
            decoded: legacy,
            settings: .neutral,
            destination: legacyTIFF,
            maxDimension: 1_500,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        _ = try renderer.exportTIFF(
            decoded: wrapped.decoded,
            settings: .neutral,
            destination: wrappedTIFF,
            maxDimension: 1_500,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        let legacyBytes = try Data(contentsOf: legacyTIFF)
        let wrappedBytes = try Data(contentsOf: wrappedTIFF)
        #expect(legacyBytes == wrappedBytes)
        #expect(SHA256.hash(data: legacyBytes) == SHA256.hash(data: wrappedBytes))
    }

    @Test func customRAWDecodeRecordsRequestedSourceAndEffectiveValues() throws {
        let raw = projectRoot.appendingPathComponent("P1524180.RW2")
        try #require(FileManager.default.fileExists(atPath: raw.path))
        let request = try RAWCustomWhiteBalance(temperatureKelvin: 4_000, tint: 0)
        let result = try CoreImageRAWWhiteBalanceDecoder().decode(
            url: raw,
            intent: .interactivePreview(maxDimension: 1_500),
            whiteBalance: .custom(request)
        )
        let provenance = result.provenance

        #expect(result.decoded.info.isRAW)
        #expect(result.decoded.info.width == 1_500)
        #expect(result.decoded.info.height == 1_000)
        #expect(provenance.processingIdentifier == CoreImageRAWWhiteBalanceDecoder.customProcessingIdentifier)
        #expect(provenance.requestMode == "custom-core-image-neutral")
        #expect(provenance.neutralPropertiesObserved)
        #expect(provenance.requested == request)
        #expect(provenance.sourceAsShot != nil)
        #expect(abs((provenance.applied?.temperatureKelvin ?? 0) - 4_000) < 0.01)
        #expect(abs(provenance.applied?.tint ?? 1) < 0.01)
        #expect(provenance.setterOrder == .temperatureThenTint)
        #expect(provenance.neutralLocationPolicy == "unused")
        #expect(provenance.decoderVersion == "8")
        #expect(provenance.supportedDecoderVersions.contains("8"))
        #expect(provenance.appRAWCalibrationProfileID == RAWCalibrationProfile.panasonicDCS5Lightroom93.id)
        #expect(provenance.decodeConfiguration?.scaleFactor == 0.25)
        #expect(provenance.appleCameraProfileObservability == "unavailable-in-public-api")
        #expect(provenance.supportedCameraModelsSHA256.count == 64)
        #expect(!provenance.macOSBuild.isEmpty)
        #expect(!provenance.colorSpacePolicy.isEmpty)
    }

    @Test func customWhiteBalanceRejectsRasterButAsShotRasterRemainsUnchanged() throws {
        let jpeg = projectRoot.appendingPathComponent("DSC02072.JPG")
        try #require(FileManager.default.fileExists(atPath: jpeg.path))
        let request = try RAWCustomWhiteBalance(temperatureKelvin: 5_000, tint: 0)
        #expect(throws: RAWWhiteBalanceDecoderError.self) {
            _ = try CoreImageRAWWhiteBalanceDecoder().decode(
                url: jpeg,
                whiteBalance: .custom(request)
            )
        }

        let legacy = try CoreImageDecoder().decode(url: jpeg)
        let wrapped = try CoreImageRAWWhiteBalanceDecoder().decode(
            url: jpeg,
            whiteBalance: .asShot
        )
        expectSameDecodeSemantics(wrapped.decoded.info, legacy.info)
        #expect(!wrapped.provenance.neutralPropertiesObserved)
    }

    @Test func setterOrderCharacterizationUsesFreshFilters() throws {
        let raw = projectRoot.appendingPathComponent("P1524180.RW2")
        try #require(FileManager.default.fileExists(atPath: raw.path))
        let decoder = CoreImageRAWWhiteBalanceDecoder()
        let source = try decoder.observeSourceNeutral(url: raw)
        let request = try RAWCustomWhiteBalance(
            temperatureKelvin: source.temperatureKelvin,
            tint: source.tint
        )
        let temperatureFirst = try decoder.decodeForObservation(
            url: raw,
            intent: .interactivePreview(maxDimension: 1_500),
            customWhiteBalance: request,
            setterOrder: .temperatureThenTint
        )
        let tintFirst = try decoder.decodeForObservation(
            url: raw,
            intent: .interactivePreview(maxDimension: 1_500),
            customWhiteBalance: request,
            setterOrder: .tintThenTemperature
        )
        #expect(temperatureFirst.provenance.setterOrder == .temperatureThenTint)
        #expect(tintFirst.provenance.setterOrder == .tintThenTemperature)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBench-WB-Setter-Order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let temperatureFirstTIFF = temporary.appendingPathComponent("temperature-first.tif")
        let tintFirstTIFF = temporary.appendingPathComponent("tint-first.tif")
        let renderer = RenderEngine()
        _ = try renderer.exportTIFF(
            decoded: temperatureFirst.decoded,
            settings: .neutral,
            destination: temperatureFirstTIFF,
            maxDimension: 1_500,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        _ = try renderer.exportTIFF(
            decoded: tintFirst.decoded,
            settings: .neutral,
            destination: tintFirstTIFF,
            maxDimension: 1_500,
            downsamplingFilter: .lanczos,
            outputTransformPlacement: .afterDownsampling
        )
        let temperatureFirstBytes = try Data(contentsOf: temperatureFirstTIFF)
        let tintFirstBytes = try Data(contentsOf: tintFirstTIFF)
        #expect(!temperatureFirstBytes.isEmpty)
        #expect(temperatureFirstBytes == tintFirstBytes)
    }

    @Test func immutableEvidenceInstallNeverReplacesAnExistingDestination() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoBench-Immutable-Install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let temporary = sandbox.appendingPathComponent("new.tif")
        let destination = sandbox.appendingPathComponent("evidence.tif")
        let original = Data("existing-evidence".utf8)
        try Data("new-render".utf8).write(to: temporary)
        try original.write(to: destination)

        #expect(throws: Error.self) {
            try RenderEngine.installAtomically(
                temporary: temporary,
                destination: destination,
                protectedSources: [],
                allowDestinationReplacement: false
            )
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
    }
}

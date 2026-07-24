import CoreImage
import Darwin
import Foundation
import Metal
import PhotoCore

public struct MetalRuntimeProvenance: Codable, Equatable, Sendable {
    public let name: String
    public let registryID: UInt64
    public let hasUnifiedMemory: Bool
    public let currentAllocatedSize: UInt64
    public let recommendedMaxWorkingSetSize: UInt64
}

public struct RuntimeProvenance: Codable, Equatable, Sendable {
    public let macOSVersion: String
    public let macOSBuild: String
    public let architecture: String
    public let hardwareModel: String
    public let processorCount: Int
    public let physicalMemoryBytes: UInt64
    public let thermalState: String
    public let lowPowerModeEnabled: Bool
    public let buildConfiguration: String
    public let coreImageFrameworkVersion: String?
    public let executableSHA256: String?
    public let metalDevice: MetalRuntimeProvenance?

    public static func capture(executableURL: URL?) -> RuntimeProvenance {
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        let metal = MTLCreateSystemDefaultDevice().map { device in
            MetalRuntimeProvenance(
                name: device.name,
                registryID: device.registryID,
                hasUnifiedMemory: device.hasUnifiedMemory,
                currentAllocatedSize: UInt64(device.currentAllocatedSize),
                recommendedMaxWorkingSetSize: UInt64(device.recommendedMaxWorkingSetSize)
            )
        }
        let frameworkVersion = Bundle(identifier: "com.apple.CoreImage")?
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let executableHash = executableURL.flatMap { try? SHA256Digest.file($0) }
        return RuntimeProvenance(
            macOSVersion: version,
            macOSBuild: operatingSystemBuild,
            architecture: architecture,
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            buildConfiguration: buildConfiguration,
            coreImageFrameworkVersion: frameworkVersion,
            executableSHA256: executableHash,
            metalDevice: metal
        )
    }

    public static func captureCurrentExecutable() throws -> RuntimeProvenance {
        let executableURL: URL
        if let bundled = Bundle.main.executableURL {
            executableURL = bundled.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }
        guard FileManager.default.isReadableFile(atPath: executableURL.path) else {
            throw CalibrationManifestError.invalid(
                "実行binaryをprovenance用に読み取れません: \(executableURL.path)"
            )
        }
        let runtime = capture(executableURL: executableURL)
        guard runtime.executableSHA256 != nil else {
            throw CalibrationManifestError.invalid("実行binaryのSHA-256を取得できません")
        }
        return runtime
    }

    /// `kern.osversion` omits Rapid Security Response suffix builds. ProcessInfo
    /// exposes the effective build used by the running process, including RSRs.
    private static var operatingSystemBuild: String {
        let description = ProcessInfo.processInfo.operatingSystemVersionString
        guard let marker = description.range(of: "(Build ") else {
            return sysctlString("kern.osversion") ?? "unknown"
        }
        let suffix = description[marker.upperBound...]
        guard let closing = suffix.firstIndex(of: ")") else {
            return sysctlString("kern.osversion") ?? "unknown"
        }
        return String(suffix[..<closing])
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    fileprivate static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// A volatile observation of host load at one benchmark boundary.
///
/// This intentionally remains separate from `RuntimeProvenance`: provenance
/// identifies the machine and executable, while these values can change during
/// one run and are diagnostic evidence rather than benchmark eligibility gates.
public struct SystemLoadSnapshot: Codable, Equatable, Sendable {
    public let capturedAtUTC: String
    public let loadAverage1Minute: Double
    public let loadAverage5Minutes: Double
    public let loadAverage15Minutes: Double
    public let load1PerActiveProcessor: Double
    public let thermalState: String
    public let lowPowerModeEnabled: Bool
    public let processCPUTimeSeconds: Double
    public let metalCurrentAllocatedSizeBytes: UInt64?

    public static func capture() throws -> SystemLoadSnapshot {
        var loadAverages = [Double](repeating: 0, count: 3)
        let loadAverageCount = loadAverages.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, Int32(buffer.count))
        }
        guard loadAverageCount == loadAverages.count,
              loadAverages.allSatisfy({ $0.isFinite && $0 >= 0 })
        else {
            throw CalibrationManifestError.invalid(
                "system load averageを取得できません"
            )
        }

        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        guard processorCount > 0 else {
            throw CalibrationManifestError.invalid(
                "active processor countを取得できません"
            )
        }

        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw CalibrationManifestError.invalid(
                "process CPU timeを取得できません"
            )
        }
        let userCPUTime = Self.seconds(usage.ru_utime)
        let systemCPUTime = Self.seconds(usage.ru_stime)
        let processCPUTime = userCPUTime + systemCPUTime
        let normalizedLoad = loadAverages[0] / Double(processorCount)
        guard processCPUTime.isFinite,
              processCPUTime >= 0,
              normalizedLoad.isFinite,
              normalizedLoad >= 0
        else {
            throw CalibrationManifestError.invalid(
                "system load snapshotに非finite値があります"
            )
        }

        let processInfo = ProcessInfo.processInfo
        return SystemLoadSnapshot(
            capturedAtUTC: ISO8601Timestamp.now(),
            loadAverage1Minute: loadAverages[0],
            loadAverage5Minutes: loadAverages[1],
            loadAverage15Minutes: loadAverages[2],
            load1PerActiveProcessor: normalizedLoad,
            thermalState: RuntimeProvenance.thermalStateName(processInfo.thermalState),
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            processCPUTimeSeconds: processCPUTime,
            metalCurrentAllocatedSizeBytes: MTLCreateSystemDefaultDevice().map {
                UInt64($0.currentAllocatedSize)
            }
        )
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}

public struct ManifestRunReference: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let suiteID: String

    public init(path: String, sha256: String, suiteID: String) {
        self.path = path
        self.sha256 = sha256
        self.suiteID = suiteID
    }
}

public struct CalibrationDecodeRecord: Codable, Equatable, Sendable {
    public let sceneID: String
    public let route: String
    public let backend: String
    public let intent: String
    public let requestedMaximumDimension: Int?
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let appliedScaleFactor: Float?
    public let width: Int
    public let height: Int
    public let decoderGraphSetupMilliseconds: Double
    public let cameraMake: String?
    public let cameraModel: String?
    public let calibrationID: String?

    public init(
        sceneID: String,
        route: String,
        backend: String,
        intent: String,
        requestedMaximumDimension: Int?,
        nativeWidth: Int,
        nativeHeight: Int,
        appliedScaleFactor: Float?,
        width: Int,
        height: Int,
        decoderGraphSetupMilliseconds: Double,
        cameraMake: String?,
        cameraModel: String?,
        calibrationID: String?
    ) {
        self.sceneID = sceneID
        self.route = route
        self.backend = backend
        self.intent = intent
        self.requestedMaximumDimension = requestedMaximumDimension
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.appliedScaleFactor = appliedScaleFactor
        self.width = width
        self.height = height
        self.decoderGraphSetupMilliseconds = decoderGraphSetupMilliseconds
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.calibrationID = calibrationID
    }
}

public struct CalibrationArtifact: Codable, Equatable, Sendable {
    public let role: String
    public let sceneID: String
    public let route: String?
    public let candidateGroup: String?
    public let candidateID: String?
    public let label: String?
    public let path: String
    public let sha256: String
    public let byteCount: UInt64
    public let width: Int
    public let height: Int
    public let renderAndEncodeMilliseconds: Double
    public let settings: EditSettings
    public let settingsSHA256: String

    public init(
        role: String,
        sceneID: String,
        route: String?,
        candidateGroup: String?,
        candidateID: String?,
        label: String?,
        path: String,
        sha256: String,
        byteCount: UInt64,
        width: Int,
        height: Int,
        renderAndEncodeMilliseconds: Double,
        settings: EditSettings,
        settingsSHA256: String
    ) {
        self.role = role
        self.sceneID = sceneID
        self.route = route
        self.candidateGroup = candidateGroup
        self.candidateID = candidateID
        self.label = label
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.renderAndEncodeMilliseconds = renderAndEncodeMilliseconds
        self.settings = settings
        self.settingsSHA256 = settingsSHA256
    }
}

public struct EDRHeadroomRecord: Codable, Equatable, Sendable {
    public let sceneID: String
    public let amount: Double
    public let maximumChannel: Double
    public let extendedChannelPixelFraction: Double
    public let maximumLuminance: Double
    public let extendedLuminancePixelFraction: Double

    public init(
        sceneID: String,
        amount: Double,
        maximumChannel: Double,
        extendedChannelPixelFraction: Double,
        maximumLuminance: Double,
        extendedLuminancePixelFraction: Double
    ) {
        self.sceneID = sceneID
        self.amount = amount
        self.maximumChannel = maximumChannel
        self.extendedChannelPixelFraction = extendedChannelPixelFraction
        self.maximumLuminance = maximumLuminance
        self.extendedLuminancePixelFraction = extendedLuminancePixelFraction
    }
}

public struct CalibrationRunManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let status: String
    public let runID: String
    public let startedAtUTC: String
    public let completedAtUTC: String?
    public let manifest: ManifestRunReference
    public let runtime: RuntimeProvenance
    public let processing: PhotoCoreProcessingFingerprint
    public let sourceFingerprintSHA256: String
    public let postflightSourceFingerprintSHA256: String?
    public let sourceFiles: [VerifiedFile]
    public let verifiedInputs: [VerifiedFile]
    public let postflightVerifiedInputs: [VerifiedFile]?
    public let decodes: [CalibrationDecodeRecord]
    public let artifacts: [CalibrationArtifact]
    public let edrHeadroom: [EDRHeadroomRecord]

    public init(
        status: String,
        runID: String,
        startedAtUTC: String,
        completedAtUTC: String? = nil,
        manifest: ManifestRunReference,
        runtime: RuntimeProvenance,
        processing: PhotoCoreProcessingFingerprint,
        sourceFingerprintSHA256: String,
        postflightSourceFingerprintSHA256: String? = nil,
        sourceFiles: [VerifiedFile],
        verifiedInputs: [VerifiedFile],
        postflightVerifiedInputs: [VerifiedFile]? = nil,
        decodes: [CalibrationDecodeRecord] = [],
        artifacts: [CalibrationArtifact] = [],
        edrHeadroom: [EDRHeadroomRecord] = []
    ) {
        self.schemaVersion = 2
        self.status = status
        self.runID = runID
        self.startedAtUTC = startedAtUTC
        self.completedAtUTC = completedAtUTC
        self.manifest = manifest
        self.runtime = runtime
        self.processing = processing
        self.sourceFingerprintSHA256 = sourceFingerprintSHA256
        self.postflightSourceFingerprintSHA256 = postflightSourceFingerprintSHA256
        self.sourceFiles = sourceFiles
        self.verifiedInputs = verifiedInputs
        self.postflightVerifiedInputs = postflightVerifiedInputs
        self.decodes = decodes
        self.artifacts = artifacts
        self.edrHeadroom = edrHeadroom
    }
}

public enum AtomicJSONWriter {
    public static func write<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value) + Data("\n".utf8)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: [.atomic])
    }
}

public enum ISO8601Timestamp {
    public static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public enum ProcessMemory {
    /// macOS reports ru_maxrss in bytes. This is process-wide, not phase-local.
    public static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(usage.ru_maxrss, 0))
    }
}

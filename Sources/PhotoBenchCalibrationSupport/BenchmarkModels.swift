import Foundation

public struct BenchmarkDistribution: Codable, Equatable, Sendable {
    public let unit: String
    public let samples: [Double]
    public let minimum: Double
    public let maximum: Double
    public let mean: Double
    public let p50: Double
    public let p95: Double

    public init(samples: [Double], unit: String = "ms") throws {
        guard !samples.isEmpty,
              samples.allSatisfy({ $0.isFinite && $0 >= 0 })
        else {
            throw CalibrationManifestError.invalid(
                "benchmark samplesは非空のfinite非負値である必要があります"
            )
        }
        self.unit = unit
        self.samples = samples
        self.minimum = samples.min()!
        self.maximum = samples.max()!
        self.mean = samples.reduce(0, +) / Double(samples.count)
        self.p50 = Self.percentile(samples, quantile: 0.50)
        self.p95 = Self.percentile(samples, quantile: 0.95)
    }

    /// R-7 / NumPy linear percentile: h=(n-1)q with linear interpolation.
    public static func percentile(_ samples: [Double], quantile: Double) -> Double {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        let boundedQuantile = min(max(quantile, 0), 1)
        let position = Double(sorted.count - 1) * boundedQuantile
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] * (1 - fraction) + sorted[upperIndex] * fraction
    }
}

public struct BenchmarkPhaseDistributions: Codable, Equatable, Sendable {
    public let decoderGraphSetup: BenchmarkDistribution?
    public let graphAndKernelSetup: BenchmarkDistribution?
    public let materializeAndReadback: BenchmarkDistribution?
    public let jpegEncodeAndWrite: BenchmarkDistribution?
    public let atomicInstall: BenchmarkDistribution?
    public let total: BenchmarkDistribution

    public init(
        decoderGraphSetup: BenchmarkDistribution?,
        graphAndKernelSetup: BenchmarkDistribution?,
        materializeAndReadback: BenchmarkDistribution?,
        jpegEncodeAndWrite: BenchmarkDistribution?,
        atomicInstall: BenchmarkDistribution?,
        total: BenchmarkDistribution
    ) {
        self.decoderGraphSetup = decoderGraphSetup
        self.graphAndKernelSetup = graphAndKernelSetup
        self.materializeAndReadback = materializeAndReadback
        self.jpegEncodeAndWrite = jpegEncodeAndWrite
        self.atomicInstall = atomicInstall
        self.total = total
    }
}

public struct BenchmarkGateResult: Codable, Equatable, Sendable {
    public let status: String
    public let observedP95Milliseconds: Double?
    public let maximumP95Milliseconds: Double
    public let reason: String?

    public init(
        status: String,
        observedP95Milliseconds: Double?,
        maximumP95Milliseconds: Double,
        reason: String?
    ) {
        self.status = status
        self.observedP95Milliseconds = observedP95Milliseconds
        self.maximumP95Milliseconds = maximumP95Milliseconds
        self.reason = reason
    }
}

public enum BenchmarkGateEvaluation: Equatable, Sendable {
    case passed
    case performanceFailed
    case notEvaluated

    public var enforcedExitCode: Int32 {
        switch self {
        case .passed: 0
        case .performanceFailed: 1
        case .notEvaluated: 2
        }
    }

    public static func evaluate(
        _ gates: some Collection<BenchmarkGateResult>
    ) throws -> BenchmarkGateEvaluation {
        guard !gates.isEmpty else {
            throw CalibrationManifestError.invalid("benchmark gateが空です")
        }
        var hasPerformanceFailure = false
        var hasNotEvaluated = false
        for gate in gates {
            switch gate.status {
            case "passed":
                break
            case "failed":
                hasPerformanceFailure = true
            case "notEvaluated":
                hasNotEvaluated = true
            default:
                throw CalibrationManifestError.invalid(
                    "未知のbenchmark gate statusです: \(gate.status)"
                )
            }
        }
        if hasNotEvaluated { return .notEvaluated }
        return hasPerformanceFailure ? .performanceFailed : .passed
    }
}

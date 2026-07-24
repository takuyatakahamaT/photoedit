import Foundation

/// Opt-in diagnostic modes for isolating the direct Metal presentation path.
///
/// The production route remains the default. A probe changes exactly one of
/// the drawing payload or MTKView scheduling mode while keeping the same
/// drawable, command queue, presentation callback, deadline, and fallback.
public enum MetalPresentationProbeMode: String, CaseIterable, Sendable {
    case metalClearOnDemand = "metal-clear/on-demand"
    case metalClearContinuous = "metal-clear/continuous"
    case ciSolidOnDemand = "ci-solid/on-demand"
    case productionOnDemand = "production/on-demand"

    public enum Payload: Equatable, Sendable {
        case metalClear
        case ciSolid
        case production
    }

    public enum DrawingMode: Equatable, Sendable {
        case onDemand
        case continuous
    }

    public var payload: Payload {
        switch self {
        case .metalClearOnDemand, .metalClearContinuous:
            .metalClear
        case .ciSolidOnDemand:
            .ciSolid
        case .productionOnDemand:
            .production
        }
    }

    public var drawingMode: DrawingMode {
        self == .metalClearContinuous ? .continuous : .onDemand
    }
}

public struct MetalPresentationProbeConfiguration: Equatable, Sendable {
    public static let environmentKey = "PHOTO_BENCH_METAL_PRESENTATION_PROBE"

    public let mode: MetalPresentationProbeMode
    public let isExplicit: Bool
    public let invalidValue: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let rawValue = environment[Self.environmentKey] else {
            mode = .productionOnDemand
            isExplicit = false
            invalidValue = nil
            return
        }
        if let parsed = MetalPresentationProbeMode(rawValue: rawValue) {
            mode = parsed
            isExplicit = true
            invalidValue = nil
        } else {
            mode = .productionOnDemand
            isExplicit = false
            invalidValue = rawValue
        }
    }
}

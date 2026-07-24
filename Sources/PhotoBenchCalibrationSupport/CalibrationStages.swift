import Foundation
import PhotoCore

public enum CalibrationStageError: LocalizedError, Equatable {
    case unsupportedCandidate(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedCandidate(id):
            "未対応の校正candidateです: \(id)"
        }
    }
}

public enum CalibrationStageFactory {
    public static func settings(
        for candidateID: String,
        preset: XMPPreset
    ) throws -> EditSettings {
        let full = preset.settings
        let tone = toneBase(from: full)
        switch candidateID {
        case "neutral":
            return .neutral
        case "exposure-only":
            return EditSettings(exposure: full.exposure)
        case "tone-base":
            return tone
        case "basic-legacy":
            var settings = full
            settings.toneCurves = []
            settings.hsl = [:]
            return settings
        case "tone-plus-vibrance":
            var settings = tone
            settings.vibrance = full.vibrance
            return settings
        case "tone-plus-global-saturation":
            var settings = tone
            settings.saturation = full.saturation
            return settings
        case "tone-plus-global-curve":
            var settings = tone
            settings.toneCurves = full.toneCurves.filter { $0.channel == .rgb }
            return settings
        case "tone-plus-rgb-curves":
            var settings = tone
            settings.toneCurves = full.toneCurves.filter { $0.channel != .rgb }
            return settings
        case "tone-plus-all-curves":
            var settings = tone
            settings.toneCurves = full.toneCurves
            return settings
        case "tone-plus-mixer-hue":
            var settings = tone
            settings.hsl = isolatedMixer(full.hsl, component: .hue)
            return settings
        case "tone-plus-mixer-saturation":
            var settings = tone
            settings.hsl = isolatedMixer(full.hsl, component: .saturation)
            return settings
        case "tone-plus-mixer-luminance":
            var settings = tone
            settings.hsl = isolatedMixer(full.hsl, component: .luminance)
            return settings
        case "tone-plus-all-mixer":
            var settings = tone
            settings.hsl = full.hsl
            return settings
        case "tone-plus-curves-mixer":
            var settings = tone
            settings.toneCurves = full.toneCurves
            settings.hsl = full.hsl
            return settings
        case "full-current":
            return full
        default:
            throw CalibrationStageError.unsupportedCandidate(candidateID)
        }
    }

    public static func settingsSHA256(
        for candidateID: String,
        preset: XMPPreset
    ) throws -> String {
        try SHA256Digest.encodable(settings(for: candidateID, preset: preset))
    }

    private static func toneBase(from full: EditSettings) -> EditSettings {
        var settings = full
        settings.vibrance = 0
        settings.saturation = 0
        settings.toneCurves = []
        settings.hsl = [:]
        return settings
    }

    private enum MixerComponent {
        case hue
        case saturation
        case luminance
    }

    private static func isolatedMixer(
        _ source: [HSLBand: HSLAdjustment],
        component: MixerComponent
    ) -> [HSLBand: HSLAdjustment] {
        var result: [HSLBand: HSLAdjustment] = [:]
        for band in HSLBand.allCases {
            guard let adjustment = source[band] else { continue }
            let isolated: HSLAdjustment
            switch component {
            case .hue:
                isolated = HSLAdjustment(hue: adjustment.hue)
            case .saturation:
                isolated = HSLAdjustment(saturation: adjustment.saturation)
            case .luminance:
                isolated = HSLAdjustment(luminance: adjustment.luminance)
            }
            if isolated != HSLAdjustment() {
                result[band] = isolated
            }
        }
        return result
    }
}

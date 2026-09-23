import CoreImage
import Foundation
import PhotoCore

/// `photobench-render`: batch RAW/raster -> JPEG/TIFF renderer used to
/// gate-measure the phase1 Adobe DCP base-rendering pipeline against
/// Lightroom-default references (`docs/PHASE1_BASE_RENDERING.md` B2).
///
/// Usage:
///   photobench-render <input...> --output-dir <dir>
///       [--preset <xmp>] [--engine libraw-dcp|coreimage]
///       [--max-dimension N] [--stage matrix|huesat|exposure|look|tone|full]
///       [--format jpg|tif16] [--quality interactive|final]
///
/// `--quality` (default `final`) is a benchmark-only knob for measuring the
/// preview `.interactive` path's speed/quality trade-off (owner-reported
/// slider sluggishness) -- like `--max-dimension`, it is only honored for
/// `--format tif16`; real JPEG export always renders at `.final`.

enum CLIError: LocalizedError {
    case missingValue(String)
    case invalidValue(flag: String, value: String)
    case unknownArgument(String)
    case noInputs
    case missingOutputDir

    var errorDescription: String? {
        switch self {
        case let .missingValue(flag): "\(flag) に値がありません"
        case let .invalidValue(flag, value): "\(flag) の値が不正です: \(value)"
        case let .unknownArgument(argument): "不明な引数です: \(argument)"
        case .noInputs: "入力ファイルが指定されていません"
        case .missingOutputDir: "--output-dir が指定されていません"
        }
    }
}

enum RenderEngineChoice: String {
    case librawDCP = "libraw-dcp"
    case coreimage
}

enum OutputFormat: String {
    case jpg
    case tif16
}

struct CLIOptions {
    var inputs: [URL] = []
    var outputDir: URL?
    var presetURL: URL?
    var engine: RenderEngineChoice = .librawDCP
    var maxDimension: Int?
    var stage: AdobeBaseRenderer.Handle.Stage?
    var format: OutputFormat = .jpg
    /// Benchmark-only override (default `.final`, matching every production
    /// caller): mirrors `--max-dimension`'s "comparison shortcut, not real
    /// export" convention exactly, so it is only honored for `--format
    /// tif16` below -- real JPEG export always resolves `.final` and has no
    /// way to ask for anything else.
    var quality: SpatialToneQuality = .final
}

func parseArguments(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = 0

    func nextValue(for flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(flag) }
        return arguments[index]
    }

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--output-dir":
            options.outputDir = URL(fileURLWithPath: try nextValue(for: argument))
        case "--preset":
            options.presetURL = URL(fileURLWithPath: try nextValue(for: argument))
        case "--engine":
            let value = try nextValue(for: argument)
            guard let engine = RenderEngineChoice(rawValue: value) else {
                throw CLIError.invalidValue(flag: argument, value: value)
            }
            options.engine = engine
        case "--max-dimension":
            let value = try nextValue(for: argument)
            guard let dimension = Int(value), dimension > 0 else {
                throw CLIError.invalidValue(flag: argument, value: value)
            }
            options.maxDimension = dimension
        case "--quality":
            let value = try nextValue(for: argument)
            switch value {
            case "interactive": options.quality = .interactive
            case "final": options.quality = .final
            default: throw CLIError.invalidValue(flag: argument, value: value)
            }
        case "--stage":
            let value = try nextValue(for: argument)
            guard let stage = AdobeBaseRenderer.Handle.Stage(rawValue: value) else {
                throw CLIError.invalidValue(flag: argument, value: value)
            }
            options.stage = stage
        case "--format":
            let value = try nextValue(for: argument)
            guard let format = OutputFormat(rawValue: value) else {
                throw CLIError.invalidValue(flag: argument, value: value)
            }
            options.format = format
        default:
            if argument.hasPrefix("--") {
                throw CLIError.unknownArgument(argument)
            }
            options.inputs.append(URL(fileURLWithPath: argument))
        }
        index += 1
    }
    return options
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

/// Debug dump for `--stage`: 32-bit-float TIFF so an intermediate stage's
/// exact numeric values (including the negative/over-1 values every stage
/// before `.full` can carry) survive, rather than clipping them into a
/// displayable 16-bit range the way a normal export would. Tagged as
/// extended-linear-sRGB purely so *some* viewer can open it; the pipeline
/// itself does not treat intermediate stages as sRGB (only `.full`, the
/// working-space hand-off point, actually is).
func writeStageDebugTIFF(_ image: CIImage, to url: URL) throws {
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    try context.writeTIFFRepresentation(
        of: image, to: url, format: .RGBAf, colorSpace: colorSpace, options: [:]
    )
}

func run() throws {
    let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    guard !options.inputs.isEmpty else { throw CLIError.noInputs }
    guard let outputDir = options.outputDir else { throw CLIError.missingOutputDir }
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let settings: EditSettings
    if let presetURL = options.presetURL {
        settings = try XMPPresetParser.parse(url: presetURL).applying(to: .neutral)
    } else {
        settings = .neutral
    }

    let renderEngine = RenderEngine()
    // `--stage` and TIFF export both tolerate a non-full decode
    // (`RenderEngine.exportTIFF`'s `maxDimension` explicitly allows it);
    // `exportJPEG` has no such parameter and always requires
    // `.fullResolution` (`RenderEngine.requireFullResolutionDecodeForExport`),
    // so `--max-dimension` is a no-op there and full resolution is decoded
    // regardless.
    let usesPreviewDecode = options.stage != nil || options.format == .tif16

    for inputURL in options.inputs {
        let decoder: any ImageDecoding = switch options.engine {
        case .librawDCP: LibRawDecoder()
        case .coreimage: CoreImageDecoder()
        }

        let decodeIntent: ImageDecodeIntent
        if usesPreviewDecode, let maxDimension = options.maxDimension {
            decodeIntent = .interactivePreview(maxDimension: maxDimension)
        } else {
            decodeIntent = .fullResolution
        }

        let decodeStarted = ContinuousClock.now
        let decoded = try decoder.decode(url: inputURL, intent: decodeIntent)
        let decodeMilliseconds = milliseconds(decodeStarted.duration(to: .now))
        let stem = inputURL.deletingPathExtension().lastPathComponent

        if let stage = options.stage {
            guard let adobeBase = decoded.adobeBase else {
                FileHandle.standardError.write(Data((
                    "警告: \(inputURL.lastPathComponent) はAdobeBaseRendererの中間段を持ちません"
                        + "（--engine coreimage、または未検出プロファイルへのフォールバック）。スキップします。\n"
                ).utf8))
                continue
            }
            let renderStarted = ContinuousClock.now
            let stageImage = adobeBase.image(through: stage)
            let outputURL = outputDir.appendingPathComponent("\(stem).\(stage.rawValue).tif")
            try writeStageDebugTIFF(stageImage, to: outputURL)
            let renderMilliseconds = milliseconds(renderStarted.duration(to: .now))
            print(
                "\(inputURL.lastPathComponent): backend=\(decoded.info.backend) stage=\(stage.rawValue) "
                    + "decode=\(String(format: "%.1f", decodeMilliseconds))ms "
                    + "render=\(String(format: "%.1f", renderMilliseconds))ms -> \(outputURL.path)"
            )
            continue
        }

        let outputURL = outputDir.appendingPathComponent(
            "\(stem).\(options.format == .jpg ? "jpg" : "tif")"
        )
        let renderMilliseconds: Double = switch options.format {
        case .jpg:
            try renderEngine.exportJPEG(decoded: decoded, settings: settings, destination: outputURL)
        case .tif16:
            try renderEngine.exportTIFF(
                decoded: decoded, settings: settings, destination: outputURL,
                maxDimension: options.maxDimension.map { CGFloat($0) },
                quality: options.quality
            )
        }
        print(
            "\(inputURL.lastPathComponent): backend=\(decoded.info.backend) "
                + "decode=\(String(format: "%.1f", decodeMilliseconds))ms "
                + "render=\(String(format: "%.1f", renderMilliseconds))ms -> \(outputURL.path)"
        )
    }
}

do {
    try run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    FileHandle.standardError.write(Data("エラー: \(message)\n".utf8))
    exit(1)
}

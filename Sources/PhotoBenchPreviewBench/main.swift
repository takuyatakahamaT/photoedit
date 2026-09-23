import Accelerate
import CoreImage
import Foundation
import Metal
import PhotoCore

/// `photobench-preview-bench`: replays slider drags against the app's own
/// preview entry points and reports where each update's time goes.
///
///   photobench-preview-bench <photo> [--preset <xmp>] [--scenarios a,b,...]
///       [--ticks N] [--mode exact|drag] [--route bitmap|metal] [--display WxH]
///       [--json <out.json>] [--dump-dir <dir>]
///
/// The photo is decoded and reduced to the preview working copy exactly as
/// `EditorModel` does when a photo is opened; each tick then prepares the
/// preview frame (`RenderEngine.preparePreviewFromWorkingCopy`, `.interactive`)
/// and presents it through the app's route: `bitmap` (the default route,
/// `RenderEngine.materializePreview` -> `NSImage`) or `metal`
/// (`PHOTO_BENCH_PREVIEW_ROUTE=metal-direct`: `MetalPreviewRenderer.
/// encodeAspectFit` into a `bgra8Unorm` target of `--display` size), waiting
/// for the GPU before the next tick. Every tick moves
/// the scenario's slider to a value no earlier tick used, like a real drag.
/// The per-step breakdown comes from `PreviewDiagnostics`.
///
/// `--mode exact` renders every tick exactly (what the app did before drag
/// sessions). `--mode drag` renders the ticks as the app does now while a
/// slider is held (`PreviewDragSession`), then the exact frame the app swaps
/// in after release ("settle"), and reports the ΔE00 between the last drag
/// frame and that exact frame. `--dump-dir` writes the last tick and the
/// exact frame as PNG, and the exact frame's float pixels (`.f32`) so two
/// builds can be compared bit for bit. `--cancel-probe` (drag mode): before
/// the settle frame, starts the same exact render on another thread, cancels
/// it after 40 ms (a new drag arriving) and reports how long it took to stop.
///
/// Only preview-size work runs after the one full-resolution decode, so this
/// is the tool for timing on the 16 GB Mac mini.

enum BenchError: LocalizedError {
    case usage(String)
    case metalUnavailable
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message): "使い方: \(message)"
        case .metalUnavailable: "Metal デバイスがありません"
        case let .renderFailed(message): "描画に失敗しました: \(message)"
        }
    }
}

struct Options {
    var photo: URL?
    var preset: URL?
    var scenarios: [String]?
    var ticks = 10
    var displayWidth = 1_400
    var displayHeight = 934
    var jsonURL: URL?
    var dumpDirectory: URL?
    var metalRoute = false
    var dragMode = false
    var cancelProbe = false
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    func value(_ flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw BenchError.usage("\(flag) に値がありません") }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--preset": options.preset = URL(fileURLWithPath: try value(argument))
        case "--scenarios": options.scenarios = try value(argument).split(separator: ",").map(String.init)
        case "--ticks":
            guard let ticks = Int(try value(argument)), ticks > 0 else { throw BenchError.usage("--ticks") }
            options.ticks = ticks
        case "--display":
            let parts = try value(argument).split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw BenchError.usage("--display WxH") }
            options.displayWidth = parts[0]
            options.displayHeight = parts[1]
        case "--cancel-probe": options.cancelProbe = true
        case "--mode":
            switch try value(argument) {
            case "exact": options.dragMode = false
            case "drag": options.dragMode = true
            default: throw BenchError.usage("--mode exact|drag")
            }
        case "--route":
            switch try value(argument) {
            case "bitmap": options.metalRoute = false
            case "metal": options.metalRoute = true
            default: throw BenchError.usage("--route bitmap|metal")
            }
        case "--json": options.jsonURL = URL(fileURLWithPath: try value(argument))
        case "--dump-dir": options.dumpDirectory = URL(fileURLWithPath: try value(argument))
        default:
            guard !argument.hasPrefix("--"), options.photo == nil else {
                throw BenchError.usage("不明な引数 \(argument)")
            }
            options.photo = URL(fileURLWithPath: argument)
        }
        index += 1
    }
    return options
}

// MARK: - Scenarios

struct Scenario {
    let name: String
    /// Settings after `tick` steps from `base` (tick 0 is `base`).
    let apply: (EditSettings, Int, Bool) -> EditSettings
}

func makeScenarios(asShotTemperatureTint: (temperature: Double, tint: Double)?) -> [Scenario] {
    func slider(_ name: String, _ step: Double, _ keyPath: WritableKeyPath<EditSettings, Double>) -> Scenario {
        Scenario(name: name) { base, tick, _ in
            var settings = base
            settings[keyPath: keyPath] += step * Double(tick)
            return settings
        }
    }
    func hsl(_ name: String, _ band: HSLBand, _ step: Double, _ keyPath: WritableKeyPath<HSLAdjustment, Double>) -> Scenario {
        Scenario(name: name) { base, tick, _ in
            var settings = base
            settings.hsl[band, default: HSLAdjustment()][keyPath: keyPath] += step * Double(tick)
            return settings
        }
    }
    func whiteBalance(_ name: String, temperatureStep: Double, tintStep: Double, relativeStep: Double) -> Scenario {
        Scenario(name: name) { base, tick, isRAW in
            var settings = base
            if isRAW {
                let start: (temperature: Double, tint: Double)
                if base.whiteBalance.mode == .custom,
                   let temperature = base.whiteBalance.temperature,
                   let tint = base.whiteBalance.tint {
                    start = (temperature, tint)
                } else {
                    start = asShotTemperatureTint ?? (5_500, 0)
                }
                settings.whiteBalance = WhiteBalanceSettings(
                    mode: .custom,
                    temperature: (start.temperature + temperatureStep * Double(tick)).rounded(),
                    tint: (start.tint + tintStep * Double(tick)).rounded()
                )
            } else if temperatureStep != 0 {
                settings.relativeTemperature += relativeStep * Double(tick)
            } else {
                settings.relativeTint += relativeStep * Double(tick)
            }
            return settings
        }
    }
    return [
        slider("exposure", 0.04, \.exposure),
        slider("contrast", 2, \.contrast),
        slider("highlights", -2, \.highlights),
        slider("shadows", 2, \.shadows),
        slider("whites", 2, \.whites),
        slider("blacks", -2, \.blacks),
        slider("texture", 2, \.texture),
        slider("clarity", 2, \.clarity),
        slider("dehaze", 2, \.dehaze),
        slider("vibrance", 2, \.vibrance),
        slider("saturation", 2, \.saturation),
        whiteBalance("temperature", temperatureStep: 60, tintStep: 0, relativeStep: 2),
        whiteBalance("tint", temperatureStep: 0, tintStep: 1, relativeStep: 1),
        slider("parametricDarks", 2, \.parametricDarks),
        Scenario(name: "curve") { base, tick, _ in
            var settings = base
            let composite = settings.toneCurves.first { $0.channel == .rgb }
            var points = composite?.points ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)]
            if points.count < 3 {
                points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)]
            }
            let middle = points.count / 2
            points[middle] = CurvePoint(x: points[middle].x, y: min(1, points[middle].y + 0.004 * Double(tick)))
            settings.toneCurves = settings.toneCurves.filter { $0.channel != .rgb } + [ToneCurve(channel: .rgb, points: points)]
            return settings
        },
        hsl("hslOrangeSaturation", .orange, 2, \.saturation),
        hsl("hslBlueHue", .blue, 2, \.hue),
        Scenario(name: "colorGrading") { base, tick, _ in
            var settings = base
            if settings.colorGrading.shadow.hue == 0 { settings.colorGrading.shadow.hue = 210 }
            settings.colorGrading.shadow.saturation = min(100, settings.colorGrading.shadow.saturation + 2 * Double(tick))
            return settings
        },
        Scenario(name: "calibrationRedHue") { base, tick, _ in
            var settings = base
            settings.calibration.redHue += 2 * Double(tick)
            return settings
        }
    ]
}

// MARK: - Display (the app's direct Metal route)

final class Display {
    let renderer: MetalPreviewRenderer
    let texture: MTLTexture

    init(width: Int, height: Int) throws {
        guard let renderer = MetalPreviewRenderer() else { throw BenchError.metalUnavailable }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalPreviewRenderer.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
            throw BenchError.metalUnavailable
        }
        self.renderer = renderer
        self.texture = texture
    }

    /// CPU encode, then commit and wait: (encode ms, commit-to-completed ms, GPU ms).
    func draw(_ frame: PreparedPreviewFrame) throws -> (encode: Double, wait: Double, gpu: Double) {
        let encodeStart = DispatchTime.now()
        let commandBuffer = try renderer.makeCommandBuffer()
        let task = try renderer.encodeAspectFit(frame: frame, to: texture, commandBuffer: commandBuffer)
        let encode = milliseconds(since: encodeStart)
        let waitStart = DispatchTime.now()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        _ = try task.waitUntilCompleted()
        let wait = milliseconds(since: waitStart)
        if let error = commandBuffer.error { throw BenchError.renderFailed(String(describing: error)) }
        return (encode, wait, (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000)
    }
}

/// The process's physical footprint (what Activity Monitor shows as memory), MB.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
}

// MARK: - Fidelity (same metric as `PreviewWorkingCopyTests.parity`)

struct EncodedFrame {
    let width: Int
    let height: Int
    var red: [Float]
    var green: [Float]
    var blue: [Float]
}

let readbackContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .cacheIntermediates: false
])

func readEncodedSRGB(_ frame: PreparedPreviewFrame) -> EncodedFrame {
    let width = Int(frame.extent.width)
    let height = Int(frame.extent.height)
    let count = width * height
    var rgba = [Float](repeating: 0, count: count * 4)
    rgba.withUnsafeMutableBytes { raw in
        readbackContext.render(
            frame.image, toBitmap: raw.baseAddress!, rowBytes: width * 16, bounds: frame.extent,
            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
    }
    var red = [Float](repeating: 0, count: count)
    var green = [Float](repeating: 0, count: count)
    var blue = [Float](repeating: 0, count: count)
    for index in 0..<count {
        red[index] = min(max(rgba[4 * index], 0), 1)
        green[index] = min(max(rgba[4 * index + 1], 0), 1)
        blue[index] = min(max(rgba[4 * index + 2], 0), 1)
    }
    return EncodedFrame(width: width, height: height, red: red, green: green, blue: blue)
}

func gaussianBlurred(_ plane: [Float], width: Int, height: Int) -> [Float] {
    let sigma: Float = 1.2
    let taps = (-5...5).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
    let total = taps.reduce(0, +)
    let kernel = taps.map { $0 / total }
    var source = plane
    var temporary = [Float](repeating: 0, count: plane.count)
    var destination = [Float](repeating: 0, count: plane.count)
    let rowBytes = width * MemoryLayout<Float>.size
    source.withUnsafeMutableBufferPointer { s in
        temporary.withUnsafeMutableBufferPointer { t in
            destination.withUnsafeMutableBufferPointer { d in
                var sourceBuffer = vImage_Buffer(
                    data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes
                )
                var temporaryBuffer = vImage_Buffer(
                    data: t.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes
                )
                var destinationBuffer = vImage_Buffer(
                    data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes
                )
                let flags = vImage_Flags(kvImageEdgeExtend)
                _ = vImageConvolve_PlanarF(&sourceBuffer, &temporaryBuffer, nil, 0, 0, kernel, 1, UInt32(kernel.count), 0, flags)
                _ = vImageConvolve_PlanarF(&temporaryBuffer, &destinationBuffer, nil, 0, 0, kernel, UInt32(kernel.count), 1, 0, flags)
            }
        }
    }
    return destination
}

func linearized(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
    func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return SIMD3(channel(encoded.x), channel(encoded.y), channel(encoded.z))
}

func lab(linear rgb: SIMD3<Double>) -> SIMD3<Double> {
    let x = (0.4124564 * rgb.x + 0.3575761 * rgb.y + 0.1804375 * rgb.z) / 0.95047
    let y = 0.2126729 * rgb.x + 0.7151522 * rgb.y + 0.0721750 * rgb.z
    let z = (0.0193339 * rgb.x + 0.1191920 * rgb.y + 0.9503041 * rgb.z) / 1.08883
    let delta = 6.0 / 29.0
    func f(_ t: Double) -> Double { t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0 }
    let fx = f(x), fy = f(y), fz = f(z)
    return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

func deltaE2000(_ lab1: SIMD3<Double>, _ lab2: SIMD3<Double>) -> Double {
    let radians = Double.pi / 180
    let pow25To7 = 6_103_515_625.0
    let c1 = (lab1.y * lab1.y + lab1.z * lab1.z).squareRoot()
    let c2 = (lab2.y * lab2.y + lab2.z * lab2.z).squareRoot()
    let cBar7 = pow((c1 + c2) / 2, 7)
    let g = 0.5 * (1 - (cBar7 / (cBar7 + pow25To7)).squareRoot())
    let ap1 = (1 + g) * lab1.y
    let ap2 = (1 + g) * lab2.y
    let cp1 = (ap1 * ap1 + lab1.z * lab1.z).squareRoot()
    let cp2 = (ap2 * ap2 + lab2.z * lab2.z).squareRoot()
    func hue(_ b: Double, _ ap: Double) -> Double {
        guard ap != 0 || b != 0 else { return 0 }
        let degrees = atan2(b, ap) / radians
        return degrees < 0 ? degrees + 360 : degrees
    }
    let hp1 = hue(lab1.z, ap1)
    let hp2 = hue(lab2.z, ap2)
    let dL = lab2.x - lab1.x
    let dC = cp2 - cp1
    var dhAngle = hp2 - hp1
    if cp1 * cp2 == 0 {
        dhAngle = 0
    } else if abs(dhAngle) > 180 {
        dhAngle -= dhAngle > 0 ? 360 : -360
    }
    let dH = 2 * (cp1 * cp2).squareRoot() * sin(dhAngle / 2 * radians)
    let lBar = (lab1.x + lab2.x) / 2
    let cpBar = (cp1 + cp2) / 2
    let hpSum = hp1 + hp2
    let hpBar: Double
    if cp1 * cp2 == 0 {
        hpBar = hpSum
    } else if abs(hp1 - hp2) <= 180 {
        hpBar = hpSum / 2
    } else if hpSum < 360 {
        hpBar = (hpSum + 360) / 2
    } else {
        hpBar = (hpSum - 360) / 2
    }
    let t = 1
        - 0.17 * cos((hpBar - 30) * radians)
        + 0.24 * cos(2 * hpBar * radians)
        + 0.32 * cos((3 * hpBar + 6) * radians)
        - 0.20 * cos((4 * hpBar - 63) * radians)
    let lOffset = (lBar - 50) * (lBar - 50)
    let sl = 1 + 0.015 * lOffset / (20 + lOffset).squareRoot()
    let sc = 1 + 0.045 * cpBar
    let sh = 1 + 0.015 * cpBar * t
    let hueDistance = (hpBar - 275) / 25
    let deltaTheta = 30 * exp(-hueDistance * hueDistance)
    let cpBar7 = pow(cpBar, 7)
    let rc = 2 * (cpBar7 / (cpBar7 + pow25To7)).squareRoot()
    let rt = -rc * sin(2 * deltaTheta * radians)
    let lTerm = dL / sl
    let cTerm = dC / sc
    let hTerm = dH / sh
    return (lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + rt * cTerm * hTerm).squareRoot()
}

struct Fidelity: Codable {
    var meanDeltaE: Double
    var p95DeltaE: Double
    var p99DeltaE: Double
    var maxDeltaE: Double
    var blurredMeanDeltaE: Double
    var blurredP95DeltaE: Double
}

func percentile(sorted values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let rank = fraction * Double(values.count - 1)
    let low = Int(rank.rounded(.down))
    let high = Int(rank.rounded(.up))
    return values[low] + (values[high] - values[low]) * (rank - Double(low))
}

final class CancelProbeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "running"
    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return stored }
}

struct SendableBuffers: @unchecked Sendable {
    let deltaE: UnsafeMutableBufferPointer<Double>
    let blurred: UnsafeMutableBufferPointer<Double>
}

/// Every pixel (no subsampling), plus the sigma 1.2 blurred variant.
func fidelity(reference: EncodedFrame, candidate: EncodedFrame) -> Fidelity {
    precondition(reference.width == candidate.width && reference.height == candidate.height)
    let width = reference.width
    let height = reference.height
    let blurred = [reference.red, reference.green, reference.blue, candidate.red, candidate.green, candidate.blue]
        .map { gaussianBlurred($0, width: width, height: height) }
    let count = width * height
    let deltaEBuffer = UnsafeMutableBufferPointer<Double>.allocate(capacity: count)
    let blurredBuffer = UnsafeMutableBufferPointer<Double>.allocate(capacity: count)
    defer {
        deltaEBuffer.deallocate()
        blurredBuffer.deallocate()
    }
    let outputs = SendableBuffers(deltaE: deltaEBuffer, blurred: blurredBuffer)
    // Each row writes only its own slice of the two buffers.
    DispatchQueue.concurrentPerform(iterations: height) { y in
        for x in 0..<width {
            let index = y * width + x
            let ref = SIMD3(Double(reference.red[index]), Double(reference.green[index]), Double(reference.blue[index]))
            let can = SIMD3(Double(candidate.red[index]), Double(candidate.green[index]), Double(candidate.blue[index]))
            outputs.deltaE[index] = deltaE2000(lab(linear: linearized(ref)), lab(linear: linearized(can)))
            let refBlur = SIMD3(Double(blurred[0][index]), Double(blurred[1][index]), Double(blurred[2][index]))
            let canBlur = SIMD3(Double(blurred[3][index]), Double(blurred[4][index]), Double(blurred[5][index]))
            outputs.blurred[index] = deltaE2000(lab(linear: linearized(refBlur)), lab(linear: linearized(canBlur)))
        }
    }
    var deltaE = Array(deltaEBuffer)
    var blurredDeltaE = Array(blurredBuffer)
    let mean = deltaE.reduce(0, +) / Double(deltaE.count)
    let blurredMean = blurredDeltaE.reduce(0, +) / Double(blurredDeltaE.count)
    deltaE.sort()
    blurredDeltaE.sort()
    return Fidelity(
        meanDeltaE: mean, p95DeltaE: percentile(sorted: deltaE, 0.95), p99DeltaE: percentile(sorted: deltaE, 0.99),
        maxDeltaE: deltaE.last ?? 0,
        blurredMeanDeltaE: blurredMean, blurredP95DeltaE: percentile(sorted: blurredDeltaE, 0.95)
    )
}

func writePNG(_ frame: EncodedFrame, to url: URL) throws {
    let count = frame.width * frame.height
    var bytes = [UInt8](repeating: 255, count: count * 4)
    for index in 0..<count {
        bytes[4 * index] = UInt8((frame.red[index] * 255).rounded())
        bytes[4 * index + 1] = UInt8((frame.green[index] * 255).rounded())
        bytes[4 * index + 2] = UInt8((frame.blue[index] * 255).rounded())
    }
    let image = CIImage(
        bitmapData: Data(bytes), bytesPerRow: frame.width * 4,
        size: CGSize(width: frame.width, height: frame.height), format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
    try readbackContext.writePNGRepresentation(
        of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
}

func writeRaw(_ frame: EncodedFrame, to url: URL) throws {
    var data = Data(capacity: frame.red.count * 12)
    for plane in [frame.red, frame.green, frame.blue] {
        plane.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
    }
    try data.write(to: url)
}

// MARK: - Measurement

struct TickTiming: Codable {
    var prepare: Double
    var displayEncode: Double
    var displayWait: Double
    var displayGPU: Double
    var total: Double
    var steps: [String: Double]
}

struct ScenarioResult: Codable {
    var name: String
    var ticks: [TickTiming]
    var settle: TickTiming?
    var footprintMB: Double?
    var dragVersusSettled: Fidelity?
}

struct Report: Codable {
    var photo: String
    var preset: String?
    var host: String
    var mode: String
    var route: String
    var displaySize: [Int]
    var decodeMilliseconds: Double
    var workingCopyMilliseconds: Double
    var open: TickTiming
    var scenarios: [ScenarioResult]
}

func summarize(_ records: [PreviewDiagnostics.Record]) -> [String: Double] {
    var steps: [String: Double] = [:]
    for record in records where record.label != "prepare" {
        steps[record.label, default: 0] += record.milliseconds
    }
    return steps
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

func run() throws {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard let photo = options.photo else {
        throw BenchError.usage("photobench-preview-bench <photo> [--preset <xmp>] [--scenarios a,b] [--ticks N] [--display WxH] [--json out] [--dump-dir dir]")
    }
    let base: EditSettings = try options.preset.map {
        try XMPPresetParser.parse(url: $0).applying(to: .neutral)
    } ?? .neutral

    PreviewDiagnostics.setCollecting(true)
    let engine = RenderEngine()
    let decodeStart = DispatchTime.now()
    var decoded: DecodedPhoto? = try PhotoDecoder().decode(url: photo)
    let decodeMilliseconds = milliseconds(since: decodeStart)
    let copyStart = DispatchTime.now()
    let workingCopy = try engine.makePreviewWorkingCopy(from: decoded!)
    let copyMilliseconds = milliseconds(since: copyStart)
    let isRAW = workingCopy.info.isRAW
    let asShot = workingCopy.info.asShotWhiteXY.map { ColorSpec.temperatureAndTint(fromXY: $0) }
    decoded = nil
    _ = PreviewDiagnostics.drain()
    print(String(
        format: "photo %@ %dx%d (%@) decode %.0fms, working copy %dx%d %.0fms",
        photo.lastPathComponent, workingCopy.info.nativeWidth, workingCopy.info.nativeHeight,
        workingCopy.info.backend, decodeMilliseconds, workingCopy.info.width, workingCopy.info.height, copyMilliseconds
    ))

    let display = try Display(width: options.displayWidth, height: options.displayHeight)

    // Each tick drains its own autorelease pool, as the app's run loop and
    // render tasks do (without it, Core Image/Metal objects of every tick
    // pile up and the footprint grows ~75 MB per spatial pass).
    func tick(_ settings: EditSettings, drag: PreviewDragSession? = nil) throws -> (TickTiming, PreparedPreviewFrame) {
        try autoreleasepool { try tickBody(settings, drag: drag) }
    }

    func tickBody(_ settings: EditSettings, drag: PreviewDragSession?) throws -> (TickTiming, PreparedPreviewFrame) {
        _ = PreviewDiagnostics.drain()
        let start = DispatchTime.now()
        let frame = try engine.preparePreviewFromWorkingCopy(
            workingCopy: workingCopy, settings: settings, quality: .interactive, drag: drag
        )
        let prepare = milliseconds(since: start)
        let drawn: (encode: Double, wait: Double, gpu: Double)
        if options.metalRoute {
            drawn = try display.draw(frame)
        } else {
            let materializeStart = DispatchTime.now()
            let rendered = try engine.materializePreview(frame)
            _ = rendered.image.size
            drawn = (0, milliseconds(since: materializeStart), 0)
        }
        let total = milliseconds(since: start)
        let timing = TickTiming(
            prepare: prepare, displayEncode: drawn.encode, displayWait: drawn.wait, displayGPU: drawn.gpu,
            total: total, steps: summarize(PreviewDiagnostics.drain())
        )
        return (timing, frame)
    }

    func describe(_ timing: TickTiming) -> String {
        let steps = timing.steps.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.0f", $0.value))" }
            .joined(separator: " ")
        return String(
            format: "total %4.0fms prepare %4.0f display %3.0f+%3.0f (gpu %3.0f) | ",
            timing.total, timing.prepare, timing.displayEncode, timing.displayWait, timing.displayGPU
        ) + steps
    }

    let (open, _) = try tick(base)
    print("open: " + describe(open))

    let allScenarios = makeScenarios(asShotTemperatureTint: asShot)
    let selected = options.scenarios.map { names in allScenarios.filter { names.contains($0.name) } } ?? allScenarios
    var results: [ScenarioResult] = []
    for scenario in selected {
        // The state the drag starts from, already on screen.
        _ = try tick(base)
        let session = options.dragMode ? PreviewDragSession(startSettings: base) : nil
        var ticks: [TickTiming] = []
        var lastFrame: PreparedPreviewFrame?
        for index in 1...options.ticks {
            let (timing, frame) = try tick(scenario.apply(base, index, isRAW), drag: session)
            ticks.append(timing)
            lastFrame = frame
        }
        // Release: the exact frame the app swaps in (drag mode); in exact
        // mode the last tick already is that frame.
        var settle: TickTiming?
        var exactFrame = lastFrame
        var dragVersusSettled: Fidelity?
        if options.dragMode, options.cancelProbe {
            let cancellation = PreviewCancellation()
            let settings = scenario.apply(base, options.ticks, isRAW)
            let done = DispatchSemaphore(value: 0)
            let start = DispatchTime.now()
            let outcome = CancelProbeOutcome()
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        _ = try engine.preparePreviewFromWorkingCopy(
                            workingCopy: workingCopy, settings: settings, quality: .interactive, cancellation: cancellation
                        )
                        outcome.set("completed")
                    } catch is CancellationError {
                        outcome.set("cancelled")
                    } catch {
                        outcome.set("error \(error)")
                    }
                }
                done.signal()
            }
            Thread.sleep(forTimeInterval: 0.040)
            let cancelAt = DispatchTime.now()
            cancellation.cancel()
            done.wait()
            print(String(
                format: "    cancel probe: %@ %.0fms after cancel (cancelled at %.0fms)",
                outcome.value as NSString, milliseconds(since: cancelAt),
                Double(cancelAt.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
            ))
            _ = PreviewDiagnostics.drain()
        }
        if options.dragMode, let lastFrame {
            let (timing, frame) = try tick(scenario.apply(base, options.ticks, isRAW))
            settle = timing
            exactFrame = frame
            dragVersusSettled = autoreleasepool {
                fidelity(reference: readEncodedSRGB(frame), candidate: readEncodedSRGB(lastFrame))
            }
        }
        let totals = ticks.map(\.total)
        var stepMedians: [String: Double] = [:]
        for key in Set(ticks.flatMap { $0.steps.keys }) {
            stepMedians[key] = median(ticks.map { $0.steps[key] ?? 0 })
        }
        let stepText = stepMedians.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.0f", $0.value))" }.joined(separator: " ")
        print(String(
            format: "%-20@ tick median %4.0fms (min %4.0f max %4.0f) prepare %4.0f display %3.0f | ",
            scenario.name as NSString, median(totals), totals.min() ?? 0, totals.max() ?? 0,
            median(ticks.map(\.prepare)), median(ticks.map { $0.displayEncode + $0.displayWait })
        ) + stepText)
        if let settle {
            print("    settle: " + describe(settle))
        }
        print(String(format: "    footprint %.0f MB", footprintMB()))
        if let dragVersusSettled {
            print(String(
                format: "    drag vs settled ΔE00 mean %.3f p95 %.3f p99 %.3f max %.2f | blurred mean %.3f p95 %.3f",
                dragVersusSettled.meanDeltaE, dragVersusSettled.p95DeltaE, dragVersusSettled.p99DeltaE,
                dragVersusSettled.maxDeltaE, dragVersusSettled.blurredMeanDeltaE, dragVersusSettled.blurredP95DeltaE
            ))
        }
        if let dumpDirectory = options.dumpDirectory, let lastFrame, let exactFrame {
            try FileManager.default.createDirectory(at: dumpDirectory, withIntermediateDirectories: true)
            try writePNG(readEncodedSRGB(lastFrame), to: dumpDirectory.appendingPathComponent("\(scenario.name)-last-tick.png"))
            let exact = readEncodedSRGB(exactFrame)
            try writePNG(exact, to: dumpDirectory.appendingPathComponent("\(scenario.name)-exact.png"))
            try writeRaw(exact, to: dumpDirectory.appendingPathComponent("\(scenario.name)-exact.f32"))
        }
        results.append(ScenarioResult(
            name: scenario.name, ticks: ticks, settle: settle, footprintMB: footprintMB(),
            dragVersusSettled: dragVersusSettled
        ))
    }

    if let jsonURL = options.jsonURL {
        let report = Report(
            photo: photo.lastPathComponent, preset: options.preset?.lastPathComponent,
            host: ProcessInfo.processInfo.hostName,
            mode: options.dragMode ? "drag" : "exact",
            route: options.metalRoute ? "metal" : "bitmap",
            displaySize: [options.displayWidth, options.displayHeight],
            decodeMilliseconds: decodeMilliseconds, workingCopyMilliseconds: copyMilliseconds,
            open: open, scenarios: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: jsonURL)
        print("json -> \(jsonURL.path)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("エラー: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))\n".utf8))
    exit(1)
}

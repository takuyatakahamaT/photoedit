import AppKit
import Metal
import MetalKit
import PhotoCore
import QuartzCore
import SwiftUI
import os

struct ContentView: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                libraryPane
                Divider()
                centerPane
                Divider()
                inspectorPane
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("フォルダを開く", action: model.chooseFolder)
                .disabled(!model.canChooseFolder)
            Button("XMPを読み込む", action: model.importPreset)
                .disabled(model.isBusy)
            Divider().frame(height: 18)
            Text(model.selectedAsset?.filename ?? "写真を選択")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if model.decodeInfo?.isRAW == true {
                Label("RAW", systemImage: "camera.aperture")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if let info = model.decodeInfo, info.isRAW {
                let isCalibratedDCS5 = info.calibrationID
                    == RAWCalibrationProfile.panasonicDCS5Lightroom93.id
                Text(isCalibratedDCS5 ? "DC-S5 色差試験（白飛び未校正）" : "機種別の色は未校正")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
            }
            if model.preset != nil {
                Text("XMP近似・未校正")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.yellow.opacity(0.16), in: Capsule())
                    .foregroundStyle(.yellow)
            }
            if model.previewRoute == .metalDirect {
                Text("Metal直接表示・検証中")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.16), in: Capsule())
                    .foregroundStyle(.blue)
            }
            Button("JPEGを書き出す", action: model.exportFromPanel)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("写真")
                    .font(.headline)
                Text(model.rootURL?.path ?? "写真フォルダを選択してください")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            Divider()
            List(model.assets, selection: $model.selectedAssetID) { asset in
                HStack(spacing: 8) {
                    Image(systemName: asset.kind == .raw ? "camera.aperture" : "photo")
                        .foregroundStyle(asset.kind == .raw ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.filename)
                            .lineLimit(1)
                        Text(asset.kind.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(asset.id)
            }
            .listStyle(.sidebar)
            .disabled(model.isBusy)
        }
        .frame(width: 230)
    }

    private var centerPane: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.82)
                if model.previewRoute == .metalDirect,
                   let request = model.directPreviewRequest {
                    DirectMetalPreviewView(
                        request: request,
                        onPresented: model.directPreviewPresented,
                        onCoalesced: model.directPreviewCoalesced,
                        onDrawableUnavailable: model.directPreviewDrawableUnavailable,
                        onDropped: model.directPreviewDropped,
                        onFailure: model.directPreviewFailed
                    )
                    .padding(20)
                } else if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .padding(20)
            } else if model.isBusy || model.hasPreviewInFlight {
                ProgressView("プレビューを準備中…")
                } else {
                    ContentUnavailableView("写真がありません", systemImage: "photo")
                }
            }
            filmstrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(model.assets) { asset in
                    Button {
                        model.selectedAssetID = asset.id
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(asset.kind == .raw ? Color.orange.opacity(0.18) : Color.white.opacity(0.08))
                                Image(systemName: asset.kind == .raw ? "camera.aperture" : "photo")
                                    .font(.title2)
                            }
                            .frame(width: 74, height: 48)
                            .overlay {
                                if model.selectedAssetID == asset.id {
                                    RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 2)
                                }
                            }
                            Text(asset.filename)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 86)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                }
            }
            .padding(10)
        }
        .frame(height: 86)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今の写真")
                        .font(.headline)
                    if let info = model.decodeInfo {
                        LabeledContent("デコード", value: info.backend)
                        LabeledContent("解像度", value: "\(info.width) × \(info.height)")
                        if let cameraModel = info.cameraModel {
                            LabeledContent("カメラ", value: cameraModel)
                        }
                        if let calibrationLabel = info.calibrationLabel, info.isRAW {
                            LabeledContent("RAW基準", value: calibrationLabel)
                        }
                        LabeledContent("読込", value: String(format: "%.0f ms", info.durationMilliseconds))
                    }
                    if let render = model.renderMilliseconds {
                        LabeledContent(
                            model.previewRoute == .metalDirect ? "入力→実表示" : "プレビュー生成",
                            value: String(format: "%.0f ms", render)
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("一発調整").font(.headline)
                        Spacer()
                        Button("リセット", action: model.resetAdjustments)
                            .buttonStyle(.link)
                    }
                    adjustmentSlider("露出", value: $model.settings.exposure, range: -5...5, format: "%.2f")
                    adjustmentSlider("コントラスト", value: $model.settings.contrast, range: -100...100, format: "%.0f")
                    adjustmentSlider("ハイライト", value: $model.settings.highlights, range: -100...100, format: "%.0f")
                    adjustmentSlider("シャドウ", value: $model.settings.shadows, range: -100...100, format: "%.0f")
                    adjustmentSlider("白レベル", value: $model.settings.whites, range: -100...100, format: "%.0f")
                    adjustmentSlider("黒レベル", value: $model.settings.blacks, range: -100...100, format: "%.0f")
                    adjustmentSlider("自然な彩度", value: $model.settings.vibrance, range: -100...100, format: "%.0f")
                    adjustmentSlider("彩度", value: $model.settings.saturation, range: -100...100, format: "%.0f")
                }
                .disabled(model.isBusy)

                if let preset = model.preset {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("プリセット").font(.headline)
                        Text(preset.name).font(.subheadline.weight(.semibold))
                        Text("Process \(preset.processVersion ?? "不明") / Camera Raw \(preset.cameraRawVersion ?? "不明")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let supported = preset.compatibility.filter { $0.level == .supported }.count
                        let approximate = preset.compatibility.filter { $0.level == .approximate }.count
                        let unsupported = preset.compatibility.filter { $0.level == .unsupported }.count
                        Text("対応 \(supported) ・ 近似 \(approximate) ・ 未対応 \(unsupported)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("HSL・カーブ近似を適用（未校正）", isOn: $model.applyApproximateXMPColor)
                            .font(.caption)
                            .onChange(of: model.applyApproximateXMPColor) { _, _ in model.scheduleRender() }
                            .disabled(model.isBusy)
                        DisclosureGroup("互換性の詳細") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(preset.compatibility.filter { $0.level != .metadata }) { item in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(item.level.rawValue)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(color(for: item.level))
                                            .frame(width: 36, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.property).font(.caption)
                                            Text("\(item.value) — \(item.note)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 318)
    }

    private var statusBar: some View {
        HStack {
            if model.isBusy { ProgressView().controlSize(.small) }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("編集は終了時に消えます ・ 原本は上書きしません")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("・プレビュー/書き出し: sRGB")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if model.previewRoute == .metalDirect {
                Text("・present \(model.directPresentedCount) / coalesce \(model.directCoalescedCount) / drawable nil \(model.directDrawableUnavailableCount) / drop \(model.directDroppedCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func adjustmentSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, _ in model.scheduleRender() }
        }
    }

    private func color(for level: CompatibilityLevel) -> Color {
        switch level {
        case .supported: .green
        case .approximate: .yellow
        case .unsupported: .red
        case .metadata: .secondary
        }
    }
}

/// Opt-in presentation surface used while the direct route is under formal
/// acceptance. It is event-driven, keeps at most one GPU frame in flight and
/// one pending frame, and never waits for the GPU on the main thread.
private let directPreviewProbeLog = Logger(
    subsystem: "life.niho.photobench",
    category: "metal-probe"
)

private struct DirectMetalPreviewView: NSViewRepresentable {
    let request: DirectPreviewRequest
    let onPresented: (UInt64, CFTimeInterval) -> Void
    let onCoalesced: (UInt64) -> Void
    let onDrawableUnavailable: (UInt64) -> Void
    let onDropped: (UInt64) -> Void
    let onFailure: (UInt64, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPresented: onPresented,
            onCoalesced: onCoalesced,
            onDrawableUnavailable: onDrawableUnavailable,
            onDropped: onDropped,
            onFailure: onFailure
        )
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.updateCallbacks(
            onPresented: onPresented,
            onCoalesced: onCoalesced,
            onDrawableUnavailable: onDrawableUnavailable,
            onDropped: onDropped,
            onFailure: onFailure
        )
        context.coordinator.submit(request, to: view)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private static let presentationLog = OSLog(
            subsystem: "life.niho.photobench",
            category: "presentation"
        )
        private let renderer: MetalPreviewRenderer?
        private let probeConfiguration: MetalPresentationProbeConfiguration
        private let probeRunID = UUID().uuidString
        private var lifecycle = DirectPreviewLifecycle()
        private var requests: [UInt64: DirectPreviewRequest] = [:]
        private var probeAttempt: UInt64 = 0
        private var inFlightCompletion: DirectPreviewSubmissionArbiter?
        private var inFlightCompletionRequestID: UInt64?
        private var deliveryWatchdogTask: Task<Void, Never>?
        private var deliveryWatchdogToken: DirectPreviewLifecycle.Token?
        private var redrawRetryTask: Task<Void, Never>?
        private var redrawRetryToken: DirectPreviewLifecycle.Token?
        private weak var view: MTKView?
        private weak var observedWindow: NSWindow?

        private var onPresented: (UInt64, CFTimeInterval) -> Void
        private var onCoalesced: (UInt64) -> Void
        private var onDrawableUnavailable: (UInt64) -> Void
        private var onDropped: (UInt64) -> Void
        private var onFailure: (UInt64, String) -> Void

        init(
            onPresented: @escaping (UInt64, CFTimeInterval) -> Void,
            onCoalesced: @escaping (UInt64) -> Void,
            onDrawableUnavailable: @escaping (UInt64) -> Void,
            onDropped: @escaping (UInt64) -> Void,
            onFailure: @escaping (UInt64, String) -> Void
        ) {
            renderer = MetalPreviewRenderer()
            probeConfiguration = MetalPresentationProbeConfiguration()
            self.onPresented = onPresented
            self.onCoalesced = onCoalesced
            self.onDrawableUnavailable = onDrawableUnavailable
            self.onDropped = onDropped
            self.onFailure = onFailure
            super.init()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive(_:)),
                name: NSApplication.didBecomeActiveNotification,
                object: NSApplication.shared
            )

            if let invalidValue = probeConfiguration.invalidValue {
                directPreviewProbeLog.error(
                    "invalid configuration value=\(invalidValue, privacy: .public); using production/on-demand"
                )
            }
        }

        func makeView() -> MTKView {
            let metalView = DirectPreviewMTKView(frame: .zero, device: renderer?.device)
            view = metalView
            metalView.didMoveToWindowHandler = { [weak self, weak metalView] in
                guard let self, let metalView else { return }
                self.observeWindowIfNeeded(for: metalView)
                self.updateSurface(for: metalView)
                // Moving between windows recreates the presentation surface
                // even when its visibility and pixel size are unchanged.
                self.send(.drawableSizeChanged(
                    isValid: metalView.drawableSize.width > 0
                        && metalView.drawableSize.height > 0
                ))
                // SwiftUI can attach the view before AppKit has published the
                // initial occlusion state. Reconcile once after one compositor
                // tick so a newly opened visible window cannot remain idle
                // until the user minimizes or moves it.
                Task { @MainActor [weak self, weak metalView] in
                    do {
                        try await Task.sleep(for: .milliseconds(16))
                    } catch {
                        return
                    }
                    guard let self, let metalView else { return }
                    self.updateSurface(for: metalView)
                }
            }
            metalView.delegate = self
            metalView.framebufferOnly = false
            metalView.colorPixelFormat = MetalPreviewRenderer.pixelFormat
            metalView.colorspace = MetalPreviewRenderer.outputColorSpace
            metalView.sampleCount = 1
            metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
            switch probeConfiguration.mode.drawingMode {
            case .onDemand:
                metalView.isPaused = true
                metalView.enableSetNeedsDisplay = true
            case .continuous:
                metalView.enableSetNeedsDisplay = false
                metalView.isPaused = false
            }
            metalView.autoResizeDrawable = true
            metalView.layer?.isOpaque = true
            if let metalLayer = metalView.layer as? CAMetalLayer {
                metalLayer.wantsExtendedDynamicRangeContent = false
                metalLayer.allowsNextDrawableTimeout = true
            }
            if probeConfiguration.isExplicit {
                directPreviewProbeLog.notice(
                    "configured run=\(self.probeRunID, privacy: .public) mode=\(self.probeConfiguration.mode.rawValue, privacy: .public) paused=\(metalView.isPaused, privacy: .public) setNeedsDisplay=\(metalView.enableSetNeedsDisplay, privacy: .public) fps=\(metalView.preferredFramesPerSecond, privacy: .public)"
                )
            }
            return metalView
        }

        func updateCallbacks(
            onPresented: @escaping (UInt64, CFTimeInterval) -> Void,
            onCoalesced: @escaping (UInt64) -> Void,
            onDrawableUnavailable: @escaping (UInt64) -> Void,
            onDropped: @escaping (UInt64) -> Void,
            onFailure: @escaping (UInt64, String) -> Void
        ) {
            self.onPresented = onPresented
            self.onCoalesced = onCoalesced
            self.onDrawableUnavailable = onDrawableUnavailable
            self.onDropped = onDropped
            self.onFailure = onFailure
        }

        func submit(_ request: DirectPreviewRequest, to view: MTKView) {
            if let latestID = lifecycle.queue.latestID, request.id <= latestID { return }
            observeWindowIfNeeded(for: view)
            updateSurface(for: view)
            requests[request.id] = request
            send(.submit(request.id))
            if renderer == nil {
                send(.failLatest(
                    requestID: request.id,
                    failure: .rendererUnavailable(
                        MetalPreviewRendererError.commandQueueUnavailable
                            .localizedDescription
                    )
                ))
            }
        }

        func draw(in view: MTKView) {
            autoreleasepool {
                observeWindowIfNeeded(for: view)
                updateSurface(for: view)
                guard lifecycle.queue.inFlightID == nil,
                      let requestID = lifecycle.queue.pendingID
                else { return }
                probeAttempt &+= 1
                if probeConfiguration.isExplicit {
                    directPreviewProbeLog.debug(
                        "draw run=\(self.probeRunID, privacy: .public) mode=\(self.probeConfiguration.mode.rawValue, privacy: .public) request=\(requestID, privacy: .public) attempt=\(self.probeAttempt, privacy: .public) visible=\(self.isVisible(view), privacy: .public) width=\(view.drawableSize.width, privacy: .public) height=\(view.drawableSize.height, privacy: .public)"
                    )
                }
                os_signpost(
                    .event,
                    log: Self.presentationLog,
                    name: "PreviewDrawStarted",
                    "request=%{public}llu visible=%{public}d width=%{public}.0f height=%{public}.0f",
                    requestID,
                    isVisible(view) ? 1 : 0,
                    view.drawableSize.width,
                    view.drawableSize.height
                )
                guard lifecycle.surface.isReady else { return }
                guard requests[requestID] != nil else {
                    send(.failLatest(
                        requestID: requestID,
                        failure: .submission("Metal表示用フレームが失われました。")
                    ))
                    return
                }
                guard let drawable = view.currentDrawable else {
                    send(.drawAttempted(
                        requestID: requestID,
                        drawableAvailable: false
                    ))
                    return
                }
                send(
                    .drawAttempted(
                        requestID: requestID,
                        drawableAvailable: true
                    ),
                    drawable: drawable
                )
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            let visible = isVisible(view)
            if lifecycle.surface.isVisible != visible {
                send(.surfaceChanged(
                    isVisible: visible,
                    hasDrawableSize: lifecycle.surface.hasDrawableSize
                ))
            }
            send(.drawableSizeChanged(
                isValid: size.width > 0 && size.height > 0
            ))
        }

        func tearDown() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            (view as? DirectPreviewMTKView)?.didMoveToWindowHandler = nil
            send(.tearDown)
            view = nil
        }

        private func observeWindowIfNeeded(for view: MTKView) {
            guard observedWindow !== view.window else { return }
            if let previousWindow = observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: previousWindow
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didBecomeKeyNotification,
                    object: previousWindow
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didMiniaturizeNotification,
                    object: previousWindow
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didDeminiaturizeNotification,
                    object: previousWindow
                )
            }
            observedWindow = view.window
            guard let observedWindow else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged(_:)),
                name: NSWindow.didMiniaturizeNotification,
                object: observedWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityChanged(_:)),
                name: NSWindow.didDeminiaturizeNotification,
                object: observedWindow
            )
        }

        private func commandBufferCompleted(
            requestID: UInt64,
            statusRawValue: Int,
            resolution: DirectPreviewSubmissionArbiter.Resolution?
        ) {
            os_signpost(
                .event,
                log: Self.presentationLog,
                name: "PreviewGPUCompleted",
                "request=%{public}llu status=%{public}d",
                requestID,
                statusRawValue
            )
            guard let resolution else { return }
            submissionResolved(requestID: requestID, resolution: resolution)
        }

        private func submissionResolved(
            requestID: UInt64,
            resolution: DirectPreviewSubmissionArbiter.Resolution
        ) {
            switch resolution {
            case .presentation(let presentedTime):
                send(.presentationClaimed(
                    requestID: requestID,
                    presentedTime: presentedTime
                ))
            case .gpuFailure(let message):
                send(.gpuFailureClaimed(
                    requestID: requestID,
                    message: message ?? "Metal command buffer error"
                ))
            }
        }

        @objc private func windowVisibilityChanged(_ notification: Notification) {
            guard let view else { return }
            updateSurface(for: view)
        }

        @objc private func applicationDidBecomeActive(_ notification: Notification) {
            guard let view else { return }
            updateSurface(for: view)
        }

        private func isVisible(_ view: MTKView) -> Bool {
            guard let window = view.window,
                  !window.isMiniaturized,
                  window.occlusionState.contains(.visible),
                  !view.isHiddenOrHasHiddenAncestor
            else { return false }
            return true
        }

        private func updateSurface(for view: MTKView) {
            let surface = DirectPreviewLifecycle.Surface(
                isVisible: isVisible(view),
                hasDrawableSize: view.drawableSize.width > 0
                    && view.drawableSize.height > 0
            )
            if probeConfiguration.isExplicit, lifecycle.surface != surface {
                directPreviewProbeLog.info(
                    "surface run=\(self.probeRunID, privacy: .public) mode=\(self.probeConfiguration.mode.rawValue, privacy: .public) visible=\(surface.isVisible, privacy: .public) drawable=\(surface.hasDrawableSize, privacy: .public) windowVisible=\(view.window?.isVisible ?? false, privacy: .public) miniaturized=\(view.window?.isMiniaturized ?? false, privacy: .public) occlusion=\(view.window?.occlusionState.rawValue ?? 0, privacy: .public)"
                )
            }
            guard lifecycle.surface != surface else { return }
            send(.surfaceChanged(
                isVisible: surface.isVisible,
                hasDrawableSize: surface.hasDrawableSize
            ))
        }

        private func send(
            _ event: DirectPreviewLifecycle.Event,
            drawable: CAMetalDrawable? = nil
        ) {
            let effects = lifecycle.reduce(event)
            handle(effects, drawable: drawable)
        }

        private func handle(
            _ effects: [DirectPreviewLifecycle.Effect],
            drawable: CAMetalDrawable?
        ) {
            for effect in effects {
                switch effect {
                case .requestDisplay(let requestID):
                    os_signpost(
                        .event,
                        log: Self.presentationLog,
                        name: "PreviewDrawRequested",
                        "request=%{public}llu",
                        requestID
                    )
                    view?.setNeedsDisplay(view?.bounds ?? .zero)

                case .beginSubmission(let requestID):
                    guard let drawable else {
                        send(.submissionFailed(
                            requestID: requestID,
                            failure: .submission("Metal drawableが失われました。")
                        ))
                        continue
                    }
                    beginSubmission(requestID: requestID, drawable: drawable)

                case .scheduleRetry(let token, let milliseconds):
                    scheduleRetry(token: token, milliseconds: milliseconds)

                case .cancelRetry(let token):
                    cancelRetry(token: token)

                case .scheduleDeadline(let token, let milliseconds):
                    scheduleDeadline(token: token, milliseconds: milliseconds)

                case .cancelDeadline(let token):
                    cancelDeadline(token: token)

                case .claimSubmissionForDeadline(let requestID, let token):
                    let won: Bool
                    if inFlightCompletionRequestID == requestID,
                       let inFlightCompletion {
                        won = inFlightCompletion.claimDeadline()
                        if won {
                            self.inFlightCompletion = nil
                            inFlightCompletionRequestID = nil
                        }
                    } else {
                        // The reducer believes this request is in flight. If
                        // its completion owner is missing, fail closed instead
                        // of leaving the direct route permanently pending.
                        let actualID = inFlightCompletionRequestID
                            .map(String.init) ?? "nil"
                        directPreviewProbeLog.fault(
                            "in-flight/completion desync expectedRequest=\(requestID, privacy: .public) actualRequest=\(actualID, privacy: .public) hasCompletion=\(self.inFlightCompletion != nil, privacy: .public)"
                        )
                        assertionFailure("in-flight/completion desync")
                        won = true
                    }
                    if probeConfiguration.isExplicit {
                        directPreviewProbeLog.error(
                            "deadline run=\(self.probeRunID, privacy: .public) mode=\(self.probeConfiguration.mode.rawValue, privacy: .public) request=\(requestID, privacy: .public) completionClaimWon=\(won, privacy: .public)"
                        )
                    }
                    send(.deadlineClaimResolved(token, won: won))

                case .invalidateSubmission(let requestID):
                    guard inFlightCompletionRequestID == requestID else { continue }
                    inFlightCompletion?.invalidate()
                    inFlightCompletion = nil
                    inFlightCompletionRequestID = nil

                case .reportCoalesced(let requestID):
                    onCoalesced(requestID)

                case .reportDrawableUnavailable(let requestID):
                    onDrawableUnavailable(requestID)

                case .reportDropped(let requestID):
                    if probeConfiguration.isExplicit {
                        directPreviewProbeLog.warning(
                            "dropped run=\(self.probeRunID, privacy: .public) mode=\(self.probeConfiguration.mode.rawValue, privacy: .public) request=\(requestID, privacy: .public)"
                        )
                    }
                    onDropped(requestID)

                case .reportPresented(let requestID, let presentedTime):
                    if probeConfiguration.isExplicit {
                        directPreviewProbeLog.notice(
                            "result=positive run=\(self.probeRunID, privacy: .public) mode=\(self.probeConfiguration.mode.rawValue, privacy: .public) request=\(requestID, privacy: .public) presentedTime=\(presentedTime, privacy: .public)"
                        )
                    }
                    onPresented(requestID, presentedTime)

                case .reportFailure(let requestID, let failure):
                    if probeConfiguration.isExplicit {
                        directPreviewProbeLog.error(
                            "result=fallback run=\(self.probeRunID, privacy: .public) mode=\(self.probeConfiguration.mode.rawValue, privacy: .public) request=\(requestID, privacy: .public) reason=\(failure.message, privacy: .public)"
                        )
                    }
                    onFailure(requestID, failure.message)

                case .discardPayload(let requestID):
                    requests[requestID] = nil

                case .discardAllPayloads:
                    requests.removeAll(keepingCapacity: false)

                case .clearRendererCaches:
                    renderer?.clearCaches()
                }
            }
        }

        private func beginSubmission(
            requestID: UInt64,
            drawable: CAMetalDrawable
        ) {
            guard let request = requests[requestID], let renderer else {
                send(.submissionFailed(
                    requestID: requestID,
                    failure: .submission("Metal表示用フレームを開始できません。")
                ))
                return
            }

            do {
                let commandBuffer = try renderer.makeCommandBuffer()
                switch probeConfiguration.mode.payload {
                case .metalClear:
                    try renderer.encodeDiagnosticMetalClear(
                        to: drawable.texture,
                        commandBuffer: commandBuffer
                    )
                case .ciSolid:
                    _ = try renderer.encodeDiagnosticCISolid(
                        to: drawable.texture,
                        commandBuffer: commandBuffer
                    )
                case .production:
                    _ = try renderer.encodeAspectFit(
                        frame: request.frame,
                        to: drawable.texture,
                        commandBuffer: commandBuffer
                    )
                }
                let completion = DirectPreviewSubmissionArbiter()
                inFlightCompletion = completion
                inFlightCompletionRequestID = requestID
                let probeIsExplicit = probeConfiguration.isExplicit
                let probeMode = probeConfiguration.mode.rawValue
                let probeRunID = self.probeRunID
                let probeAttempt = self.probeAttempt

                drawable.addPresentedHandler { [weak self] presentedDrawable in
                    let presentedTime = presentedDrawable.presentedTime
                    let resolution = completion.observePresentation(presentedTime)
                    if probeIsExplicit {
                        directPreviewProbeLog.info(
                            "presented-callback run=\(probeRunID, privacy: .public) mode=\(probeMode, privacy: .public) request=\(requestID, privacy: .public) attempt=\(probeAttempt, privacy: .public) presentedTime=\(presentedTime, privacy: .public) resolutionProduced=\(resolution != nil, privacy: .public)"
                        )
                    }
                    guard let resolution else { return }
                    Task { @MainActor [weak self] in
                        self?.submissionResolved(
                            requestID: requestID,
                            resolution: resolution
                        )
                    }
                }
                commandBuffer.addCompletedHandler { [weak self] completed in
                    let statusRawValue = Int(completed.status.rawValue)
                    let message = completed.error?.localizedDescription
                    let resolution = completion.observeGPUCompletion(
                        failed: statusRawValue
                            == Int(MTLCommandBufferStatus.error.rawValue),
                        message: message
                    )
                    if probeIsExplicit {
                        directPreviewProbeLog.info(
                            "gpu-completed run=\(probeRunID, privacy: .public) mode=\(probeMode, privacy: .public) request=\(requestID, privacy: .public) attempt=\(probeAttempt, privacy: .public) status=\(statusRawValue, privacy: .public) error=\(message ?? "none", privacy: .public) resolutionProduced=\(resolution != nil, privacy: .public)"
                        )
                    }
                    Task { @MainActor [weak self] in
                        self?.commandBufferCompleted(
                            requestID: requestID,
                            statusRawValue: statusRawValue,
                            resolution: resolution
                        )
                    }
                }
                commandBuffer.present(drawable)
                commandBuffer.commit()
                if probeConfiguration.isExplicit {
                    directPreviewProbeLog.info(
                        "committed run=\(self.probeRunID, privacy: .public) mode=\(self.probeConfiguration.mode.rawValue, privacy: .public) request=\(requestID, privacy: .public) attempt=\(self.probeAttempt, privacy: .public) width=\(drawable.texture.width, privacy: .public) height=\(drawable.texture.height, privacy: .public)"
                    )
                }
            } catch {
                send(.submissionFailed(
                    requestID: requestID,
                    failure: .submission(error.localizedDescription)
                ))
            }
        }

        private func scheduleRetry(
            token: DirectPreviewLifecycle.Token,
            milliseconds: Int
        ) {
            redrawRetryTask?.cancel()
            redrawRetryToken = token
            redrawRetryTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(milliseconds))
                } catch {
                    return
                }
                guard let self, self.redrawRetryToken == token else { return }
                self.redrawRetryTask = nil
                self.redrawRetryToken = nil
                self.send(.retryFired(token))
            }
        }

        private func cancelRetry(token: DirectPreviewLifecycle.Token) {
            guard redrawRetryToken == token else { return }
            redrawRetryTask?.cancel()
            redrawRetryTask = nil
            redrawRetryToken = nil
        }

        private func scheduleDeadline(
            token: DirectPreviewLifecycle.Token,
            milliseconds: Int
        ) {
            deliveryWatchdogTask?.cancel()
            deliveryWatchdogToken = token
            deliveryWatchdogTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(milliseconds))
                } catch {
                    return
                }
                guard let self, self.deliveryWatchdogToken == token else { return }
                self.deliveryWatchdogTask = nil
                self.deliveryWatchdogToken = nil
                self.send(.deadlineFired(token))
            }
        }

        private func cancelDeadline(token: DirectPreviewLifecycle.Token) {
            guard deliveryWatchdogToken == token else { return }
            deliveryWatchdogTask?.cancel()
            deliveryWatchdogTask = nil
            deliveryWatchdogToken = nil
        }
    }
}

@MainActor
private final class DirectPreviewMTKView: MTKView {
    var didMoveToWindowHandler: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didMoveToWindowHandler?()
    }
}

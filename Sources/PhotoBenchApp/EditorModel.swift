import AppKit
import Foundation
import PhotoBenchAppSupport
import PhotoCore
import QuartzCore
import UniformTypeIdentifiers
import os

enum PreviewPresentationRoute: String, Sendable {
    case legacyBitmap = "legacy-bitmap"
    case metalDirect = "metal-direct"

    static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        environment["PHOTO_BENCH_PREVIEW_ROUTE"] == metalDirect.rawValue
            ? .metalDirect
            : .legacyBitmap
    }
}

struct DirectPreviewRequest: Identifiable, @unchecked Sendable {
    enum Kind: Sendable {
        case initialSelection
        case edit
    }

    let id: UInt64
    let frame: PreparedPreviewFrame
    let inputHostTime: CFTimeInterval
    let kind: Kind
}

@MainActor
final class EditorModel: ObservableObject {
    private static let presentationLog = OSLog(
        subsystem: "life.niho.photobench",
        category: "presentation"
    )

    @Published private(set) var rootURL: URL?
    @Published private(set) var assets: [PhotoAsset] = []
    @Published var selectedAssetID: String? {
        didSet {
            guard selectedAssetID != oldValue else { return }
            saveEditState(for: oldValue)
            restoreEditState(for: selectedAssetID)
            loadSelection()
        }
    }
    @Published private(set) var preview: NSImage?
    @Published private(set) var directPreviewRequest: DirectPreviewRequest?
    @Published private(set) var previewRoute: PreviewPresentationRoute
    @Published private(set) var decodeInfo: DecodeInfo?
    @Published private(set) var renderMilliseconds: Double?
    @Published private(set) var preset: XMPPreset?
    @Published var settings = EditSettings.neutral
    @Published var applyApproximateXMPColor = false
    @Published private(set) var isBusy = false
    @Published private(set) var hasPreviewInFlight = false
    @Published private(set) var directPresentedCount = 0
    @Published private(set) var directCoalescedCount = 0
    @Published private(set) var directDrawableUnavailableCount = 0
    @Published private(set) var directDroppedCount = 0
    @Published private(set) var statusMessage = "写真フォルダを読み込んでいます…"

    private let decoder = CoreImageDecoder()
    private let renderCoordinator = RenderCoordinator()
    private let initialDirectoryHint: URL
    private let folderAccess: FolderAccessCoordinator
    private var decodedPhoto: DecodedPhoto?
    private var assetsByID: [String: PhotoAsset] = [:]
    private var scanTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var renderRevision: UInt64 = 0
    private var editStates: [String: SessionEditState] = [:]

    private struct SessionEditState {
        let settings: EditSettings
        let preset: XMPPreset?
        let applyApproximateXMPColor: Bool
    }

    init(
        initialDirectoryHint: URL,
        folderAccess: FolderAccessCoordinator? = nil
    ) {
        self.initialDirectoryHint = initialDirectoryHint
        self.folderAccess = folderAccess ?? FolderAccessCoordinator()
        let configuredRoute = PreviewPresentationRoute.configured()
        previewRoute = configuredRoute == .metalDirect && MetalPreviewRenderer.isSupported
            ? .metalDirect
            : .legacyBitmap
        rootURL = nil

        switch self.folderAccess.restore() {
        case let .restored(url):
            rootURL = url
            reloadLibrary()
        case .selectionRequired(.missing):
            isBusy = false
            statusMessage = "写真フォルダを選択してください。初回は自動走査しません。"
        case .selectionRequired(.stale):
            isBusy = false
            statusMessage = "保存した写真フォルダ情報が古くなりました。もう一度フォルダを選択してください。"
        case .selectionRequired(.accessDenied):
            isBusy = false
            statusMessage = "保存した写真フォルダへのアクセスを再開できません。もう一度フォルダを選択してください。"
        case .selectionRequired(.unavailable):
            isBusy = false
            statusMessage = "保存した写真フォルダが見つかりません。SSDを接続して再起動するか、別のフォルダを選択してください。"
        case .selectionRequired(.invalid):
            isBusy = false
            statusMessage = "保存した写真フォルダ情報を復元できません。もう一度フォルダを選択してください。"
        }
    }

    var selectedAsset: PhotoAsset? {
        selectedAssetID.flatMap { assetsByID[$0] }
    }

    var canExport: Bool { decodedPhoto != nil && !isBusy }
    var canChooseFolder: Bool { !isBusy && !hasPreviewInFlight }

    func reloadLibrary() {
        scanTask?.cancel()
        guard let root = rootURL else {
            isBusy = false
            statusMessage = "写真フォルダを選択してください。"
            return
        }
        isBusy = true
        statusMessage = "写真フォルダを走査しています…"
        scanTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try PhotoLibrary.scan(root: root)
                }
                let scanned = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.rootURL == root else { return }
                self.assets = scanned
                self.assetsByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
                let nextID = self.selectedAssetID.flatMap { self.assetsByID[$0] }?.id ?? scanned.first?.id
                if self.selectedAssetID != nextID {
                    self.selectedAssetID = nextID
                } else if nextID != nil {
                    self.loadSelection()
                } else {
                    self.isBusy = false
                    self.statusMessage = "対応するJPEGまたはRAWがありません。"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.rootURL == root else { return }
                self.assets = []
                self.assetsByID = [:]
                self.isBusy = false
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func chooseFolder() {
        // Replacing the active security-scoped root while a lazy Core Image
        // decode/render/export is still using it can revoke access mid-flight.
        // Keep the capability alive until the current operation completes.
        guard canChooseFolder else {
            statusMessage = "処理中は写真フォルダを変更できません。完了後にもう一度お試しください。"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "JPEGとRAWがある写真フォルダを選んでください"
        panel.directoryURL = rootURL ?? initialDirectoryHint
        guard panel.runModal() == .OK, let url = panel.url else { return }

        scanTask?.cancel()
        loadTask?.cancel()
        renderTask?.cancel()
        renderRevision &+= 1
        do {
            try folderAccess.activateSelection(url)
        } catch {
            isBusy = false
            statusMessage = "写真フォルダのアクセス情報を保存できません: \(error.localizedDescription)"
            return
        }

        rootURL = url
        selectedAssetID = nil
        assets = []
        assetsByID = [:]
        preview = nil
        directPreviewRequest = nil
        hasPreviewInFlight = false
        decodedPhoto = nil
        decodeInfo = nil
        reloadLibrary()
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL ?? initialDirectoryHint
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let parsed = try ImplicitSecurityScopedAccess.withAccess(to: url) {
                try XMPPresetParser.parse(url: url)
            }
            preset = parsed
            settings = parsed.applying(to: settings)
            applyApproximateXMPColor = false
            scheduleRender()
            let unsupported = parsed.compatibility.filter { $0.level == .unsupported }.count
            statusMessage = "\(parsed.name)の基本補正を適用しました（未対応 \(unsupported)項目、HSL/カーブ近似はOFF）。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func resetAdjustments() {
        settings = .neutral
        preset = nil
        applyApproximateXMPColor = false
        scheduleRender()
        statusMessage = "調整をリセットしました。"
    }

    func scheduleRender() {
        guard let decodedPhoto else { return }
        let inputHostTime = CACurrentMediaTime()
        renderTask?.cancel()
        renderRevision &+= 1
        let revision = renderRevision
        let capturedSettings = renderSettings
        let coordinator = renderCoordinator
        hasPreviewInFlight = true
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewInput",
            "request=%{public}llu",
            revision
        )
        renderTask = Task { [weak self] in
            do {
                let frame = try await coordinator.prepareProductionPreview(
                    decoded: decodedPhoto,
                    settings: capturedSettings
                )
                try Task.checkCancellation()
                guard let self, self.renderRevision == revision else { return }
                try await self.presentPreparedFrame(
                    frame,
                    revision: revision,
                    inputHostTime: inputHostTime,
                    kind: .edit
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.renderRevision == revision
                else { return }
                self.hasPreviewInFlight = false
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func directPreviewPresented(
        requestID: UInt64,
        presentedTime: CFTimeInterval
    ) {
        guard previewRoute == .metalDirect,
              let request = directPreviewRequest,
              request.id == requestID,
              renderRevision == requestID
        else {
            return
        }
        guard presentedTime > 0 else {
            directPreviewDropped(requestID: requestID)
            return
        }
        let milliseconds = max(0, (presentedTime - request.inputHostTime) * 1_000)
        renderMilliseconds = milliseconds
        directPresentedCount += 1
        hasPreviewInFlight = false
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewPresented",
            "request=%{public}llu inputToPresentMs=%{public}.3f",
            requestID,
            milliseconds
        )
        if request.kind == .initialSelection {
            isBusy = false
            statusMessage = loadedStatusMessage()
        }
    }

    func directPreviewCoalesced(requestID: UInt64) {
        directCoalescedCount += 1
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewCoalesced",
            "request=%{public}llu",
            requestID
        )
    }

    func directPreviewDrawableUnavailable(requestID: UInt64) {
        directDrawableUnavailableCount += 1
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewDrawableUnavailable",
            "request=%{public}llu",
            requestID
        )
    }

    func directPreviewDropped(requestID: UInt64) {
        directDroppedCount += 1
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewDropped",
            "request=%{public}llu",
            requestID
        )
    }

    func directPreviewFailed(requestID: UInt64, errorDescription: String) {
        guard previewRoute == .metalDirect,
              let request = directPreviewRequest,
              request.id == requestID,
              renderRevision == requestID
        else {
            return
        }
        // Runtime fallback is intentionally one-way for this process. Repeated
        // Metal/bitmap oscillation would make both color and latency unstable.
        // Keep the loading state visible until the same prepared frame has
        // been materialized; switching routes must never flash an empty state.
        isBusy = true
        hasPreviewInFlight = true
        previewRoute = .legacyBitmap
        directPreviewRequest = nil
        statusMessage = "Metal直接表示を停止し、従来表示へ戻しています: \(errorDescription)"
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewMetalFallback",
            "request=%{public}llu",
            requestID
        )
        let coordinator = renderCoordinator
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            do {
                let rendered = try await coordinator.materializePreview(request.frame)
                guard let self,
                      self.renderRevision == requestID,
                      self.previewRoute == .legacyBitmap
                else { return }
                self.preview = rendered.image
                // This label becomes "preview generation" after switching to
                // the bitmap route. Report only the work that produced that
                // bitmap; the failed direct-route delivery latency remains in
                // the presentation signposts and status message.
                self.renderMilliseconds = request.frame.graphAndKernelSetupMilliseconds
                    + rendered.durationMilliseconds
                self.hasPreviewInFlight = false
                self.isBusy = false
                self.statusMessage = "Metal直接表示に失敗したため、この起動中は従来表示を使用します（\(errorDescription)）。"
            } catch {
                guard let self, self.renderRevision == requestID else { return }
                self.hasPreviewInFlight = false
                self.isBusy = false
                self.statusMessage = "プレビュー表示に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    func exportFromPanel() {
        guard let decodedPhoto, let source = selectedAsset else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = rootURL?.appendingPathComponent("exports", isDirectory: true)
            ?? initialDirectoryHint
        panel.nameFieldStringValue = source.url.deletingPathExtension().lastPathComponent + "-photobench.jpg"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isBusy = true
        statusMessage = "原寸JPEGを書き出しています…"
        let capturedSettings = renderSettings
        let protectedSourceURLs = assets.map(\.url)
        let coordinator = renderCoordinator
        Task { [weak self] in
            do {
                let milliseconds = try await ImplicitSecurityScopedAccess.withAccess(to: destination) {
                    try await coordinator.exportJPEG(
                        decoded: decodedPhoto,
                        settings: capturedSettings,
                        destination: destination,
                        protectedSourceURLs: protectedSourceURLs
                    )
                }
                self?.isBusy = false
                self?.statusMessage = String(format: "sRGB JPEGを書き出しました（XMP互換は項目別、%.0fms）: %@", milliseconds, destination.lastPathComponent)
            } catch {
                self?.isBusy = false
                self?.statusMessage = "書き出し失敗: \(error.localizedDescription)"
            }
        }
    }

    private func loadSelection() {
        guard let asset = selectedAsset else {
            loadTask?.cancel()
            renderRevision &+= 1
            preview = nil
            directPreviewRequest = nil
            hasPreviewInFlight = false
            decodedPhoto = nil
            decodeInfo = nil
            return
        }
        renderTask?.cancel()
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        renderRevision &+= 1
        let revision = renderRevision
        let inputHostTime = CACurrentMediaTime()
        isBusy = true
        hasPreviewInFlight = true
        preview = nil
        directPreviewRequest = nil
        decodedPhoto = nil
        decodeInfo = nil
        renderMilliseconds = nil
        statusMessage = "\(asset.filename)を現像しています…"
        os_signpost(
            .event,
            log: Self.presentationLog,
            name: "PreviewInput",
            "request=%{public}llu initial=1",
            revision
        )
        let decoder = decoder
        let coordinator = renderCoordinator

        loadTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try decoder.decode(url: asset.url)
                }
                let decoded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.loadGeneration == generation else { return }
                // Resolve settings after decoding. The top-level controls are
                // disabled while busy, but taking the value here also prevents
                // an old pre-decode snapshot from reaching the screen.
                let frame = try await coordinator.prepareProductionPreview(
                    decoded: decoded,
                    settings: self.renderSettings
                )
                try Task.checkCancellation()
                guard self.loadGeneration == generation,
                      self.renderRevision == revision
                else { return }
                self.decodedPhoto = decoded
                self.decodeInfo = decoded.info
                try await self.presentPreparedFrame(
                    frame,
                    revision: revision,
                    inputHostTime: inputHostTime,
                    kind: .initialSelection
                )
            } catch is CancellationError {
                return
            } catch {
                guard self?.loadGeneration == generation,
                      self?.renderRevision == revision
                else { return }
                self?.isBusy = false
                self?.hasPreviewInFlight = false
                self?.preview = nil
                self?.directPreviewRequest = nil
                self?.decodedPhoto = nil
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    private func presentPreparedFrame(
        _ frame: PreparedPreviewFrame,
        revision: UInt64,
        inputHostTime: CFTimeInterval,
        kind: DirectPreviewRequest.Kind
    ) async throws {
        guard renderRevision == revision else { throw CancellationError() }
        switch previewRoute {
        case .metalDirect:
            preview = nil
            directPreviewRequest = DirectPreviewRequest(
                id: revision,
                frame: frame,
                inputHostTime: inputHostTime,
                kind: kind
            )
            if kind == .initialSelection {
                statusMessage = "原寸デコード済み。Metalで画面表示しています…"
            }
        case .legacyBitmap:
            let materialized = try await renderCoordinator.materializePreview(frame)
            try Task.checkCancellation()
            guard renderRevision == revision else { throw CancellationError() }
            directPreviewRequest = nil
            preview = materialized.image
            renderMilliseconds = max(0, (CACurrentMediaTime() - inputHostTime) * 1_000)
            hasPreviewInFlight = false
            if kind == .initialSelection {
                isBusy = false
                statusMessage = loadedStatusMessage()
            }
        }
    }

    private func loadedStatusMessage() -> String {
        guard let info = decodeInfo else { return "プレビューを表示しました。" }
        if info.isRAW {
            if info.calibrationID == RAWCalibrationProfile.panasonicDCS5Lightroom93.id {
                return "\(info.backend)で原寸デコードしました（DC-S5色差2枚のみ、白飛び未校正）。"
            }
            return "\(info.backend)で原寸デコードしました（この機種の色は未校正）。"
        }
        return "JPEGを読み込みました。"
    }

    private var renderSettings: EditSettings {
        guard !applyApproximateXMPColor else { return settings }
        var safe = settings
        safe.toneCurves = []
        safe.hsl = [:]
        return safe
    }

    private func saveEditState(for assetID: String?) {
        guard let assetID else { return }
        editStates[assetID] = SessionEditState(
            settings: settings,
            preset: preset,
            applyApproximateXMPColor: applyApproximateXMPColor
        )
    }

    private func restoreEditState(for assetID: String?) {
        guard let assetID, let state = editStates[assetID] else {
            settings = .neutral
            preset = nil
            applyApproximateXMPColor = false
            return
        }
        settings = state.settings
        preset = state.preset
        applyApproximateXMPColor = state.applyApproximateXMPColor
    }
}

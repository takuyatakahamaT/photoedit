import Foundation
import Testing
@testable import PhotoBenchAppSupport

struct FolderAccessTests {
    private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PhotoBenchFolderAccessTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func missingBookmarkDoesNotResolveOrRequestAccess() {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        var resolverWasCalled = false
        let store = FolderBookmarkStore(
            defaults: isolated.defaults,
            resolveBookmark: { _ in
                resolverWasCalled = true
                return (URL(fileURLWithPath: "/unexpected"), false)
            }
        )
        var accessWasStarted = false
        let coordinator = FolderAccessCoordinator(
            bookmarkStore: store,
            startAccess: { _ in
                accessWasStarted = true
                return true
            }
        )

        guard case let .selectionRequired(reason) = coordinator.restore() else {
            Issue.record("ブックマークなしで自動復元されました。")
            return
        }
        guard case .missing = reason else {
            Issue.record("missing以外の復元結果です。")
            return
        }
        #expect(!resolverWasCalled)
        #expect(!accessWasStarted)
    }

    @Test func selectedFolderIsPersistedAndRestoredWithoutUI() throws {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let selected = URL(fileURLWithPath: "/Volumes/PhotoLibrary/edit", isDirectory: true)
        let marker = Data("selected-folder-capability".utf8)
        var createdURL: URL?
        var resolvedData: Data?
        let store = FolderBookmarkStore(
            defaults: isolated.defaults,
            createBookmark: { url in
                createdURL = url
                return marker
            },
            resolveBookmark: { data in
                resolvedData = data
                return (selected, false)
            }
        )

        try store.save(url: selected)
        #expect(createdURL == selected)
        guard case let .restored(url) = store.restore() else {
            Issue.record("保存したフォルダを復元できませんでした。")
            return
        }
        #expect(url == selected)
        #expect(resolvedData == marker)
    }

    @Test func staleBookmarkIsRenewedBeforeAccessStarts() {
        let staleDefaults = isolatedDefaults()
        defer { staleDefaults.defaults.removePersistentDomain(forName: staleDefaults.suiteName) }
        let key = "stale"
        let renewedData = Data([9])
        staleDefaults.defaults.set(Data([1]), forKey: key)
        let staleStore = FolderBookmarkStore(
            defaults: staleDefaults.defaults,
            key: key,
            createBookmark: { _ in renewedData },
            resolveBookmark: { _ in (URL(fileURLWithPath: "/stale"), true) }
        )
        var staleAccessStarts = 0
        let staleCoordinator = FolderAccessCoordinator(
            bookmarkStore: staleStore,
            startAccess: { _ in
                staleAccessStarts += 1
                return true
            }
        )
        guard case let .restored(url) = staleCoordinator.restore() else {
            Issue.record("staleブックマークを更新・復元できませんでした。")
            return
        }
        #expect(url.path == "/stale")
        #expect(staleAccessStarts == 1)
        #expect(staleDefaults.defaults.data(forKey: key) == renewedData)
        staleCoordinator.deactivate()
    }

    @Test func unrenewableStaleAndCorruptBookmarksRequireSelectionWithoutAccess() {
        let staleDefaults = isolatedDefaults()
        defer { staleDefaults.defaults.removePersistentDomain(forName: staleDefaults.suiteName) }
        let staleKey = "stale-unrenewable"
        staleDefaults.defaults.set(Data([1]), forKey: staleKey)
        let staleStore = FolderBookmarkStore(
            defaults: staleDefaults.defaults,
            key: staleKey,
            createBookmark: { _ in throw CocoaError(.fileWriteNoPermission) },
            resolveBookmark: { _ in (URL(fileURLWithPath: "/stale"), true) }
        )
        var staleAccessStarts = 0
        let staleCoordinator = FolderAccessCoordinator(
            bookmarkStore: staleStore,
            startAccess: { _ in
                staleAccessStarts += 1
                return true
            }
        )
        guard case let .selectionRequired(staleResult) = staleCoordinator.restore(),
              case .stale = staleResult else {
            Issue.record("更新不能なstaleブックマークが選択要求になりませんでした。")
            return
        }
        #expect(staleAccessStarts == 0)
        #expect(staleDefaults.defaults.data(forKey: staleKey) == nil)

        let corruptDefaults = isolatedDefaults()
        defer { corruptDefaults.defaults.removePersistentDomain(forName: corruptDefaults.suiteName) }
        let corruptKey = "corrupt"
        corruptDefaults.defaults.set(Data([2]), forKey: corruptKey)
        let corruptStore = FolderBookmarkStore(
            defaults: corruptDefaults.defaults,
            key: corruptKey,
            resolveBookmark: { _ in throw CocoaError(.fileReadCorruptFile) }
        )
        let corruptCoordinator = FolderAccessCoordinator(bookmarkStore: corruptStore)
        guard case let .selectionRequired(corruptResult) = corruptCoordinator.restore(),
              case .invalid = corruptResult else {
            Issue.record("壊れたブックマークが選択要求になりませんでした。")
            return
        }
        #expect(corruptDefaults.defaults.data(forKey: corruptKey) == nil)
    }

    @Test func failedRestoredAccessClearsBookmarkAndNeverActivatesFolder() {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let key = "denied"
        isolated.defaults.set(Data([3]), forKey: key)
        let deniedURL = URL(fileURLWithPath: "/denied", isDirectory: true)
        let store = FolderBookmarkStore(
            defaults: isolated.defaults,
            key: key,
            resolveBookmark: { _ in (deniedURL, false) }
        )
        var attempted: [URL] = []
        let coordinator = FolderAccessCoordinator(
            bookmarkStore: store,
            startAccess: {
                attempted.append($0)
                return false
            }
        )

        guard case let .selectionRequired(reason) = coordinator.restore(),
              case .accessDenied = reason else {
            Issue.record("アクセス開始失敗が選択要求になりませんでした。")
            return
        }
        #expect(attempted == [deniedURL])
        #expect(coordinator.activeURL == nil)
        #expect(isolated.defaults.data(forKey: key) == nil)
    }

    @Test func temporarilyUnavailableVolumeKeepsBookmarkForReconnect() {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let key = "offline-volume"
        let bookmark = Data([4])
        isolated.defaults.set(bookmark, forKey: key)
        let store = FolderBookmarkStore(
            defaults: isolated.defaults,
            key: key,
            resolveBookmark: { _ in throw CocoaError(.fileReadNoSuchFile) }
        )
        var accessWasStarted = false
        let coordinator = FolderAccessCoordinator(
            bookmarkStore: store,
            startAccess: { _ in
                accessWasStarted = true
                return true
            }
        )

        guard case let .selectionRequired(reason) = coordinator.restore(),
              case .unavailable = reason else {
            Issue.record("未接続ボリュームが一時利用不可として扱われませんでした。")
            return
        }
        #expect(!accessWasStarted)
        #expect(isolated.defaults.data(forKey: key) == bookmark)
    }

    @Test func switchingFoldersBalancesAccessAndStopsTheOldFolder() throws {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let store = FolderBookmarkStore(
            defaults: isolated.defaults,
            createBookmark: { Data($0.path.utf8) }
        )
        var started: [URL] = []
        var stopped: [URL] = []
        let coordinator = FolderAccessCoordinator(
            bookmarkStore: store,
            startAccess: { started.append($0); return true },
            stopAccess: { stopped.append($0) }
        )
        let first = URL(fileURLWithPath: "/photos/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/photos/second", isDirectory: true)

        try coordinator.activateSelection(first)
        try coordinator.activateSelection(second)
        // NSOpenPanel URLs are already started by the system.
        #expect(started.isEmpty)
        #expect(stopped == [first])
        #expect(coordinator.activeURL == second)

        coordinator.deactivate()
        #expect(stopped == [first, second])
        #expect(coordinator.activeURL == nil)
    }

    @Test func failedBookmarkCreationKeepsOldAccessAndBalancesNewAttempt() throws {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let first = URL(fileURLWithPath: "/photos/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/photos/second", isDirectory: true)
        let store = FolderBookmarkStore(
            defaults: isolated.defaults,
            createBookmark: { url in
                if url == second { throw CocoaError(.fileWriteNoPermission) }
                return Data(url.path.utf8)
            }
        )
        var stopped: [URL] = []
        let coordinator = FolderAccessCoordinator(
            bookmarkStore: store,
            startAccess: { _ in true },
            stopAccess: { stopped.append($0) }
        )

        try coordinator.activateSelection(first)
        #expect(throws: (any Error).self) {
            try coordinator.activateSelection(second)
        }
        #expect(coordinator.activeURL == first)
        #expect(stopped == [second])
        coordinator.deactivate()
        #expect(stopped == [second, first])
    }

    @Test @MainActor func panelAccessStopsOnceAfterSynchronousFailure() {
        let url = URL(fileURLWithPath: "/selected/preset.xmp")
        var stopped: [URL] = []

        #expect(throws: CocoaError.self) {
            try ImplicitSecurityScopedAccess.withAccess(
                to: url,
                stopAccess: { stopped.append($0) }
            ) {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        #expect(stopped == [url])
    }

    @Test @MainActor func panelAccessStaysOpenAcrossAsyncWorkAndStopsOnce() async {
        let url = URL(fileURLWithPath: "/selected/export.jpg")
        var stopped: [URL] = []
        var operationCompleted = false

        let value = await ImplicitSecurityScopedAccess.withAccess(
            to: url,
            stopAccess: { stopped.append($0) }
        ) {
            await Task.yield()
            operationCompleted = true
            return 42
        }
        #expect(value == 42)
        #expect(operationCompleted)
        #expect(stopped == [url])
    }
}

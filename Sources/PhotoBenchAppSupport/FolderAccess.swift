import Foundation

public enum FolderBookmarkRestoreResult {
    case missing
    case restored(URL)
    case stale
    case invalid
    case unavailable
}

/// Persists only the user-selected directory capability. Resolving is always
/// non-interactive so launch can never trigger a hidden Documents/volume prompt.
public final class FolderBookmarkStore {
    public typealias BookmarkCreator = (URL) throws -> Data
    public typealias BookmarkResolver = (Data) throws -> (url: URL, isStale: Bool)

    private let defaults: UserDefaults
    private let key: String
    private let createBookmark: BookmarkCreator
    private let resolveBookmark: BookmarkResolver

    public init(
        defaults: UserDefaults = .standard,
        key: String = "PhotoBench.photoFolderSecurityScopedBookmark",
        createBookmark: @escaping BookmarkCreator = FolderBookmarkStore.createSecurityScopedBookmark,
        resolveBookmark: @escaping BookmarkResolver = FolderBookmarkStore.resolveSecurityScopedBookmark
    ) {
        self.defaults = defaults
        self.key = key
        self.createBookmark = createBookmark
        self.resolveBookmark = resolveBookmark
    }

    public func save(url: URL) throws {
        defaults.set(try createBookmark(url), forKey: key)
    }

    public func restore() -> FolderBookmarkRestoreResult {
        guard let data = defaults.data(forKey: key) else { return .missing }
        do {
            let resolved = try resolveBookmark(data)
            if resolved.isStale {
                do {
                    try save(url: resolved.url)
                } catch {
                    clear()
                    return .stale
                }
            }
            return .restored(resolved.url)
        } catch {
            let cocoaError = error as NSError
            let isTemporarilyUnavailable = cocoaError.code == NSFileNoSuchFileError
                || cocoaError.code == NSFileReadNoSuchFileError
            if cocoaError.domain == NSCocoaErrorDomain, isTemporarilyUnavailable {
                // A removable photo volume may simply be offline. Preserve the
                // capability so the next launch can restore it after reconnect.
                return .unavailable
            }
            clear()
            return .invalid
        }
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    public static func createSecurityScopedBookmark(url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public static func resolveSecurityScopedBookmark(data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

/// NSOpenPanel/NSSavePanel URLs arrive with access implicitly started by the
/// system. These helpers guarantee exactly one matching stop on every exit.
public enum ImplicitSecurityScopedAccess {
    @MainActor
    public static func withAccess<Value>(
        to url: URL,
        stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        operation: () throws -> Value
    ) rethrows -> Value {
        defer { stopAccess(url) }
        return try operation()
    }

    @MainActor
    public static func withAccess<Value>(
        to url: URL,
        stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        operation: () async throws -> Value
    ) async rethrows -> Value {
        defer { stopAccess(url) }
        return try await operation()
    }
}

public enum FolderAccessSelectionReason {
    case missing
    case stale
    case invalid
    case unavailable
    case accessDenied
}

public enum FolderAccessRestoreResult {
    case selectionRequired(FolderAccessSelectionReason)
    case restored(URL)
}

/// Owns the balanced start/stop lifetime for exactly one photo directory.
/// The app keeps this object alive for as long as scans and image reads may run.
public final class FolderAccessCoordinator {
    public typealias StartAccess = (URL) -> Bool
    public typealias StopAccess = (URL) -> Void

    private let bookmarkStore: FolderBookmarkStore
    private let startAccess: StartAccess
    private let stopAccess: StopAccess
    private var activeAccessWasStarted = false

    public private(set) var activeURL: URL?

    public init(
        bookmarkStore: FolderBookmarkStore = FolderBookmarkStore(),
        startAccess: @escaping StartAccess = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping StopAccess = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.bookmarkStore = bookmarkStore
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    deinit {
        deactivate()
    }

    public func restore() -> FolderAccessRestoreResult {
        let result = bookmarkStore.restore()
        let url: URL
        switch result {
        case let .restored(restoredURL):
            url = restoredURL
        case .missing:
            deactivate()
            return .selectionRequired(.missing)
        case .stale:
            deactivate()
            return .selectionRequired(.stale)
        case .invalid:
            deactivate()
            return .selectionRequired(.invalid)
        case .unavailable:
            deactivate()
            return .selectionRequired(.unavailable)
        }

        guard activateResolvedURL(url) else {
            bookmarkStore.clear()
            return .selectionRequired(.accessDenied)
        }
        return .restored(url)
    }

    /// Call only with a URL returned by NSOpenPanel. The new capability is
    /// established and persisted before the previous capability is released.
    public func activateSelection(_ url: URL) throws {
        do {
            try bookmarkStore.save(url: url)
        } catch {
            // NSOpenPanel gives the URL with access already started on the
            // app's behalf. Balance that implicit start if persistence fails.
            stopAccess(url)
            throw error
        }

        deactivate()
        activeURL = url
        // NSOpenPanel implicitly starts access; this object owns its stop.
        activeAccessWasStarted = true
    }

    public func deactivate() {
        if activeAccessWasStarted, let activeURL {
            stopAccess(activeURL)
        }
        activeURL = nil
        activeAccessWasStarted = false
    }

    private func activateResolvedURL(_ url: URL) -> Bool {
        let didStart = startAccess(url)
        guard didStart else { return false }
        deactivate()
        activeURL = url
        activeAccessWasStarted = true
        return true
    }
}

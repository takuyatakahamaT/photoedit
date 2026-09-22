import Foundation

public struct PhotoEditHistory: Sendable {
    public static let defaultLimit = 100

    private let limit: Int
    private var undoStack: [PhotoEditSnapshot] = []
    private var redoStack: [PhotoEditSnapshot] = []
    private var activeGroupStart: PhotoEditSnapshot?
    private var activeGroupCurrent: PhotoEditSnapshot?

    public init(limit: Int = Self.defaultLimit) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool {
        !undoStack.isEmpty || activeGroupStart != activeGroupCurrent
    }
    public var canRedo: Bool {
        activeGroupStart == activeGroupCurrent && !redoStack.isEmpty
    }

    public mutating func beginGroup(startingAt snapshot: PhotoEditSnapshot) {
        guard activeGroupStart == nil else { return }
        activeGroupStart = snapshot
        activeGroupCurrent = snapshot
    }

    public mutating func endGroup(at snapshot: PhotoEditSnapshot) {
        guard let start = activeGroupStart else { return }
        activeGroupStart = nil
        activeGroupCurrent = nil
        appendUndo(start, whenDifferentFrom: snapshot)
    }

    public mutating func record(before: PhotoEditSnapshot, after: PhotoEditSnapshot) {
        if activeGroupStart != nil {
            activeGroupCurrent = after
            return
        }
        guard before != after else { return }
        appendUndo(before, whenDifferentFrom: after)
    }

    public mutating func undo(current: PhotoEditSnapshot) -> PhotoEditSnapshot? {
        endGroup(at: current)
        guard let previous = undoStack.popLast() else { return nil }
        push(current, onto: &redoStack)
        return previous
    }

    public mutating func redo(current: PhotoEditSnapshot) -> PhotoEditSnapshot? {
        endGroup(at: current)
        guard let next = redoStack.popLast() else { return nil }
        push(current, onto: &undoStack)
        return next
    }

    private mutating func appendUndo(_ snapshot: PhotoEditSnapshot, whenDifferentFrom after: PhotoEditSnapshot) {
        guard snapshot != after else { return }
        push(snapshot, onto: &undoStack)
        redoStack.removeAll(keepingCapacity: true)
    }

    private func push(_ snapshot: PhotoEditSnapshot, onto stack: inout [PhotoEditSnapshot]) {
        stack.append(snapshot)
        if stack.count > limit {
            stack.removeFirst(stack.count - limit)
        }
    }
}

/// Session-only histories keyed by the same stable in-memory photo identity
/// used by the editor. A photo switch leaves each photo's stack independent.
public struct PerPhotoEditHistory: Sendable {
    private var histories: [String: PhotoEditHistory] = [:]

    public init() {}

    public func canUndo(for photoID: String?) -> Bool {
        guard let photoID else { return false }
        return histories[photoID]?.canUndo ?? false
    }

    public func canRedo(for photoID: String?) -> Bool {
        guard let photoID else { return false }
        return histories[photoID]?.canRedo ?? false
    }

    public mutating func beginGroup(for photoID: String, startingAt snapshot: PhotoEditSnapshot) {
        var history = histories[photoID] ?? PhotoEditHistory()
        history.beginGroup(startingAt: snapshot)
        histories[photoID] = history
    }

    public mutating func endGroup(for photoID: String, at snapshot: PhotoEditSnapshot) {
        guard var history = histories[photoID] else { return }
        history.endGroup(at: snapshot)
        histories[photoID] = history
    }

    public mutating func record(
        before: PhotoEditSnapshot,
        after: PhotoEditSnapshot,
        for photoID: String
    ) {
        var history = histories[photoID] ?? PhotoEditHistory()
        history.record(before: before, after: after)
        histories[photoID] = history
    }

    public mutating func undo(for photoID: String, current: PhotoEditSnapshot) -> PhotoEditSnapshot? {
        guard var history = histories[photoID] else { return nil }
        let snapshot = history.undo(current: current)
        histories[photoID] = history
        return snapshot
    }

    public mutating func redo(for photoID: String, current: PhotoEditSnapshot) -> PhotoEditSnapshot? {
        guard var history = histories[photoID] else { return nil }
        let snapshot = history.redo(current: current)
        histories[photoID] = history
        return snapshot
    }
}

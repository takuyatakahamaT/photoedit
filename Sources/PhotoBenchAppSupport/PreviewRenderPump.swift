import Foundation

/// The preview's render scheduling as a pure state machine; `EditorModel`
/// carries out the jobs it hands back (render, present, cancel).
///
/// - One render runs at a time (the render coordinator is serial anyway).
/// - A drag frame that is already running is never discarded: a newer drag
///   tick waits (only the newest one) and starts when it finishes, so a
///   continuous drag keeps updating at the render rate instead of restarting
///   on every mouse event and showing nothing until the pointer rests.
/// - Every other request (an exact edit, a new photo state) supersedes the
///   running job, which the caller cancels.
/// - After a drag, once nothing is running or waiting and the frame on
///   screen is a drag approximation, one "settle" job renders the same
///   revision exactly. It is started at most once per revision, and any new
///   request supersedes it.
public struct PreviewRenderPump<Payload> {
    public enum Kind: Equatable, Sendable {
        case exact
        case drag
        case settle
    }

    public struct Job {
        public let serial: UInt64
        public let revision: UInt64
        public let kind: Kind
        /// The request's own data; `nil` for `.settle` (the caller renders
        /// its current settings).
        public let payload: Payload?
    }

    public private(set) var running: (serial: UInt64, kind: Kind)?
    public private(set) var waitingDrag: (revision: UInt64, payload: Payload)?
    public private(set) var presentedRevision: UInt64 = 0
    public private(set) var presentedIsApproximate = false
    public private(set) var latestRevision: UInt64 = 0
    public private(set) var isDragging = false
    private var settleStartedRevision: UInt64?
    private var serial: UInt64 = 0

    public init() {}

    public mutating func beginDrag() {
        isDragging = true
    }

    /// Returns the settle job to start now, if one is due.
    public mutating func endDrag() -> Job? {
        isDragging = false
        return settleIfIdle()
    }

    /// A new revision of the edit. Returns the job to start now (the caller
    /// cancels whatever was running), or `nil` when the revision waits for
    /// the running drag frame.
    public mutating func submit(revision: UInt64, isDragFrame: Bool, payload: Payload) -> Job? {
        latestRevision = max(latestRevision, revision)
        if isDragFrame, running?.kind == .drag {
            waitingDrag = (revision, payload)
            return nil
        }
        return start(revision: revision, kind: isDragFrame ? .drag : .exact, payload: payload)
    }

    /// Whether a finished job's frame may replace the one on screen: a newer
    /// revision, or the exact frame of the revision whose drag
    /// approximation is shown.
    public func canPresent(_ job: Job) -> Bool {
        job.revision > presentedRevision
            || (job.revision == presentedRevision && presentedIsApproximate && job.kind != .drag)
    }

    public mutating func presented(_ job: Job) {
        presentedRevision = job.revision
        presentedIsApproximate = job.kind == .drag
    }

    /// A frame shown outside the pump (the photo's first render).
    public mutating func presentedExactFrame(revision: UInt64) {
        latestRevision = max(latestRevision, revision)
        presentedRevision = revision
        presentedIsApproximate = false
    }

    /// The job ended (presented, superseded, cancelled or failed). Returns the
    /// next job to start: the waiting drag tick, or the settle job.
    public mutating func finish(_ job: Job) -> Job? {
        guard running?.serial == job.serial else { return nil }
        running = nil
        if let waiting = waitingDrag {
            waitingDrag = nil
            return start(revision: waiting.revision, kind: .drag, payload: waiting.payload)
        }
        return settleIfIdle()
    }

    /// The photo or folder changed: forget the running and waiting jobs.
    public mutating func reset() {
        running = nil
        waitingDrag = nil
        presentedIsApproximate = false
    }

    private mutating func settleIfIdle() -> Job? {
        guard !isDragging, running == nil, waitingDrag == nil, presentedIsApproximate,
              settleStartedRevision != latestRevision
        else { return nil }
        settleStartedRevision = latestRevision
        return start(revision: latestRevision, kind: .settle, payload: nil)
    }

    private mutating func start(revision: UInt64, kind: Kind, payload: Payload?) -> Job {
        serial &+= 1
        running = (serial, kind)
        waitingDrag = nil
        return Job(serial: serial, revision: revision, kind: kind, payload: payload)
    }
}

extension PreviewRenderPump.Job: Sendable where Payload: Sendable {}
extension PreviewRenderPump.Job: Equatable where Payload: Equatable {}
extension PreviewRenderPump: Sendable where Payload: Sendable {}

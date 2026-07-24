import Foundation

/// Deterministic lifecycle for the opt-in direct Metal preview route.
///
/// The reducer owns only request identifiers and scheduling decisions. AppKit,
/// Metal payloads, Tasks, and callbacks stay in the presentation coordinator,
/// which interprets the returned effects. Cross-thread callback arbitration is
/// kept in `DirectPreviewSubmissionArbiter` below so it can be tested without
/// AppKit or Metal objects.
public struct DirectPreviewLifecycle: Equatable, Sendable {
    public struct Token: Hashable, Sendable {
        public let rawValue: UInt64

        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    public struct Surface: Equatable, Sendable {
        public var isVisible: Bool
        public var hasDrawableSize: Bool

        public var isReady: Bool {
            isVisible && hasDrawableSize
        }

        public init(isVisible: Bool = false, hasDrawableSize: Bool = false) {
            self.isVisible = isVisible
            self.hasDrawableSize = hasDrawableSize
        }
    }

    public enum Route: Equatable, Sendable {
        case active
        case failed(requestID: UInt64)
        case tornDown
    }

    public enum Failure: Equatable, Sendable {
        case rendererUnavailable(String)
        case submission(String)
        case gpu(String)
        case deliveryDeadline

        public var message: String {
            switch self {
            case .rendererUnavailable(let message),
                 .submission(let message),
                 .gpu(let message):
                message
            case .deliveryDeadline:
                "可視状態のMetal drawableを10秒以内に実表示できませんでした。"
            }
        }
    }

    public struct ScheduledRequest: Equatable, Sendable {
        public let requestID: UInt64
        public let token: Token

        public init(requestID: UInt64, token: Token) {
            self.requestID = requestID
            self.token = token
        }
    }

    public enum Event: Equatable, Sendable {
        case submit(UInt64)
        case failLatest(requestID: UInt64, failure: Failure)
        case surfaceChanged(isVisible: Bool, hasDrawableSize: Bool)
        case drawableSizeChanged(isValid: Bool)
        case drawAttempted(requestID: UInt64, drawableAvailable: Bool)
        case submissionFailed(requestID: UInt64, failure: Failure)
        case presentationClaimed(requestID: UInt64, presentedTime: Double)
        case gpuFailureClaimed(requestID: UInt64, message: String)
        case retryFired(Token)
        case deadlineFired(Token)
        case deadlineClaimResolved(Token, won: Bool)
        case tearDown
    }

    public enum Effect: Equatable, Sendable {
        case requestDisplay(UInt64)
        case beginSubmission(UInt64)
        case scheduleRetry(Token, milliseconds: Int)
        case cancelRetry(Token)
        case scheduleDeadline(Token, milliseconds: Int)
        case cancelDeadline(Token)
        case claimSubmissionForDeadline(requestID: UInt64, token: Token)
        case invalidateSubmission(UInt64)
        case reportCoalesced(UInt64)
        case reportDrawableUnavailable(UInt64)
        case reportDropped(UInt64)
        case reportPresented(UInt64, presentedTime: Double)
        case reportFailure(UInt64, failure: Failure)
        case discardPayload(UInt64)
        case discardAllPayloads
        case clearRendererCaches
    }

    public private(set) var route: Route = .active
    public private(set) var surface = Surface()
    public private(set) var queue = LatestPreviewQueueState()
    public private(set) var retryStep = 0
    public private(set) var retry: ScheduledRequest?
    public private(set) var deadline: ScheduledRequest?
    public private(set) var deadlineAwaitingClaim: ScheduledRequest?
    public private(set) var lastReportedPresentedID: UInt64?

    private var retryRequestID: UInt64?
    private var nextTokenValue: UInt64 = 1

    public init() {}

    @discardableResult
    public mutating func reduce(_ event: Event) -> [Effect] {
        if case .tearDown = event {
            return tearDown()
        }
        guard route == .active else { return [] }

        switch event {
        case .submit(let requestID):
            return submit(requestID)
        case .failLatest(let requestID, let failure):
            guard queue.latestID == requestID else { return [] }
            return fail(requestID: requestID, failure: failure)
        case .surfaceChanged(let isVisible, let hasDrawableSize):
            return surfaceChanged(
                isVisible: isVisible,
                hasDrawableSize: hasDrawableSize
            )
        case .drawableSizeChanged(let isValid):
            return drawableSizeChanged(isValid: isValid)
        case .drawAttempted(let requestID, let drawableAvailable):
            return drawAttempted(
                requestID: requestID,
                drawableAvailable: drawableAvailable
            )
        case .submissionFailed(let requestID, let failure):
            return submissionFailed(requestID: requestID, failure: failure)
        case .presentationClaimed(let requestID, let presentedTime):
            return presentationClaimed(
                requestID: requestID,
                presentedTime: presentedTime
            )
        case .gpuFailureClaimed(let requestID, let message):
            return submissionFailed(
                requestID: requestID,
                failure: .gpu(message)
            )
        case .retryFired(let token):
            return retryFired(token)
        case .deadlineFired(let token):
            return deadlineFired(token)
        case .deadlineClaimResolved(let token, let won):
            return deadlineClaimResolved(token, won: won)
        case .tearDown:
            return []
        }
    }

    private mutating func submit(_ requestID: UInt64) -> [Effect] {
        if let latestID = queue.latestID, requestID <= latestID { return [] }

        let previousLatestID = queue.latestID

        var effects = cancelRetry()
        effects += cancelDeadline()
        deadlineAwaitingClaim = nil
        retryRequestID = requestID
        retryStep = 0

        let supersededID = queue.submit(requestID)
        if let supersededID {
            effects.append(.reportCoalesced(supersededID))
            effects.append(.discardPayload(supersededID))
        }
        if let previousLatestID,
           previousLatestID != supersededID,
           previousLatestID != queue.inFlightID
        {
            // A successfully presented latest revision is no longer represented
            // by the mailbox. Release its retained frame when the next revision
            // arrives; an in-flight revision remains owned until its callback.
            effects.append(.discardPayload(previousLatestID))
        }

        if surface.isReady {
            effects += armDeadline(for: requestID)
            if queue.inFlightID == nil {
                effects.append(.requestDisplay(requestID))
            }
        }
        return effects
    }

    private mutating func surfaceChanged(
        isVisible: Bool,
        hasDrawableSize: Bool
    ) -> [Effect] {
        let nextSurface = Surface(
            isVisible: isVisible,
            hasDrawableSize: hasDrawableSize
        )
        guard nextSurface != surface else { return [] }
        let wasReady = surface.isReady
        surface = nextSurface
        guard surface.isReady else {
            return cancelRetry() + cancelDeadline()
        }

        var effects: [Effect] = []
        if !wasReady, let latestID = queue.latestID {
            // A successfully presented frame has no pending mailbox entry.
            // A newly visible/recreated surface still needs that latest frame
            // rendered again before starting its delivery deadline.
            if queue.inFlightID == nil, queue.pendingID == nil {
                queue.resubmitLatest()
            }
            effects += armDeadline(for: latestID)
        }
        if queue.inFlightID == nil, let pendingID = queue.pendingID {
            effects.append(.requestDisplay(pendingID))
        }
        return effects
    }

    private mutating func drawableSizeChanged(isValid: Bool) -> [Effect] {
        surface.hasDrawableSize = isValid
        guard isValid else {
            return cancelRetry() + cancelDeadline()
        }
        guard let latestID = queue.latestID else { return [] }

        var effects = cancelRetry()
        retryRequestID = latestID
        retryStep = 0
        queue.resubmitLatest()
        if surface.isReady {
            effects += cancelDeadline()
            effects += armDeadline(for: latestID)
            if queue.inFlightID == nil {
                effects.append(.requestDisplay(latestID))
            }
        }
        return effects
    }

    private mutating func drawAttempted(
        requestID: UInt64,
        drawableAvailable: Bool
    ) -> [Effect] {
        guard surface.isReady,
              queue.inFlightID == nil,
              queue.pendingID == requestID
        else { return [] }

        var effects: [Effect] = []
        if deadline == nil {
            effects += armDeadline(for: queue.latestID ?? requestID)
        }
        guard drawableAvailable else {
            effects.append(.reportDrawableUnavailable(requestID))
            effects += scheduleRetry(for: requestID)
            return effects
        }

        effects += cancelRetry()
        guard queue.beginPending(requestID) else { return effects }
        effects.append(.beginSubmission(requestID))
        return effects
    }

    private mutating func submissionFailed(
        requestID: UInt64,
        failure: Failure
    ) -> [Effect] {
        guard queue.inFlightID == requestID,
              queue.finish(requestID)
        else { return [] }

        var effects: [Effect] = [.invalidateSubmission(requestID)]
        if queue.latestID == requestID {
            effects += fail(requestID: requestID, failure: failure)
        } else {
            effects.append(.discardPayload(requestID))
            effects += requestPendingDisplayIfPossible()
        }
        return effects
    }

    private mutating func presentationClaimed(
        requestID: UInt64,
        presentedTime: Double
    ) -> [Effect] {
        guard queue.inFlightID == requestID,
              queue.finish(requestID)
        else { return [] }

        var effects: [Effect] = [.invalidateSubmission(requestID)]
        let isLatest = queue.latestID == requestID
        let wasPresented = presentedTime.isFinite && presentedTime > 0

        if wasPresented {
            retryRequestID = nil
            retryStep = 0
            effects += cancelRetry()
            if isLatest {
                if lastReportedPresentedID != requestID {
                    lastReportedPresentedID = requestID
                    effects.append(
                        .reportPresented(requestID, presentedTime: presentedTime)
                    )
                }
                if queue.pendingID == nil {
                    effects += cancelDeadline()
                } else if deadline == nil, surface.isReady {
                    effects += armDeadline(for: requestID)
                }
            } else {
                effects.append(.discardPayload(requestID))
            }
            effects += requestPendingDisplayIfPossible()
            return effects
        }

        effects.append(.reportDropped(requestID))
        if isLatest {
            queue.resubmitLatest()
            if surface.isReady {
                if deadline == nil {
                    effects += armDeadline(for: requestID)
                }
                effects += scheduleRetry(for: requestID)
            }
        } else {
            effects.append(.discardPayload(requestID))
            effects += requestPendingDisplayIfPossible()
        }
        return effects
    }

    private mutating func retryFired(_ token: Token) -> [Effect] {
        guard retry?.token == token else { return [] }
        retry = nil
        guard surface.isReady,
              queue.inFlightID == nil,
              let pendingID = queue.pendingID
        else { return [] }
        return [.requestDisplay(pendingID)]
    }

    private mutating func deadlineFired(_ token: Token) -> [Effect] {
        guard let scheduled = deadline, scheduled.token == token else { return [] }
        deadline = nil
        guard surface.isReady,
              queue.latestID == scheduled.requestID
        else { return [] }

        if queue.inFlightID == scheduled.requestID {
            deadlineAwaitingClaim = scheduled
            return [
                .claimSubmissionForDeadline(
                    requestID: scheduled.requestID,
                    token: scheduled.token
                )
            ]
        }
        return fail(requestID: scheduled.requestID, failure: .deliveryDeadline)
    }

    private mutating func deadlineClaimResolved(
        _ token: Token,
        won: Bool
    ) -> [Effect] {
        guard let scheduled = deadlineAwaitingClaim,
              scheduled.token == token
        else { return [] }
        deadlineAwaitingClaim = nil
        guard won else { return [] }
        return fail(requestID: scheduled.requestID, failure: .deliveryDeadline)
    }

    private mutating func requestPendingDisplayIfPossible() -> [Effect] {
        guard surface.isReady,
              queue.inFlightID == nil,
              retry == nil,
              let pendingID = queue.pendingID
        else { return [] }
        return [.requestDisplay(pendingID)]
    }

    private mutating func scheduleRetry(for requestID: UInt64) -> [Effect] {
        guard retry == nil,
              queue.latestID == requestID,
              queue.pendingID == requestID,
              surface.isReady
        else { return [] }
        if retryRequestID != requestID {
            retryRequestID = requestID
            retryStep = 0
        }
        let delays = [16, 33, 67, 133]
        let milliseconds = delays[min(retryStep, delays.count - 1)]
        retryStep += 1
        let token = makeToken()
        retry = ScheduledRequest(requestID: requestID, token: token)
        return [.scheduleRetry(token, milliseconds: milliseconds)]
    }

    private mutating func armDeadline(for requestID: UInt64) -> [Effect] {
        guard surface.isReady,
              queue.pendingID == requestID || queue.inFlightID == requestID
        else { return [] }
        if deadline?.requestID == requestID { return [] }
        var effects = cancelDeadline()
        let token = makeToken()
        deadline = ScheduledRequest(requestID: requestID, token: token)
        effects.append(.scheduleDeadline(token, milliseconds: 10_000))
        return effects
    }

    private mutating func cancelRetry() -> [Effect] {
        guard let retry else { return [] }
        self.retry = nil
        return [.cancelRetry(retry.token)]
    }

    private mutating func cancelDeadline() -> [Effect] {
        guard let deadline else { return [] }
        self.deadline = nil
        return [.cancelDeadline(deadline.token)]
    }

    private mutating func fail(
        requestID: UInt64,
        failure: Failure
    ) -> [Effect] {
        guard route == .active, queue.latestID == requestID else { return [] }
        var effects = cancelRetry() + cancelDeadline()
        deadlineAwaitingClaim = nil
        if let inFlightID = queue.inFlightID {
            effects.append(.invalidateSubmission(inFlightID))
        }
        route = .failed(requestID: requestID)
        queue = LatestPreviewQueueState()
        retryRequestID = nil
        effects.append(.discardAllPayloads)
        effects.append(.clearRendererCaches)
        effects.append(.reportFailure(requestID, failure: failure))
        return effects
    }

    private mutating func tearDown() -> [Effect] {
        guard route != .tornDown else { return [] }
        var effects = cancelRetry() + cancelDeadline()
        if let inFlightID = queue.inFlightID {
            effects.append(.invalidateSubmission(inFlightID))
        }
        route = .tornDown
        deadlineAwaitingClaim = nil
        retryRequestID = nil
        retryStep = 0
        queue = LatestPreviewQueueState()
        effects.append(.discardAllPayloads)
        effects.append(.clearRendererCaches)
        return effects
    }

    private mutating func makeToken() -> Token {
        defer { nextTokenValue &+= 1 }
        return Token(rawValue: nextTokenValue)
    }
}

/// Resolves one drawable submission only after its GPU and presentation
/// outcomes are consistent, regardless of callback order.
///
/// A presentation callback is not terminal on its own because Metal does not
/// guarantee its ordering relative to the command-buffer completion callback.
/// In particular, a zero `presentedTime` must not hide a later GPU error. A GPU
/// error is terminal immediately; GPU success waits for the presentation
/// callback. Deadline and teardown claims suppress all later callbacks.
public final class DirectPreviewSubmissionArbiter: @unchecked Sendable {
    public enum Resolution: Equatable, Sendable {
        case presentation(Double)
        case gpuFailure(String?)
    }

    private enum GPUObservation {
        case pending
        case succeeded
    }

    private let lock = NSLock()
    private var gpuObservation = GPUObservation.pending
    private var presentedTime: Double?
    private var isResolved = false

    public init() {}

    public func observePresentation(_ time: Double) -> Resolution? {
        withLock {
            guard !isResolved else { return nil }
            if presentedTime == nil {
                presentedTime = time
            }
            guard case .succeeded = gpuObservation,
                  let presentedTime
            else { return nil }
            isResolved = true
            return .presentation(presentedTime)
        }
    }

    public func observeGPUCompletion(
        failed: Bool,
        message: String? = nil
    ) -> Resolution? {
        withLock {
            guard !isResolved else { return nil }
            if failed {
                isResolved = true
                return .gpuFailure(message)
            }
            gpuObservation = .succeeded
            guard let presentedTime else { return nil }
            isResolved = true
            return .presentation(presentedTime)
        }
    }

    @discardableResult
    public func claimDeadline() -> Bool {
        withLock {
            guard !isResolved else { return false }
            isResolved = true
            return true
        }
    }

    public func invalidate() {
        withLock {
            isResolved = true
        }
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

import Testing
@testable import PhotoCore

@Suite("Direct preview lifecycle")
struct DirectPreviewLifecycleTests {
    @Test func hiddenSubmitKeepsPendingWithoutDrawingOrDeadline() {
        var lifecycle = DirectPreviewLifecycle()

        let effects = lifecycle.reduce(.submit(1))

        #expect(effects.isEmpty)
        #expect(lifecycle.queue.latestID == 1)
        #expect(lifecycle.queue.pendingID == 1)
        #expect(lifecycle.deadline == nil)
    }

    @Test func visibleZeroSizeDoesNotStartDelivery() {
        var lifecycle = DirectPreviewLifecycle()
        _ = lifecycle.reduce(
            .surfaceChanged(isVisible: true, hasDrawableSize: false)
        )

        let effects = lifecycle.reduce(.submit(1))

        #expect(effects.isEmpty)
        #expect(lifecycle.surface.isVisible)
        #expect(!lifecycle.surface.isReady)
        #expect(lifecycle.deadline == nil)
    }

    @Test func becomingReadySchedulesOneDeadlineAndOneDraw() throws {
        var lifecycle = DirectPreviewLifecycle()
        _ = lifecycle.reduce(.submit(1))

        let effects = lifecycle.reduce(
            .surfaceChanged(isVisible: true, hasDrawableSize: true)
        )
        let token = try #require(lifecycle.deadline?.token)

        #expect(effects.contains(.scheduleDeadline(token, milliseconds: 10_000)))
        #expect(effects.contains(.requestDisplay(1)))
        #expect(effects.filter { effect in
            if case .scheduleDeadline = effect { true } else { false }
        }.count == 1)
    }

    @Test func repeatedNilDrawableKeepsPendingAndOnlyOneRetry() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))

        let first = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: false)
        )
        let token = try #require(lifecycle.retry?.token)
        let second = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: false)
        )

        #expect(first.contains(.reportDrawableUnavailable(1)))
        #expect(first.contains(.scheduleRetry(token, milliseconds: 16)))
        #expect(second == [.reportDrawableUnavailable(1)])
        #expect(lifecycle.queue.pendingID == 1)
        #expect(lifecycle.queue.inFlightID == nil)
    }

    @Test func retryBackoffSaturatesAtOneHundredThirtyThreeMilliseconds() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        var delays: [Int] = []

        for _ in 0..<6 {
            let effects = lifecycle.reduce(
                .drawAttempted(requestID: 1, drawableAvailable: false)
            )
            for effect in effects {
                if case .scheduleRetry(_, let milliseconds) = effect {
                    delays.append(milliseconds)
                }
            }
            let token = try #require(lifecycle.retry?.token)
            _ = lifecycle.reduce(.retryFired(token))
        }

        #expect(delays == [16, 33, 67, 133, 133, 133])
    }

    @Test func staleRetryTokenCannotWakeANewerRequest() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: false)
        )
        let stale = try #require(lifecycle.retry?.token)

        let submitEffects = lifecycle.reduce(.submit(2))
        let staleEffects = lifecycle.reduce(.retryFired(stale))

        #expect(submitEffects.contains(.cancelRetry(stale)))
        #expect(staleEffects.isEmpty)
        #expect(lifecycle.queue.pendingID == 2)
    }

    @Test func inFlightFrameKeepsOnlyNewestPendingSubmission() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        let begin = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        let submitTwo = lifecycle.reduce(.submit(2))
        let submitThree = lifecycle.reduce(.submit(3))

        #expect(begin.contains(.beginSubmission(1)))
        #expect(submitTwo.contains(.requestDisplay(2)) == false)
        #expect(submitThree.contains(.reportCoalesced(2)))
        #expect(submitThree.contains(.discardPayload(2)))
        #expect(lifecycle.queue.inFlightID == 1)
        #expect(lifecycle.queue.pendingID == 3)
    }

    @Test func stalePresentationAdvancesButDoesNotCompleteLatest() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        _ = lifecycle.reduce(.submit(2))

        let effects = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 42)
        )

        #expect(!effects.contains(.reportPresented(1, presentedTime: 42)))
        #expect(effects.contains(.discardPayload(1)))
        #expect(effects.contains(.requestDisplay(2)))
        #expect(lifecycle.queue.pendingID == 2)
        #expect(lifecycle.route == .active)
    }

    @Test func zeroPresentedTimeDropsAndRequeuesLatest() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )

        let effects = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 0)
        )
        let retryToken = try #require(lifecycle.retry?.token)

        #expect(effects.contains(.reportDropped(1)))
        #expect(effects.contains(.scheduleRetry(retryToken, milliseconds: 16)))
        #expect(lifecycle.queue.pendingID == 1)
        #expect(lifecycle.queue.inFlightID == nil)
    }

    @Test func nonFinitePresentedTimeIsAlsoADrop() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )

        let effects = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: .infinity)
        )

        #expect(effects.contains(.reportDropped(1)))
        #expect(lifecycle.queue.pendingID == 1)
    }

    @Test func positiveLatestPresentationIsReportedExactlyOnce() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )

        let first = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 12.5)
        )
        let duplicate = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 13)
        )

        #expect(first.contains(.reportPresented(1, presentedTime: 12.5)))
        #expect(duplicate.isEmpty)
        #expect(lifecycle.lastReportedPresentedID == 1)
        #expect(lifecycle.deadline == nil)
    }

    @Test func nextSubmissionDiscardsPreviouslyPresentedPayload() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        _ = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 12.5)
        )

        let effects = lifecycle.reduce(.submit(2))

        #expect(effects.contains(.discardPayload(1)))
        #expect(!effects.contains(.reportCoalesced(1)))
        #expect(lifecycle.queue.latestID == 2)
        #expect(lifecycle.queue.pendingID == 2)
    }

    @Test func hiddenAndZeroSizeCancelTimersThenResumeWithFreshTokens() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: false)
        )
        let oldRetry = try #require(lifecycle.retry?.token)
        let oldDeadline = try #require(lifecycle.deadline?.token)

        let hidden = lifecycle.reduce(
            .surfaceChanged(isVisible: false, hasDrawableSize: true)
        )
        let stillInvalid = lifecycle.reduce(
            .surfaceChanged(isVisible: true, hasDrawableSize: false)
        )
        let resumed = lifecycle.reduce(
            .surfaceChanged(isVisible: true, hasDrawableSize: true)
        )
        let newDeadline = try #require(lifecycle.deadline?.token)

        #expect(hidden.contains(.cancelRetry(oldRetry)))
        #expect(hidden.contains(.cancelDeadline(oldDeadline)))
        #expect(stillInvalid.isEmpty)
        #expect(newDeadline != oldDeadline)
        #expect(resumed.contains(.scheduleDeadline(newDeadline, milliseconds: 10_000)))
        #expect(resumed.contains(.requestDisplay(1)))
    }

    @Test func showingAfterPresentationResubmitsInsteadOfTimingOutIdleState() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        _ = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 5)
        )
        _ = lifecycle.reduce(
            .surfaceChanged(isVisible: false, hasDrawableSize: true)
        )

        let effects = lifecycle.reduce(
            .surfaceChanged(isVisible: true, hasDrawableSize: true)
        )
        let deadline = try #require(lifecycle.deadline)

        #expect(lifecycle.queue.pendingID == 1)
        #expect(effects.contains(.requestDisplay(1)))
        #expect(effects.contains(
            .scheduleDeadline(deadline.token, milliseconds: 10_000)
        ))
    }

    @Test func identicalSurfaceNotificationIsACompleteNoOp() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))

        let effects = lifecycle.reduce(
            .surfaceChanged(isVisible: true, hasDrawableSize: true)
        )

        #expect(effects.isEmpty)
    }

    @Test func resizeResubmitsLatestAndDoesNotReplaceNewerPending() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        _ = lifecycle.reduce(.submit(2))

        _ = lifecycle.reduce(.drawableSizeChanged(isValid: true))

        #expect(lifecycle.queue.inFlightID == 1)
        #expect(lifecycle.queue.pendingID == 2)
        #expect(lifecycle.deadline?.requestID == 2)
    }

    @Test func resizeAfterPresentationRendersSameLatestWithoutDoubleReporting() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        _ = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 5)
        )

        let resize = lifecycle.reduce(.drawableSizeChanged(isValid: true))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        let secondPresentation = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 6)
        )

        #expect(resize.contains(.requestDisplay(1)))
        #expect(!secondPresentation.contains(.reportPresented(1, presentedTime: 6)))
    }

    @Test func callbackWinningDeadlineRaceDoesNotFallback() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        let deadlineToken = try #require(lifecycle.deadline?.token)

        let claim = lifecycle.reduce(.deadlineFired(deadlineToken))
        let lost = lifecycle.reduce(
            .deadlineClaimResolved(deadlineToken, won: false)
        )
        let callback = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 10)
        )

        #expect(claim.contains(
            .claimSubmissionForDeadline(requestID: 1, token: deadlineToken)
        ))
        #expect(lost.isEmpty)
        #expect(callback.contains(.reportPresented(1, presentedTime: 10)))
        #expect(lifecycle.route == .active)
    }

    @Test func deadlineWinningRaceFailsExactlyOnceAndIgnoresLateCallback() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        let token = try #require(lifecycle.deadline?.token)
        _ = lifecycle.reduce(.deadlineFired(token))

        let won = lifecycle.reduce(.deadlineClaimResolved(token, won: true))
        let duplicate = lifecycle.reduce(.deadlineClaimResolved(token, won: true))
        let late = lifecycle.reduce(
            .presentationClaimed(requestID: 1, presentedTime: 11)
        )

        #expect(won.contains(.reportFailure(1, failure: .deliveryDeadline)))
        #expect(duplicate.isEmpty)
        #expect(late.isEmpty)
        #expect(lifecycle.route == .failed(requestID: 1))
    }

    @Test func pendingDeadlineFailsWithoutWaitingForACompletionClaim() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        let token = try #require(lifecycle.deadline?.token)

        let effects = lifecycle.reduce(.deadlineFired(token))

        #expect(effects.contains(.reportFailure(1, failure: .deliveryDeadline)))
        #expect(!effects.contains(
            .claimSubmissionForDeadline(requestID: 1, token: token)
        ))
        #expect(lifecycle.route == .failed(requestID: 1))
    }

    @Test func teardownCancelsResourcesAndIgnoresEveryLaterEvent() throws {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(1))
        _ = lifecycle.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        let deadline = try #require(lifecycle.deadline?.token)

        let effects = lifecycle.reduce(.tearDown)
        let laterEvents = [
            lifecycle.reduce(.deadlineFired(deadline)),
            lifecycle.reduce(.submit(2)),
            lifecycle.reduce(
                .presentationClaimed(requestID: 1, presentedTime: 20)
            ),
            lifecycle.reduce(
                .gpuFailureClaimed(requestID: 1, message: "late")
            )
        ]

        #expect(effects.contains(.cancelDeadline(deadline)))
        #expect(effects.contains(.invalidateSubmission(1)))
        #expect(effects.contains(.discardAllPayloads))
        #expect(effects.contains(.clearRendererCaches))
        for later in laterEvents {
            #expect(later.isEmpty)
        }
        #expect(lifecycle.route == .tornDown)
    }

    @Test func latestSubmissionFailureIsTerminalButStaleFailureAdvances() {
        var latest = readyLifecycle()
        _ = latest.reduce(.submit(1))
        _ = latest.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        let terminal = latest.reduce(
            .submissionFailed(requestID: 1, failure: .submission("encode"))
        )

        var stale = readyLifecycle()
        _ = stale.reduce(.submit(1))
        _ = stale.reduce(
            .drawAttempted(requestID: 1, drawableAvailable: true)
        )
        _ = stale.reduce(.submit(2))
        let advance = stale.reduce(
            .gpuFailureClaimed(requestID: 1, message: "gpu")
        )

        #expect(terminal.contains(
            .reportFailure(1, failure: .submission("encode"))
        ))
        #expect(latest.route == .failed(requestID: 1))
        #expect(advance.contains(.discardPayload(1)))
        #expect(advance.contains(.requestDisplay(2)))
        #expect(stale.route == .active)
    }

    @Test func duplicateAndOutOfOrderSubmissionsAreIgnored() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(2))

        #expect(lifecycle.reduce(.submit(2)).isEmpty)
        #expect(lifecycle.reduce(.submit(1)).isEmpty)
        #expect(lifecycle.queue.latestID == 2)
        #expect(lifecycle.queue.pendingID == 2)
    }

    @Test func rendererFailureOnlyAppliesToTheCurrentLatestRequest() {
        var lifecycle = readyLifecycle()
        _ = lifecycle.reduce(.submit(2))

        let stale = lifecycle.reduce(
            .failLatest(requestID: 1, failure: .rendererUnavailable("none"))
        )
        let current = lifecycle.reduce(
            .failLatest(requestID: 2, failure: .rendererUnavailable("none"))
        )

        #expect(stale.isEmpty)
        #expect(current.contains(
            .reportFailure(2, failure: .rendererUnavailable("none"))
        ))
        #expect(lifecycle.route == .failed(requestID: 2))
    }

    @Test func submissionArbiterResolvesSuccessfulCallbacksInEitherOrder() {
        let presentationFirst = DirectPreviewSubmissionArbiter()
        #expect(presentationFirst.observePresentation(12.5) == nil)
        #expect(presentationFirst.observeGPUCompletion(failed: false) == .presentation(12.5))

        let gpuFirst = DirectPreviewSubmissionArbiter()
        #expect(gpuFirst.observeGPUCompletion(failed: false) == nil)
        #expect(gpuFirst.observePresentation(13.5) == .presentation(13.5))
    }

    @Test func submissionArbiterPreservesZeroPresentationForReducerDropHandling() {
        let presentationFirst = DirectPreviewSubmissionArbiter()
        #expect(presentationFirst.observePresentation(0) == nil)
        #expect(presentationFirst.observeGPUCompletion(failed: false) == .presentation(0))

        let gpuFirst = DirectPreviewSubmissionArbiter()
        #expect(gpuFirst.observeGPUCompletion(failed: false) == nil)
        #expect(gpuFirst.observePresentation(0) == .presentation(0))
    }

    @Test func submissionArbiterGPUErrorWinsRegardlessOfPresentationOrder() {
        let presentationFirst = DirectPreviewSubmissionArbiter()
        #expect(presentationFirst.observePresentation(0) == nil)
        #expect(
            presentationFirst.observeGPUCompletion(failed: true, message: "gpu")
                == .gpuFailure("gpu")
        )

        let gpuFirst = DirectPreviewSubmissionArbiter()
        #expect(
            gpuFirst.observeGPUCompletion(failed: true, message: "gpu")
                == .gpuFailure("gpu")
        )
        #expect(gpuFirst.observePresentation(42) == nil)
    }

    @Test func submissionArbiterDeadlineSuppressesEveryLateCallback() {
        let arbiter = DirectPreviewSubmissionArbiter()
        #expect(arbiter.observePresentation(7) == nil)
        #expect(arbiter.claimDeadline())
        #expect(arbiter.observeGPUCompletion(failed: false) == nil)
        #expect(arbiter.observeGPUCompletion(failed: true, message: "late") == nil)
        #expect(!arbiter.claimDeadline())
    }

    @Test func submissionArbiterInvalidationAndDuplicateCallbacksAreNoOps() {
        let invalidated = DirectPreviewSubmissionArbiter()
        invalidated.invalidate()
        #expect(invalidated.observePresentation(7) == nil)
        #expect(invalidated.observeGPUCompletion(failed: false) == nil)
        #expect(!invalidated.claimDeadline())

        let resolved = DirectPreviewSubmissionArbiter()
        #expect(resolved.observeGPUCompletion(failed: false) == nil)
        #expect(resolved.observePresentation(8) == .presentation(8))
        #expect(resolved.observePresentation(9) == nil)
        #expect(resolved.observeGPUCompletion(failed: true, message: "late") == nil)
    }

    @Test func submissionArbiterConcurrentErrorAndPresentationResolveOnce() async {
        let arbiter = DirectPreviewSubmissionArbiter()
        let resolutions = await withTaskGroup(
            of: DirectPreviewSubmissionArbiter.Resolution?.self,
            returning: [DirectPreviewSubmissionArbiter.Resolution].self
        ) { group in
            group.addTask {
                arbiter.observePresentation(0)
            }
            group.addTask {
                arbiter.observeGPUCompletion(failed: true, message: "gpu")
            }
            var resolutions: [DirectPreviewSubmissionArbiter.Resolution] = []
            for await resolution in group {
                if let resolution {
                    resolutions.append(resolution)
                }
            }
            return resolutions
        }

        #expect(resolutions == [.gpuFailure("gpu")])
    }

    private func readyLifecycle() -> DirectPreviewLifecycle {
        var lifecycle = DirectPreviewLifecycle()
        _ = lifecycle.reduce(
            .surfaceChanged(isVisible: true, hasDrawableSize: true)
        )
        return lifecycle
    }
}

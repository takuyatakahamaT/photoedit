import PhotoBenchAppSupport
import Testing

/// `PreviewRenderPump`: a continuous drag keeps presenting frames, the exact
/// frame follows the drag once, and new input supersedes it.
struct PreviewRenderPumpTests {
    typealias Pump = PreviewRenderPump<String>

    /// Runs `job` to completion (presenting it when the pump allows) and
    /// returns the job the pump starts next.
    private func complete(_ job: Pump.Job, in pump: inout Pump, presented: inout [String]) -> Pump.Job? {
        if pump.canPresent(job) {
            pump.presented(job)
            presented.append("\(job.revision)\(job.kind == .drag ? "~" : "")")
        }
        return pump.finish(job)
    }

    @Test func continuousDragPresentsTheRunningFrameAndOnlyTheNewestWaitingTick() throws {
        var pump = Pump()
        var presented: [String] = []
        pump.beginDrag()
        let firstSubmitted = pump.submit(revision: 1, isDragFrame: true, payload: "a")
        let first = try #require(firstSubmitted)
        #expect(first.kind == .drag)
        // Ticks 2...4 arrive while tick 1 renders: they wait, newest wins.
        let second = pump.submit(revision: 2, isDragFrame: true, payload: "b")
        let third = pump.submit(revision: 3, isDragFrame: true, payload: "c")
        let fourth = pump.submit(revision: 4, isDragFrame: true, payload: "d")
        #expect(second == nil && third == nil && fourth == nil)
        let afterFirst = complete(first, in: &pump, presented: &presented)
        let next = try #require(afterFirst)
        #expect(next.revision == 4)
        #expect(next.payload == "d")
        #expect(next.kind == .drag)
        // Still dragging: no settle job after the last tick.
        let afterNext = complete(next, in: &pump, presented: &presented)
        #expect(afterNext == nil)
        #expect(presented == ["1~", "4~"])

        // Release: one exact render of the same revision replaces it.
        let released = pump.endDrag()
        let settle = try #require(released)
        #expect(settle.kind == .settle)
        #expect(settle.revision == 4)
        #expect(settle.payload == nil)
        let afterSettle = complete(settle, in: &pump, presented: &presented)
        #expect(afterSettle == nil)
        #expect(presented == ["1~", "4~", "4"])
        #expect(!pump.presentedIsApproximate)
        let releasedAgain = pump.endDrag()
        #expect(releasedAgain == nil)
    }

    @Test func releaseWhileAFrameRendersSettlesAfterIt() throws {
        var pump = Pump()
        var presented: [String] = []
        pump.beginDrag()
        let firstSubmitted = pump.submit(revision: 7, isDragFrame: true, payload: "x")
        let first = try #require(firstSubmitted)
        let waitingTick = pump.submit(revision: 8, isDragFrame: true, payload: "y")
        #expect(waitingTick == nil)
        let early = pump.endDrag()
        #expect(early == nil)  // a frame is still running and one waits
        let afterFirst = complete(first, in: &pump, presented: &presented)
        let waiting = try #require(afterFirst)
        #expect(waiting.revision == 8 && waiting.kind == .drag)
        let afterWaiting = complete(waiting, in: &pump, presented: &presented)
        let settle = try #require(afterWaiting)
        #expect(settle.kind == .settle && settle.revision == 8)
        _ = complete(settle, in: &pump, presented: &presented)
        #expect(presented == ["7~", "8~", "8"])
    }

    @Test func newInputSupersedesTheSettleRender() throws {
        var pump = Pump()
        var presented: [String] = []
        pump.beginDrag()
        let tickSubmitted = pump.submit(revision: 1, isDragFrame: true, payload: "a")
        let tick = try #require(tickSubmitted)
        _ = complete(tick, in: &pump, presented: &presented)
        let released = pump.endDrag()
        let settle = try #require(released)
        // A new drag starts before the exact frame is ready: its first tick
        // supersedes the settle job (the caller cancels that render).
        pump.beginDrag()
        let newTickSubmitted = pump.submit(revision: 2, isDragFrame: true, payload: "b")
        let newTick = try #require(newTickSubmitted)
        #expect(newTick.kind == .drag)
        let afterCancelledSettle = pump.finish(settle)
        #expect(afterCancelledSettle == nil)
        _ = complete(newTick, in: &pump, presented: &presented)
        let releasedAgain = pump.endDrag()
        let secondSettle = try #require(releasedAgain)
        #expect(secondSettle.revision == 2)
        _ = complete(secondSettle, in: &pump, presented: &presented)
        #expect(presented == ["1~", "2~", "2"])
    }

    @Test func exactEditsSupersedeTheRunningRender() throws {
        var pump = Pump()
        var presented: [String] = []
        let firstSubmitted = pump.submit(revision: 1, isDragFrame: false, payload: "a")
        let first = try #require(firstSubmitted)
        let secondSubmitted = pump.submit(revision: 2, isDragFrame: false, payload: "b")
        let second = try #require(secondSubmitted)
        #expect(second.serial != first.serial)
        let afterSuperseded = pump.finish(first)
        #expect(afterSuperseded == nil)
        let afterSecond = complete(second, in: &pump, presented: &presented)
        #expect(afterSecond == nil)
        #expect(presented == ["2"])
        // An exact frame is never followed by a settle job.
        let released = pump.endDrag()
        #expect(released == nil)
    }

    @Test func aStaleFrameNeverReplacesANewerOne() throws {
        var pump = Pump()
        pump.presentedExactFrame(revision: 5)
        let oldSubmitted = pump.submit(revision: 4, isDragFrame: false, payload: "old")
        let old = try #require(oldSubmitted)
        #expect(!pump.canPresent(old))
        pump.beginDrag()
        let dragSubmitted = pump.submit(revision: 6, isDragFrame: true, payload: "d")
        let drag = try #require(dragSubmitted)
        #expect(pump.canPresent(drag))
        pump.presented(drag)
        // The exact frame of the shown drag revision may replace it; another
        // drag frame of the same revision may not.
        #expect(!pump.canPresent(drag))
    }

    @Test func aFailingSettleIsNotRetriedForTheSameRevision() throws {
        var pump = Pump()
        var presented: [String] = []
        pump.beginDrag()
        let tickSubmitted = pump.submit(revision: 3, isDragFrame: true, payload: "a")
        let tick = try #require(tickSubmitted)
        _ = complete(tick, in: &pump, presented: &presented)
        let released = pump.endDrag()
        let settle = try #require(released)
        // The settle render fails: it finishes without being presented.
        let afterFailure = pump.finish(settle)
        #expect(afterFailure == nil)
        let releasedAgain = pump.endDrag()
        #expect(releasedAgain == nil)
        #expect(pump.presentedIsApproximate)
    }

    @Test func resetForgetsRunningAndWaitingJobs() throws {
        var pump = Pump()
        pump.beginDrag()
        let tickSubmitted = pump.submit(revision: 1, isDragFrame: true, payload: "a")
        let tick = try #require(tickSubmitted)
        let waiting = pump.submit(revision: 2, isDragFrame: true, payload: "b")
        #expect(waiting == nil)
        pump.reset()
        #expect(pump.running?.serial == nil)
        #expect(pump.waitingDrag?.revision == nil)
        let afterReset = pump.finish(tick)
        #expect(afterReset == nil)
        let freshSubmitted = pump.submit(revision: 3, isDragFrame: true, payload: "c")
        let fresh = try #require(freshSubmitted)
        #expect(fresh.kind == .drag)
    }
}

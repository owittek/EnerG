import Testing
@testable import EnerGCore

private let start = ContinuousClock.now

/// `seconds` after the start of the test clock.
private func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

/// A Reconciler that has received `status` from its first poll.
private func ready(_ status: Status) -> Reconciler {
    var reconciler = Reconciler()
    let token = reconciler.beginPoll()!
    reconciler.received(status, for: token, now: at(0))
    return reconciler
}

struct ReconcilerQueueTests {
    @Test func latestClickWinsWhileARequestIsInFlight() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (first, token) = r.nextCommand()!
        #expect(first == .setPaused(true))
        r.want(.setPaused(false), now: at(0.1))
        r.want(.setPaused(true), now: at(0.2))
        let whileInFlight = r.nextCommand()?.0
        #expect(whileInFlight == nil)
        r.received(reported(Settings(paused: true), percent: 80), for: token, now: at(0.3))
        let afterReply = r.nextCommand()?.0
        #expect(afterReply == nil)
    }

    @Test func pauseThenResumeWhileInFlightSendsTheResume() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, token) = r.nextCommand()!
        r.want(.setPaused(false), now: at(0.1))
        r.received(reported(Settings(paused: true), percent: 80), for: token, now: at(0.3))
        let next = r.nextCommand()?.0
        #expect(next == .setPaused(false))
    }

    @Test func clicksThatCancelOutSendNothing() {
        var r = ready(reported(percent: 80))
        let poll = r.beginPoll()!
        r.want(.setPaused(true), now: at(0))
        r.want(.setPaused(false), now: at(0.1))
        r.received(reported(percent: 80), for: poll, now: at(0.2))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func aPollAnsweredBeforeTheRequestRunsDoesNotForgetIt() {
        var r = ready(reported(Settings(paused: true)))
        let poll = r.beginPoll()!
        r.want(.setPaused(false), now: at(0))
        r.received(reported(Settings(paused: true)), for: poll, now: at(0.1))
        let blockedPoll = r.beginPoll()
        #expect(blockedPoll == nil)
        let next = r.nextCommand()?.0
        #expect(next == .setPaused(false))
    }

    @Test func sendOrderIsPausedLimitTopUpLED() {
        var r = ready(reported(percent: 70))
        r.want(.setLEDMode(.off), now: at(0))
        let (led, token) = r.nextCommand()!
        #expect(led == .setLEDMode(.off))
        r.want(.topUp, now: at(0.1))
        r.want(.setLimit(90), now: at(0.1))
        r.received(reported(Settings(ledMode: .off), percent: 70), for: token, now: at(0.2))
        let next = r.nextCommand()?.0
        #expect(next == .setLimit(90))
    }

    @Test func pauseDropsAWantedTopUp() {
        var r = ready(reported(percent: 85))
        r.want(.topUp, now: at(0))
        r.want(.setPaused(true), now: at(0.1))
        let (request, token) = r.nextCommand()!
        #expect(request == .setPaused(true))
        r.received(reported(Settings(paused: true), percent: 85), for: token, now: at(0.3))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func followsATopUpEndedByEnergd() {
        var r = ready(reported(percent: 99, toppingUp: true))
        r.want(.setLEDMode(.off), now: at(0))
        let (_, token) = r.nextCommand()!
        r.received(reported(Settings(ledMode: .off), percent: 100, toppingUp: false), for: token, now: at(0.3))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func aRefusedRequestIsDropped() {
        var r = ready(reported(percent: 85, plugged: false))
        r.want(.topUp, now: at(0))
        let (request, token) = r.nextCommand()!
        #expect(request == .topUp)
        r.received(reported(percent: 85, plugged: false), for: token, now: at(0.3))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func clicksBeforeTheFirstStatusAreIgnored() {
        var r = Reconciler()
        r.want(.setPaused(true), now: at(0))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func repliesFromBeforeAResetAreStale() {
        var r = Reconciler()
        let poll = r.beginPoll()!
        r.reset()
        let applied = r.received(reported(), for: poll, now: at(0))
        #expect(!applied)
        let outcome = r.failed(poll, now: at(0))
        #expect(outcome == .stale)
        let fresh = r.beginPoll()
        #expect(fresh != nil)
    }

    @Test func aShortOutageIsRetried() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, first) = r.nextCommand()!
        let outcome = r.failed(first, now: at(0))
        #expect(outcome == .retry)
        #expect(r.waitingForHelper)
        let (again, second) = r.nextCommand()!
        #expect(again == .setPaused(true))
        r.received(reported(Settings(paused: true), percent: 80), for: second, now: at(3))
        #expect(!r.waitingForHelper)
    }

    @Test func aLongOutageGivesUpAfterTheRetryWindow() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        for second in 0..<10 {
            let (_, token) = r.nextCommand()!
            let outcome = r.failed(token, now: at(Double(second)))
            #expect(outcome == .retry)
        }
        let (_, last) = r.nextCommand()!
        let outcome = r.failed(last, now: at(10))
        #expect(outcome == .gaveUp)
        #expect(!r.waitingForHelper)
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func aClickDuringTheRetryWindowReplacesThePendingChange() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, token) = r.nextCommand()!
        _ = r.failed(token, now: at(0))
        r.want(.setPaused(false), now: at(0.5))
        #expect(!r.waitingForHelper)
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func aFailureAfterACancelBackClickWaitsForAPoll() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, token) = r.nextCommand()!
        r.want(.setPaused(false), now: at(0.1))
        let outcome = r.failed(token, now: at(0))
        #expect(outcome == .retry)
        #expect(!r.waitingForHelper)
        let next = r.nextCommand()?.0
        #expect(next == nil)
        let poll = r.beginPoll()
        #expect(poll != nil)
        r.received(reported(Settings(paused: true), percent: 80), for: poll!, now: at(1))
        let resume = r.nextCommand()?.0
        #expect(resume == .setPaused(false))
    }

    @Test func aFailedPollIsNotRetriedHere() {
        var r = Reconciler()
        let poll = r.beginPoll()!
        let outcome = r.failed(poll, now: at(0))
        #expect(outcome == .retry)
        #expect(!r.waitingForHelper)
        let next = r.beginPoll()
        #expect(next != nil)
    }
}

struct ReconcilerDisplayTests {
    /// Paused at `percent` with limit `limit`, macOS charging.
    private func pausedAt(_ percent: Int, limit: Int = 80, charging: Bool = true) -> Reconciler {
        ready(reported(Settings(chargeLimit: limit, paused: true), percent: percent, charging: charging))
    }

    @Test func resumeShowsThePredictionAndHidesTheStaleCharging() {
        var r = pausedAt(85)
        r.want(.setPaused(false), now: at(0))
        #expect(r.displayed(now: at(0))?.stateLabel == "Draining to 80%")
        let (_, token) = r.nextCommand()!
        r.received(reported(percent: 85, charging: true), for: token, now: at(0.3))
        #expect(r.displayed(now: at(0.4))?.stateLabel == "Draining to 80%")
        #expect(r.isSettling(now: at(0.4)))
        let poll = r.beginPoll()!
        r.received(reported(percent: 85), for: poll, now: at(2))
        #expect(!r.isSettling(now: at(2)))
        #expect(r.displayed(now: at(2))?.stateLabel == "Draining to 80%")
    }

    @Test func theCapStartsWhenTheQueueEmpties() {
        var r = pausedAt(70, limit: 60)
        r.want(.setPaused(false), now: at(0))
        #expect(r.settleDeadline == nil)
        let (_, token) = r.nextCommand()!
        r.received(reported(Settings(chargeLimit: 60), percent: 70, charging: true), for: token, now: at(5))
        #expect(r.settleDeadline == at(11))
        #expect(r.displayed(now: at(10.9))?.stateLabel == "Draining to 60%")
        #expect(r.displayed(now: at(11.1))?.stateLabel == "Charging")
        #expect(!r.isSettling(now: at(11.1)))
    }

    @Test func pauseShowsPausedAtOnce() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let shown = r.displayed(now: at(0))
        #expect(shown?.state == .paused)
        #expect(shown?.settings.paused == true)
    }

    @Test func aRejectedLowLimitCorrectsOnceTo80() {
        var r = ready(reported(percent: 85))
        r.want(.setLimit(60), now: at(0))
        #expect(r.displayed(now: at(0))?.stateLabel == "Draining to 60%")
        let (_, token) = r.nextCommand()!
        r.received(reported(Settings(chargeLimit: 60), percent: 85, warnings: [.lowLimitUnsupported]),
                   for: token, now: at(5))
        #expect(!r.isSettling(now: at(5)))
        #expect(r.displayed(now: at(5))?.stateLabel == "Draining to 80%")
    }

    @Test func theBandUsesTheChargingStateFromBeforeTheClick() {
        var r = pausedAt(77, charging: false)
        r.want(.setPaused(false), now: at(0))
        #expect(r.displayed(now: at(0))?.stateLabel == "Not charging · resumes below 75%")
        let (_, token) = r.nextCommand()!
        r.received(reported(percent: 77, charging: true), for: token, now: at(0.3))
        #expect(r.displayed(now: at(0.4))?.stateLabel == "Not charging · resumes below 75%")
        let poll = r.beginPoll()!
        r.received(reported(percent: 77), for: poll, now: at(2))
        #expect(!r.isSettling(now: at(2)))
    }

    @Test func anLEDChangeLeavesTheChargeStateAsReported() {
        var r = ready(reported(percent: 70))
        r.want(.setLEDMode(.off), now: at(0))
        let shown = r.displayed(now: at(0))
        #expect(shown?.stateLabel == "Not charging")
        #expect(shown?.settings.ledMode == .off)
    }

    @Test func reopeningHoldsWhatWasShownUntilAFreshPoll() {
        var r = pausedAt(85)
        r.want(.setPaused(false), now: at(0))
        let (_, token) = r.nextCommand()!
        r.closed(now: at(0.2))
        r.received(reported(percent: 85, charging: true), for: token, now: at(5))
        #expect(r.displayed(now: at(12))?.stateLabel == "Draining to 80%")
        let poll = r.beginPoll()!
        r.received(reported(percent: 79), for: poll, now: at(12.2))
        #expect(r.displayed(now: at(12.2))?.stateLabel == "Not charging · resumes below 75%")
        #expect(!r.isSettling(now: at(12.2)))
    }

    @Test func aPollSentBeforeClosingDoesNotEndTheHold() {
        var r = ready(reported(percent: 80))
        let early = r.beginPoll()!
        r.closed(now: at(0))
        r.received(reported(percent: 79), for: early, now: at(0.2))
        #expect(r.displayed(now: at(0.3))?.stateLabel == "Holding at 80%")
        let fresh = r.beginPoll()!
        r.received(reported(percent: 79), for: fresh, now: at(1))
        #expect(r.displayed(now: at(1))?.stateLabel == "Not charging · resumes below 75%")
    }

    @Test func aFailureWithNothingLeftToSendStillCapsTheSettle() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, token) = r.nextCommand()!
        r.want(.setPaused(false), now: at(0.1))
        _ = r.failed(token, now: at(1))
        #expect(!r.isSettling(now: at(7.1)))
        #expect(r.displayed(now: at(7.1))?.state != .paused)
    }

    @Test func retriesKeepThePredictionAndGivingUpShowsTheTruth() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        for second in 0..<10 {
            let (_, token) = r.nextCommand()!
            _ = r.failed(token, now: at(Double(second)))
            #expect(r.displayed(now: at(Double(second)))?.state == .paused)
        }
        let (_, last) = r.nextCommand()!
        let outcome = r.failed(last, now: at(10))
        #expect(outcome == .gaveUp)
        #expect(r.displayed(now: at(10))?.stateLabel == "Holding at 80%")
        #expect(!r.isSettling(now: at(10)))
    }

    @Test func pauseThenResumeInFlightHidesTheStaleChargingReply() {
        var r = ready(reported(percent: 85))
        r.want(.setPaused(true), now: at(0))
        let (_, pause) = r.nextCommand()!
        r.want(.setPaused(false), now: at(0.1))
        r.received(reported(Settings(paused: true), percent: 85), for: pause, now: at(0.3))
        let (_, resume) = r.nextCommand()!
        r.received(reported(percent: 85, charging: true), for: resume, now: at(0.6))
        #expect(r.displayed(now: at(0.7))?.stateLabel == "Draining to 80%")
        #expect(r.isSettling(now: at(0.7)))
        let poll = r.beginPoll()!
        r.received(reported(percent: 85), for: poll, now: at(2))
        #expect(!r.isSettling(now: at(2)))
        #expect(r.displayed(now: at(2))?.stateLabel == "Draining to 80%")
    }

    @Test func topUpThenStopInFlightHidesTheStaleChargingReply() {
        var r = ready(reported(percent: 85))
        r.want(.topUp, now: at(0))
        let (_, topUp) = r.nextCommand()!
        r.want(.cancelTopUp, now: at(0.1))
        r.received(reported(percent: 85, charging: true, toppingUp: true), for: topUp, now: at(0.3))
        let (stop, token) = r.nextCommand()!
        #expect(stop == .cancelTopUp)
        r.received(reported(percent: 85, charging: true), for: token, now: at(0.6))
        #expect(r.displayed(now: at(0.7))?.stateLabel == "Draining to 80%")
        #expect(r.isSettling(now: at(0.7)))
        let poll = r.beginPoll()!
        r.received(reported(percent: 85), for: poll, now: at(2))
        #expect(!r.isSettling(now: at(2)))
    }

    @Test func givingUpWhileClosedShowsTheTruth() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, first) = r.nextCommand()!
        _ = r.failed(first, now: at(0))
        r.closed(now: at(0.5))
        for second in 1..<10 {
            let (_, token) = r.nextCommand()!
            _ = r.failed(token, now: at(Double(second)))
        }
        let (_, last) = r.nextCommand()!
        let outcome = r.failed(last, now: at(10))
        #expect(outcome == .gaveUp)
        #expect(r.displayed(now: at(10))?.stateLabel == "Holding at 80%")
    }

    @Test func aClickAfterReopeningShowsAtOnce() {
        var r = pausedAt(85)
        r.want(.setPaused(false), now: at(0))
        let (_, token) = r.nextCommand()!
        r.closed(now: at(0.2))
        let blockedPoll = r.beginPoll()
        #expect(blockedPoll == nil)
        r.want(.setPaused(true), now: at(1))
        #expect(r.displayed(now: at(1))?.state == .paused)
        r.received(reported(percent: 85, charging: true), for: token, now: at(2))
        let next = r.nextCommand()?.0
        #expect(next == .setPaused(true))
    }

    @Test func aCancelBackResendShowsThePrediction() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, token) = r.nextCommand()!
        r.want(.setPaused(false), now: at(0.1))
        _ = r.failed(token, now: at(0.2))
        let poll = r.beginPoll()!
        r.received(reported(Settings(paused: true), percent: 80), for: poll, now: at(1))
        #expect(r.displayed(now: at(1))?.stateLabel == "Holding at 80%")
        #expect(r.isSettling(now: at(1)))
        let resume = r.nextCommand()?.0
        #expect(resume == .setPaused(false))
    }
}

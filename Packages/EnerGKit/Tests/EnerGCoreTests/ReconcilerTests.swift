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

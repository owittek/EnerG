import Testing
@testable import EnerGCore

struct ProblemTests {
    @Test func copy() {
        #expect(Problem.helperUnreachable.message == "Helper not reachable.")
        #expect(Problem.changeNotApplied.message == "Helper not reachable. Your change wasn't applied.")
        #expect(Problem.waitingForHelper.message == "Waiting for helper…")
        #expect(Problem.installFailed.message == "Couldn't install the helper.")
        #expect(Problem.releaseFailed.message
                == "Couldn't hand charging back to macOS, so the helper is still installed.")
        #expect(Problem.uninstallFailed.message == "Couldn't uninstall the helper.")
        #expect(Problem.launchAtLoginFailed.message == "Couldn't change Launch at Login.")
    }

    @Test func buttons() {
        #expect(Problem.releaseFailed.action == .uninstallAnyway)
        #expect(Problem.launchAtLoginFailed.action == .openLoginItems)
        #expect(ProblemAction.uninstallAnyway.title == "Uninstall Anyway")
        #expect(ProblemAction.openLoginItems.title == "Open Login Items")
        for problem in [Problem.installFailed, .uninstallFailed, .changeNotApplied, .waitingForHelper,
                        .helperUnreachable] {
            #expect(problem.action == nil)
        }
    }

    @Test func onlyWaitingIsPending() {
        #expect(Problem.waitingForHelper.isPending)
        #expect(!Problem.helperUnreachable.isPending)
        #expect(!Problem.changeNotApplied.isPending)
    }

    @Test func helperFailuresBeatTheConnectionWhichBeatsOtherFailures() {
        #expect(Problem.shown(failure: .changeNotApplied, connection: .helperUnreachable) == .changeNotApplied)
        #expect(Problem.shown(failure: .releaseFailed, connection: .helperUnreachable) == .releaseFailed)
        #expect(Problem.shown(failure: .launchAtLoginFailed, connection: .helperUnreachable) == .helperUnreachable)
        #expect(Problem.shown(failure: .installFailed, connection: .waitingForHelper) == .waitingForHelper)
        #expect(Problem.shown(failure: .launchAtLoginFailed, connection: nil) == .launchAtLoginFailed)
        #expect(Problem.shown(failure: nil, connection: nil) == nil)
    }
}

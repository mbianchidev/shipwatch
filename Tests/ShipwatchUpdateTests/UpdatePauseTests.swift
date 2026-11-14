import Foundation
import Testing
@testable import ShipwatchUpdate

struct UpdatePauseTests {
    private let failed = UpdateVersion(major: 1, minor: 2, patch: 4)
    private let newer = UpdateVersion(major: 1, minor: 2, patch: 5)

    private func readPause(
        result: String?, argument: String? = nil, current: UpdateVersion = UpdateVersion(major: 1, minor: 2, patch: 3)
    ) throws -> UpdatePause {
        try withScratchDirectory { directory in
            let url = directory.appendingPathComponent("LastUpdate.json")
            if let result { try Data(result.utf8).write(to: url) }
            return UpdatePause(resultURL: url, failedVersionArgument: argument, currentVersion: current)
        }
    }

    @Test func failedResultPausesOnlyThatVersion() throws {
        let pause = try readPause(result: #"{"version":"1.2.4","errorMessage":"The updated app did not start."}"#)
        #expect(!pause.allowsAutomaticInstall(of: failed))
        #expect(pause.allowsAutomaticInstall(of: newer))
        #expect(pause.message(offering: failed)?.contains("The updated app did not start.") == true)
        #expect(pause.message(offering: nil) != nil)
        // A newer release than the failed one is offered normally.
        #expect(pause.message(offering: newer) == nil)
    }

    @Test func failureOfAnInstalledVersionIsForgotten() throws {
        let failure = #"{"version":"1.2.4","errorMessage":"The updated app did not start."}"#
        for pause in [try readPause(result: failure, current: failed), try readPause(result: nil, argument: "1.2.4", current: newer)] {
            #expect(pause.allowsAutomaticInstall(of: failed))
            #expect(pause.message(offering: nil) == nil)
        }
    }

    @Test func failedVersionArgumentPausesThatVersion() throws {
        let pause = try readPause(result: nil, argument: "1.2.4")
        #expect(!pause.allowsAutomaticInstall(of: failed))
        #expect(pause.allowsAutomaticInstall(of: newer))
        #expect(pause.message(offering: nil) != nil)
    }

    @Test func successOrNoResultAllowsEverything() throws {
        for result in [#"{"version":"1.2.4"}"#, nil] {
            let pause = try readPause(result: result)
            #expect(pause.allowsAutomaticInstall(of: failed))
            #expect(pause.message(offering: nil) == nil)
        }
    }

    @Test func unreadableResultPausesEveryVersionEvenAfterAnotherFailure() throws {
        var pause = try readPause(result: "{not json", argument: "1.2.4")
        #expect(!pause.allowsAutomaticInstall(of: newer))
        #expect(pause.message(offering: newer)?.contains("could not read") == true)

        pause.pause("1.2.5", message: "Couldn't install 1.2.5.")
        #expect(!pause.allowsAutomaticInstall(of: failed))
    }
}

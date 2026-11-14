import Foundation
import Testing
@testable import ShipwatchUpdate

struct UpdatePauseTests {
    private let failed = UpdateVersion(major: 1, minor: 2, patch: 4)
    private let newer = UpdateVersion(major: 1, minor: 2, patch: 5)

    private func readPause(result: String?, argument: String? = nil) throws -> UpdatePause {
        try withScratchDirectory { directory in
            let url = directory.appendingPathComponent("LastUpdate.json")
            if let result { try Data(result.utf8).write(to: url) }
            return UpdatePause(resultURL: url, failedVersionArgument: argument)
        }
    }

    @Test func failedResultPausesOnlyThatVersion() throws {
        let pause = try readPause(result: #"{"version":"1.2.4","errorMessage":"The updated app did not start."}"#)
        #expect(!pause.allowsAutomaticInstall(of: failed))
        #expect(pause.allowsAutomaticInstall(of: newer))
        #expect(pause.message?.contains("The updated app did not start.") == true)
    }

    @Test func failedVersionArgumentPausesThatVersion() throws {
        let pause = try readPause(result: nil, argument: "1.2.4")
        #expect(!pause.allowsAutomaticInstall(of: failed))
        #expect(pause.allowsAutomaticInstall(of: newer))
        #expect(pause.message != nil)
    }

    @Test func successOrNoResultAllowsEverything() throws {
        for result in [#"{"version":"1.2.4"}"#, nil] {
            let pause = try readPause(result: result)
            #expect(pause.allowsAutomaticInstall(of: failed))
            #expect(pause.message == nil)
        }
    }

    @Test func unreadableResultPausesEveryVersionEvenAfterAnotherFailure() throws {
        var pause = try readPause(result: "{not json", argument: "1.2.4")
        #expect(!pause.allowsAutomaticInstall(of: newer))
        #expect(pause.message?.contains("could not read") == true)

        pause.pause("1.2.5", message: "Couldn't install 1.2.5.")
        #expect(!pause.allowsAutomaticInstall(of: failed))
    }
}

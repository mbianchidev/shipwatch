import Foundation

package enum CommandRunnerError: LocalizedError {
    case launchFailed(executable: String, underlying: String)
    case commandFailed(executable: String, status: Int32, message: String)

    package var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, underlying):
            "Could not launch \(executable): \(underlying)"
        case let .commandFailed(executable, status, message):
            "\(executable) exited with status \(status): \(message)"
        }
    }
}

/// Runs a system tool synchronously and throws with its error output if it fails. Callers must stay off the main thread.
package enum CommandRunner {
    package static func run(_ executable: String, arguments: [String] = []) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            throw CommandRunnerError.launchFailed(executable: executable, underlying: error.localizedDescription)
        }
        let errors = errorPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw CommandRunnerError.commandFailed(
                executable: executable,
                status: task.terminationStatus,
                message: String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

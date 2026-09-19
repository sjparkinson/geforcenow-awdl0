import ArgumentParser
import GFNAwdl0Lib
import Logging

@main
struct GFNAwdl0: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "geforcenow-awdl0",
    abstract: "Keep awdl0 down while playing GeForce NOW to prevent AirDrop/AirPlay latency.",
    discussion: """
      Normally started by launchd via `make install`. Logs go to standard error, \
      which the LaunchAgent redirects to ~/Library/Logs/geforcenow-awdl0.log.

      Bringing awdl0 down needs root, so the installed binary is setuid.
      """
  )

  @Flag(name: .shortAndLong, help: "Enable verbose logging.")
  var verbose = false

  @MainActor
  mutating func run() async throws {
    let logLevel: Logger.Level = verbose ? .debug : .info
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardError(label: label)
      handler.logLevel = logLevel
      return handler
    }

    let daemon = try Daemon()
    try await daemon.run()
  }
}

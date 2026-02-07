import ArgumentParser
import GFNAwdl0Lib
import Logging

@main
struct GFNAwdl0: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "geforcenow-awdl0",
        abstract: "Keep awdl0 down while playing GeForce NOW to prevent AirDrop/AirPlay latency.",
        version: "2.0.0",
        subcommands: [Run.self, Install.self, Uninstall.self, Status.self]
    )

    @Flag(name: .shortAndLong, help: "Enable verbose logging.")
    var verbose = false
}

extension GFNAwdl0 {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the daemon (typically invoked by launchd)."
        )

        @OptionGroup var options: GFNAwdl0

        mutating func run() async throws {
            let logLevel: Logger.Level = options.verbose ? .debug : .info
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardError(label: label)
                handler.logLevel = logLevel
                return handler
            }

            #if os(macOS)
            let daemon = try Daemon()
            try await daemon.run()
            #else
            print("This command only works on macOS")
            #endif
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the daemon (requires root)."
        )

        @OptionGroup var options: GFNAwdl0

        mutating func run() throws {
            #if os(macOS)
            try Installer.install(verbose: options.verbose)
            #else
            print("This command only works on macOS")
            #endif
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Uninstall the daemon (requires root)."
        )

        @OptionGroup var options: GFNAwdl0

        mutating func run() throws {
            #if os(macOS)
            try Installer.uninstall(verbose: options.verbose)
            #else
            print("This command only works on macOS")
            #endif
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show daemon status."
        )

        @OptionGroup var options: GFNAwdl0

        mutating func run() throws {
            #if os(macOS)
            try Installer.status(verbose: options.verbose)
            #else
            print("This command only works on macOS")
            #endif
        }
    }
}

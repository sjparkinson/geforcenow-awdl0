import Foundation

/// Handles installation and uninstallation of the daemon
public enum Installer {
    private static let binaryPath = "/usr/local/bin/geforcenow-awdl0"
    private static let plistPath = "/Library/LaunchDaemons/io.github.sjparkinson.geforcenow-awdl0.plist"
    private static let launchctlLabel = "io.github.sjparkinson.geforcenow-awdl0"

    private static let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>io.github.sjparkinson.geforcenow-awdl0</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/local/bin/geforcenow-awdl0</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>StandardOutPath</key>
            <string>/var/log/geforcenow-awdl0/stdout.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/geforcenow-awdl0/stderr.log</string>
        </dict>
        </plist>
        """

    /// Install the daemon (requires root)
    public static func install(verbose: Bool) throws {
        guard getuid() == 0 else {
            throw InstallerError.rootRequired
        }

        print("Installing geforcenow-awdl0...")

        // Get path to current executable
        guard let executablePath = Bundle.main.executablePath else {
            throw InstallerError.executableNotFound
        }

        // Create log directory
        let logDir = "/var/log/geforcenow-awdl0"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        // Copy binary to /usr/local/bin
        if FileManager.default.fileExists(atPath: binaryPath) {
            try FileManager.default.removeItem(atPath: binaryPath)
        }
        try FileManager.default.copyItem(atPath: executablePath, toPath: binaryPath)

        // Make binary executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)

        // Ad-hoc code sign the binary (required for Apple Silicon)
        let signResult = shell("codesign", "-s", "-", "-f", binaryPath)
        if signResult != 0 {
            print("Warning: Failed to code sign binary (exit code \(signResult))")
        }

        if verbose {
            print("  Copied binary to \(binaryPath)")
            print("  Code signed binary (ad-hoc)")
        }

        // Write plist
        try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistPath)

        if verbose {
            print("  Wrote plist to \(plistPath)")
        }

        // Load the daemon using modern launchctl syntax
        let loadResult = shell("launchctl", "bootstrap", "system", plistPath)
        if loadResult != 0 {
            print("Warning: Failed to load daemon (exit code \(loadResult))")
        }

        print("Installation complete!")
        print("")
        print("The daemon is now running and will start automatically at boot.")
        print("Use 'geforcenow-awdl0 status' to check the daemon status.")
    }

    /// Uninstall the daemon (requires root)
    public static func uninstall(verbose: Bool) throws {
        guard getuid() == 0 else {
            throw InstallerError.rootRequired
        }

        print("Uninstalling geforcenow-awdl0...")

        // Unload the daemon using modern launchctl syntax
        let unloadResult = shell("launchctl", "bootout", "system/\(launchctlLabel)")
        if verbose {
            print("  Unloaded daemon (exit code \(unloadResult))")
        }

        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
            if verbose {
                print("  Removed \(plistPath)")
            }
        }

        // Remove binary
        if FileManager.default.fileExists(atPath: binaryPath) {
            try FileManager.default.removeItem(atPath: binaryPath)
            if verbose {
                print("  Removed \(binaryPath)")
            }
        }

        print("Uninstallation complete!")
    }

    /// Show daemon status
    public static func status(verbose: Bool) throws {
        let binaryInstalled = FileManager.default.fileExists(atPath: binaryPath)
        let plistInstalled = FileManager.default.fileExists(atPath: plistPath)

        print("geforcenow-awdl0 status:")
        print("")

        if binaryInstalled && plistInstalled {
            print("  Installed: Yes")

            // Check if running via launchctl
            let listResult = shellOutput("launchctl", "print", "system/\(launchctlLabel)")
            if listResult.exitCode == 0 {
                print("  Running: Yes")
                if verbose {
                    print("")
                    print("  launchctl output:")
                    for line in listResult.output.split(separator: "\n") {
                        print("    \(line)")
                    }
                }
            } else {
                print("  Running: No")
            }
        } else {
            print("  Installed: No")
            if verbose {
                print("  Binary: \(binaryInstalled ? "present" : "missing")")
                print("  Plist: \(plistInstalled ? "present" : "missing")")
            }
        }
    }

    @discardableResult
    private static func shell(_ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func shellOutput(_ args: String...) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return (process.terminationStatus, output)
    }
}

/// Errors that can occur during installation
public enum InstallerError: Error, CustomStringConvertible, Sendable {
    case rootRequired
    case executableNotFound

    public var description: String {
        switch self {
        case .rootRequired:
            return "This command requires root privileges. Run with sudo."
        case .executableNotFound:
            return "Could not determine executable path"
        }
    }
}

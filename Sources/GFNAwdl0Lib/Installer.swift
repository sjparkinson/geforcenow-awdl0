import Foundation

/// Handles installation and uninstallation of the daemon
public enum Installer {
    private static let binaryPath = "/usr/local/bin/geforcenow-awdl0"
    private static let plistPath = "/Library/LaunchDaemons/io.github.sjparkinson.geforcenow-awdl0.plist"
    private static let launchctlLabel = "io.github.sjparkinson.geforcenow-awdl0"

    private static func plistContent(programPath: String, stdoutPath: String, stderrPath: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchctlLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(programPath)</string>
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
            <string>\(stdoutPath)</string>
            <key>StandardErrorPath</key>
            <string>\(stderrPath)</string>
        </dict>
        </plist>
        """
    }

    /// Install as a per-user LaunchAgent.
    public static func install(verbose: Bool) throws {
        print("Installing geforcenow-awdl0 (per-user)...")

        // Get path to current executable
        guard let executablePath = Bundle.main.executablePath else {
            throw InstallerError.executableNotFound
        }

        // Prepare user log and launch agent directories
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = home + "/Library/Logs/geforcenow-awdl0"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let agentsDir = home + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)

        // Copy executable to ~/bin for a stable user install path
        let userBin = home + "/bin"
        try? FileManager.default.createDirectory(atPath: userBin, withIntermediateDirectories: true)
        let installedBinary = userBin + "/geforcenow-awdl0"
        if FileManager.default.fileExists(atPath: installedBinary) {
            try? FileManager.default.removeItem(atPath: installedBinary)
        }
        try FileManager.default.copyItem(atPath: executablePath, toPath: installedBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBinary)

        let programPath = installedBinary
        let targetPlistPath = agentsDir + "/\(launchctlLabel).plist"

        // Write plist using user log paths
        let content = plistContent(programPath: programPath, stdoutPath: logDir + "/stdout.log", stderrPath: logDir + "/stderr.log")
        try content.write(toFile: targetPlistPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: targetPlistPath)

        if verbose {
            print("  Wrote plist to \(targetPlistPath)")
            print("  Using program path \(programPath)")
        }

        // Unload any existing registration first (ignore errors)
        _ = shellQuiet("launchctl", "bootout", "gui/\(getuid())/\(launchctlLabel)")

        // Load the agent for the current user
        let loadResult = shell("launchctl", "bootstrap", "gui/\(getuid())", targetPlistPath)
        if loadResult != 0 {
            print("Warning: Failed to load agent (exit code \(loadResult))")
        }

        print("Installation complete!")
        print("")
        print("The agent is now loaded for the current user and will start at login.")
        print("Use 'geforcenow-awdl0 status' to check the agent status.")
    }

    /// Uninstall the per-user agent
    public static func uninstall(verbose: Bool) throws {
        print("Uninstalling geforcenow-awdl0 (per-user)...")

        // Unload the agent
        let unloadResult = shellQuiet("launchctl", "bootout", "gui/\(getuid())/\(launchctlLabel)")
        if verbose {
            print("  Unloaded agent (exit code \(unloadResult))")
        }

        // Remove plist
        let targetPlistPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents/\(launchctlLabel).plist"
        if FileManager.default.fileExists(atPath: targetPlistPath) {
            try FileManager.default.removeItem(atPath: targetPlistPath)
            if verbose {
                print("  Removed \(targetPlistPath)")
            }
        }

        print("Uninstallation complete!")
    }

    /// Show agent status
    public static func status(verbose: Bool) throws {
        let plistToCheck = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents/\(launchctlLabel).plist"
        let plistInstalled = FileManager.default.fileExists(atPath: plistToCheck)

        print("geforcenow-awdl0 status:")
        print("")

        if plistInstalled {
            print("  Installed: Yes")

            // Check if running via launchctl for the current user
            let listResult = shellOutput("launchctl", "print", "gui/\(getuid())/\(launchctlLabel)")
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
                print("  Plist: missing")
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

    @discardableResult
    private static func shellQuiet(_ args: String...) -> Int32 {
        let process = Process()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = outPipe
        process.standardError = outPipe
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

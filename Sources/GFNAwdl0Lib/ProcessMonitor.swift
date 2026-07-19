@preconcurrency import AppKit
import Logging

/// Events emitted by the ProcessMonitor
public enum ProcessEvent: Equatable, Sendable {
    case launched(pid: pid_t)
    case terminated(pid: pid_t)
}

/// Monitors for GeForce NOW process launch and termination using AsyncStream
public struct ProcessMonitor: Sendable {
    /// The bundle identifier for GeForce NOW
    public static let geforceNowBundleID = "com.nvidia.gfnpc.mall"

    public init() {}

    /// Returns an AsyncStream of process events. Must be consumed on main actor.
    @MainActor
    public func events() -> AsyncStream<ProcessEvent> {
        let logger = Logger(label: "ProcessMonitor")

        return AsyncStream { continuation in
            let workspace = NSWorkspace.shared
            let center = workspace.notificationCenter

            func addObserver(
                for name: Notification.Name,
                message: Logger.Message,
                event: @escaping (pid_t) -> ProcessEvent
            ) -> NSObjectProtocol {
                center.addObserver(forName: name, object: workspace, queue: .main) { notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier == Self.geforceNowBundleID else {
                        return
                    }
                    logger.info(message, metadata: ["pid": "\(app.processIdentifier)"])
                    continuation.yield(event(app.processIdentifier))
                }
            }

            let launchObserver = addObserver(
                for: NSWorkspace.didLaunchApplicationNotification,
                message: "GeForce NOW launched",
                event: { .launched(pid: $0) }
            )

            let terminateObserver = addObserver(
                for: NSWorkspace.didTerminateApplicationNotification,
                message: "GeForce NOW terminated",
                event: { .terminated(pid: $0) }
            )

            // Check if GeForce NOW is already running
            if let app = workspace.runningApplications.first(where: {
                $0.bundleIdentifier == Self.geforceNowBundleID
            }) {
                logger.info("GeForce NOW already running", metadata: ["pid": "\(app.processIdentifier)"])
                continuation.yield(.launched(pid: app.processIdentifier))
            }

            logger.debug("Started monitoring for GeForce NOW process")

            continuation.onTermination = { @Sendable _ in
                MainActor.assumeIsolated {
                    center.removeObserver(launchObserver)
                    center.removeObserver(terminateObserver)
                }
                logger.debug("Stopped monitoring for GeForce NOW process")
            }
        }
    }
}

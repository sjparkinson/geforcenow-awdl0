#if os(macOS)
import CoreGraphics
import Foundation
import Logging

/// Events emitted by the WindowMonitor
public enum WindowEvent: Equatable, Sendable {
    case streaming
    case notStreaming
}

/// Monitors for fullscreen windows belonging to a specific process using AsyncStream
public struct WindowMonitor: Sendable {
    /// Polling interval in seconds
    public static let pollingInterval: Duration = .seconds(5)

    /// Tolerance for fullscreen detection (pixels)
    private static let fullscreenTolerance: CGFloat = 1.0

    private let pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }

    /// Returns an AsyncStream of window events, polling at the configured interval.
    /// Only emits when state changes.
    public func events() -> AsyncStream<WindowEvent> {
        let logger = Logger(label: "WindowMonitor")
        let pid = self.pid

        return AsyncStream { continuation in
            let task = Task {
                var lastState: WindowEvent?

                logger.debug("Started monitoring windows", metadata: ["pid": "\(pid)"])

                while !Task.isCancelled {
                    let isFullscreen = Self.hasFullscreenWindow(pid: pid)
                    let newState: WindowEvent = isFullscreen ? .streaming : .notStreaming

                    if newState != lastState {
                        logger.info("Window state changed", metadata: [
                            "pid": "\(pid)",
                            "streaming": "\(isFullscreen)"
                        ])
                        lastState = newState
                        continuation.yield(newState)
                    }

                    try? await Task.sleep(for: Self.pollingInterval)
                }

                logger.debug("Stopped monitoring windows", metadata: ["pid": "\(pid)"])
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func hasFullscreenWindow(pid: pid_t) -> Bool {
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())

        // CGWindowListCopyWindowInfo returns a CFArray of CFDictionary
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            // Filter by process ID
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }

            // Use CGRect(dictionaryRepresentation:) for cleaner bounds extraction
            // kCGWindowBounds contains a CFDictionary that CGRect can parse directly
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary as CFDictionary?,
                  let windowBounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            if isFullscreen(windowBounds: windowBounds, displayBounds: mainDisplayBounds) {
                return true
            }
        }

        return false
    }

    private static func isFullscreen(windowBounds: CGRect, displayBounds: CGRect) -> Bool {
        // Check if window bounds approximately match display bounds (within tolerance)
        let tolerance = fullscreenTolerance
        let expandedDisplay = displayBounds.insetBy(dx: -tolerance, dy: -tolerance)
        let contractedDisplay = displayBounds.insetBy(dx: tolerance, dy: tolerance)

        // Window must be at least as big as contracted display and no bigger than expanded
        return windowBounds.contains(contractedDisplay) && expandedDisplay.contains(windowBounds)
    }
}
#endif

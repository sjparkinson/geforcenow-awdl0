#if os(macOS)
import Dispatch
import Foundation
import Logging

/// The main daemon actor that orchestrates all monitors and the interface controller
public actor Daemon {
    private let logger = Logger(label: "Daemon")
    private let interfaceController: InterfaceController

    private var geforceNowPid: pid_t?
    private var isStreaming = false
    private var windowMonitorTask: Task<Void, Never>?

    public init() throws {
        self.interfaceController = try InterfaceController()
    }

    /// Run the daemon (blocks until terminated)
    @MainActor
    public func run() async throws {
        let logger = Logger(label: "Daemon")
        logger.info("Starting geforcenow-awdl0 daemon")

        // Set up signal handling
        let shouldStop = setupSignalHandling()

        // Create monitors
        let processMonitor = ProcessMonitor()
        let interfaceMonitor = InterfaceMonitor()

        // Start monitoring
        let processEvents = processMonitor.events()
        let interfaceEvents = try interfaceMonitor.events()

        logger.info("Daemon started, waiting for GeForce NOW...")

        // Process events using task groups
        await withTaskGroup(of: Void.self) { group in
            // Process events task
            group.addTask {
                for await event in processEvents {
                    await self.handleProcessEvent(event)
                }
            }

            // Interface events task
            group.addTask {
                for await event in interfaceEvents {
                    await self.handleInterfaceEvent(event)
                }
            }

            // Keep the run loop alive for NSWorkspace notifications
            // This runs synchronously on the main thread between await points
            group.addTask { @MainActor in
                // Poll for shutdown signal while keeping run loop alive
                while !shouldStop.pointee {
                    // Process pending events on the main run loop
                    // Using a short timeout to stay responsive to shutdown
                    _ = CFRunLoopRunInMode(.defaultMode, 0.5, true)
                }
                group.cancelAll()
            }
        }

        await self.shutdown()
        logger.info("Daemon stopped")
    }

    /// Sets up signal handlers and returns a pointer to a Bool that indicates shutdown
    @MainActor
    private func setupSignalHandling() -> UnsafeMutablePointer<Bool> {
        let shouldStop = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        shouldStop.pointee = false

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler {
            Logger(label: "Daemon").info("Received SIGTERM, shutting down...")
            shouldStop.pointee = true
        }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler {
            Logger(label: "Daemon").info("Received SIGINT, shutting down...")
            shouldStop.pointee = true
        }
        intSource.resume()

        return shouldStop
    }

    private func handleProcessEvent(_ event: ProcessEvent) async {
        switch event {
        case .launched(let pid):
            geforceNowPid = pid
            logger.info("GeForce NOW detected, starting window monitor", metadata: ["pid": "\(pid)"])

            // Cancel any existing window monitor task
            windowMonitorTask?.cancel()

            // Start window monitoring in a new task
            windowMonitorTask = Task {
                let windowMonitor = WindowMonitor(pid: pid)
                for await windowEvent in windowMonitor.events() {
                    guard !Task.isCancelled else { break }
                    await self.handleWindowEvent(windowEvent)
                    // Stop if process is no longer tracked
                    if self.geforceNowPid != pid {
                        break
                    }
                }
            }

        case .terminated(let pid):
            logger.info("GeForce NOW terminated", metadata: ["pid": "\(pid)"])
            geforceNowPid = nil
            windowMonitorTask?.cancel()
            windowMonitorTask = nil

            // If we were streaming, bring the interface back up
            if isStreaming {
                isStreaming = false
                bringInterfaceUp()
            }
        }
    }

    private func handleWindowEvent(_ event: WindowEvent) {
        switch event {
        case .streaming:
            guard !isStreaming else { return }
            isStreaming = true
            logger.info("Streaming detected (fullscreen), bringing awdl0 down")
            bringInterfaceDown()

        case .notStreaming:
            guard isStreaming else { return }
            isStreaming = false
            logger.info("Streaming ended (not fullscreen), bringing awdl0 up")
            bringInterfaceUp()
        }
    }

    private func handleInterfaceEvent(_ event: InterfaceEvent) {
        switch event {
        case .stateChanged(let isUp):
            // If awdl0 came back up while we're streaming, bring it back down
            if isUp && isStreaming {
                logger.warning("awdl0 came back up during streaming, bringing it down again")
                bringInterfaceDown()
            }
        }
    }

    private func bringInterfaceDown() {
        do {
            try interfaceController.bringDown()
        } catch {
            logger.error("Failed to bring interface down: \(error)")
        }
    }

    private func bringInterfaceUp() {
        do {
            try interfaceController.bringUp()
        } catch {
            logger.error("Failed to bring interface up: \(error)")
        }
    }

    private func shutdown() {
        logger.info("Shutting down daemon...")
        windowMonitorTask?.cancel()

        // Restore interface to up state
        if isStreaming {
            logger.info("Restoring awdl0 to up state before exit")
            bringInterfaceUp()
        }
    }
}
#endif
            signal(SIGINT, SIG_IGN)

            continuation.onTermination = { _ in
                termSource.cancel()
                intSource.cancel()
            }
        }
    }
}
#endif

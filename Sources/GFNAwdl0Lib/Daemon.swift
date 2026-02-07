import Dispatch
import Foundation
import Logging

/// Sendable wrapper for shutdown signaling
private final class ShutdownSignal: @unchecked Sendable {
    var shouldStop = false
    // Hold references to dispatch sources to keep them alive
    var termSource: DispatchSourceSignal?
    var intSource: DispatchSourceSignal?
}

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
        let shutdownSignal = ShutdownSignal()
        setupSignalHandling(shutdownSignal)

        // Create monitors
        let processMonitor = ProcessMonitor()
        let interfaceMonitor = InterfaceMonitor()

        // Start monitoring
        let processEvents = processMonitor.events()
        let interfaceEvents = try interfaceMonitor.events()

        logger.info("Daemon started, waiting for GeForce NOW...")

        // Start event processing tasks
        let processTask = Task {
            for await event in processEvents {
                guard !Task.isCancelled else { break }
                await self.handleProcessEvent(event)
            }
        }

        let interfaceTask = Task {
            for await event in interfaceEvents {
                guard !Task.isCancelled else { break }
                await self.handleInterfaceEvent(event)
            }
        }

        // Keep the run loop alive for NSWorkspace notifications
        // Dispatch to main queue to escape async context restriction
        while !shutdownSignal.shouldStop {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    _ = CFRunLoopRunInMode(.defaultMode, 0.5, true)
                    continuation.resume()
                }
            }
        }

        // Cancel event tasks
        processTask.cancel()
        interfaceTask.cancel()

        await self.shutdown()
        logger.info("Daemon stopped")
    }

    /// Sets up signal handlers for graceful shutdown
    @MainActor
    private func setupSignalHandling(_ shutdownSignal: ShutdownSignal) {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [shutdownSignal] in
            Logger(label: "Daemon").info("Received SIGTERM, shutting down...")
            shutdownSignal.shouldStop = true
        }
        termSource.resume()
        shutdownSignal.termSource = termSource

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [shutdownSignal] in
            Logger(label: "Daemon").info("Received SIGINT, shutting down...")
            shutdownSignal.shouldStop = true
        }
        intSource.resume()
        shutdownSignal.intSource = intSource
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
                    self.handleWindowEvent(windowEvent)
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
                try? interfaceController.bringUp()
            }
        }
    }

    private func handleWindowEvent(_ event: WindowEvent) {
        switch event {
        case .streaming:
            guard !isStreaming else { return }
            isStreaming = true
            logger.info("Streaming detected (fullscreen), bringing awdl0 down")
            try? interfaceController.bringDown()

        case .notStreaming:
            guard isStreaming else { return }
            isStreaming = false
            logger.info("Streaming ended (not fullscreen), bringing awdl0 up")
            try? interfaceController.bringUp()
        }
    }

    private func handleInterfaceEvent(_ event: InterfaceEvent) {
        switch event {
        case .stateChanged(let isUp):
            // If awdl0 came back up while we're streaming, bring it back down
            if isUp && isStreaming {
                logger.warning("awdl0 came back up during streaming, bringing it down again")
                try? interfaceController.bringDown()
            }
        }
    }

    private func shutdown() {
        logger.info("Shutting down daemon...")
        windowMonitorTask?.cancel()

        // Restore interface to up state
        if isStreaming {
            logger.info("Restoring awdl0 to up state before exit")
            try? interfaceController.bringUp()
        }
    }
}

#if os(macOS)
import Dispatch
import Foundation
import Logging

/// Internal events for the daemon's state machine
private enum DaemonEvent: Sendable {
    case process(ProcessEvent)
    case window(WindowEvent)
    case interface(InterfaceEvent)
    case shutdown
}

/// The main daemon actor that orchestrates all monitors and the interface controller
public actor Daemon {
    private let logger = Logger(label: "Daemon")
    private let interfaceController: InterfaceController

    private var geforceNowPid: pid_t?
    private var isStreaming = false

    public init() throws {
        self.interfaceController = try InterfaceController()
    }

    /// Run the daemon (blocks until terminated)
    @MainActor
    public func run() async throws {
        let logger = Logger(label: "Daemon")
        logger.info("Starting geforcenow-awdl0 daemon")

        // Create a stream for shutdown signals
        let shutdownStream = Self.signalStream()

        // Create monitors
        let processMonitor = ProcessMonitor()
        let interfaceMonitor = InterfaceMonitor()

        // Start monitoring
        let processEvents = processMonitor.events()
        let interfaceEvents = try interfaceMonitor.events()

        logger.info("Daemon started, waiting for GeForce NOW...")

        // Merge all event streams and process them
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

            // Shutdown signal task
            group.addTask {
                for await _ in shutdownStream {
                    logger.info("Received shutdown signal")
                    await self.shutdown()
                    group.cancelAll()
                    return
                }
            }

            // RunLoop task - keeps the main run loop alive for notifications
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    await Task.yield()
                }
            }
        }

        logger.info("Daemon stopped")
    }

    private func handleProcessEvent(_ event: ProcessEvent) async {
        switch event {
        case .launched(let pid):
            geforceNowPid = pid
            logger.info("GeForce NOW detected, starting window monitor", metadata: ["pid": "\(pid)"])

            // Start window monitoring in a new task
            Task {
                let windowMonitor = WindowMonitor(pid: pid)
                for await windowEvent in windowMonitor.events() {
                    await self.handleWindowEvent(windowEvent)
                    // Stop if process is no longer tracked
                    if await self.geforceNowPid != pid {
                        break
                    }
                }
            }

        case .terminated(let pid):
            logger.info("GeForce NOW terminated", metadata: ["pid": "\(pid)"])
            geforceNowPid = nil

            // If we were streaming, bring the interface back up
            if isStreaming {
                isStreaming = false
                await bringInterfaceUp()
            }
        }
    }

    private func handleWindowEvent(_ event: WindowEvent) async {
        switch event {
        case .streaming:
            guard !isStreaming else { return }
            isStreaming = true
            logger.info("Streaming detected (fullscreen), bringing awdl0 down")
            await bringInterfaceDown()

        case .notStreaming:
            guard isStreaming else { return }
            isStreaming = false
            logger.info("Streaming ended (not fullscreen), bringing awdl0 up")
            await bringInterfaceUp()
        }
    }

    private func handleInterfaceEvent(_ event: InterfaceEvent) async {
        switch event {
        case .stateChanged(let isUp):
            // If awdl0 came back up while we're streaming, bring it back down
            if isUp && isStreaming {
                logger.warning("awdl0 came back up during streaming, bringing it down again")
                await bringInterfaceDown()
            }
        }
    }

    private func bringInterfaceDown() async {
        do {
            try interfaceController.bringDown()
        } catch {
            logger.error("Failed to bring interface down: \(error)")
        }
    }

    private func bringInterfaceUp() async {
        do {
            try interfaceController.bringUp()
        } catch {
            logger.error("Failed to bring interface up: \(error)")
        }
    }

    private func shutdown() async {
        logger.info("Shutting down daemon...")

        // Restore interface to up state
        if isStreaming {
            logger.info("Restoring awdl0 to up state before exit")
            await bringInterfaceUp()
        }
    }

    /// Creates an AsyncStream that yields when SIGTERM or SIGINT is received
    private static func signalStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termSource.setEventHandler {
                continuation.yield()
                continuation.finish()
            }
            termSource.resume()
            signal(SIGTERM, SIG_IGN)

            let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            intSource.setEventHandler {
                continuation.yield()
                continuation.finish()
            }
            intSource.resume()
            signal(SIGINT, SIG_IGN)

            continuation.onTermination = { _ in
                termSource.cancel()
                intSource.cancel()
            }
        }
    }
}
#endif

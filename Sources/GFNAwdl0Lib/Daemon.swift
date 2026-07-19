import Dispatch
import Foundation
import Logging

/// Holds the shutdown continuation and signal sources. Mutated only from the main queue.
private final class ShutdownWaiter: @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Never>?
    var termSource: DispatchSourceSignal?
    var intSource: DispatchSourceSignal?

    func signal() {
        if let cont = continuation {
            continuation = nil
            cont.resume()
        }
    }
}

/// Abstraction over interface control so the daemon's state machine can be
/// tested without root privileges.
public protocol InterfaceControlling: Sendable {
    func bringUp() throws
    func bringDown() throws
}

extension InterfaceController: InterfaceControlling {}

/// The main daemon that orchestrates all monitors and the interface controller.
@MainActor
public final class Daemon {
    private let logger = Logger(label: "Daemon")
    private let interfaceController: any InterfaceControlling
    private let windowEvents: (pid_t) -> AsyncStream<WindowEvent>

    private var geforceNowPid: pid_t?
    private var isStreaming = false
    private var windowMonitorTask: Task<Void, Never>?

    public init(
        interfaceController: any InterfaceControlling,
        windowEvents: @escaping (pid_t) -> AsyncStream<WindowEvent> = { WindowMonitor(pid: $0).events() }
    ) {
        self.interfaceController = interfaceController
        self.windowEvents = windowEvents
    }

    public convenience init() throws {
        self.init(interfaceController: try InterfaceController())
    }

    /// Run the daemon (suspends until SIGTERM/SIGINT).
    public func run() async throws {
        logger.info("Starting geforcenow-awdl0 daemon")

        let waiter = ShutdownWaiter()
        setupSignalHandling(waiter)

        let processMonitor = ProcessMonitor()
        let interfaceMonitor = InterfaceMonitor()

        let processEvents = processMonitor.events()
        let interfaceEvents = try interfaceMonitor.events()

        logger.info("Daemon started, waiting for GeForce NOW...")

        let processTask = Task {
            for await event in processEvents {
                guard !Task.isCancelled else { break }
                self.handleProcessEvent(event)
            }
        }

        let interfaceTask = Task {
            for await event in interfaceEvents {
                guard !Task.isCancelled else { break }
                self.handleInterfaceEvent(event)
            }
        }

        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
        }

        processTask.cancel()
        interfaceTask.cancel()

        shutdown()
        logger.info("Daemon stopped")
    }

    private func setupSignalHandling(_ waiter: ShutdownWaiter) {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [waiter, logger] in
            logger.info("Received SIGTERM, shutting down...")
            waiter.signal()
        }
        termSource.resume()
        waiter.termSource = termSource

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [waiter, logger] in
            logger.info("Received SIGINT, shutting down...")
            waiter.signal()
        }
        intSource.resume()
        waiter.intSource = intSource
    }

    func handleProcessEvent(_ event: ProcessEvent) {
        switch event {
        case .launched(let pid):
            geforceNowPid = pid
            logger.info("GeForce NOW detected, starting window monitor", metadata: ["pid": "\(pid)"])

            windowMonitorTask?.cancel()
            windowMonitorTask = Task {
                for await windowEvent in windowEvents(pid) {
                    guard !Task.isCancelled else { break }
                    self.handleWindowEvent(windowEvent)
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

            if isStreaming {
                isStreaming = false
                bringInterfaceUp()
            }
        }
    }

    func handleWindowEvent(_ event: WindowEvent) {
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

    func handleInterfaceEvent(_ event: InterfaceEvent) {
        switch event {
        case .stateChanged(let isUp):
            if isUp && isStreaming {
                logger.warning("awdl0 came back up during streaming, bringing it down again")
                bringInterfaceDown()
            }
        }
    }

    private func shutdown() {
        logger.info("Shutting down daemon...")
        windowMonitorTask?.cancel()

        if isStreaming {
            logger.info("Restoring awdl0 to up state before exit")
            bringInterfaceUp()
        }
    }

    private func bringInterfaceDown() {
        do {
            try interfaceController.bringDown()
        } catch {
            logger.error("Failed to bring awdl0 down", metadata: ["error": "\(error)"])
        }
    }

    private func bringInterfaceUp() {
        do {
            try interfaceController.bringUp()
        } catch {
            logger.error("Failed to bring awdl0 up", metadata: ["error": "\(error)"])
        }
    }
}

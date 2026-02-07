#if os(macOS)
import Logging
import SystemConfiguration

/// Events emitted by the InterfaceMonitor
public enum InterfaceEvent: Equatable, Sendable {
    case stateChanged(isUp: Bool)
}

/// Monitors network interface state changes using SCDynamicStore and AsyncStream
public struct InterfaceMonitor: Sendable {
    private let interfaceName: String

    public init(interfaceName: String = "awdl0") {
        self.interfaceName = interfaceName
    }

    /// Returns an AsyncStream of interface state change events.
    /// Must be run with an active RunLoop on the main thread.
    @MainActor
    public func events() throws -> AsyncStream<InterfaceEvent> {
        let logger = Logger(label: "InterfaceMonitor")
        let interfaceName = self.interfaceName

        // We need to use a class to hold the continuation since SCDynamicStore uses a C callback
        final class StreamState: @unchecked Sendable {
            var continuation: AsyncStream<InterfaceEvent>.Continuation?
            let interfaceName: String
            let logger: Logger
            var store: SCDynamicStore?
            var runLoopSource: CFRunLoopSource?

            init(interfaceName: String, logger: Logger) {
                self.interfaceName = interfaceName
                self.logger = logger
            }
        }

        let state = StreamState(interfaceName: interfaceName, logger: logger)

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(state).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let store = SCDynamicStoreCreate(
            nil,
            "geforcenow-awdl0" as CFString,
            { store, changedKeys, info in
                guard let info = info else { return }
                let state = Unmanaged<StreamState>.fromOpaque(info).takeUnretainedValue()

                let key = "State:/Network/Interface/\(state.interfaceName)/Link" as CFString
                if let value = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                   let active = value["Active"] as? Bool {
                    state.logger.info("Interface state changed", metadata: [
                        "interface": "\(state.interfaceName)",
                        "active": "\(active)"
                    ])
                    state.continuation?.yield(.stateChanged(isUp: active))
                }
            },
            &context
        ) else {
            throw InterfaceMonitorError.storeCreationFailed
        }

        state.store = store

        let key = "State:/Network/Interface/\(interfaceName)/Link" as CFString
        guard SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil) else {
            throw InterfaceMonitorError.notificationSetupFailed
        }

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            throw InterfaceMonitorError.runLoopSourceCreationFailed
        }

        state.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        logger.debug("Started monitoring interface state", metadata: ["interface": "\(interfaceName)"])

        return AsyncStream { continuation in
            state.continuation = continuation

            continuation.onTermination = { _ in
                if let source = state.runLoopSource {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
                }
                state.store = nil
                state.runLoopSource = nil
                logger.debug("Stopped monitoring interface state", metadata: ["interface": "\(interfaceName)"])
            }
        }
    }
}

/// Errors that can occur during interface monitoring
public enum InterfaceMonitorError: Error, CustomStringConvertible, Sendable {
    case storeCreationFailed
    case notificationSetupFailed
    case runLoopSourceCreationFailed

    public var description: String {
        switch self {
        case .storeCreationFailed:
            return "Failed to create SCDynamicStore"
        case .notificationSetupFailed:
            return "Failed to set up notifications"
        case .runLoopSourceCreationFailed:
            return "Failed to create run loop source"
        }
    }
}
#endif

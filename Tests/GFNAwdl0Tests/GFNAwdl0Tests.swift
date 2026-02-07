import Testing
@testable import GFNAwdl0Lib

@Suite("ProcessMonitor Tests")
struct ProcessMonitorTests {
    #if os(macOS)
    @Test("Bundle ID constant is correct")
    func bundleIDConstant() {
        #expect(ProcessMonitor.geforceNowBundleID == "com.nvidia.gfnpc.mall")
    }

    @Test("ProcessEvent equality")
    func processEventEquality() {
        #expect(ProcessEvent.launched(pid: 123) == ProcessEvent.launched(pid: 123))
        #expect(ProcessEvent.launched(pid: 123) != ProcessEvent.launched(pid: 456))
        #expect(ProcessEvent.terminated(pid: 123) == ProcessEvent.terminated(pid: 123))
        #expect(ProcessEvent.launched(pid: 123) != ProcessEvent.terminated(pid: 123))
    }

    @Test("Can create ProcessMonitor")
    func canCreateMonitor() {
        let monitor = ProcessMonitor()
        #expect(monitor != nil)
    }
    #endif
}

@Suite("WindowMonitor Tests")
struct WindowMonitorTests {
    #if os(macOS)
    @Test("Polling interval is 5 seconds")
    func pollingInterval() {
        #expect(WindowMonitor.pollingInterval == .seconds(5))
    }

    @Test("WindowEvent equality")
    func windowEventEquality() {
        #expect(WindowEvent.streaming == WindowEvent.streaming)
        #expect(WindowEvent.notStreaming == WindowEvent.notStreaming)
        #expect(WindowEvent.streaming != WindowEvent.notStreaming)
    }

    @Test("Can create WindowMonitor")
    func canCreateMonitor() {
        let monitor = WindowMonitor(pid: 1)
        #expect(monitor != nil)
    }
    #endif
}

@Suite("InterfaceController Tests")
struct InterfaceControllerTests {
    #if os(macOS)
    @Test("Default interface name is awdl0")
    func defaultInterfaceName() throws {
        let controller = try InterfaceController()
        #expect(controller.interfaceName == "awdl0")
    }

    @Test("Custom interface name")
    func customInterfaceName() throws {
        let controller = try InterfaceController(interfaceName: "en0")
        #expect(controller.interfaceName == "en0")
    }

    @Test("Invalid interface name too long")
    func invalidInterfaceNameTooLong() {
        #expect(throws: InterfaceError.self) {
            _ = try InterfaceController(interfaceName: "this_name_is_way_too_long")
        }
    }

    @Test("Interface name at max length is valid")
    func interfaceNameAtMaxLength() throws {
        // IFNAMSIZ is 16, so max usable length is 15 characters (need null terminator)
        let controller = try InterfaceController(interfaceName: "123456789012345")
        #expect(controller.interfaceName == "123456789012345")
    }

    @Test("Interface name at IFNAMSIZ rejected")
    func interfaceNameAtIFNAMSIZRejected() {
        // 16 characters should fail (IFNAMSIZ includes the null terminator)
        #expect(throws: InterfaceError.self) {
            _ = try InterfaceController(interfaceName: "1234567890123456")
        }
    }

    @Test("InterfaceError descriptions")
    func errorDescriptions() {
        let errors: [InterfaceError] = [
            .invalidInterfaceName("test"),
            .socketCreationFailed(1),
            .getInterfaceFlagsFailed(2),
            .setInterfaceFlagsFailed(3),
            .interfaceNotFound("eth0")
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }
    #endif
}

@Suite("InterfaceMonitor Tests")
struct InterfaceMonitorTests {
    #if os(macOS)
    @Test("InterfaceEvent equality")
    func interfaceEventEquality() {
        #expect(InterfaceEvent.stateChanged(isUp: true) == InterfaceEvent.stateChanged(isUp: true))
        #expect(InterfaceEvent.stateChanged(isUp: false) == InterfaceEvent.stateChanged(isUp: false))
        #expect(InterfaceEvent.stateChanged(isUp: true) != InterfaceEvent.stateChanged(isUp: false))
    }

    @Test("Can create InterfaceMonitor")
    func canCreateMonitor() {
        let monitor = InterfaceMonitor()
        #expect(monitor != nil)
    }

    @Test("Can create InterfaceMonitor with custom interface")
    func canCreateMonitorWithCustomInterface() {
        let monitor = InterfaceMonitor(interfaceName: "en0")
        #expect(monitor != nil)
    }

    @Test("InterfaceMonitorError descriptions")
    func errorDescriptions() {
        let errors: [InterfaceMonitorError] = [
            .storeCreationFailed,
            .notificationSetupFailed,
            .runLoopSourceCreationFailed
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }
    #endif
}

@Suite("Daemon Tests")
struct DaemonTests {
    #if os(macOS)
    @Test("Can create Daemon")
    func canCreateDaemon() throws {
        let daemon = try Daemon()
        #expect(daemon != nil)
    }
    #endif
}

@Suite("Installer Tests")
struct InstallerTests {
    #if os(macOS)
    @Test("InstallerError descriptions")
    func errorDescriptions() {
        let errors: [InstallerError] = [
            .rootRequired,
            .executableNotFound
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }
    #endif
}

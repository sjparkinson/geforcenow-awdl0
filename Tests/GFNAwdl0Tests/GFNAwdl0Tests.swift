import Testing
@testable import GFNAwdl0Lib

@Suite("ProcessMonitor Tests")
struct ProcessMonitorTests {
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
        _ = ProcessMonitor()
    }
}

@Suite("WindowMonitor Tests")
struct WindowMonitorTests {
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
        _ = WindowMonitor(pid: 1)
    }
}

@Suite("InterfaceController Tests")
struct InterfaceControllerTests {
    @Test("ioctl encoding constants match BSD values")
    func ioctlEncodingConstants() {
        // Verify the encoding constants from <sys/ioccom.h>
        #expect(InterfaceController.IOC_OUT == 0x40000000)
        #expect(InterfaceController.IOC_IN == 0x80000000)
        #expect(InterfaceController.IOC_INOUT == 0xc0000000)
        #expect(InterfaceController.IOCPARM_MASK == 0x1fff)
    }

    @Test("ioc() encodes ioctl request codes correctly")
    func iocEncoding() {
        // Test the encoding formula: inout | (len << 16) | (group << 8) | num
        // Using a simple case: _IO('x', 1) with len=0
        let simple = InterfaceController.ioc(0, UInt8(ascii: "x"), 1, 0)
        #expect(simple == 0x7801)  // ('x' << 8) | 1 = (0x78 << 8) | 1

        // _IOW('t', 42, 8 bytes) = IOC_IN | (8 << 16) | ('t' << 8) | 42
        let iow = InterfaceController.ioc(InterfaceController.IOC_IN, UInt8(ascii: "t"), 42, 8)
        #expect(iow == 0x8008_742a)
    }

    @Test("SIOCGIFFLAGS matches known BSD value")
    func siocgifflags() {
        // SIOCGIFFLAGS = _IOWR('i', 17, struct ifreq) = 0xc0206911
        // This is the documented value from BSD systems
        #expect(InterfaceController.SIOCGIFFLAGS == 0xc020_6911)
    }

    @Test("SIOCSIFFLAGS matches known BSD value")
    func siocsifflags() {
        // SIOCSIFFLAGS = _IOW('i', 16, struct ifreq) = 0x80206910
        // This is the documented value from BSD systems
        #expect(InterfaceController.SIOCSIFFLAGS == 0x8020_6910)
    }

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
}

@Suite("InterfaceMonitor Tests")
struct InterfaceMonitorTests {
    @Test("InterfaceEvent equality")
    func interfaceEventEquality() {
        #expect(InterfaceEvent.stateChanged(isUp: true) == InterfaceEvent.stateChanged(isUp: true))
        #expect(InterfaceEvent.stateChanged(isUp: false) == InterfaceEvent.stateChanged(isUp: false))
        #expect(InterfaceEvent.stateChanged(isUp: true) != InterfaceEvent.stateChanged(isUp: false))
    }

    @Test("Can create InterfaceMonitor")
    func canCreateMonitor() {
        _ = InterfaceMonitor()
    }

    @Test("Can create InterfaceMonitor with custom interface")
    func canCreateMonitorWithCustomInterface() {
        _ = InterfaceMonitor(interfaceName: "en0")
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
}

@Suite("Daemon Tests")
struct DaemonTests {
    @Test("Can create Daemon")
    func canCreateDaemon() throws {
        _ = try Daemon()
    }
}

@Suite("Installer Tests")
struct InstallerTests {
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
}

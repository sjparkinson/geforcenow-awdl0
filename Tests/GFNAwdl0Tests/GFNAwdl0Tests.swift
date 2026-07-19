import CoreGraphics
import Synchronization
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

    @Test("Window exactly at display bounds is fullscreen")
    func windowAtBounds() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(WindowMonitor.isFullscreen(windowBounds: display, displayBounds: display))
    }

    @Test("Window slightly oversized within tolerance is fullscreen")
    func slightlyOversized() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let window = CGRect(x: -1, y: -1, width: 2562, height: 1442)
        #expect(WindowMonitor.isFullscreen(windowBounds: window, displayBounds: display))
    }

    @Test("Window 2px oversized is not fullscreen")
    func tooLarge() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let window = CGRect(x: -2, y: -2, width: 2564, height: 1444)
        #expect(!WindowMonitor.isFullscreen(windowBounds: window, displayBounds: display))
    }

    @Test("Window 2px undersized is not fullscreen")
    func tooSmall() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let window = CGRect(x: 2, y: 2, width: 2556, height: 1436)
        #expect(!WindowMonitor.isFullscreen(windowBounds: window, displayBounds: display))
    }

    @Test("Window filling a secondary display is fullscreen")
    func fullscreenOnSecondaryDisplay() {
        let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let secondary = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let window = secondary
        #expect(WindowMonitor.isFullscreen(windowBounds: window, displays: [main, secondary]))
    }

    @Test("Window matching no display is not fullscreen")
    func fullscreenOnNoDisplay() {
        let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let secondary = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 100, y: 100, width: 1280, height: 720)
        #expect(!WindowMonitor.isFullscreen(windowBounds: window, displays: [main, secondary]))
    }

    @Test("No active displays means nothing is fullscreen")
    func noDisplays() {
        let window = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(!WindowMonitor.isFullscreen(windowBounds: window, displays: []))
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

/// Records bringUp/bringDown calls so tests can assert on the daemon's decisions.
final class InterfaceControllerSpy: InterfaceControlling {
    enum Call: Equatable {
        case up
        case down
    }

    private let calls = Mutex<[Call]>([])
    private let interfaceIsUp = Mutex<Bool>(true)

    var recordedCalls: [Call] {
        calls.withLock { $0 }
    }

    func bringUp() throws {
        calls.withLock { $0.append(.up) }
    }

    func bringDown() throws {
        calls.withLock { $0.append(.down) }
    }

    func isUp() throws -> Bool {
        interfaceIsUp.withLock { $0 }
    }

    func setInterfaceUp(_ up: Bool) {
        interfaceIsUp.withLock { $0 = up }
    }
}

@Suite("Daemon Tests")
@MainActor
struct DaemonTests {
    let spy = InterfaceControllerSpy()

    func makeDaemon(windowEvents: @escaping (pid_t) -> AsyncStream<WindowEvent> = { _ in AsyncStream { _ in } }) -> Daemon {
        Daemon(interfaceController: spy, windowEvents: windowEvents)
    }

    @Test("Streaming brings the interface down once")
    func streamingBringsInterfaceDown() {
        let daemon = makeDaemon()
        daemon.handleWindowEvent(.streaming)
        daemon.handleWindowEvent(.streaming)
        #expect(spy.recordedCalls == [.down])
    }

    @Test("Streaming ending brings the interface back up")
    func streamingEndingBringsInterfaceUp() {
        let daemon = makeDaemon()
        daemon.handleWindowEvent(.streaming)
        daemon.handleWindowEvent(.notStreaming)
        #expect(spy.recordedCalls == [.down, .up])
    }

    @Test("Not streaming while already up does nothing")
    func notStreamingWhileUpIsIgnored() {
        let daemon = makeDaemon()
        daemon.handleWindowEvent(.notStreaming)
        #expect(spy.recordedCalls.isEmpty)
    }

    @Test("Interface coming back up mid-stream is brought down again")
    func interfaceUpDuringStreamingBroughtDownAgain() {
        let daemon = makeDaemon()
        daemon.handleWindowEvent(.streaming)
        daemon.handleInterfaceEvent(.stateChanged(isUp: true))
        #expect(spy.recordedCalls == [.down, .down])
    }

    @Test("Interface state changes while not streaming are ignored")
    func interfaceUpWhileNotStreamingIsIgnored() {
        let daemon = makeDaemon()
        daemon.handleInterfaceEvent(.stateChanged(isUp: true))
        daemon.handleInterfaceEvent(.stateChanged(isUp: false))
        #expect(spy.recordedCalls.isEmpty)
    }

    @Test("Process termination during streaming restores the interface")
    func terminationDuringStreamingRestoresInterface() {
        let daemon = makeDaemon()
        daemon.handleProcessEvent(.launched(pid: 42))
        daemon.handleWindowEvent(.streaming)
        daemon.handleProcessEvent(.terminated(pid: 42))
        #expect(spy.recordedCalls == [.down, .up])
    }

    @Test("Process termination while not streaming leaves the interface alone")
    func terminationWhileNotStreamingIsIgnored() {
        let daemon = makeDaemon()
        daemon.handleProcessEvent(.launched(pid: 42))
        daemon.handleProcessEvent(.terminated(pid: 42))
        #expect(spy.recordedCalls.isEmpty)
    }

    @Test("Startup reconciliation restores an interface left down")
    func reconciliationRestoresDownedInterface() {
        spy.setInterfaceUp(false)
        let daemon = makeDaemon()
        daemon.reconcileInterfaceState()
        #expect(spy.recordedCalls == [.up])
    }

    @Test("Startup reconciliation leaves a healthy interface alone")
    func reconciliationLeavesHealthyInterfaceAlone() {
        let daemon = makeDaemon()
        daemon.reconcileInterfaceState()
        #expect(spy.recordedCalls.isEmpty)
    }

    @Test("Launch spawns a window monitor whose events drive the interface")
    func launchSpawnsWindowMonitor() async {
        let (stream, continuation) = AsyncStream.makeStream(of: WindowEvent.self)
        let daemon = makeDaemon(windowEvents: { _ in stream })

        daemon.handleProcessEvent(.launched(pid: 42))
        continuation.yield(.streaming)

        var attempts = 0
        while spy.recordedCalls.isEmpty && attempts < 1000 {
            await Task.yield()
            attempts += 1
        }
        #expect(spy.recordedCalls == [.down])
        continuation.finish()
    }
}

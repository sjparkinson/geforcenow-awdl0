import Darwin
import Logging

/// Errors that can occur during interface control
public enum InterfaceError: Error, CustomStringConvertible, Sendable {
    case invalidInterfaceName(String)
    case socketCreationFailed(Int32)
    case getInterfaceFlagsFailed(Int32)
    case setInterfaceFlagsFailed(Int32)
    case interfaceNotFound(String)

    public var description: String {
        switch self {
        case .invalidInterfaceName(let name):
            return "Invalid interface name: '\(name)' (max 15 characters)"
        case .socketCreationFailed(let errno):
            return "Failed to create socket: \(String(cString: strerror(errno)))"
        case .getInterfaceFlagsFailed(let errno):
            return "Failed to get interface flags: \(String(cString: strerror(errno)))"
        case .setInterfaceFlagsFailed(let errno):
            return "Failed to set interface flags: \(String(cString: strerror(errno)))"
        case .interfaceNotFound(let name):
            return "Interface not found: '\(name)'"
        }
    }
}

/// Controls the state of a network interface using BSD sockets and ioctl.
///
/// This uses standard POSIX/BSD interfaces:
/// - `SIOCGIFFLAGS`: Get interface flags (from <sys/sockio.h>)
/// - `SIOCSIFFLAGS`: Set interface flags (from <sys/sockio.h>)
/// - `IFF_UP`: Interface is up flag (from <net/if.h>)
///
/// Note: The ioctl codes are hardcoded because Swift doesn't bridge the C macros
/// that depend on struct ifreq layout. These values are stable across macOS versions.
///
/// Bringing an interface down requires root privileges.
public final class InterfaceController: Sendable {
    // ioctl encoding constants from <sys/ioccom.h>
    // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/ioccom.h
    static let IOC_OUT: UInt = 0x40000000
    static let IOC_IN: UInt = 0x80000000
    static let IOC_INOUT: UInt = IOC_IN | IOC_OUT
    static let IOCPARM_MASK: UInt = 0x1fff

    /// Encodes an ioctl request code: _IOC(inout, group, num, len)
    static func ioc(_ direction: UInt, _ group: UInt8, _ num: UInt8, _ len: Int) -> UInt {
        direction | ((UInt(len) & IOCPARM_MASK) << 16) | (UInt(group) << 8) | UInt(num)
    }

    // ioctl request codes derived from <sys/sockio.h>
    // SIOCSIFFLAGS = _IOW('i', 16, struct ifreq)
    // SIOCGIFFLAGS = _IOWR('i', 17, struct ifreq)
    static let SIOCSIFFLAGS = ioc(IOC_IN, UInt8(ascii: "i"), 16, MemoryLayout<ifreq>.size)
    static let SIOCGIFFLAGS = ioc(IOC_INOUT, UInt8(ascii: "i"), 17, MemoryLayout<ifreq>.size)

    // Interface flag from <net/if.h>
    // Source: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if.h
    private static let IFF_UP: UInt16 = 0x1

    // Maximum interface name length (IFNAMSIZ from <net/if.h> is 16, minus null terminator)
    private static let maxInterfaceNameLength = 15

    private let logger = Logger(label: "InterfaceController")
    public let interfaceName: String

    public init(interfaceName: String = "awdl0") throws {
        guard interfaceName.count <= Self.maxInterfaceNameLength else {
            throw InterfaceError.invalidInterfaceName(interfaceName)
        }
        self.interfaceName = interfaceName
    }

    /// Bring the interface down (requires root)
    public func bringDown() throws {
        logger.info("Bringing down interface", metadata: ["interface": "\(interfaceName)"])
        try setInterfaceUp(false)
    }

    /// Bring the interface up (requires root)
    public func bringUp() throws {
        logger.info("Bringing up interface", metadata: ["interface": "\(interfaceName)"])
        try setInterfaceUp(true)
    }

    /// Check if the interface is currently up
    public func isUp() throws -> Bool {
        let flags = try getInterfaceFlags()
        return (flags & Self.IFF_UP) != 0
    }

    private func setInterfaceUp(_ up: Bool) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw InterfaceError.socketCreationFailed(errno)
        }
        defer { close(fd) }

        var ifr = ifreq()
        copyInterfaceName(to: &ifr)

        // Get current flags
        guard ioctl(fd, Self.SIOCGIFFLAGS, &ifr) == 0 else {
            throw InterfaceError.getInterfaceFlagsFailed(errno)
        }

        // Modify the IFF_UP flag
        var flags = UInt16(bitPattern: ifr.ifr_ifru.ifru_flags)
        if up {
            flags |= Self.IFF_UP
        } else {
            flags &= ~Self.IFF_UP
        }
        ifr.ifr_ifru.ifru_flags = Int16(bitPattern: flags)

        // Set new flags
        guard ioctl(fd, Self.SIOCSIFFLAGS, &ifr) == 0 else {
            throw InterfaceError.setInterfaceFlagsFailed(errno)
        }

        logger.debug("Interface state changed", metadata: [
            "interface": "\(interfaceName)",
            "up": "\(up)"
        ])
    }

    private func getInterfaceFlags() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw InterfaceError.socketCreationFailed(errno)
        }
        defer { close(fd) }

        var ifr = ifreq()
        copyInterfaceName(to: &ifr)

        guard ioctl(fd, Self.SIOCGIFFLAGS, &ifr) == 0 else {
            throw InterfaceError.getInterfaceFlagsFailed(errno)
        }

        return UInt16(bitPattern: ifr.ifr_ifru.ifru_flags)
    }

    private func copyInterfaceName(to ifr: inout ifreq) {
        // ifr_name is a tuple of Int8 with 16 elements (IFNAMSIZ)
        withUnsafeMutablePointer(to: &ifr.ifr_name) { ptr in
            ptr.withMemoryRebound(to: Int8.self, capacity: 16) { namePtr in
                _ = interfaceName.withCString { cString in
                    strlcpy(namePtr, cString, 16)
                }
            }
        }
    }
}

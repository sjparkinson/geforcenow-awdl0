#if os(macOS)
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
            return "Invalid interface name: '\(name)' (max \(IFNAMSIZ - 1) characters)"
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
/// This uses standard POSIX/BSD interfaces available through Darwin:
/// - `SIOCGIFFLAGS`: Get interface flags (defined in <sys/sockio.h>)
/// - `SIOCSIFFLAGS`: Set interface flags (defined in <sys/sockio.h>)
/// - `IFF_UP`: Interface is up flag (defined in <net/if.h>)
/// - `IFNAMSIZ`: Max interface name length (defined in <net/if.h>)
///
/// Note: Bringing an interface down requires root privileges.
public final class InterfaceController: Sendable {
    // These constants come from Darwin SDK headers:
    // - SIOCGIFFLAGS/SIOCSIFFLAGS: <sys/sockio.h> - ioctl codes for getting/setting interface flags
    // - IFF_UP: <net/if.h> - the "interface is up" flag
    // The ioctl codes are available via `import Darwin` in Swift.

    private let logger = Logger(label: "InterfaceController")
    public let interfaceName: String

    public init(interfaceName: String = "awdl0") throws {
        // IFNAMSIZ is defined in <net/if.h>, available via Darwin
        guard interfaceName.count < IFNAMSIZ else {
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
        // IFF_UP is defined in <net/if.h>, available via Darwin
        return (flags & UInt16(IFF_UP)) != 0
    }

    private func setInterfaceUp(_ up: Bool) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw InterfaceError.socketCreationFailed(errno)
        }
        defer { close(fd) }

        var ifr = ifreq()
        copyInterfaceName(to: &ifr)

        // SIOCGIFFLAGS: get interface flags - from <sys/sockio.h>
        guard ioctl(fd, SIOCGIFFLAGS, &ifr) == 0 else {
            throw InterfaceError.getInterfaceFlagsFailed(errno)
        }

        // Modify the IFF_UP flag
        var flags = UInt16(bitPattern: ifr.ifr_ifru.ifru_flags)
        if up {
            flags |= UInt16(IFF_UP)
        } else {
            flags &= ~UInt16(IFF_UP)
        }
        ifr.ifr_ifru.ifru_flags = Int16(bitPattern: flags)

        // SIOCSIFFLAGS: set interface flags - from <sys/sockio.h>
        guard ioctl(fd, SIOCSIFFLAGS, &ifr) == 0 else {
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

        guard ioctl(fd, SIOCGIFFLAGS, &ifr) == 0 else {
            throw InterfaceError.getInterfaceFlagsFailed(errno)
        }

        return UInt16(bitPattern: ifr.ifr_ifru.ifru_flags)
    }

    private func copyInterfaceName(to ifr: inout ifreq) {
        // ifr_name is a tuple of Int8 with IFNAMSIZ elements
        withUnsafeMutablePointer(to: &ifr.ifr_name) { ptr in
            ptr.withMemoryRebound(to: Int8.self, capacity: Int(IFNAMSIZ)) { namePtr in
                _ = interfaceName.withCString { cString in
                    strlcpy(namePtr, cString, Int(IFNAMSIZ))
                }
            }
        }
    }
}
#endif

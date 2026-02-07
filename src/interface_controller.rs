//! Network interface control for macOS.
//!
//! This module provides functionality to bring network interfaces up and down
//! using ioctl syscalls on macOS.

use std::ffi::CString;
use std::os::fd::AsRawFd;

use nix::sys::socket::{socket, AddressFamily, SockFlag, SockType};
use thiserror::Error;
use tracing::{debug, info, warn};

/// `ioctl` request to get interface flags (macOS specific).
/// Not defined in libc crate for macOS.
const SIOCGIFFLAGS: libc::c_ulong = 0xc020_6911;

/// `ioctl` request to set interface flags (macOS specific).
/// Not defined in libc crate for macOS.
const SIOCSIFFLAGS: libc::c_ulong = 0x8020_6910;

/// Interface flag for "up" state.
/// Using i16 to match the `ifru_flags` field type.
#[allow(clippy::cast_possible_truncation)]
const IFF_UP: i16 = libc::IFF_UP as i16;

/// Errors that can occur when controlling network interfaces.
#[derive(Debug, Error)]
pub enum InterfaceError {
    #[error("failed to create socket: {0}")]
    SocketCreation(#[from] nix::Error),

    #[error("interface name too long (max 15 characters): {0}")]
    NameTooLong(String),

    #[error("interface name contains null byte: {0}")]
    InvalidName(String),

    #[error("ioctl failed: {0}")]
    Ioctl(std::io::Error),

    #[error("interface not found: {0}")]
    NotFound(String),
}

/// Result type for interface operations.
pub type Result<T> = std::result::Result<T, InterfaceError>;

/// Trait for controlling network interfaces.
///
/// This trait abstracts interface control operations to allow for testing
/// with mock implementations.
pub trait InterfaceController: Send + Sync {
    /// Bring the specified interface down (disable it).
    ///
    /// # Errors
    ///
    /// Returns an error if the interface cannot be found or controlled.
    fn bring_down(&self, name: &str) -> Result<()>;

    /// Allow the interface to come back up.
    ///
    /// Note: On macOS, `awdl0` is managed by the system. This doesn't force it up,
    /// but removes any restrictions we've placed on it.
    ///
    /// # Errors
    ///
    /// Returns an error if the interface cannot be found or controlled.
    fn allow_up(&self, name: &str) -> Result<()>;

    /// Check if the interface is currently up.
    ///
    /// # Errors
    ///
    /// Returns an error if the interface cannot be found or queried.
    fn is_up(&self, name: &str) -> Result<bool>;
}

/// macOS interface controller using `ioctl` syscalls.
pub struct MacOsInterfaceController;

impl MacOsInterfaceController {
    /// Create a new macOS interface controller.
    #[must_use]
    pub const fn new() -> Self {
        Self
    }

    /// Create a socket for `ioctl` operations.
    fn create_socket() -> Result<impl AsRawFd> {
        socket(
            AddressFamily::Inet,
            SockType::Datagram,
            SockFlag::empty(),
            None,
        )
        .map_err(InterfaceError::SocketCreation)
    }

    /// Validate and convert interface name to C string.
    fn validate_name(name: &str) -> Result<CString> {
        // macOS interface names are limited to `IFNAMSIZ` (16) including null terminator
        if name.len() > 15 {
            return Err(InterfaceError::NameTooLong(name.to_string()));
        }

        CString::new(name).map_err(|_| InterfaceError::InvalidName(name.to_string()))
    }

    /// Get the current flags for an interface.
    fn get_flags(name: &str) -> Result<i16> {
        let sock = Self::create_socket()?;
        let ifname = Self::validate_name(name)?;

        let mut ifr = ifreq::new(&ifname);

        // SAFETY: We're calling ioctl with a valid socket fd and properly initialized ifreq
        let result = unsafe { libc::ioctl(sock.as_raw_fd(), SIOCGIFFLAGS, &mut ifr) };

        if result < 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::ENXIO) {
                return Err(InterfaceError::NotFound(name.to_string()));
            }
            return Err(InterfaceError::Ioctl(err));
        }

        // SAFETY: If ioctl succeeded, ifr_ifru.ifru_flags is valid
        Ok(unsafe { ifr.ifr_ifru.ifru_flags })
    }

    /// Set the flags for an interface.
    fn set_flags(name: &str, flags: i16) -> Result<()> {
        let sock = Self::create_socket()?;
        let ifname = Self::validate_name(name)?;

        let mut ifr = ifreq::new(&ifname);
        ifr.ifr_ifru.ifru_flags = flags;

        // SAFETY: We're calling ioctl with a valid socket fd and properly initialized ifreq
        let result = unsafe { libc::ioctl(sock.as_raw_fd(), SIOCSIFFLAGS, &mut ifr) };

        if result < 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::ENXIO) {
                return Err(InterfaceError::NotFound(name.to_string()));
            }
            return Err(InterfaceError::Ioctl(err));
        }

        Ok(())
    }
}

impl Default for MacOsInterfaceController {
    fn default() -> Self {
        Self::new()
    }
}

impl InterfaceController for MacOsInterfaceController {
    fn bring_down(&self, name: &str) -> Result<()> {
        let current_flags = Self::get_flags(name)?;
        let is_up = (current_flags & IFF_UP) != 0;

        if !is_up {
            debug!(interface = name, "interface already down");
            return Ok(());
        }

        let new_flags = current_flags & !IFF_UP;
        Self::set_flags(name, new_flags)?;

        info!(interface = name, "brought interface down");
        Ok(())
    }

    fn allow_up(&self, name: &str) -> Result<()> {
        // For `awdl0`, we don't forcefully bring it up - we just ensure we're not
        // blocking it. The system will bring it up when needed (e.g., for AirDrop).
        // However, if we want to explicitly allow it, we can set the UP flag.

        let current_flags = match Self::get_flags(name) {
            Ok(flags) => flags,
            Err(InterfaceError::NotFound(_)) => {
                // Interface might not exist if system hasn't created it yet
                warn!(interface = name, "interface not found, cannot bring up");
                return Ok(());
            }
            Err(e) => return Err(e),
        };

        let is_up = (current_flags & IFF_UP) != 0;

        if is_up {
            debug!(interface = name, "interface already up");
            return Ok(());
        }

        let new_flags = current_flags | IFF_UP;
        Self::set_flags(name, new_flags)?;

        info!(interface = name, "allowed interface to come up");
        Ok(())
    }

    fn is_up(&self, name: &str) -> Result<bool> {
        let flags = Self::get_flags(name)?;
        Ok((flags & IFF_UP) != 0)
    }
}

/// Helper module for `ifreq` struct manipulation.
mod ifreq {
    use std::ffi::CString;

    /// Create a new `ifreq` struct with the given interface name.
    pub fn new(name: &CString) -> libc::ifreq {
        let mut ifr: libc::ifreq = unsafe { std::mem::zeroed() };

        let name_bytes = name.as_bytes_with_nul();
        let len = name_bytes.len().min(libc::IFNAMSIZ);

        // Copy interface name into ifr_name
        // SAFETY: We're copying at most IFNAMSIZ bytes into the correctly sized array
        unsafe {
            std::ptr::copy_nonoverlapping(
                name_bytes.as_ptr(),
                ifr.ifr_name.as_mut_ptr().cast::<u8>(),
                len,
            );
        }

        ifr
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_name_valid() {
        let result = MacOsInterfaceController::validate_name("en0");
        assert!(result.is_ok());
    }

    #[test]
    fn test_validate_name_too_long() {
        let long_name = "a".repeat(20);
        let result = MacOsInterfaceController::validate_name(&long_name);
        assert!(matches!(result, Err(InterfaceError::NameTooLong(_))));
    }

    #[test]
    fn test_validate_name_with_null() {
        let result = MacOsInterfaceController::validate_name("en\0zero");
        assert!(matches!(result, Err(InterfaceError::InvalidName(_))));
    }

    #[test]
    fn test_validate_name_max_length() {
        let name = "a".repeat(15); // Exactly 15 chars (max allowed)
        let result = MacOsInterfaceController::validate_name(&name);
        assert!(result.is_ok());
    }
}

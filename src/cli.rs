//! CLI commands for installation, uninstallation, and status.

#[cfg(target_os = "macos")]
use std::fs;
#[cfg(target_os = "macos")]
use std::path::Path;
#[cfg(target_os = "macos")]
use std::process::Command;

use thiserror::Error;
#[cfg(target_os = "macos")]
use tracing::{debug, info, warn};

/// The installation path for the binary.
#[cfg(target_os = "macos")]
pub const INSTALL_PATH: &str = "/usr/local/bin/geforcenow-awdl0";

/// The path to the `LaunchDaemon` plist.
#[cfg(target_os = "macos")]
pub const PLIST_PATH: &str = "/Library/LaunchDaemons/com.geforcenow.awdl0.plist";

/// The log directory for the daemon.
#[cfg(target_os = "macos")]
pub const LOG_DIR: &str = "/var/log/geforcenow-awdl0";

/// Errors that can occur during CLI operations.
#[derive(Debug, Error)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub enum CliError {
    #[error("not running as root (try sudo)")]
    NotRoot,

    #[error("failed to copy binary: {0}")]
    CopyBinary(std::io::Error),

    #[error("failed to write plist: {0}")]
    WritePlist(std::io::Error),

    #[error("failed to create log directory: {0}")]
    CreateLogDir(std::io::Error),

    #[error("launchctl command failed: {0}")]
    Launchctl(String),

    #[error("failed to remove file: {0}")]
    RemoveFile(std::io::Error),

    #[error("failed to get current executable path: {0}")]
    CurrentExe(std::io::Error),
}

/// Result type for CLI operations.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub type Result<T> = std::result::Result<T, CliError>;

/// Check if running as root.
#[cfg(target_os = "macos")]
fn check_root() -> Result<()> {
    // SAFETY: getuid is always safe to call
    if unsafe { libc::getuid() } != 0 {
        return Err(CliError::NotRoot);
    }
    Ok(())
}

/// Install the daemon.
///
/// This copies the binary to the installation path, creates the `LaunchDaemon`
/// plist, and loads the daemon.
///
/// # Errors
///
/// Returns an error if not running as root, or if file operations fail.
#[cfg(target_os = "macos")]
pub fn install() -> Result<()> {
    check_root()?;

    info!("installing geforcenow-awdl0 daemon");

    // Get current executable path
    let current_exe = std::env::current_exe().map_err(CliError::CurrentExe)?;
    debug!(path = %current_exe.display(), "current executable");

    // Create log directory
    if !Path::new(LOG_DIR).exists() {
        fs::create_dir_all(LOG_DIR).map_err(CliError::CreateLogDir)?;
        info!(path = LOG_DIR, "created log directory");
    }

    // Copy binary to installation path
    fs::copy(&current_exe, INSTALL_PATH).map_err(CliError::CopyBinary)?;

    // Make it executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(INSTALL_PATH)
            .map_err(CliError::CopyBinary)?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(INSTALL_PATH, perms).map_err(CliError::CopyBinary)?;
    }

    info!(path = INSTALL_PATH, "installed binary");

    // Write plist
    let plist_content = generate_plist();
    fs::write(PLIST_PATH, plist_content).map_err(CliError::WritePlist)?;
    info!(path = PLIST_PATH, "created LaunchDaemon plist");

    // Load the daemon
    load_daemon()?;

    info!("geforcenow-awdl0 daemon installed and started successfully");
    println!("✓ Daemon installed and started");
    println!("  Binary: {INSTALL_PATH}");
    println!("  Plist:  {PLIST_PATH}");
    println!("  Logs:   {LOG_DIR}/");

    Ok(())
}

/// Uninstall the daemon.
///
/// This unloads the daemon, removes the plist, and optionally removes the binary.
///
/// # Errors
///
/// Returns an error if not running as root, or if file operations fail.
#[cfg(target_os = "macos")]
pub fn uninstall() -> Result<()> {
    check_root()?;

    info!("uninstalling geforcenow-awdl0 daemon");

    // Unload the daemon first (ignore errors if not loaded)
    if Path::new(PLIST_PATH).exists() {
        let _ = unload_daemon();
    }

    // Remove the plist
    if Path::new(PLIST_PATH).exists() {
        fs::remove_file(PLIST_PATH).map_err(CliError::RemoveFile)?;
        info!(path = PLIST_PATH, "removed LaunchDaemon plist");
    }

    // Remove the binary
    if Path::new(INSTALL_PATH).exists() {
        fs::remove_file(INSTALL_PATH).map_err(CliError::RemoveFile)?;
        info!(path = INSTALL_PATH, "removed binary");
    }

    info!("geforcenow-awdl0 daemon uninstalled successfully");
    println!("✓ Daemon uninstalled");

    Ok(())
}

/// Show the daemon status.
///
/// # Errors
///
/// Returns an error if launchctl command fails.
#[cfg(target_os = "macos")]
pub fn status() -> Result<()> {
    // Check if installed
    let binary_installed = Path::new(INSTALL_PATH).exists();
    let plist_installed = Path::new(PLIST_PATH).exists();

    println!("geforcenow-awdl0 status:");
    println!();

    // Installation status
    if binary_installed && plist_installed {
        println!("  Installation: ✓ Installed");
    } else if binary_installed || plist_installed {
        println!(
            "  Installation: ⚠ Partial (binary: {binary_installed}, plist: {plist_installed})"
        );
    } else {
        println!("  Installation: ✗ Not installed");
    }

    // Daemon running status
    let running = is_daemon_running();
    if running {
        println!("  Daemon:       ✓ Running");
    } else {
        println!("  Daemon:       ✗ Not running");
    }

    // awdl0 interface status (best effort)
    match get_awdl0_status() {
        Some(true) => println!("  awdl0:        ↑ Up"),
        Some(false) => println!("  awdl0:        ↓ Down"),
        None => println!("  awdl0:        ? Unknown"),
    }

    // GeForce NOW status (best effort, only works when running with appropriate permissions)
    // We can't easily check this without running NSWorkspace, so we'll skip it
    println!("  GeForce NOW:  Run 'pgrep -f GeForceNOW' to check");

    Ok(())
}

/// Generate the `LaunchDaemon` plist content.
#[cfg(target_os = "macos")]
fn generate_plist() -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.awdl0.manager</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>{INSTALL_PATH}</string>
        <string>run</string>
    </array>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>KeepAlive</key>
    <true/>
    
    <key>ProcessType</key>
    <string>Background</string>
    
    <key>StandardOutPath</key>
    <string>{LOG_DIR}/stdout.log</string>
    
    <key>StandardErrorPath</key>
    <string>{LOG_DIR}/stderr.log</string>
    
    <key>ThrottleInterval</key>
    <integer>5</integer>
</dict>
</plist>
"#
    )
}

/// Load the daemon using launchctl.
#[cfg(target_os = "macos")]
fn load_daemon() -> Result<()> {
    debug!("loading daemon with launchctl");

    let output = Command::new("launchctl")
        .args(["load", "-w", PLIST_PATH])
        .output()
        .map_err(|e| CliError::Launchctl(e.to_string()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!(stderr = %stderr, "launchctl load failed");
        return Err(CliError::Launchctl(stderr.to_string()));
    }

    debug!("daemon loaded successfully");
    Ok(())
}

/// Unload the daemon using launchctl.
#[cfg(target_os = "macos")]
fn unload_daemon() -> Result<()> {
    debug!("unloading daemon with launchctl");

    let output = Command::new("launchctl")
        .args(["unload", "-w", PLIST_PATH])
        .output()
        .map_err(|e| CliError::Launchctl(e.to_string()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!(stderr = %stderr, "launchctl unload failed");
        // Don't fail - the daemon might not be loaded
    }

    debug!("daemon unloaded");
    Ok(())
}

/// Check if the daemon is currently running.
#[cfg(target_os = "macos")]
fn is_daemon_running() -> bool {
    let output = Command::new("launchctl")
        .args(["list", "com.awdl0.manager"])
        .output();

    match output {
        Ok(o) => o.status.success(),
        Err(_) => false,
    }
}

/// Get the current status of the `awdl0` interface.
#[cfg(target_os = "macos")]
fn get_awdl0_status() -> Option<bool> {
    let output = Command::new("ifconfig").arg("awdl0").output().ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    Some(stdout.contains("status: active"))
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn test_generate_plist() {
        let plist = generate_plist();
        assert!(plist.contains("com.awdl0.manager"));
        assert!(plist.contains(INSTALL_PATH));
        assert!(plist.contains("RunAtLoad"));
        assert!(plist.contains("KeepAlive"));
    }

    #[test]
    fn test_plist_is_valid_xml() {
        let plist = generate_plist();
        // Basic XML validation - should start with XML declaration
        assert!(plist.starts_with("<?xml"));
        // Should have matching tags
        assert!(plist.contains("<dict>"));
        assert!(plist.contains("</dict>"));
        assert!(plist.contains("<plist"));
        assert!(plist.contains("</plist>"));
    }
}

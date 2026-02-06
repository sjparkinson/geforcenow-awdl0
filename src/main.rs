//! geforcenow-awdl0: Prevent Apple Wireless Direct Link from causing latency
//! issues while gaming on `GeForce NOW`.
//!
//! This daemon monitors for the `GeForce NOW` application and automatically
//! brings down the awdl0 interface when it's running, re-enabling it when
//! `GeForce NOW` exits.

#[cfg(target_os = "macos")]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(target_os = "macos")]
use std::sync::Arc;

use clap::{Parser, Subcommand};
use tracing::Level;
use tracing_subscriber::EnvFilter;

#[cfg(target_os = "macos")]
use objc2_foundation::{MainThreadMarker, NSRunLoop};
#[cfg(target_os = "macos")]
use tracing::{debug, error, info, warn};

mod cli;
#[cfg(target_os = "macos")]
mod interface;
#[cfg(target_os = "macos")]
mod monitor;

#[cfg(target_os = "macos")]
use interface::{InterfaceController, MacOsInterfaceController};
#[cfg(target_os = "macos")]
use monitor::{MonitorConfig, ProcessEvent, ProcessMonitor};

/// The network interface to control.
#[cfg(target_os = "macos")]
const AWDL_INTERFACE: &str = "awdl0";

/// CLI argument parser.
#[derive(Parser)]
#[command(name = "geforcenow-awdl0")]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Enable verbose logging.
    #[arg(short, long, global = true)]
    verbose: bool,
}

/// Available CLI commands.
#[derive(Subcommand)]
enum Commands {
    /// Run the daemon (typically invoked by launchd).
    Run {
        /// Custom bundle ID to monitor (default: com.nvidia.gfnpc.mall).
        #[arg(long, default_value = "com.nvidia.gfnpc.mall")]
        bundle_id: String,
    },

    /// Install the daemon (requires root).
    Install,

    /// Uninstall the daemon (requires root).
    Uninstall,

    /// Show daemon status.
    Status,
}

fn main() {
    let cli = Cli::parse();

    // Initialize logging
    let filter = if cli.verbose {
        EnvFilter::new(Level::TRACE.to_string())
    } else {
        EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::new(Level::INFO.to_string()))
    };

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .init();

    #[cfg(target_os = "macos")]
    let result: cli::Result<()> = match cli.command {
        Commands::Run { bundle_id } => run_daemon(&bundle_id),
        Commands::Install => cli::install(),
        Commands::Uninstall => cli::uninstall(),
        Commands::Status => cli::status(),
    };

    #[cfg(not(target_os = "macos"))]
    {
        let _ = cli.command; // Silence unused warning
        eprintln!("geforcenow-awdl0 is only supported on macOS");
        std::process::exit(1);
    }

    #[cfg(target_os = "macos")]
    if let Err(e) = result {
        error!(error = %e, "command failed");
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}

/// Run the daemon.
#[cfg(target_os = "macos")]
fn run_daemon(bundle_id: &str) -> cli::Result<()> {
    info!(
        version = env!("CARGO_PKG_VERSION"),
        bundle_id = bundle_id,
        "starting geforcenow-awdl0 daemon"
    );

    // Ensure we're on the main thread (required for NSWorkspace)
    let _mtm = MainThreadMarker::new().expect("must run on main thread");

    // Set up signal handling
    let running = Arc::new(AtomicBool::new(true));
    let running_signal = Arc::clone(&running);

    // Set up SIGTERM and SIGINT handlers
    // SAFETY: We're just setting an atomic bool
    unsafe {
        libc::signal(libc::SIGTERM, handle_signal as *const () as usize);
        libc::signal(libc::SIGINT, handle_signal as *const () as usize);
    }

    // Store the running flag for signal handler
    RUNNING.store(
        Box::into_raw(Box::new(running_signal)) as usize,
        Ordering::SeqCst,
    );

    // Create the interface controller
    let controller = Arc::new(MacOsInterfaceController::new());
    let controller_clone = Arc::clone(&controller);

    // Track whether GeForce NOW is currently running
    let gfn_running = Arc::new(AtomicBool::new(false));
    let gfn_running_clone = Arc::clone(&gfn_running);

    // Create callback for process events
    let callback: monitor::EventCallback = Arc::new(move |event| match event {
        ProcessEvent::Launched { bundle_id, pid } => {
            info!(
                bundle_id = %bundle_id,
                pid = pid,
                "GeForce NOW launched, disabling awdl0"
            );

            gfn_running_clone.store(true, Ordering::SeqCst);

            if let Err(e) = controller_clone.bring_down(AWDL_INTERFACE) {
                error!(error = %e, "failed to bring down awdl0");
            }
        }
        ProcessEvent::Terminated { bundle_id, pid } => {
            info!(
                bundle_id = %bundle_id,
                pid = pid,
                "GeForce NOW terminated, allowing awdl0"
            );

            gfn_running_clone.store(false, Ordering::SeqCst);

            if let Err(e) = controller_clone.allow_up(AWDL_INTERFACE) {
                error!(error = %e, "failed to allow awdl0 up");
            }
        }
    });

    // Create and start the process monitor
    let config = MonitorConfig {
        target_bundle_id: bundle_id.to_string(),
    };

    let monitor = ProcessMonitor::new(config, callback);

    if let Err(e) = monitor.start() {
        error!(error = %e, "failed to start process monitor");
        return Err(cli::CliError::Launchctl(format!(
            "failed to start process monitor: {e}"
        )));
    }

    info!("daemon running, waiting for events");

    // Run the main loop
    // We use NSRunLoop to process Cocoa notifications
    let run_loop = unsafe { NSRunLoop::mainRunLoop() };

    while running.load(Ordering::SeqCst) {
        // Run the loop for a short interval, then check if we should exit
        // This allows us to handle signals gracefully
        unsafe {
            run_loop.runUntilDate(&objc2_foundation::NSDate::dateWithTimeIntervalSinceNow(1.0));
        }

        // If GeForce NOW is running, periodically check that awdl0 is still down
        // (the system might try to bring it back up)
        if gfn_running.load(Ordering::SeqCst) {
            match controller.is_up(AWDL_INTERFACE) {
                Ok(true) => {
                    warn!(
                        "awdl0 came back up while GeForce NOW is running, bringing it down again"
                    );
                    if let Err(e) = controller.bring_down(AWDL_INTERFACE) {
                        error!(error = %e, "failed to bring down awdl0");
                    }
                }
                Ok(false) => {
                    debug!("awdl0 is down as expected");
                }
                Err(e) => {
                    debug!(error = %e, "could not check awdl0 status");
                }
            }
        }
    }

    info!("daemon shutting down");

    // If GeForce NOW was running when we shut down, allow awdl0 back up
    if gfn_running.load(Ordering::SeqCst) {
        info!("allowing awdl0 up on shutdown");
        if let Err(e) = controller.allow_up(AWDL_INTERFACE) {
            warn!(error = %e, "failed to allow awdl0 up on shutdown");
        }
    }

    info!("daemon stopped");
    Ok(())
}

/// Static storage for the running flag (used by signal handler).
#[cfg(target_os = "macos")]
static RUNNING: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Signal handler.
#[cfg(target_os = "macos")]
extern "C" fn handle_signal(sig: i32) {
    // Note: Cannot use tracing in signal handler as it's not async-signal-safe
    let _ = sig;

    let ptr = RUNNING.load(Ordering::SeqCst);
    if ptr != 0 {
        // SAFETY: We stored a valid Box pointer earlier
        let running = unsafe { &*(ptr as *const Arc<AtomicBool>) };
        running.store(false, Ordering::SeqCst);
    }
}

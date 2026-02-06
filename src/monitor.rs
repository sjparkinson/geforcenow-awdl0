//! Process monitoring using macOS NSWorkspace notifications.
//!
//! This module provides event-driven monitoring for application launches and
//! terminations on macOS, using NSWorkspace notifications rather than polling.

use std::cell::RefCell;
use std::sync::Arc;

use block2::RcBlock;
use objc2::msg_send_id;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_app_kit::{NSRunningApplication, NSWorkspace};
use objc2_foundation::{
    MainThreadMarker, NSNotification, NSNotificationCenter, NSNotificationName, NSObjectProtocol,
    NSOperationQueue, NSString,
};
use thiserror::Error;
use tracing::{debug, info, trace, warn};

/// Errors that can occur during process monitoring.
#[derive(Debug, Error)]
pub enum MonitorError {
    #[error("failed to initialize NSWorkspace")]
    WorkspaceInit,

    #[error("not running on main thread")]
    NotMainThread,

    #[error("failed to register notification observer")]
    ObserverRegistration,
}

/// Result type for monitor operations.
pub type Result<T> = std::result::Result<T, MonitorError>;

/// Events emitted by the process monitor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessEvent {
    /// The target application was launched.
    Launched { bundle_id: String, pid: i32 },
    /// The target application was terminated.
    Terminated { bundle_id: String, pid: i32 },
}

/// Callback type for process events.
pub type EventCallback = Arc<dyn Fn(ProcessEvent) + Send + Sync>;

/// Configuration for the process monitor.
#[derive(Debug, Clone)]
pub struct MonitorConfig {
    /// The bundle identifier to watch for (e.g., "com.nvidia.gfnpc.mall").
    pub target_bundle_id: String,
}

impl Default for MonitorConfig {
    fn default() -> Self {
        Self {
            target_bundle_id: "com.nvidia.gfnpc.mall".to_string(),
        }
    }
}

/// Process monitor that watches for application launches and terminations.
///
/// Uses NSWorkspace notifications for event-driven monitoring (no polling).
pub struct ProcessMonitor {
    config: MonitorConfig,
    callback: EventCallback,
    /// Stored observers to ensure they stay alive.
    /// We use RefCell because observers are set up on the main thread.
    _observers: RefCell<Vec<Retained<ProtocolObject<dyn NSObjectProtocol>>>>,
}

impl ProcessMonitor {
    /// Create a new process monitor with the given configuration and callback.
    ///
    /// # Arguments
    /// * `config` - Configuration specifying which application to monitor.
    /// * `callback` - Callback function invoked when the target app launches or terminates.
    pub fn new(config: MonitorConfig, callback: EventCallback) -> Self {
        Self {
            config,
            callback,
            _observers: RefCell::new(Vec::new()),
        }
    }

    /// Start the process monitor.
    ///
    /// This registers for NSWorkspace notifications and checks if the target
    /// application is already running.
    ///
    /// Must be called from the main thread.
    ///
    /// # Errors
    /// Returns an error if not called from the main thread or if notification
    /// registration fails.
    pub fn start(&self) -> Result<()> {
        let mtm = MainThreadMarker::new().ok_or(MonitorError::NotMainThread)?;

        info!(
            bundle_id = %self.config.target_bundle_id,
            "starting process monitor"
        );

        // Get the shared workspace
        let workspace = NSWorkspace::sharedWorkspace(mtm);

        // Check if target is already running
        self.check_running_applications(&workspace);

        // Register for launch and termination notifications
        self.register_notifications(&workspace)?;

        info!("process monitor started successfully");
        Ok(())
    }

    /// Check if the target application is currently running.
    fn check_running_applications(&self, workspace: &NSWorkspace) {
        let running_apps = unsafe { workspace.runningApplications() };

        for app in &*running_apps {
            if let Some(bundle_id) = get_bundle_identifier(app) {
                trace!(bundle_id = %bundle_id, "checking running application");

                if bundle_id == self.config.target_bundle_id {
                    let pid = get_process_identifier(app);
                    info!(
                        bundle_id = %bundle_id,
                        pid = pid,
                        "target application already running"
                    );
                    (self.callback)(ProcessEvent::Launched { bundle_id, pid });
                    return;
                }
            }
        }

        debug!(
            bundle_id = %self.config.target_bundle_id,
            "target application not currently running"
        );
    }

    /// Register for workspace notifications.
    fn register_notifications(&self, workspace: &NSWorkspace) -> Result<()> {
        let notification_center = unsafe { workspace.notificationCenter() };

        // Register for launch notifications
        let launch_observer = self.register_notification(
            &notification_center,
            unsafe { NSWorkspace::didLaunchApplicationNotification() },
            true,
        )?;

        // Register for termination notifications
        let terminate_observer = self.register_notification(
            &notification_center,
            unsafe { NSWorkspace::didTerminateApplicationNotification() },
            false,
        )?;

        self._observers
            .borrow_mut()
            .extend([launch_observer, terminate_observer]);

        Ok(())
    }

    /// Register for a specific notification.
    fn register_notification(
        &self,
        center: &NSNotificationCenter,
        name: &NSNotificationName,
        is_launch: bool,
    ) -> Result<Retained<ProtocolObject<dyn NSObjectProtocol>>> {
        let target_bundle_id = self.config.target_bundle_id.clone();
        let callback = Arc::clone(&self.callback);

        let block = RcBlock::new(move |notification: *mut NSNotification| {
            // SAFETY: The notification pointer is valid during the callback
            let notification = unsafe { &*notification };
            handle_notification(notification, &target_bundle_id, &callback, is_launch);
        });

        let observer = unsafe {
            center.addObserverForName_object_queue_usingBlock(
                Some(name),
                None,
                Some(&NSOperationQueue::mainQueue()),
                &block,
            )
        };

        debug!(
            notification = if is_launch { "launch" } else { "terminate" },
            "registered notification observer"
        );

        Ok(observer)
    }

    /// Check if the target application is currently running.
    ///
    /// This can be called from any thread.
    pub fn is_target_running(&self) -> bool {
        // We need to be on the main thread to access NSWorkspace
        if MainThreadMarker::new().is_none() {
            warn!("is_target_running called from non-main thread");
            return false;
        }

        let mtm = MainThreadMarker::new().unwrap();
        let workspace = NSWorkspace::sharedWorkspace(mtm);
        let running_apps = unsafe { workspace.runningApplications() };

        for app in running_apps {
            if let Some(bundle_id) = get_bundle_identifier(&app) {
                if bundle_id == self.config.target_bundle_id {
                    return true;
                }
            }
        }

        false
    }
}

/// Handle a workspace notification.
fn handle_notification(
    notification: &NSNotification,
    target_bundle_id: &str,
    callback: &EventCallback,
    is_launch: bool,
) {
    let user_info = match unsafe { notification.userInfo() } {
        Some(info) => info,
        None => {
            warn!("notification missing userInfo");
            return;
        }
    };

    // Get the NSRunningApplication from userInfo
    // The key is NSWorkspaceApplicationKey
    let app_key = NSString::from_str("NSWorkspaceApplicationKey");
    let app: Option<Retained<NSRunningApplication>> = unsafe {
        let obj = user_info.objectForKey(&app_key);
        obj.map(|o| msg_send_id![&o, self])
    };

    let app = match app {
        Some(app) => app,
        None => {
            warn!("notification missing application object");
            return;
        }
    };

    let bundle_id = match get_bundle_identifier(&app) {
        Some(id) => id,
        None => {
            trace!("application has no bundle identifier");
            return;
        }
    };

    // Check if this is the application we're interested in
    if bundle_id != target_bundle_id {
        trace!(
            bundle_id = %bundle_id,
            target = %target_bundle_id,
            "ignoring notification for non-target application"
        );
        return;
    }

    let pid = get_process_identifier(&app);

    if is_launch {
        info!(bundle_id = %bundle_id, pid = pid, "target application launched");
        callback(ProcessEvent::Launched { bundle_id, pid });
    } else {
        info!(bundle_id = %bundle_id, pid = pid, "target application terminated");
        callback(ProcessEvent::Terminated { bundle_id, pid });
    }
}

/// Get the bundle identifier from an NSRunningApplication.
fn get_bundle_identifier(app: &NSRunningApplication) -> Option<String> {
    let bundle_id: Option<Retained<NSString>> = unsafe { app.bundleIdentifier() };
    bundle_id.map(|s| s.to_string())
}

/// Get the process identifier from an NSRunningApplication.
fn get_process_identifier(app: &NSRunningApplication) -> i32 {
    // Use msg_send since processIdentifier may not be directly exposed
    unsafe { objc2::msg_send![app, processIdentifier] }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn test_monitor_config_default() {
        let config = MonitorConfig::default();
        assert_eq!(config.target_bundle_id, "com.nvidia.gfnpc.mall");
    }

    #[test]
    fn test_process_event_equality() {
        let event1 = ProcessEvent::Launched {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        };
        let event2 = ProcessEvent::Launched {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        };
        assert_eq!(event1, event2);
    }

    #[test]
    fn test_monitor_creation() {
        let config = MonitorConfig::default();
        let called = Arc::new(AtomicBool::new(false));
        let called_clone = Arc::clone(&called);

        let callback: EventCallback = Arc::new(move |_event| {
            called_clone.store(true, Ordering::SeqCst);
        });

        let monitor = ProcessMonitor::new(config.clone(), callback);
        assert_eq!(monitor.config.target_bundle_id, config.target_bundle_id);
    }
}

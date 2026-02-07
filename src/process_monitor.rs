//! Process monitoring using macOS `NSWorkspace` notifications.
//!
//! This module provides event-driven monitoring for application launches and
//! terminations on macOS, using `NSWorkspace` notifications rather than polling.
//!
//! Additionally, when the target application is running, it polls for fullscreen
//! window state to detect when streaming starts and stops.

use std::cell::RefCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::thread;
use std::time::Duration;

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{ClassType, msg_send};
use objc2_app_kit::{NSRunningApplication, NSWorkspace};
use objc2_foundation::{
    MainThreadMarker, NSNotification, NSNotificationCenter, NSObjectProtocol, NSOperationQueue,
    NSString,
};
use thiserror::Error;
use tracing::{debug, info, trace, warn};

use crate::window_monitor;

/// Errors that can occur during process monitoring.
#[derive(Debug, Error)]
pub enum MonitorError {
    #[error("not running on main thread")]
    NotMainThread,
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
    /// The target application entered fullscreen (streaming started).
    StreamStarted { bundle_id: String, pid: i32 },
    /// The target application exited fullscreen (streaming stopped).
    StreamEnded { bundle_id: String, pid: i32 },
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
/// Uses `NSWorkspace` notifications for event-driven monitoring (no polling).
/// When the target application is running, polls for fullscreen state to detect
/// streaming activity.
pub struct ProcessMonitor {
    config: MonitorConfig,
    callback: EventCallback,
    /// Stored observers to ensure they stay alive.
    /// We use `RefCell` because observers are set up on the main thread.
    observers: RefCell<Vec<Retained<ProtocolObject<dyn NSObjectProtocol>>>>,
    /// The PID of the currently running target application (0 if not running).
    current_pid: Arc<AtomicI32>,
    /// Whether the application is currently streaming (fullscreen).
    is_streaming: Arc<AtomicBool>,
    /// Flag to signal the polling thread to stop.
    polling_active: Arc<AtomicBool>,
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
            observers: RefCell::new(Vec::new()),
            current_pid: Arc::new(AtomicI32::new(0)),
            is_streaming: Arc::new(AtomicBool::new(false)),
            polling_active: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Start the process monitor.
    ///
    /// This registers for `NSWorkspace` notifications and checks if the target
    /// application is already running.
    ///
    /// Must be called from the main thread.
    ///
    /// # Errors
    /// Returns an error if not called from the main thread or if notification
    /// registration fails.
    pub fn start(&self) -> Result<()> {
        let _mtm = MainThreadMarker::new().ok_or(MonitorError::NotMainThread)?;

        info!(
            bundle_id = %self.config.target_bundle_id,
            "starting process monitor"
        );

        // Get the shared workspace
        let workspace: Retained<NSWorkspace> =
            unsafe { msg_send![objc2_app_kit::NSWorkspace::class(), sharedWorkspace] };

        // Check if target is already running
        self.check_running_applications(&workspace);

        // Register for launch and termination notifications
        self.register_notifications(&workspace);

        info!("process monitor started successfully");
        Ok(())
    }

    /// Check if the target application is currently running.
    fn check_running_applications(&self, workspace: &NSWorkspace) {
        let running_apps = workspace.runningApplications();

        for app in &*running_apps {
            if let Some(bundle_id) = get_bundle_identifier(&app) {
                trace!(bundle_id = %bundle_id, "checking running application");

                if bundle_id == self.config.target_bundle_id {
                    let pid = get_process_identifier(&app);
                    info!(
                        bundle_id = %bundle_id,
                        pid = pid,
                        "target application already running"
                    );

                    // Store the PID
                    self.current_pid.store(pid, Ordering::SeqCst);

                    // Emit the Launched event
                    (self.callback)(ProcessEvent::Launched {
                        bundle_id: bundle_id.clone(),
                        pid,
                    });

                    // Start the fullscreen polling thread
                    start_fullscreen_polling(
                        bundle_id,
                        pid,
                        Arc::clone(&self.callback),
                        Arc::clone(&self.polling_active),
                        Arc::clone(&self.is_streaming),
                    );

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
    fn register_notifications(&self, workspace: &NSWorkspace) {
        let notification_center = workspace.notificationCenter();

        // Get notification names - these are NSString constants
        let launch_name = NSString::from_str("NSWorkspaceDidLaunchApplicationNotification");
        let terminate_name = NSString::from_str("NSWorkspaceDidTerminateApplicationNotification");

        // Register for launch notifications
        let launch_observer = self.register_notification(&notification_center, &launch_name, true);

        // Register for termination notifications
        let terminate_observer =
            self.register_notification(&notification_center, &terminate_name, false);

        self.observers
            .borrow_mut()
            .extend([launch_observer, terminate_observer]);
    }

    /// Register for a specific notification.
    fn register_notification(
        &self,
        center: &NSNotificationCenter,
        name: &NSString,
        is_launch: bool,
    ) -> Retained<ProtocolObject<dyn NSObjectProtocol>> {
        let target_bundle_id = self.config.target_bundle_id.clone();
        let callback = Arc::clone(&self.callback);
        let current_pid = Arc::clone(&self.current_pid);
        let is_streaming = Arc::clone(&self.is_streaming);
        let polling_active = Arc::clone(&self.polling_active);

        let block = RcBlock::new(move |notification: *mut NSNotification| {
            // SAFETY: The notification pointer is valid during the callback
            let notification = unsafe { &*notification };
            handle_notification(
                notification,
                &target_bundle_id,
                &callback,
                &current_pid,
                &is_streaming,
                &polling_active,
                is_launch,
            );
        });

        let queue = NSOperationQueue::mainQueue();
        let observer: Retained<ProtocolObject<dyn NSObjectProtocol>> = unsafe {
            msg_send![
                center,
                addObserverForName: name,
                object: std::ptr::null::<objc2::runtime::AnyObject>(),
                queue: &*queue,
                usingBlock: &*block,
            ]
        };

        debug!(
            notification = if is_launch { "launch" } else { "terminate" },
            "registered notification observer"
        );

        observer
    }
}

/// Handle a workspace notification.
fn handle_notification(
    notification: &NSNotification,
    target_bundle_id: &str,
    callback: &EventCallback,
    current_pid: &Arc<AtomicI32>,
    is_streaming: &Arc<AtomicBool>,
    polling_active: &Arc<AtomicBool>,
    is_launch: bool,
) {
    let Some(user_info) = notification.userInfo() else {
        warn!("notification missing userInfo");
        return;
    };

    // Get the NSRunningApplication from userInfo
    // The key is NSWorkspaceApplicationKey
    let app_key = NSString::from_str("NSWorkspaceApplicationKey");
    let app: Option<Retained<NSRunningApplication>> = {
        let obj = user_info.objectForKey(&app_key);
        obj.map(|o| unsafe { msg_send![&o, self] })
    };

    let Some(app) = app else {
        warn!("notification missing application object");
        return;
    };

    let Some(bundle_id) = get_bundle_identifier(&app) else {
        trace!("application has no bundle identifier");
        return;
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

        // Store the PID
        current_pid.store(pid, Ordering::SeqCst);

        // Emit the Launched event
        callback(ProcessEvent::Launched {
            bundle_id: bundle_id.clone(),
            pid,
        });

        // Start the fullscreen polling thread
        start_fullscreen_polling(
            bundle_id,
            pid,
            Arc::clone(callback),
            Arc::clone(polling_active),
            Arc::clone(is_streaming),
        );
    } else {
        info!(bundle_id = %bundle_id, pid = pid, "target application terminated");

        // Stop the polling thread
        polling_active.store(false, Ordering::SeqCst);

        // If we were streaming, emit StreamEnded first
        if is_streaming.swap(false, Ordering::SeqCst) {
            info!(
                bundle_id = %bundle_id,
                pid = pid,
                "streaming ended (application terminated)"
            );
            callback(ProcessEvent::StreamEnded {
                bundle_id: bundle_id.clone(),
                pid,
            });
        }

        // Clear the PID
        current_pid.store(0, Ordering::SeqCst);

        // Emit the Terminated event
        callback(ProcessEvent::Terminated { bundle_id, pid });
    }
}

/// Start a background thread to poll for fullscreen window state.
fn start_fullscreen_polling(
    bundle_id: String,
    pid: i32,
    callback: EventCallback,
    polling_active: Arc<AtomicBool>,
    is_streaming: Arc<AtomicBool>,
) {
    /// Polling interval for checking fullscreen state (5 seconds).
    const POLL_INTERVAL: Duration = Duration::from_secs(5);

    polling_active.store(true, Ordering::SeqCst);

    thread::spawn(move || {
        debug!(pid = pid, "started fullscreen polling thread");

        while polling_active.load(Ordering::SeqCst) {
            thread::sleep(POLL_INTERVAL);

            // Check if we should still be running
            if !polling_active.load(Ordering::SeqCst) {
                break;
            }

            let is_fullscreen = window_monitor::has_fullscreen_window(pid);
            let was_streaming = is_streaming.load(Ordering::SeqCst);

            if is_fullscreen && !was_streaming {
                // Entered fullscreen - streaming started
                info!(
                    bundle_id = %bundle_id,
                    pid = pid,
                    "detected fullscreen window, streaming started"
                );
                is_streaming.store(true, Ordering::SeqCst);
                callback(ProcessEvent::StreamStarted {
                    bundle_id: bundle_id.clone(),
                    pid,
                });
            } else if !is_fullscreen && was_streaming {
                // Exited fullscreen - streaming ended
                info!(
                    bundle_id = %bundle_id,
                    pid = pid,
                    "fullscreen window closed, streaming ended"
                );
                is_streaming.store(false, Ordering::SeqCst);
                callback(ProcessEvent::StreamEnded {
                    bundle_id: bundle_id.clone(),
                    pid,
                });
            } else {
                trace!(
                    pid = pid,
                    is_fullscreen = is_fullscreen,
                    was_streaming = was_streaming,
                    "no streaming state change"
                );
            }
        }

        debug!(pid = pid, "fullscreen polling thread stopped");
    });
}

/// Get the bundle identifier from an `NSRunningApplication`.
fn get_bundle_identifier(app: &NSRunningApplication) -> Option<String> {
    let bundle_id: Option<Retained<NSString>> = app.bundleIdentifier();
    bundle_id.map(|s| s.to_string())
}

/// Get the process identifier from an `NSRunningApplication`.
fn get_process_identifier(app: &NSRunningApplication) -> i32 {
    // Use msg_send since processIdentifier may not be directly exposed
    unsafe { objc2::msg_send![app, processIdentifier] }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

    #[test]
    fn test_monitor_config_default() {
        let config = MonitorConfig::default();
        assert_eq!(config.target_bundle_id, "com.nvidia.gfnpc.mall");
    }

    #[test]
    fn test_monitor_config_custom() {
        let config = MonitorConfig {
            target_bundle_id: "com.custom.app".to_string(),
        };
        assert_eq!(config.target_bundle_id, "com.custom.app");
    }

    #[test]
    fn test_process_event_launched_equality() {
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
    fn test_process_event_terminated_equality() {
        let event1 = ProcessEvent::Terminated {
            bundle_id: "com.test.app".to_string(),
            pid: 456,
        };
        let event2 = ProcessEvent::Terminated {
            bundle_id: "com.test.app".to_string(),
            pid: 456,
        };
        assert_eq!(event1, event2);
    }

    #[test]
    fn test_process_event_stream_started_equality() {
        let event1 = ProcessEvent::StreamStarted {
            bundle_id: "com.test.app".to_string(),
            pid: 789,
        };
        let event2 = ProcessEvent::StreamStarted {
            bundle_id: "com.test.app".to_string(),
            pid: 789,
        };
        assert_eq!(event1, event2);
    }

    #[test]
    fn test_process_event_stream_ended_equality() {
        let event1 = ProcessEvent::StreamEnded {
            bundle_id: "com.test.app".to_string(),
            pid: 101,
        };
        let event2 = ProcessEvent::StreamEnded {
            bundle_id: "com.test.app".to_string(),
            pid: 101,
        };
        assert_eq!(event1, event2);
    }

    #[test]
    fn test_process_event_inequality_different_types() {
        let launched = ProcessEvent::Launched {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        };
        let terminated = ProcessEvent::Terminated {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        };
        let stream_started = ProcessEvent::StreamStarted {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        };
        let stream_ended = ProcessEvent::StreamEnded {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        };

        assert_ne!(launched, terminated);
        assert_ne!(launched, stream_started);
        assert_ne!(launched, stream_ended);
        assert_ne!(terminated, stream_started);
        assert_ne!(terminated, stream_ended);
        assert_ne!(stream_started, stream_ended);
    }

    #[test]
    fn test_process_event_inequality_different_bundle_id() {
        let event1 = ProcessEvent::Launched {
            bundle_id: "com.app.one".to_string(),
            pid: 123,
        };
        let event2 = ProcessEvent::Launched {
            bundle_id: "com.app.two".to_string(),
            pid: 123,
        };
        assert_ne!(event1, event2);
    }

    #[test]
    fn test_process_event_inequality_different_pid() {
        let event1 = ProcessEvent::Launched {
            bundle_id: "com.test.app".to_string(),
            pid: 100,
        };
        let event2 = ProcessEvent::Launched {
            bundle_id: "com.test.app".to_string(),
            pid: 200,
        };
        assert_ne!(event1, event2);
    }

    #[test]
    fn test_monitor_creation() {
        let config = MonitorConfig::default();
        let called = Arc::new(AtomicBool::new(false));
        let called_clone = Arc::clone(&called);

        let callback: EventCallback = Arc::new(move |_event| {
            called_clone.store(true, Ordering::SeqCst);
        });

        // Verify monitor can be created successfully
        let _monitor = ProcessMonitor::new(config, callback);
    }

    #[test]
    fn test_monitor_initial_state() {
        let config = MonitorConfig::default();
        let callback: EventCallback = Arc::new(|_| {});

        let monitor = ProcessMonitor::new(config, callback);

        // Initial state: not streaming, no PID, polling inactive
        assert_eq!(monitor.current_pid.load(Ordering::SeqCst), 0);
        assert!(!monitor.is_streaming.load(Ordering::SeqCst));
        assert!(!monitor.polling_active.load(Ordering::SeqCst));
    }

    #[test]
    fn test_callback_receives_events() {
        let config = MonitorConfig::default();
        let event_count = Arc::new(AtomicU32::new(0));
        let event_count_clone = Arc::clone(&event_count);

        let callback: EventCallback = Arc::new(move |_event| {
            event_count_clone.fetch_add(1, Ordering::SeqCst);
        });

        // Just verify the callback can be invoked
        callback(ProcessEvent::Launched {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        });

        assert_eq!(event_count.load(Ordering::SeqCst), 1);

        callback(ProcessEvent::StreamStarted {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        });

        assert_eq!(event_count.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn test_process_event_debug_format() {
        let event = ProcessEvent::Launched {
            bundle_id: "com.test.app".to_string(),
            pid: 123,
        };
        let debug_str = format!("{event:?}");
        assert!(debug_str.contains("Launched"));
        assert!(debug_str.contains("com.test.app"));
        assert!(debug_str.contains("123"));
    }

    #[test]
    fn test_process_event_clone() {
        let event = ProcessEvent::StreamStarted {
            bundle_id: "com.test.app".to_string(),
            pid: 456,
        };
        let cloned = event.clone();
        assert_eq!(event, cloned);
    }

    #[test]
    fn test_monitor_error_display() {
        let error = MonitorError::NotMainThread;
        assert_eq!(error.to_string(), "not running on main thread");
    }
}

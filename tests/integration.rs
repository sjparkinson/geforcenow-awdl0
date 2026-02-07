//! Integration tests for geforcenow-awdl0.
//!
//! These tests are macOS-specific and test the actual system integration.

#![cfg(target_os = "macos")]

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

/// Test that the process monitor can be created and configured.
#[test]
fn test_monitor_config_creation() {
    use geforcenow_awdl0::process_monitor::MonitorConfig;

    let config = MonitorConfig {
        target_bundle_id: "com.test.app".to_string(),
    };

    assert_eq!(config.target_bundle_id, "com.test.app");
}

/// Test that the monitor default config is for `GeForce NOW`.
#[test]
fn test_monitor_default_config() {
    use geforcenow_awdl0::process_monitor::MonitorConfig;

    let config = MonitorConfig::default();
    assert_eq!(config.target_bundle_id, "com.nvidia.gfnpc.mall");
}

/// Test process event types.
#[test]
fn test_process_events() {
    use geforcenow_awdl0::process_monitor::ProcessEvent;

    let launch_event = ProcessEvent::Launched {
        bundle_id: "com.test.app".to_string(),
        pid: 12345,
    };

    let terminate_event = ProcessEvent::Terminated {
        bundle_id: "com.test.app".to_string(),
        pid: 12345,
    };

    // Events with same data should be equal
    let launch_event2 = ProcessEvent::Launched {
        bundle_id: "com.test.app".to_string(),
        pid: 12345,
    };

    assert_eq!(launch_event, launch_event2);
    assert_ne!(launch_event, terminate_event);
}

/// Test that the interface controller can be created.
#[test]
fn test_interface_controller_creation() {
    use geforcenow_awdl0::interface_controller::MacOsInterfaceController;

    let _controller = MacOsInterfaceController::new();
    // Just verify it can be created
}

/// Test interface name validation.
#[test]
fn test_interface_name_validation() {
    use geforcenow_awdl0::interface_controller::{InterfaceController, MacOsInterfaceController};

    let controller = MacOsInterfaceController::new();

    // Names that are too long should fail
    let long_name = "a".repeat(20);
    let result = controller.is_up(&long_name);
    assert!(result.is_err());
}

/// Test callback invocation tracking.
#[test]
fn test_callback_tracking() {
    use geforcenow_awdl0::process_monitor::{EventCallback, MonitorConfig, ProcessMonitor};

    let call_count = Arc::new(AtomicU32::new(0));
    let call_count_clone = Arc::clone(&call_count);

    let callback: EventCallback = Arc::new(move |_event| {
        call_count_clone.fetch_add(1, Ordering::SeqCst);
    });

    let config = MonitorConfig::default();
    let _monitor = ProcessMonitor::new(config, callback);

    // Monitor created but not started, so callback shouldn't have been called
    assert_eq!(call_count.load(Ordering::SeqCst), 0);
}

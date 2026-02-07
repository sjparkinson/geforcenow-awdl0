//! Integration tests for geforcenow-awdl0.
//!
//! These tests are macOS-specific and test the actual system integration.

#![cfg(target_os = "macos")]

use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

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

/// Test streaming event types.
#[test]
fn test_streaming_events() {
    use geforcenow_awdl0::process_monitor::ProcessEvent;

    let stream_started = ProcessEvent::StreamStarted {
        bundle_id: "com.nvidia.gfnpc.mall".to_string(),
        pid: 1234,
    };

    let stream_ended = ProcessEvent::StreamEnded {
        bundle_id: "com.nvidia.gfnpc.mall".to_string(),
        pid: 1234,
    };

    // Same type and data should be equal
    let stream_started2 = ProcessEvent::StreamStarted {
        bundle_id: "com.nvidia.gfnpc.mall".to_string(),
        pid: 1234,
    };

    assert_eq!(stream_started, stream_started2);
    assert_ne!(stream_started, stream_ended);
}

/// Test full event lifecycle types.
#[test]
fn test_event_lifecycle_types() {
    use geforcenow_awdl0::process_monitor::ProcessEvent;

    let bundle_id = "com.nvidia.gfnpc.mall".to_string();
    let pid = 5678;

    // All four event types in a typical lifecycle
    let events = vec![
        ProcessEvent::Launched {
            bundle_id: bundle_id.clone(),
            pid,
        },
        ProcessEvent::StreamStarted {
            bundle_id: bundle_id.clone(),
            pid,
        },
        ProcessEvent::StreamEnded {
            bundle_id: bundle_id.clone(),
            pid,
        },
        ProcessEvent::Terminated {
            bundle_id: bundle_id.clone(),
            pid,
        },
    ];

    // All events should be distinct
    for i in 0..events.len() {
        for j in (i + 1)..events.len() {
            assert_ne!(events[i], events[j], "Events at {i} and {j} should differ");
        }
    }
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

/// Test interface monitor creation and configuration.
#[test]
fn test_interface_monitor_creation() {
    use geforcenow_awdl0::interface_monitor::{InterfaceEventCallback, InterfaceStateMonitor};

    let callback: InterfaceEventCallback = Arc::new(|_| {});
    let monitor = InterfaceStateMonitor::new("awdl0", callback);

    // Monitor created but not started
    let _ = monitor;
}

/// Test interface event handling.
#[test]
fn test_interface_event_callback() {
    use geforcenow_awdl0::interface_monitor::{InterfaceEvent, InterfaceEventCallback};

    let received_events = Arc::new(std::sync::Mutex::new(Vec::new()));
    let received_events_clone = Arc::clone(&received_events);

    let callback: InterfaceEventCallback = Arc::new(move |event| {
        received_events_clone.lock().unwrap().push(event);
    });

    // Manually invoke the callback
    callback(InterfaceEvent::StateChanged {
        interface: "awdl0".to_string(),
    });

    let events = received_events.lock().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0],
        InterfaceEvent::StateChanged {
            interface: "awdl0".to_string()
        }
    );
}

/// Test window monitor for non-existent process.
#[test]
fn test_window_monitor_no_fullscreen() {
    use geforcenow_awdl0::window_monitor::has_fullscreen_window;

    // A non-existent PID should return false
    let result = has_fullscreen_window(999_999_999);
    assert!(!result);
}

/// Test window monitor for current process (tests shouldn't be fullscreen).
#[test]
fn test_window_monitor_current_process() {
    use geforcenow_awdl0::window_monitor::has_fullscreen_window;

    // The test process itself shouldn't have a fullscreen window
    let pid = std::process::id() as i32;
    let result = has_fullscreen_window(pid);
    assert!(!result);
}

/// Test that multiple monitors can coexist.
#[test]
fn test_multiple_monitors() {
    use geforcenow_awdl0::interface_monitor::{InterfaceEventCallback, InterfaceStateMonitor};
    use geforcenow_awdl0::process_monitor::{EventCallback, MonitorConfig, ProcessMonitor};

    let process_callback: EventCallback = Arc::new(|_| {});
    let interface_callback: InterfaceEventCallback = Arc::new(|_| {});

    let config = MonitorConfig::default();
    let _process_monitor = ProcessMonitor::new(config, process_callback);
    let _interface_monitor = InterfaceStateMonitor::new("awdl0", interface_callback);

    // Both monitors created successfully
}

/// Test event collection across multiple invocations.
#[test]
fn test_event_collection() {
    use geforcenow_awdl0::process_monitor::{EventCallback, ProcessEvent};

    let events = Arc::new(std::sync::Mutex::new(Vec::new()));
    let events_clone = Arc::clone(&events);

    let callback: EventCallback = Arc::new(move |event| {
        events_clone.lock().unwrap().push(event);
    });

    // Simulate a full lifecycle
    callback(ProcessEvent::Launched {
        bundle_id: "com.test.app".to_string(),
        pid: 100,
    });
    callback(ProcessEvent::StreamStarted {
        bundle_id: "com.test.app".to_string(),
        pid: 100,
    });
    callback(ProcessEvent::StreamEnded {
        bundle_id: "com.test.app".to_string(),
        pid: 100,
    });
    callback(ProcessEvent::Terminated {
        bundle_id: "com.test.app".to_string(),
        pid: 100,
    });

    let collected = events.lock().unwrap();
    assert_eq!(collected.len(), 4);

    // Verify order
    assert!(matches!(collected[0], ProcessEvent::Launched { .. }));
    assert!(matches!(collected[1], ProcessEvent::StreamStarted { .. }));
    assert!(matches!(collected[2], ProcessEvent::StreamEnded { .. }));
    assert!(matches!(collected[3], ProcessEvent::Terminated { .. }));
}

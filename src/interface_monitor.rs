//! Network interface state monitoring using macOS `SCDynamicStore`.
//!
//! This module provides event-driven monitoring for network interface state
//! changes on macOS, specifically designed to detect when `awdl0` comes back up.

use std::sync::Arc;

// Use re-exported core-foundation types from system-configuration to avoid version conflicts
use system_configuration::core_foundation::array::CFArray;
use system_configuration::core_foundation::runloop::{CFRunLoop, kCFRunLoopCommonModes};
use system_configuration::core_foundation::string::CFString;
use system_configuration::dynamic_store::{
    SCDynamicStore, SCDynamicStoreBuilder, SCDynamicStoreCallBackContext,
};
use thiserror::Error;
use tracing::{debug, info, trace, warn};

/// Errors that can occur during interface monitoring.
#[derive(Debug, Error)]
pub enum InterfaceMonitorError {
    #[error("failed to create dynamic store")]
    StoreCreation,

    #[error("failed to set notification keys")]
    SetNotificationKeys,

    #[error("failed to create run loop source")]
    RunLoopSource,
}

/// Result type for interface monitor operations.
pub type Result<T> = std::result::Result<T, InterfaceMonitorError>;

/// Events emitted by the interface monitor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InterfaceEvent {
    /// The interface state changed (it may have come up or gone down).
    StateChanged { interface: String },
}

/// Callback type for interface events.
pub type InterfaceEventCallback = Arc<dyn Fn(InterfaceEvent) + Send + Sync>;

/// Context passed to the `SCDynamicStore` callback function.
struct CallbackContext {
    interface: String,
    callback: InterfaceEventCallback,
}

/// The callback function for `SCDynamicStore` notifications.
/// This must be a plain function (not a closure) because `SCDynamicStore` requires a function pointer.
#[allow(clippy::needless_pass_by_value)] // Signature is dictated by system-configuration crate
fn dynamic_store_callback(
    _store: SCDynamicStore,
    changed_keys: CFArray<CFString>,
    context: &mut CallbackContext,
) {
    trace!(
        count = changed_keys.len(),
        "dynamic store callback triggered"
    );

    for key in changed_keys.iter() {
        let key_string = key.to_string();

        debug!(key = %key_string, "interface state changed");

        // Check if this is for our interface
        if key_string.contains(&context.interface) {
            info!(
                interface = %context.interface,
                key = %key_string,
                "detected interface state change"
            );

            (context.callback)(InterfaceEvent::StateChanged {
                interface: context.interface.clone(),
            });
        }
    }
}

/// Interface state monitor that watches for network interface changes.
///
/// Uses `SCDynamicStore` for event-driven monitoring (no polling).
pub struct InterfaceStateMonitor {
    interface: String,
    callback: InterfaceEventCallback,
    /// Stored dynamic store to keep it alive.
    store: Option<SCDynamicStore>,
}

impl InterfaceStateMonitor {
    /// Create a new interface state monitor.
    ///
    /// # Arguments
    /// * `interface` - The interface name to monitor (e.g., "awdl0").
    /// * `callback` - Callback function invoked when the interface state changes.
    pub fn new(interface: &str, callback: InterfaceEventCallback) -> Self {
        Self {
            interface: interface.to_string(),
            callback,
            store: None,
        }
    }

    /// Start the interface state monitor.
    ///
    /// This registers for `SCDynamicStore` notifications on the interface's
    /// link state key and integrates with the current run loop.
    ///
    /// # Errors
    /// Returns an error if the dynamic store cannot be created or configured.
    pub fn start(&mut self) -> Result<()> {
        info!(
            interface = %self.interface,
            "starting interface state monitor"
        );

        // Create the callback context with interface name and callback
        let context = CallbackContext {
            interface: self.interface.clone(),
            callback: Arc::clone(&self.callback),
        };

        // Create the dynamic store with a callback context
        let callback_context = SCDynamicStoreCallBackContext {
            callout: dynamic_store_callback,
            info: context,
        };
        let store = SCDynamicStoreBuilder::new("geforcenow-awdl0-interface-monitor")
            .callback_context(callback_context)
            .build()
            .ok_or(InterfaceMonitorError::StoreCreation)?;

        // Create the key pattern to watch for interface link state changes
        // Key format: State:/Network/Interface/<interface>/Link
        let link_key = format!("State:/Network/Interface/{}/Link", self.interface);
        let link_key_cf = CFString::new(&link_key);

        debug!(key = %link_key, "watching dynamic store key");

        // Set the notification keys
        // We watch for specific keys (not patterns) for the Link state
        let keys = CFArray::from_CFTypes(&[link_key_cf]);
        let patterns: CFArray<CFString> = CFArray::from_CFTypes(&[]);
        if !store.set_notification_keys(&keys, &patterns) {
            warn!("failed to set notification keys");
            return Err(InterfaceMonitorError::SetNotificationKeys);
        }

        // Create a run loop source and add it to the current run loop
        let run_loop_source = store
            .create_run_loop_source()
            .ok_or(InterfaceMonitorError::RunLoopSource)?;

        // Add to the main run loop
        let run_loop = CFRunLoop::get_current();
        run_loop.add_source(&run_loop_source, unsafe { kCFRunLoopCommonModes });

        info!(
            interface = %self.interface,
            "interface state monitor started"
        );

        // Store the dynamic store to keep it alive
        self.store = Some(store);

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    #[test]
    fn test_interface_event_equality() {
        let event1 = InterfaceEvent::StateChanged {
            interface: "awdl0".to_string(),
        };
        let event2 = InterfaceEvent::StateChanged {
            interface: "awdl0".to_string(),
        };
        let event3 = InterfaceEvent::StateChanged {
            interface: "en0".to_string(),
        };

        assert_eq!(event1, event2);
        assert_ne!(event1, event3);
    }

    #[test]
    fn test_interface_event_debug_format() {
        let event = InterfaceEvent::StateChanged {
            interface: "awdl0".to_string(),
        };
        let debug_str = format!("{event:?}");
        assert!(debug_str.contains("StateChanged"));
        assert!(debug_str.contains("awdl0"));
    }

    #[test]
    fn test_interface_event_clone() {
        let event = InterfaceEvent::StateChanged {
            interface: "awdl0".to_string(),
        };
        let cloned = event.clone();
        assert_eq!(event, cloned);
    }

    #[test]
    fn test_monitor_creation() {
        let callback: InterfaceEventCallback = Arc::new(|_| {});
        let monitor = InterfaceStateMonitor::new("awdl0", callback);

        assert_eq!(monitor.interface, "awdl0");
        assert!(monitor.store.is_none()); // Not started yet
    }

    #[test]
    fn test_monitor_stores_interface_name() {
        let callback: InterfaceEventCallback = Arc::new(|_| {});
        let monitor = InterfaceStateMonitor::new("en0", callback);

        assert_eq!(monitor.interface, "en0");
    }

    #[test]
    fn test_callback_can_be_invoked() {
        let call_count = Arc::new(AtomicU32::new(0));
        let call_count_clone = Arc::clone(&call_count);

        let callback: InterfaceEventCallback = Arc::new(move |_event| {
            call_count_clone.fetch_add(1, Ordering::SeqCst);
        });

        // Invoke the callback directly
        callback(InterfaceEvent::StateChanged {
            interface: "awdl0".to_string(),
        });

        assert_eq!(call_count.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn test_monitor_error_display_store_creation() {
        let error = InterfaceMonitorError::StoreCreation;
        assert_eq!(error.to_string(), "failed to create dynamic store");
    }

    #[test]
    fn test_monitor_error_display_notification_keys() {
        let error = InterfaceMonitorError::SetNotificationKeys;
        assert_eq!(error.to_string(), "failed to set notification keys");
    }

    #[test]
    fn test_monitor_error_display_run_loop_source() {
        let error = InterfaceMonitorError::RunLoopSource;
        assert_eq!(error.to_string(), "failed to create run loop source");
    }
}

//! Network interface state monitoring using macOS `SCDynamicStore`.
//!
//! This module provides event-driven monitoring for network interface state
//! changes on macOS, specifically designed to detect when `awdl0` comes back up.

use std::sync::Arc;

use core_foundation::array::CFArray;
use core_foundation::base::TCFType;
use core_foundation::runloop::{kCFRunLoopCommonModes, CFRunLoop};
use core_foundation::string::CFString;
use system_configuration::dynamic_store::{SCDynamicStore, SCDynamicStoreBuilder};
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

/// Interface state monitor that watches for network interface changes.
///
/// Uses `SCDynamicStore` for event-driven monitoring (no polling).
pub struct InterfaceStateMonitor {
    interface: String,
    callback: InterfaceEventCallback,
    /// Stored dynamic store to keep it alive.
    _store: Option<SCDynamicStore>,
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
            _store: None,
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

        let interface_name = self.interface.clone();
        let callback = Arc::clone(&self.callback);

        // Create the callback closure for SCDynamicStore
        let store_callback = move |_store: SCDynamicStore, changed_keys: CFArray<CFString>| {
            trace!(
                count = changed_keys.len(),
                "dynamic store callback triggered"
            );

            for key in changed_keys.iter() {
                let key_string = key.to_string();

                debug!(key = %key_string, "interface state changed");

                // Check if this is for our interface
                if key_string.contains(&interface_name) {
                    info!(
                        interface = %interface_name,
                        key = %key_string,
                        "detected interface state change"
                    );

                    callback(InterfaceEvent::StateChanged {
                        interface: interface_name.clone(),
                    });
                }
            }
        };

        // Create the dynamic store with a callback
        let store = SCDynamicStoreBuilder::new("geforcenow-awdl0-interface-monitor")
            .callback_context(store_callback)
            .build();

        // Create the key pattern to watch for interface link state changes
        // Key format: State:/Network/Interface/<interface>/Link
        let link_key = format!("State:/Network/Interface/{}/Link", self.interface);
        let link_key_cf = CFString::new(&link_key);

        debug!(key = %link_key, "watching dynamic store key");

        // Set the notification keys
        // We watch for specific keys (not patterns) for the Link state
        if !store.set_notification_keys(&[link_key_cf.clone()], &[]) {
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
        self._store = Some(store);

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}

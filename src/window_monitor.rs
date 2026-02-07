//! Window monitoring using macOS `CoreGraphics` APIs.
//!
//! This module provides functionality to query window state for specific processes,
//! including detecting fullscreen windows.

// Use re-exported core-foundation types from system-configuration to avoid version conflicts
use core_graphics::display::{
    CGDisplay, CGWindowListCopyWindowInfo, kCGNullWindowID, kCGWindowListExcludeDesktopElements,
    kCGWindowListOptionOnScreenOnly,
};
use core_graphics::window::{kCGWindowBounds, kCGWindowOwnerPID};
use system_configuration::core_foundation::array::CFArray;
use system_configuration::core_foundation::base::{CFType, TCFType};
use system_configuration::core_foundation::dictionary::CFDictionary;
use system_configuration::core_foundation::number::CFNumber;
use system_configuration::core_foundation::string::CFString;
use tracing::{debug, trace};

/// Check if a process has any fullscreen windows.
///
/// A window is considered fullscreen if its bounds match the main display bounds exactly.
///
/// # Arguments
/// * `pid` - The process ID to check for fullscreen windows.
///
/// # Returns
/// `true` if the process has at least one fullscreen window, `false` otherwise.
#[must_use]
pub fn has_fullscreen_window(pid: i32) -> bool {
    // Get main display bounds
    let main_display = CGDisplay::main();
    let display_bounds = main_display.bounds();

    let display_width = display_bounds.size.width;
    let display_height = display_bounds.size.height;

    trace!(
        display_width = display_width,
        display_height = display_height,
        "checking for fullscreen windows"
    );

    // Get all on-screen windows
    let options = kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements;
    let window_list_ptr = unsafe { CGWindowListCopyWindowInfo(options, kCGNullWindowID) };

    if window_list_ptr.is_null() {
        debug!("failed to get window list");
        return false;
    }

    // SAFETY: We just checked the pointer is not null
    let window_list: CFArray<CFDictionary<CFString, CFType>> =
        unsafe { CFArray::wrap_under_create_rule(window_list_ptr) };

    for window_info in window_list.iter() {
        // Get the window's owner PID
        let pid_key = unsafe { CFString::wrap_under_get_rule(kCGWindowOwnerPID) };
        let window_pid = match window_info.find(&pid_key) {
            Some(pid_ref) => {
                // SAFETY: kCGWindowOwnerPID values are always CFNumbers
                let pid_number: CFNumber =
                    unsafe { CFNumber::wrap_under_get_rule(pid_ref.as_concrete_TypeRef().cast()) };
                pid_number.to_i32().unwrap_or(0)
            }
            None => continue,
        };

        // Skip windows not owned by our target process
        if window_pid != pid {
            continue;
        }

        // Get the window bounds
        let bounds_key = unsafe { CFString::wrap_under_get_rule(kCGWindowBounds) };
        let bounds = match window_info.find(&bounds_key) {
            Some(bounds_ref) => {
                // SAFETY: kCGWindowBounds values are always CFDictionaries
                let bounds_dict: CFDictionary<CFString, CFNumber> = unsafe {
                    CFDictionary::wrap_under_get_rule(bounds_ref.as_concrete_TypeRef().cast())
                };

                let width = get_dict_number(&bounds_dict, "Width").unwrap_or(0.0);
                let height = get_dict_number(&bounds_dict, "Height").unwrap_or(0.0);
                let x = get_dict_number(&bounds_dict, "X").unwrap_or(0.0);
                let y = get_dict_number(&bounds_dict, "Y").unwrap_or(0.0);

                (x, y, width, height)
            }
            None => continue,
        };

        let (x, y, width, height) = bounds;

        trace!(
            pid = window_pid,
            x = x,
            y = y,
            width = width,
            height = height,
            "found window for target process"
        );

        // Check if the window is fullscreen (matches display bounds exactly)
        // We use approximate comparison to handle floating point differences
        let is_fullscreen = (width - display_width).abs() < 1.0
            && (height - display_height).abs() < 1.0
            && x.abs() < 1.0
            && y.abs() < 1.0;

        if is_fullscreen {
            debug!(
                pid = pid,
                width = width,
                height = height,
                "found fullscreen window"
            );
            return true;
        }
    }

    false
}

/// Get a number value from a CFDictionary by string key.
fn get_dict_number(dict: &CFDictionary<CFString, CFNumber>, key: &str) -> Option<f64> {
    let cf_key = CFString::new(key);
    dict.find(&cf_key).and_then(|v| v.to_f64())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_has_fullscreen_window_invalid_pid() {
        // A PID of -1 should never have any windows
        let result = has_fullscreen_window(-1);
        assert!(!result);
    }

    #[test]
    fn test_has_fullscreen_window_nonexistent_pid() {
        // A very high PID that shouldn't exist
        let result = has_fullscreen_window(999_999_999);
        assert!(!result);
    }
}

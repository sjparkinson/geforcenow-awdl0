//! geforcenow-awdl0 library.
//!
//! This crate provides functionality to monitor for application launches on macOS
//! and control network interfaces in response.

#![cfg(target_os = "macos")]

pub mod cli;
pub mod interface;
pub mod interface_monitor;
pub mod monitor;

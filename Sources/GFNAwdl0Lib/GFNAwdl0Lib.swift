// GFNAwdl0Lib - Library for controlling awdl0 during GeForce NOW streaming
//
// This library provides:
// - ProcessMonitor: Watches for GeForce NOW launch/terminate
// - WindowMonitor: Detects fullscreen streaming windows
// - InterfaceController: Brings awdl0 up/down
// - InterfaceMonitor: Watches for awdl0 state changes
// - Daemon: Orchestrates all components
// - Installer: Handles daemon installation/uninstallation

import Darwin
@_exported import struct Foundation.Date
@_exported import class Foundation.RunLoop

public typealias PID = pid_t

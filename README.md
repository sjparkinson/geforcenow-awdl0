# geforcenow-awdl0

Prevent Apple Wireless Direct Link (awdl0) from becoming active while GeForce NOW is running on macOS.

## The Problem

On macOS, the `awdl0` interface (Apple Wireless Direct Link) is used for AirDrop, AirPlay, and other peer-to-peer wireless features. When active, it can cause latency spikes and network instability that interfere with cloud gaming services like GeForce NOW.

## The Solution

This daemon monitors for the GeForce NOW application and automatically:
- **Brings down `awdl0`** when GeForce NOW launches
- **Allows `awdl0` back up** when GeForce NOW terminates

It uses event-driven macOS APIs (NSWorkspace notifications) rather than polling, resulting in zero CPU overhead when idle.

## Requirements

- macOS 14.0 (Sonoma) or later
- Root privileges (for network interface control)

## Installation

### From Binary Release

1. Download the latest binary from the [Releases](https://github.com/sjparkinson/awdl0/releases) page
2. Run the installer:

```bash
sudo ./geforcenow-awdl0 install
```

### From Source

```bash
# Clone the repository
git clone https://github.com/sjparkinson/awdl0.git
cd awdl0

# Build the release binary
cargo build --release

# Install the daemon
sudo ./target/release/geforcenow-awdl0 install
```

## Usage

### Commands

```bash
# Install and start the daemon (requires root)
sudo geforcenow-awdl0 install

# Check daemon status
sudo geforcenow-awdl0 status

# Uninstall the daemon (requires root)
sudo geforcenow-awdl0 uninstall

# Run the daemon manually (for debugging)
sudo geforcenow-awdl0 run --verbose
```

### Verifying It's Working

```bash
# Check daemon status
sudo geforcenow-awdl0 status

# View logs
tail -f /var/log/geforcenow-awdl0/stdout.log

# Check awdl0 interface status
ifconfig awdl0
```

## How It Works

1. The daemon subscribes to `NSWorkspaceDidLaunchApplicationNotification` and `NSWorkspaceDidTerminateApplicationNotification`
2. When GeForce NOW (`com.nvidia.gfnpc.mall`) launches, it brings down `awdl0` using `ioctl` syscalls
3. When GeForce NOW terminates, it allows `awdl0` to return to its normal state
4. The daemon periodically verifies `awdl0` stays down while gaming (macOS may try to re-enable it)

## Configuration

### Custom Application

To monitor a different application, use the `--bundle-id` flag:

```bash
sudo geforcenow-awdl0 run --bundle-id "com.example.app"
```

### Logging

Set the `RUST_LOG` environment variable to control log verbosity:

```bash
RUST_LOG=debug sudo geforcenow-awdl0 run
```

## Files

| Path | Description |
|------|-------------|
| `/usr/local/bin/geforcenow-awdl0` | The daemon binary |
| `/Library/LaunchDaemons/com.geforcenow.awdl0.plist` | launchd configuration |
| `/var/log/geforcenow-awdl0/stdout.log` | Standard output log |
| `/var/log/geforcenow-awdl0/stderr.log` | Standard error log |

## Troubleshooting

### Daemon Won't Start

Check if it's loaded:
```bash
sudo launchctl list | grep geforcenow
```

Try manually loading:
```bash
sudo launchctl load -w /Library/LaunchDaemons/com.geforcenow.awdl0.plist
```

### awdl0 Keeps Coming Back Up

This is normal - macOS aggressively re-enables awdl0. The daemon monitors for this and brings it back down while GeForce NOW is running.

### Permission Denied

The daemon must run as root to control network interfaces. Ensure you're using `sudo` for installation and the daemon is configured as a LaunchDaemon (not LaunchAgent).

## Uninstallation

```bash
sudo geforcenow-awdl0 uninstall
```

This will:
1. Stop and unload the daemon
2. Remove the LaunchDaemon plist
3. Remove the binary from `/usr/local/bin`

Log files in `/var/log/geforcenow-awdl0/` are preserved.

## Building

### Prerequisites

- Rust 1.77 or later
- macOS 14.0 or later (for building and running)

### Development

```bash
# Check code
cargo check

# Run tests
cargo test

# Run clippy
cargo clippy

# Format code
cargo fmt
```

### Release Build

```bash
cargo build --release
```

The binary will be at `target/release/geforcenow-awdl0`.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the community workarounds for GeForce NOW latency issues on macOS
- Built with [objc2](https://github.com/madsmtm/objc2) for safe Rust-Objective-C interop

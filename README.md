# geforcenow-awdl0

Prevent Apple Wireless Direct Link (awdl0) from becoming active while GeForce NOW is running on macOS.

## The Problem

On macOS, the `awdl0` interface (Apple Wireless Direct Link) is used for AirDrop, AirPlay, and other peer-to-peer wireless features. When active, it can cause latency when swapping channels that interferes with cloud gaming services like GeForce NOW.

## The Solution

This daemon monitors for the GeForce NOW application and automatically:

- **Brings down `awdl0`** when streaming starts (fullscreen detected)
- **Allows `awdl0` back up** when streaming ends or GeForce NOW terminates
- **Re-downs `awdl0`** if macOS re-enables it during streaming

## Requirements

- macOS
- Swift

## Installation

```bash
# Clone the repository
git clone https://github.com/sjparkinson/geforcenow-awdl0.git
cd geforcenow-awdl0

# Build the release binary
swift build -c release

# Install (per-user LaunchAgent)
# The installer copies the binary to `~/bin/geforcenow-awdl0`, writes a LaunchAgent
# to `~/Library/LaunchAgents/` and logs to `~/Library/Logs/geforcenow-awdl0`.
.build/release/geforcenow-awdl0 install
```

## Usage

### Commands

```bash
# Install and start the daemon
.build/release/geforcenow-awdl0 install

# Check daemon status
.build/release/geforcenow-awdl0 status

# Uninstall the daemon
.build/release/geforcenow-awdl0 uninstall

# Run the daemon manually (for debugging)
.build/release/geforcenow-awdl0 run --verbose
```

### Verifying It's Working

```bash
# Check daemon status
.build/release/geforcenow-awdl0 status

# View logs
tail -f ~/Library/Logs/geforcenow-awdl0/stderr.log

# Check awdl0 interface status
ifconfig awdl0
```

## How It Works

1. **Process monitoring**: Subscribes to `NSWorkspace.didLaunchApplicationNotification` and `didTerminateApplicationNotification` to detect when GeForce NOW (`com.nvidia.gfnpc.mall`) starts and stops.

2. **Fullscreen detection**: When GeForce NOW is running, polls every 5 seconds using `CGWindowListCopyWindowInfo` to detect fullscreen windows (indicating an active game stream).

3. **Interface control**: When streaming starts (fullscreen detected), brings down `awdl0` using `ioctl` syscalls. When streaming ends, allows `awdl0` back up.

4. **Interface monitoring**: Uses `SCDynamicStore` to watch for `awdl0` state changes—if macOS re-enables `awdl0` during a stream, the daemon brings it back down.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the community workarounds for GeForce NOW latency issues on macOS
- Built with Swift using Apple's native frameworks: AppKit, CoreGraphics, SystemConfiguration


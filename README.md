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

# Build using the provided Makefile (release build)
make build

# Install the LaunchAgent and binary
make install
```

The repository Makefile exposes the following targets:

- `make build`: Build the release binary at `.build/release/geforcenow-awdl0`.
- `make install`: Install the LaunchAgent and binary. This copies the
	binary to `~/bin/geforcenow-awdl0`, writes the LaunchAgent to
	`~/Library/LaunchAgents/io.github.sjparkinson.geforcenow-awdl0.plist` (using `~/` paths),
	and creates logs at `~/Library/Logs/geforcenow-awdl0`.
- `make uninstall`: Uninstall the LaunchAgent and remove the installed binary.
- `make run`: Run the compiled binary directly for debugging.

Logs are written to `~/Library/Logs/geforcenow-awdl0` (stdout and stderr files).

## Usage

Use the Makefile targets or the compiled binary to manage the daemon.

```bash
# Install and start the daemon
make install

# Run the daemon manually for debugging
make run

# Uninstall the daemon
make uninstall
```

### Verifying It's Working

```bash
# Tail logs
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


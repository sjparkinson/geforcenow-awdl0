# geforcenow-awdl0

Prevent Apple Wireless Direct Link (awdl0) from becoming active while GeForce NOW is running on macOS.

## The Problem

On macOS, the `awdl0` interface (Apple Wireless Direct Link) is used for AirDrop, AirPlay, and other peer-to-peer wireless features. When active, it can cause latency when swapping channels that interferes with cloud gaming services like GeForce NOW.

## The Solution

This daemon monitors for the GeForce NOW application and automatically:

- **Brings down `awdl0`** when GeForce NOW launches
- **Allows `awdl0` back up** when GeForce NOW terminates

## Installation

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
sudo ./target/release/geforcenow-awdl0 install

# Check daemon status
sudo ./target/release/geforcenow-awdl0 status

# Uninstall the daemon (requires root)
sudo ./target/release/geforcenow-awdl0 uninstall

# Run the daemon manually (for debugging)
sudo ./target/release/geforcenow-awdl0 run --verbose
```

### Verifying It's Working

```bash
# Check daemon status
sudo ./target/release/geforcenow-awdl0 status

# View logs
tail -f /var/log/geforcenow-awdl0/stdout.log

# Check awdl0 interface status
ifconfig awdl0
```

## How It Works

1. **Process monitoring**: Subscribes to `NSWorkspaceDidLaunchApplicationNotification` and `NSWorkspaceDidTerminateApplicationNotification` to detect when GeForce NOW (`com.nvidia.gfnpc.mall`) starts and stops.

2. **Fullscreen detection**: When GeForce NOW is running, polls every 5 seconds using `CGWindowListCopyWindowInfo` to detect fullscreen windows (indicating an active game stream).

3. **Interface control**: When streaming starts (fullscreen detected), brings down `awdl0` using `ioctl` syscalls. When streaming ends, allows `awdl0` back up.

4. **Interface monitoring**: Uses `SCDynamicStore` to watch for `awdl0` state changes—if macOS re-enables `awdl0` during a stream, the daemon brings it back down.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the community workarounds for GeForce NOW latency issues on macOS
- Built with [objc2](https://github.com/madsmtm/objc2) for safe Rust-Objective-C interop

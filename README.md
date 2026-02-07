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

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the community workarounds for GeForce NOW latency issues on macOS
- Built with [objc2](https://github.com/madsmtm/objc2) for safe Rust-Objective-C interop

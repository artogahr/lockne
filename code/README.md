# Lockne

**Dynamic Per-Application VPN Tunneling with eBPF and Rust**

Lockne is a system for routing network traffic on a per-application basis using eBPF and WireGuard. It can identify which process is sending each packet and route specific applications through VPN tunnels while leaving others on the direct connection.

## Current Status

✅ **Working**: Process-to-packet mapping via socket cookies  
✅ **Working**: Packet redirection via `--redirect-to` flag  
✅ **Working**: IPv4 and IPv6 support

## Quick Start

### Prerequisites

1. Rust toolchains:
   - `rustup toolchain install stable`
   - `rustup toolchain install nightly --component rust-src`
2. BPF linker: `cargo install bpf-linker`
3. Linux kernel 5.8+ with eBPF support
4. Root access (required for loading eBPF programs)

### Build

```bash
cd code
cargo build --release
```

### Run

**Launch a program and track its traffic (recommended):**
```bash
# Run curl and track its packets
sudo lockne run curl http://example.com

# Run firefox and track all its traffic
sudo lockne run firefox

# With TUI mode for live stats
sudo lockne run firefox --tui

# Redirect traffic through a specific interface (e.g., WireGuard)
sudo lockne run --redirect-to wg0 curl http://example.com
```

**Monitor all system traffic:**
```bash
# Monitor everything
sudo lockne monitor --iface eno1

# With packet limit (useful for testing)
sudo lockne monitor --iface eno1 --limit 10

# With TUI
sudo lockne monitor --iface eno1 --tui
```

### Verify It Works

```bash
# Run the verification script
sudo ./verify_tracking.sh

# Or test the launcher directly
sudo RUST_LOG=info ./target/release/lockne run curl -s http://example.com
# You should see "Tracked socket cookie=... for pid=..." messages
```

## Project Structure

```
code/
├── lockne/              # Userspace control plane
│   ├── src/
│   │   ├── main.rs      # Entry point
│   │   ├── loader.rs    # eBPF loading
│   │   ├── config.rs    # CLI configuration
│   │   └── logger.rs    # Logging
├── lockne-ebpf/         # Kernel-side eBPF programs  
│   └── src/main.rs      # TC classifier + cgroup tracker
└── lockne-common/       # Shared types
```

See the thesis documentation for detailed architecture information.

## Development

```bash
# Build and run
cargo build
sudo -E ./target/debug/lockne --iface eno1

# Run tests
cargo test
sudo -E cargo test --test integration_test -- --ignored

# Format code
cargo fmt

# Check for issues  
cargo clippy
```

## How It Works

1. **Cgroup programs** (connect4/connect6) capture socket creation events, storing PID → socket cookie mappings
2. **TC classifier** intercepts outgoing packets, looks up their PID using the socket cookie
3. **Policy map** determines if traffic from a specific PID should be redirected
4. **bpf_redirect()** sends matching packets to the target interface (e.g., WireGuard tunnel)
5. **Userspace loader** manages eBPF programs and provides CLI interface

## Features

- ✅ Process tracking via socket cookies
- ✅ eBPF-based packet interception  
- ✅ Low overhead (<1% CPU, ~60ns per packet)
- ✅ IPv4 and IPv6 support
- ✅ Process launcher mode (`lockne run <program>`)
- ✅ TUI interface with live statistics
- ✅ Packet redirection (`--redirect-to <interface>`)
- ✅ Policy-based routing per PID
- ⏳ Process hierarchy tracking (planned)
- ⏳ Automatic socket cleanup (planned)

## Use Cases

- Route web browser through VPN while keeping games on direct connection
- Isolate specific applications for security testing
- Per-application network monitoring
- Dynamic traffic routing based on process

Cargo build scripts automatically build the eBPF code and embed it in the binary.

## Cross-compiling on macOS

Cross compilation should work on both Intel and Apple Silicon Macs.

```shell
CC=${ARCH}-linux-musl-gcc cargo build --package lockne --release \
  --target=${ARCH}-unknown-linux-musl \
  --config=target.${ARCH}-unknown-linux-musl.linker=\"${ARCH}-linux-musl-gcc\"
```
The cross-compiled program `target/${ARCH}-unknown-linux-musl/release/lockne` can be
copied to a Linux server or VM and run there.

## License

With the exception of eBPF code, lockne is distributed under the terms
of either the [MIT license] or the [Apache License] (version 2.0), at your
option.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this crate by you, as defined in the Apache-2.0 license, shall
be dual licensed as above, without any additional terms or conditions.

### eBPF

All eBPF code is distributed under either the terms of the
[GNU General Public License, Version 2] or the [MIT license], at your
option.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this project by you, as defined in the GPL-2 license, shall be
dual licensed as above, without any additional terms or conditions.

[Apache license]: LICENSE-APACHE
[MIT license]: LICENSE-MIT
[GNU General Public License, Version 2]: LICENSE-GPL2

# Lockne Development Guide

This guide explains the project structure and how to continue development.

## Project Structure

```
lockne/
├── lockne/                 # Userspace control plane (Rust binary)
│   ├── src/
│   │   ├── main.rs        # Entry point - just wires everything together
│   │   ├── lib.rs         # Library exports
│   │   ├── config.rs      # CLI configuration
│   │   ├── loader.rs      # eBPF program loading logic
│   │   └── logger.rs      # eBPF logging infrastructure
│   └── tests/             # Integration tests
├── lockne-ebpf/           # Kernel-side eBPF programs
│   └── src/
│       └── main.rs        # TC classifier + cgroup tracker
└── lockne-common/         # Shared types between kernel and userspace
    └── src/
        └── lib.rs         # Common type definitions
```

## Architecture Overview

### The Three Crates

**1. lockne-ebpf** (Kernel Space)
- Contains eBPF programs that run inside the Linux kernel
- Written in `no_std` Rust (no standard library)
- Two programs:
  - `lockne` - TC egress classifier (intercepts packets)
  - `lockne_connect4` - cgroup socket tracker (captures PIDs)

**2. lockne** (Userspace)
- The control plane that loads and manages eBPF programs
- Can also be used as a library (`lib.rs`)
- Modules:
  - `config.rs` - Command-line parsing
  - `loader.rs` - eBPF program loading and attachment
  - `logger.rs` - Logging from eBPF to userspace
  - `main.rs` - Wires everything together

**3. lockne-common** (Shared)
- Types that need to be identical in both kernel and userspace
- Currently just `Pid = u32`
- Will grow to include policy structures, statistics, etc.

### Data Flow

```
User runs lockne → main.rs parses config → LockneLoader loads eBPF
                                         ↓
                           TC program attaches to network interface
                           Cgroup program attaches to /sys/fs/cgroup
                                         ↓
Process makes connection → cgroup program captures PID + socket cookie
                                         ↓
                           Stores in SOCKET_PID_MAP (eBPF hash map)
                                         ↓
Packet sent → TC program intercepts → looks up PID in map → logs it
```

## How to Add Features

### Adding a New CLI Option

1. Edit `code/lockne/src/config.rs`
2. Add your field to the `Config` struct with `#[clap(...)]` attributes
3. Use it in `main.rs` by accessing `config.your_field`

Example:
```rust
// In config.rs
#[clap(long)]
pub verbose: bool,

// In main.rs
if config.verbose {
    // do something
}
```

### Adding a New eBPF Map

1. Define the type in `lockne-common/src/lib.rs` if shared
2. Add the map in `lockne-ebpf/src/main.rs`:
```rust
#[map]
static MY_MAP: HashMap<KeyType, ValueType> = 
    HashMap::with_max_entries(1024, 0);
```
3. Access it in your eBPF programs with `unsafe { MY_MAP.get(&key) }`
4. Access it from userspace via `loader.ebpf_mut().map("MY_MAP")`

### Adding a New eBPF Program

1. Write the program in `lockne-ebpf/src/main.rs`:
```rust
#[classifier]  // or #[cgroup_sock_addr(connect4)], etc.
pub fn my_program(ctx: TcContext) -> i32 {
    // your code
}
```

2. Add a loader method in `lockne/src/loader.rs`:
```rust
pub fn attach_my_program(&mut self) -> Result<()> {
    let program: &mut ProgramType = self
        .ebpf
        .program_mut("my_program")
        .ok_or_else(|| anyhow::anyhow!("Program not found"))?
        .try_into()?;
    
    program.load()?;
    program.attach(/* attachment point */)?;
    Ok(())
}
```

3. Call it from `main.rs`:
```rust
loader.attach_my_program()?;
```

## Common Development Tasks

### Building
```bash
cd code
cargo build                 # Debug build
cargo build --release       # Release build
```

### Running
```bash
# Must run as root for eBPF
sudo -E RUST_LOG=info ./target/release/lockne --iface eno1
```

### Testing
```bash
cargo test                  # Unit tests
sudo -E cargo test --test integration_test test_ebpf_loading -- --ignored  # Integration tests
./verify_tracking.sh        # Manual verification
```

### Debugging

**eBPF programs:**
- Use `info!(&ctx, "message {}", value)` for logging
- Check `dmesg` for kernel errors
- Use `bpftool prog list` to see loaded programs
- Use `bpftool map dump name SOCKET_PID_MAP` to inspect maps

**Userspace:**
- Use `RUST_LOG=debug` for detailed logs
- Use `cargo build` (not `--release`) for better error messages
- Check for panics with `RUST_BACKTRACE=1`

## Code Style Guidelines

- **Keep it simple** - Don't use overly complex language or abstractions
- **Document with comments** - Explain the "why", not just the "what"
- **Small commits** - One logical change per commit
- **Test before committing** - At least run `cargo build` and `cargo test`
- **Update docs** - If you add a feature, document it

## Next Steps to Implement

See ROADMAP.md for a prioritized list of features to add next.

## Getting Help

- eBPF: https://ebpf.io/
- Aya docs: https://aya-rs.dev/
- Rust: https://doc.rust-lang.org/
- Ask questions in commit messages so future you remembers what you were thinking!
# Getting Started with Lockne Development

Welcome! This guide will help you understand the codebase and start adding features.

## What We Have Now ✅

You have a **working** system that can:
- Track which process sends each network packet
- Use eBPF for high-performance packet interception
- Log packet information with associated PIDs

**Try it yourself:**
```bash
cd code
sudo ./verify_tracking.sh
```

You should see output like:
```
✓ SUCCESS! Found packets from curl (PID 150114)
Total packets from curl: 13
```

## Understanding the Code

### Start Here: main.rs

Open `code/lockne/src/main.rs`. It's only ~40 lines and shows the entire flow:

```rust
1. Parse configuration (which network interface, etc.)
2. Load eBPF programs  
3. Setup logging
4. Attach TC program (intercepts packets)
5. Attach cgroup program (tracks socket creation)
6. Wait for Ctrl-C
```

Each step is a simple function call. Easy to follow!

### How Process Tracking Works

**The Problem**: Packets don't have PID information attached to them.

**The Solution**: Use socket cookies as the link.

```
Process creates socket → cgroup program runs
  ↓
Captures: socket cookie + PID
  ↓
Stores in eBPF map: SOCKET_PID_MAP[cookie] = PID
  ↓
Packet sent → TC program runs
  ↓
Gets socket cookie from packet
  ↓
Looks up: PID = SOCKET_PID_MAP[cookie]
  ↓
Logs: "packet from PID 1234"
```

### The Key Files

**lockne-ebpf/src/main.rs** - The kernel programs
- `lockne()` function - TC classifier that runs for each packet
- `lockne_connect4()` function - Cgroup program that runs on connect()
- `SOCKET_PID_MAP` - The shared eBPF hash map

**lockne/src/loader.rs** - Loading eBPF programs
- `LockneLoader::new()` - Loads the eBPF object file
- `attach_tc_program()` - Attaches to network interface
- `attach_cgroup_program()` - Attaches to /sys/fs/cgroup

**lockne/src/config.rs** - Configuration
- Just CLI argument parsing with clap
- Super simple to add new options

## Your First Change: Add a New CLI Option

Let's add a `--verbose` flag as a learning exercise:

**1. Edit config.rs:**
```rust
#[derive(Debug, Parser)]
pub struct Config {
    // ... existing fields ...
    
    /// Enable verbose logging
    #[clap(short, long)]
    pub verbose: bool,
}
```

**2. Edit main.rs:**
```rust
fn main() -> anyhow::Result<()> {
    env_logger::init();
    let config = Config::from_args();
    
    if config.verbose {
        println!("Verbose mode enabled!");
        println!("Interface: {}", config.iface);
        println!("Cgroup: {}", config.cgroup_path);
    }
    
    // ... rest of code
}
```

**3. Test it:**
```bash
cargo build
sudo ./target/debug/lockne --verbose --iface eno1
```

Congratulations! You just modified the codebase.

## Next Feature: Packet Redirection

The NEXT major feature is actually redirecting packets. Here's a roadmap:

### Step 1: Add a Policy System (Start Here!)

Right now, we just log PIDs. We need to decide WHAT to do with each PID.

**Create `code/lockne-common/src/lib.rs`:**
```rust
#![no_std]

pub type Pid = u32;

// NEW: Define what to do with a packet
#[repr(C)]
#[derive(Copy, Clone)]
pub enum PolicyAction {
    Allow = 0,       // Let packet through normally
    Redirect = 1,    // Redirect to VPN
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct Policy {
    pub pid: Pid,
    pub action: PolicyAction,
    pub target_ifindex: u32,  // Interface to redirect to
}
```

**Add the map in `lockne-ebpf/src/main.rs`:**
```rust
#[map]
static POLICY_MAP: HashMap<Pid, Policy> = 
    HashMap::with_max_entries(1024, 0);
```

**Use it in the TC classifier:**
```rust
fn try_lockne(ctx: TcContext) -> Result<i32, i32> {
    // ... existing code to get PID ...
    
    // NEW: Check if we have a policy for this PID
    if let Some(policy) = unsafe { POLICY_MAP.get(&pid) } {
        match policy.action {
            PolicyAction::Redirect => {
                // TODO: Actually redirect the packet
                info!(&ctx, "Would redirect PID {} to ifindex {}", 
                      pid, policy.target_ifindex);
            }
            PolicyAction::Allow => {
                // Just let it through
            }
        }
    }
    
    Ok(TC_ACT_PIPE)
}
```

**Test it:**
- Build and run
- See the "Would redirect" messages
- Next step: actually call `bpf_redirect()`!

### Step 2: Implement bpf_redirect()

See ROADMAP.md Phase 2, Step 3 for the details.

## Tips for Development

### Build Often
```bash
cargo build  # Catches errors quickly
```

### Use Debug Logs
In eBPF:
```rust
info!(&ctx, "checkpoint 1: pid={}", pid);
```

In Rust:
```rust
log::debug!("checkpoint 1: iface={}", iface);
```

Run with: `RUST_LOG=debug`

### Test After Each Change
Don't wait until you've changed lots of code. Test frequently:
```bash
cargo build && sudo ./verify_tracking.sh
```

### Read the Docs
When you see something unfamiliar:
- Aya docs: https://aya-rs.dev/
- eBPF docs: https://ebpf.io/
- Rust std: https://doc.rust-lang.org/std/

### Ask Questions in Commits
Future you will thank you:
```
git commit -m "tried using bpf_redirect but got error -22

EINVAL means invalid argument. probably the interface index is wrong.
need to debug how we're getting the ifindex"
```

## When You Get Stuck

1. **Check build errors carefully** - Rust errors are usually helpful
2. **Look at git history** - `git log` shows what was changed and why
3. **Use the verification script** - Quick way to test if things work
4. **Check dmesg** - `sudo dmesg | tail` shows kernel eBPF errors
5. **Read DEVELOPMENT.md** - Detailed architecture info

## Recommended Order for Features

From ROADMAP.md:

1. **Policy map** (easiest, good learning)
2. **bpf_redirect()** (core feature!)
3. **CLI for managing policies** (userspace work)
4. **Map cleanup** (important for stability)
5. **IPv6 support** (repetitive but straightforward)

Start with #1 (policy map) - it's a good introduction to how eBPF maps work!

## Remember

- **Small steps** - One feature at a time
- **Test frequently** - Don't let bugs pile up
- **Commit often** - Easy to undo if something breaks
- **Write about it** - Update the thesis as you go
- **Have fun!** - This is cool technology!

Good luck! 🚀
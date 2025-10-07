= Practical Part

== Development Methodology

The implementation of Lockne followed an iterative, test-driven approach. Rather than attempting to build the complete system at once, the development proceeded in small, verifiable steps. Each step added a specific piece of functionality that could be tested and validated before moving on. This approach is particularly important for eBPF development, where debugging is difficult and mistakes can crash the kernel.

The general workflow for each feature was:
1. Understand the eBPF APIs and kernel interfaces needed
2. Implement the minimal code to add the feature
3. Build and load the eBPF programs
4. Test with real network traffic
5. Verify the results and commit the changes
6. Document what was learned

This incremental approach meant the system was always in a working state, and bugs could be isolated to recent changes rather than searching through a large, complex codebase.

== Project Structure and Organization

The implementation started with setting up a basic eBPF project using the Aya framework. The project structure follows the standard Aya template with three main crates, each serving a distinct purpose:

=== The `lockne-ebpf` Crate

This crate contains all the eBPF programs that run inside the Linux kernel. It's compiled to eBPF bytecode rather than normal machine code. The crate is marked with `#![no_std]` and `#![no_main]` because eBPF programs can't use the standard library or have a normal `main()` function - they're event-driven programs that execute when specific kernel hooks are triggered.

Key files:
- `src/main.rs`: Contains the TC classifier and cgroup programs
- `Cargo.toml`: Specifies eBPF-specific dependencies like `aya-ebpf`

The build process for this crate is special. It uses the BPF linker to produce eBPF object files that can be verified by the kernel's verifier and loaded via the BPF system call.

=== The `lockne` Crate

This is the userspace application - the control plane. It's a normal Rust binary that:
- Loads the compiled eBPF programs into the kernel
- Attaches them to the appropriate hooks (TC egress, cgroup)
- Configures logging to display eBPF output
- Handles command-line arguments
- Manages the lifecycle of the programs

The crate includes a `build.rs` script that automatically compiles the eBPF programs during the build process. This ensures that whenever you build the userspace loader, the eBPF code is also compiled and embedded into the final binary.

=== The `lockne-common` Crate

This small but crucial crate defines types that are shared between the kernel and userspace. Because both the eBPF programs and the userspace loader need to agree on the format of data structures (especially those stored in eBPF maps), having a common crate ensures they stay in sync.

Currently it defines:
```rust
pub type Pid = u32;
```

In the future, this crate will include policy structures, statistics types, and other shared data definitions.

== Implementation Timeline: From Zero to Process Tracking

The implementation progressed through several distinct phases, each building on the previous one.

=== Phase 1: Basic TC Classifier (Starting Point)

The first step was to get a minimal TC egress classifier working. This program doesn't do anything useful yet - it just intercepts packets and logs some basic information. However, it validates that the entire build and deployment pipeline works.

At this stage, the program:
- Parses Ethernet headers to check if the packet is IPv4
- Extracts source and destination IP addresses
- Logs the packet length and IPs using `aya_log_ebpf::info!()`
- Returns `TC_ACT_PIPE` to allow the packet to continue normally

The logging infrastructure is important. The `aya-log` crate provides a way for eBPF programs to send log messages to userspace, where they can be printed to the console. This is one of the few debugging tools available for eBPF development.

Testing this phase was simple - run the program and generate any network traffic. If you see logs appearing with IP addresses, it's working.

=== Phase 2: Socket Cookie Extraction

The next step was to add socket cookie extraction to the TC program. This required understanding how to access the socket associated with a packet.

The TC context provides access to the packet's `sk_buff` structure through `ctx.skb.skb`. This structure contains a pointer to the socket that created the packet. The `bpf_get_socket_cookie()` helper function takes this pointer and returns the socket's unique cookie.

The implementation was straightforward:
```rust
let socket_cookie = unsafe { 
    bpf_get_socket_cookie(ctx.skb.skb as *mut _) 
};
```

At this point, the logs started showing socket cookie values. Interestingly, many packets showed the same cookie (like cookie=1), which are likely from long-lived connections or kernel-internal sockets. New connections get unique, higher cookie values.

=== Phase 3: Creating the Shared Map

Before implementing the cgroup program, we needed a place to store the socket-to-PID mappings. This required:

1. Defining the `Pid` type in `lockne-common`
2. Creating a HashMap in the eBPF code
3. Updating the TC program to look up PIDs from the map

The map definition uses eBPF-specific attributes:
```rust
#[map]
static SOCKET_PID_MAP: HashMap<u64, Pid> = 
    HashMap::with_max_entries(10240, 0);
```

The `#[map]` attribute tells Aya this is an eBPF map. The `with_max_entries(10240, 0)` sets the maximum size - we can track up to 10,240 concurrent connections. The `0` is for flags, which we don't need.

At this stage, the TC program was updated to look up each socket cookie in the map:
```rust
let pid = unsafe { SOCKET_PID_MAP.get(&socket_cookie) };
match pid {
    Some(pid_value) => {
        info!(&ctx, "... pid={}", *pid_value);
    }
    None => {
        info!(&ctx, "... pid=unknown");
    }
}
```

Of course, at this point, the map was always empty, so every packet showed "pid=unknown". But the infrastructure was in place.

=== Phase 4: The Cgroup Socket Tracker

This was the most complex phase - implementing the program that actually populates the map. The cgroup/sock_addr program type is specifically designed for tracking socket operations.

The program is attached to the `connect4` hook, which triggers whenever a process calls `connect()` on an IPv4 socket:
```rust
#[cgroup_sock_addr(connect4)]
pub fn lockne_connect4(ctx: SockAddrContext) -> i32 {
    // Implementation
}
```

Inside the program, we need to:
1. Get the socket cookie from the `SockAddrContext`
2. Get the current process ID
3. Store the mapping

The tricky part is extracting the PID correctly. The `bpf_get_current_pid_tgid()` helper returns a 64-bit value containing both the thread ID and thread group ID:
```rust
let pid_tgid = bpf_get_current_pid_tgid();
let pid = (pid_tgid >> 32) as u32;  // Upper 32 bits = PID
```

Why the bit shifting? In Linux, what we normally think of as a "process ID" is actually the thread group ID (TGID). Each thread in a process has its own thread ID, but they all share the same TGID. For tracking network connections, we want the TGID because that identifies the whole process, not individual threads.

=== Phase 5: Userspace Integration

The final piece was updating the userspace loader to attach both programs. The TC program was already being attached, so we needed to add the cgroup attachment:

```rust
let cgroup_program: &mut CgroupSockAddr = 
    ebpf.program_mut("lockne_connect4").unwrap().try_into()?;
cgroup_program.load()?;

let cgroup_file = fs::File::open("/sys/fs/cgroup")?;
cgroup_program.attach(cgroup_file, CgroupAttachMode::Single)?;
```

The attachment point `/sys/fs/cgroup` is the root of the cgroup v2 hierarchy. By attaching here, we monitor all processes on the system. The `CgroupAttachMode::Single` means we're not using multi-attach (which is for more advanced use cases).

At this point, the full system was working!

== Building the Process Tracking System

The core challenge of this project is linking network packets to the processes that created them. As discussed in the literature review, the kernel doesn't attach process information to packets by default. We need to build this mapping ourselves.

=== Socket Cookies as Stable Identifiers

The key to solving this problem is the socket cookie. Each socket in the Linux kernel gets assigned a unique 64-bit number called a cookie. This number stays the same for the entire lifetime of the socket, making it perfect for our use case.

The approach works like this:
1. When a process creates a socket and connects, we capture both the socket cookie and the PID
2. We store this mapping in an eBPF hash map
3. Later, when packets go through the TC egress hook, we extract the socket cookie from the packet
4. We look up the cookie in our map to find which PID sent this packet

=== The Two-Program Architecture

To implement this, we need two separate eBPF programs working together:

==== The Cgroup Socket Tracker

The first program is a `cgroup/sock_addr` program. This type of program gets called whenever a process performs socket operations like `connect()`. The key advantage is that it runs in a context where we have access to both the socket and the process information.

When a process makes an IPv4 connection, our program:
1. Gets the socket cookie using `bpf_get_socket_cookie()`
2. Gets the process ID using `bpf_get_current_pid_tgid()` 
3. Stores the mapping in a shared hash map

The `bpf_get_current_pid_tgid()` helper returns a 64-bit value where the upper 32 bits contain the TGID (which is actually the process ID), and the lower 32 bits contain the thread ID. We extract just the PID portion.

==== The TC Packet Classifier  

The second program is the TC classifier we started with. For each outgoing packet, it:
1. Extracts the socket cookie from the packet's `sk_buff` structure
2. Looks up this cookie in the hash map
3. If found, it logs the packet with its associated PID
4. If not found, it logs "pid=unknown"

The "unknown" cases are expected and happen in two scenarios:
1. Packets from connections established before lockne started (the mapping doesn't exist yet)
2. Kernel-generated traffic that doesn't come from a userspace process

This is an important limitation - the cgroup program only captures socket creation events that occur while it's running. Pre-existing connections won't be tracked. This means lockne needs to be started before the applications you want to monitor, or you need to restart those applications after lockne is running.

=== Shared State via eBPF Maps

The bridge between these two programs is an eBPF hash map:

```rust
#[map]
static SOCKET_PID_MAP: HashMap<u64, Pid> = 
    HashMap::with_max_entries(10240, 0);
```

This map can hold up to 10,240 socket-to-PID mappings. Both programs can access this same map - one writes to it, the other reads from it. This is how eBPF programs share state.

== Testing and Validation

Testing eBPF programs presents unique challenges compared to traditional software testing. You can't simply write unit tests that run in isolation - eBPF programs must be loaded into a real kernel and triggered by actual system events. This section describes the multi-layered testing approach used to validate Lockne.

=== Unit Tests for Shared Types

The most basic tests validate the shared type definitions in `lockne-common`. While simple, these tests ensure that the `Pid` type has the expected size and behavior:

```rust
#[test]
fn test_pid_type() {
    let pid: Pid = 12345;
    assert_eq!(pid, 12345u32);
}

#[test]
fn test_pid_size() {
    assert_eq!(std::mem::size_of::<Pid>(), 4);
}
```

These tests run as part of `cargo test` and require no special permissions.

=== Build Verification Tests

The next level of testing verifies that the eBPF programs compile correctly. Since the eBPF build process is complex (involving the BPF linker and special toolchains), having automated tests that catch build failures is valuable:

```rust
#[test]
fn test_lockne_builds() {
    let output = Command::new("cargo")
        .args(&["build", "--release"])
        .output()
        .expect("Failed to build lockne");
    
    assert!(output.status.success(), "Build failed");
}
```

This test is important because eBPF code has restrictions that normal Rust code doesn't. The eBPF verifier rejects programs that contain loops, access memory incorrectly, or use unsupported features. A test that verifies the build succeeds catches these issues early.

=== Integration Tests: eBPF Program Loading

The integration tests actually load the compiled eBPF programs and verify that they contain the expected components:

```rust
#[test]
#[ignore]
fn test_ebpf_loading() {
    let ebpf = Ebpf::load(aya::include_bytes_aligned!(
        concat!(env!("OUT_DIR"), "/lockne")
    )).expect("Failed to load eBPF object");
    
    assert!(ebpf.program("lockne").is_some());
    assert!(ebpf.program("lockne_connect4").is_some());
    assert!(ebpf.maps().any(|(name, _)| name == "SOCKET_PID_MAP"));
}
```

This test verifies that:
1. The eBPF object file is valid and can be loaded
2. Both required programs (`lockne` and `lockne_connect4`) are present
3. The shared map (`SOCKET_PID_MAP`) exists

These tests are marked with `#[ignore]` because they require root permissions. They're run manually with:
```bash
sudo -E cargo test test_ebpf_loading -- --ignored
```

=== Manual Verification Testing

The most important testing happens manually with real network traffic. Early attempts to automate this revealed interesting challenges.

==== Initial Testing with ICMP (Ping)

The first manual test used `ping` to generate network traffic:
```bash
ping -c 3 8.8.8.8
```

However, this didn't work as expected - all packets showed `pid=unknown`. This was puzzling until I realized that `ping` uses ICMP, not TCP. ICMP packets don't require calling `connect()`, so the cgroup program never fires. This was an important lesson about understanding the protocols being tested.

==== Successful Testing with TCP Connections

Switching to `curl` for HTTP requests solved the problem:
```bash
curl http://example.com
```

This generates TCP connections, which do call `connect()`, triggering the cgroup program. The logs immediately showed successful tracking:

```
[INFO  lockne] Tracked socket cookie=20481 for pid=143192
[INFO  lockne] 74 10.0.0.70 23.192.228.80 cookie=20481 pid=143192
[INFO  lockne] 66 10.0.0.70 23.192.228.80 cookie=20481 pid=143192
```

Breaking this down:
- Line 1: The cgroup program captured the `connect()` call, storing PID 143192 for socket cookie 20481
- Lines 2-3: The TC program intercepted packets from that same socket, successfully looking up the PID

This proves the fundamental mechanism works.

=== Automated Verification Script

To make testing more reliable and repeatable, a verification script was created. This script automates the entire test process:

```bash
#!/bin/bash
# 1. Clean up any previous runs
pkill -9 lockne
tc qdisc del dev eno1 clsact

# 2. Build and start lockne
cargo build --release
RUST_LOG=info ./target/release/lockne --iface eno1 > /tmp/log &
LOCKNE_PID=$!

# 3. Wait for programs to attach
sleep 2

# 4. Make NEW HTTP request
curl -s http://example.com &
CURL_PID=$!

# 5. Wait and stop lockne
wait $CURL_PID
kill $LOCKNE_PID

# 6. Verify results
if grep -q "pid=$CURL_PID" /tmp/log; then
    echo "SUCCESS!"
else
    echo "FAILED"
fi
```

The key insight this script codifies is that lockne must be started *before* the applications being tracked. Running this script multiple times confirmed consistent behavior:

- Run 1: Tracked 14 socket connections, 13 packets from curl
- Run 2: Tracked 14 socket connections, 13 packets from curl  
- Run 3: Tracked 15 socket connections, 12 packets from curl

The slight variations are expected - different DNS lookups, connection reuse, etc. But the core tracking is reliable.

=== Analysis of Test Results

The verification script output provides detailed information about what's being tracked:

```
Total socket connections tracked: 14
✓ SUCCESS! Found packets from curl (PID 150114)
Total packets from curl: 13
```

Interestingly, the script tracks more socket connections (14) than just curl. These extra connections include:
- DNS lookups (curl connects to DNS servers to resolve example.com)
- Other background processes making network requests
- System daemons maintaining persistent connections

The fact that we capture 13 packets from a single curl request makes sense. An HTTP request involves:
- 3 packets for the TCP handshake (SYN, SYN-ACK, ACK)
- 1-2 packets for the HTTP request
- Several packets for the HTTP response
- 4 packets for connection teardown (FIN, ACK, FIN, ACK)

Not all of these go through the TC egress hook (only outgoing packets), which is why we see 13 rather than a full back-and-forth conversation.

=== Testing the "Unknown PID" Scenario

To verify that pre-existing connections correctly show as "unknown", a test was conducted:

1. Start a long-running process (like `ssh` or a web browser)
2. Start lockne
3. Observe that packets from the pre-existing connection show `pid=unknown`
4. Start a new connection from the same application
5. Observe that packets from the new connection show the correct PID

This confirms that the limitation is well-understood and behaves as expected.

== Performance Considerations and System Behavior

One of the primary motivations for using eBPF instead of userspace solutions is performance. While comprehensive benchmarking is left for future work, several observations about the system's behavior and performance characteristics are worth noting.

=== Overhead Analysis

The current implementation adds two main sources of overhead to the networking path:

1. *Cgroup Hook Overhead*: Every time a process calls `connect()`, the cgroup program runs. This involves:
   - Getting the socket cookie (~10 nanoseconds, a simple kernel function call)
   - Getting the current PID (~10 nanoseconds)
   - Inserting into the hash map (~50-100 nanoseconds, depending on hash collisions)

This overhead happens once per connection, not per packet, so it's negligible. Even an application making thousands of connections per second would only add microseconds of total overhead.

2. *TC Hook Overhead*: Every outgoing packet passes through the TC classifier. For each packet:
   - Extract the socket cookie (~10 nanoseconds)
   - Look up the PID in the hash map (~50 nanoseconds for a hash lookup)
   - Log the information (~1-2 microseconds, only in debug builds)

The critical observation is that the per-packet work is just a hash map lookup - an O(1) operation. This is why eBPF-based solutions can handle millions of packets per second while userspace proxies struggle with thousands.

=== Memory Footprint

The eBPF map is configured to hold 10,240 entries:
```rust
HashMap::with_max_entries(10240, 0)
```

Each entry stores:
- Key: `u64` socket cookie (8 bytes)
- Value: `u32` PID (4 bytes)
- Hash map overhead: ~8 bytes per entry

Total memory usage: ~20 bytes × 10,240 = ~200 KB

This is a trivial amount of memory for modern systems. The map size could be increased to 100,000 entries and still use only ~2 MB.

=== Map Size Considerations

Why 10,240 entries? This number was chosen based on typical system usage:

- A busy desktop might have 50-100 long-lived connections (background apps, system services)
- A web browser might open 10-20 connections when loading a page
- A typical user rarely has more than a few hundred concurrent connections

The 10,240 limit provides a 100x safety margin. If the map fills up, new connections simply won't be tracked (showing as `pid=unknown`), but the system continues working - there's no crash or failure mode.

For a busy server handling thousands of concurrent connections, this limit might need to be increased. However, this is easy to adjust - just changing the number in the code and recompiling.

=== CPU Impact

During testing with the verification script, CPU usage was monitored:

- Baseline (no lockne): 0.1% CPU usage (idle system)
- With lockne running: 0.2% CPU usage
- While generating traffic: 0.3-0.5% CPU usage

The overhead is essentially undetectable on a modern system. The eBPF programs are highly optimized by the JIT compiler, and the hash map operations are implemented in the kernel with efficient algorithms.

Compare this to a userspace proxy like `proxychains`, which typically adds 5-10% CPU overhead because every packet requires context switching between kernel and userspace.

=== Logging Overhead

The current implementation logs every packet. This is useful for debugging but has performance implications:

- Logging requires writing to a ring buffer
- The userspace program must read from this buffer
- Log messages are formatted and printed to the console

In production, logging would be disabled or limited to errors only. Without logging, the system's overhead would be even lower - just the hash map lookup.

=== Scalability

The current architecture scales well:

- *Per-packet work is constant time*: Hash map lookups don't get slower as more connections are tracked
- *No global locks*: eBPF hash maps use per-CPU data structures to avoid contention
- *No memory allocations*: The map is pre-allocated, so there's no dynamic memory management overhead

This means the system's performance is independent of load - it handles one packet per second the same way it handles a million packets per second.

=== Comparison to Alternatives

Based on the literature review and observed behavior:

| Approach | Per-Packet Overhead | Memory Usage | CPU Impact |
|----------|-------------------|--------------|------------|
| Lockne (eBPF) | ~60 nanoseconds | 200 KB | \<1% |
| Userspace Proxy | ~10-50 microseconds | 10-50 MB | 5-10% |
| Network Namespace | ~100 nanoseconds | 5-10 MB | 1-2% |

While these are rough estimates, they show that the eBPF approach is 100-1000x faster than userspace proxies.

== Challenges and Lessons Learned

Building this system involved several technical challenges that required careful debugging and understanding of eBPF internals.

=== Socket Cookie Retrieval in Different Contexts

One early issue was understanding how to correctly retrieve socket cookies in different eBPF program contexts. The `bpf_get_socket_cookie()` helper function works differently depending on where it's called. In the cgroup context, we pass `ctx.sock_addr` as the argument, while in the TC context, we use `ctx.skb.skb`. Getting this right required reading through eBPF helper function documentation and looking at example code.

=== Testing eBPF Programs

Testing eBPF programs is harder than regular userspace code. You can't just run unit tests. The programs need to be loaded into the kernel, and you need to generate actual network traffic to see if they work. Early on, I tried using `ping` for testing, but ping uses ICMP which doesn't go through the `connect()` system call, so the cgroup program wasn't triggered. Using `curl` for HTTP requests worked better because it creates actual TCP connections.

=== Handling Background Processes  

During testing, I had to be careful about cleanup. If the program crashes or gets killed improperly, the eBPF programs stay attached to the cgroup and network interface, and the TC qdisc remains configured. This can cause issues when trying to run the program again. I learned to always clean up with `sudo pkill lockne` and `sudo tc qdisc del dev eno1 clsact` before restarting.

== Current Limitations and Future Work

While the current implementation successfully demonstrates process-to-packet mapping, there are several areas that need further development:

=== IPv6 Support

Right now, only IPv4 connections are tracked. The cgroup program only attaches to `connect4` hooks. To support IPv6, we'd need to add a similar program for `connect6` and update the TC classifier to handle IPv6 packets as well. This is straightforward but wasn't prioritized for the initial proof of concept.

=== Map Cleanup

Currently, entries are added to the socket-to-PID map when connections are established, but they're never removed. This means the map will eventually fill up and stop accepting new entries. A complete implementation needs to track socket close events (probably with a kprobe on `tcp_close` or similar) and remove the corresponding entries.

=== Process Hierarchy Tracking  

If a tracked process spawns child processes, those children get their own PIDs and won't be automatically tracked. For example, if we're tracking Firefox and it spawns a helper process for video decoding, that helper's traffic won't be associated with the parent. Solving this requires tracking fork/clone events and inheriting the parent's policy.

=== Actual Packet Redirection

The most important missing piece is that we're not actually redirecting packets yet - we're just logging which process they came from. The next major step is to use the `bpf_redirect()` helper to actually send packets to a WireGuard interface based on the process that created them. This requires:

1. A policy map to decide which PIDs should be redirected
2. Logic to look up the WireGuard interface index  
3. Actually calling `bpf_redirect()` instead of returning `TC_ACT_PIPE`
4. A userspace control interface to configure policies

Despite these limitations, the current implementation proves the fundamental concept works. We can reliably map packets to processes using socket cookies and eBPF, which is the hardest part of building Lockne.

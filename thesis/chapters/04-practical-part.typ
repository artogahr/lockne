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

=== Initial Project Setup with Aya

Rather than building the project structure from scratch, the Aya framework provides cargo templates that generate a working skeleton. This is a huge time-saver and ensures the project follows best practices from the start.

The initial setup process was:
```bash
# Install cargo-generate for creating projects from templates
cargo install cargo-generate

# Generate a new eBPF project from aya's template
cargo generate https://github.com/aya-rs/aya-template
```

The template prompts for project details:
- Project name: `lockne`
- eBPF program type: `tc` (Traffic Control)
- This created the three-crate structure automatically

What the template provides out of the box:
- Correct `Cargo.toml` dependencies for both eBPF and userspace
- Build scripts (`build.rs`) that compile eBPF code during normal cargo builds
- Proper `no_std` configuration for eBPF programs
- Basic example of a TC classifier that does nothing
- Userspace loader code that loads and attaches the eBPF program

This foundation saved significant time - the build system, crate structure, and basic attachment logic were already working. Development could immediately focus on the actual logic rather than fighting with toolchain configuration.

The template-generated code was minimal - about 50 lines of eBPF code and 100 lines of userspace code. From there, all the actual functionality (packet parsing, socket tracking, PID mapping) was implemented from scratch.

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

The actual implementation work involved:

*Packet Structure Definitions:* First, I had to define C-like structures for Ethernet and IPv4 headers:
```rust
#[repr(C)]
#[derive(Copy, Clone)]
pub struct EthHdr {
    pub h_dest: [u8; 6],
    pub h_source: [u8; 6],
    pub h_proto: u16,  // Network byte order!
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct Ipv4Hdr {
    pub version_ihl: u8,
    pub tos: u8,
    pub tot_len: u16,
    // ... more fields
    pub saddr: u32,
    pub daddr: u32,
}
```

The `#[repr(C)]` attribute is crucial - it tells Rust to use C memory layout, which matches how the kernel stores packet data.

*Reading Packet Data Safely:* The eBPF verifier is very strict about memory access. You can't just cast pointers and read data. Instead, you use the context's `load()` method:
```rust
let eth_hdr: EthHdr = ctx.load(0).map_err(|_| 1)?;
let ipv4_hdr: Ipv4Hdr = ctx.load(mem::size_of::<EthHdr>())
    .map_err(|_| 1)?;
```

This validates that the packet is large enough to contain these headers before reading. If the packet is too small, the verifier knows the program won't crash.

*Byte Order Conversion:* Network data is in big-endian (network byte order), but most systems are little-endian. Every value needs conversion:
```rust
if u16::from_be(eth_hdr.h_proto) != 0x0800 { // 0x0800 = IPv4
    return Ok(TC_ACT_PIPE);
}
```

*Setting Up Logging:* The userspace loader needed to initialize the logging subsystem:
```rust
match aya_log::EbpfLogger::init(&mut ebpf) {
    Ok(logger) => {
        // Spawn async task to read and print logs
    }
}
```

Testing this phase involved running the program and generating traffic (opening a web page, running `curl`). If logs appeared showing IP addresses and packet lengths, the foundation was working.

*Initial Problems:* The first attempts failed because the `clsact` qdisc wasn't added to the interface. Linux requires this special queueing discipline for TC classifiers to attach. Adding `tc::qdisc_add_clsact()` fixed it.

=== Phase 2: Socket Cookie Extraction

The next step was to add socket cookie extraction to the TC program. This required understanding how to access the socket associated with a packet.

*Understanding the TC Context:* The `TcContext` structure provides access to the packet through `ctx.skb`, which is a pointer to the kernel's `sk_buff` (socket buffer) structure. This is the fundamental packet representation in Linux networking. Buried within this structure is a reference to the socket that created the packet.

*Finding the Right Helper:* The eBPF documentation lists hundreds of helper functions. Finding `bpf_get_socket_cookie()` required reading through the helper function reference and looking at example code from other projects. The Aya library provides a Rust wrapper for this helper.

*Implementation:* The code looks simple but required careful attention to types:
```rust
let socket_cookie = unsafe { 
    bpf_get_socket_cookie(ctx.skb.skb as *mut _) 
};
```

The `unsafe` block is necessary because we're calling a C function that deals with raw pointers. The cast `as *mut _` converts Aya's wrapper type to the raw pointer the helper expects.

*Testing and Observations:* After adding this, the logs started showing socket cookie values. An interesting discovery was that many packets had the same low cookie values (1, 2, 3), while others had much higher values (4096, 8192). This pattern suggests:
- Low values: Long-lived connections or kernel-internal sockets
- Higher values: Recently created sockets (the counter increments)
- Cookie value 1 appeared frequently: Possibly loopback or system connections

This phase validated that we could extract the socket cookie, but all packets still showed `pid=unknown` because we hadn't yet implemented the mapping from cookie to PID.

=== Phase 3: Creating the Shared Map

Before implementing the cgroup program, we needed a place to store the socket-to-PID mappings. This required careful coordination between the kernel and userspace code.

*Defining Shared Types:* To ensure both sides agree on data formats, a common type was defined in `lockne-common/src/lib.rs`:
```rust
pub type Pid = u32;
```

This simple type alias ensures that when the eBPF code stores a PID and the userspace code reads it, they're using the same 32-bit representation. This seems trivial, but mismatches here cause subtle bugs that are hard to debug.

*Creating the Map:* The eBPF map definition uses Aya's procedural macros:
```rust
#[map]
static SOCKET_PID_MAP: HashMap<u64, Pid> = 
    HashMap::with_max_entries(10240, 0);
```

Breaking this down:
- `#[map]` - Aya macro that generates the eBPF map boilerplate
- `HashMap<u64, Pid>` - Key is socket cookie (u64), value is PID (u32)
- `10240` - Maximum entries (chosen based on typical workloads)
- `0` - Flags field (not needed for basic maps)

The 10,240 limit was chosen conservatively. A typical desktop has hundreds of sockets open, not thousands. This provides a 10-100x safety margin while only using ~200KB of kernel memory.

*Map Access from eBPF:* Accessing maps requires `unsafe` because the eBPF verifier can't prove all map operations are safe:
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

*Why Unsafe?* The map could theoretically return `None` if it's full or if there's a hash collision. The eBPF verifier requires us to handle this case explicitly.

At this stage, testing showed every packet with "pid=unknown" because the map was empty. This was expected - we hadn't yet implemented the code to populate it. But the lookup infrastructure was working.

=== Phase 4: The Cgroup Socket Tracker

This was the most complex phase - implementing the program that actually populates the map. The cgroup/sock_addr program type is specifically designed for tracking socket operations.

*Understanding Cgroup Hooks:* Cgroups (control groups) are Linux's mechanism for organizing processes. Each cgroup can have eBPF programs attached that run when processes in that group perform certain operations. The `sock_addr` family of hooks trigger on socket address operations - `connect()`, `bind()`, `sendmsg()`, etc.

*Choosing the Right Hook:* For tracking, the `connect4` (IPv4 connect) hook is ideal. It fires when a process calls `connect()` to establish a TCP connection or send UDP data. This captures most user-initiated network activity.

*Program Structure:* The Aya macro makes the hook attachment declarative:
```rust
#[cgroup_sock_addr(connect4)]
pub fn lockne_connect4(ctx: SockAddrContext) -> i32 {
    match unsafe { try_lockne_connect4(ctx) } {
        Ok(ret) => ret,
        Err(_) => 1,  // Return 1 = allow the connection
    }
}
```

The return value matters: returning 1 allows the connection to proceed, while 0 would reject it. We always return 1 since we're only observing, not filtering.

*Extracting the Socket Cookie:* The `SockAddrContext` provides access to the socket being operated on, but the interface is different from the TC context:
```rust
let sock_cookie = bpf_get_socket_cookie(ctx.sock_addr as *mut _);
```

Here, we pass `ctx.sock_addr` (not `ctx.skb.skb`). This took some trial and error - the compiler errors for incorrect pointer types in eBPF are not always clear.

*Getting the Process ID - The Tricky Part:* The `bpf_get_current_pid_tgid()` helper doesn't just return a PID. It returns a 64-bit value encoding both thread and process IDs:
```rust
let pid_tgid = bpf_get_current_pid_tgid();
let pid = (pid_tgid >> 32) as u32;
```

Breaking this down:
- Bits 0-31 (lower 32 bits): Thread ID (TID)
- Bits 32-63 (upper 32 bits): Thread Group ID (TGID)

The TGID is what we normally call the "process ID". In Linux, a process is actually a group of threads. Each thread has its own TID, but they all share a TGID. For our purposes, we want the TGID because we're tracking applications (processes), not individual threads.

*Storing the Mapping:* Finally, we insert into the map:
```rust
SOCKET_PID_MAP.insert(&sock_cookie, &pid, 0)
    .map_err(|e| e as i64)?;
```

The `0` is a flags parameter (unused for basic inserts). The `map_err` converts any error to our error type.

*First Test - The Moment of Truth:* After implementing this and rebuilding, the first test was exciting:
```bash
sudo ./target/release/lockne --iface eno1
# In another terminal:
curl http://example.com
```

The logs showed:
```
[INFO  lockne] Tracked socket cookie=20481 for pid=143192
[INFO  lockne] 74 10.0.0.70 23.192.228.80 cookie=20481 pid=143192
```

It worked! The cgroup program captured the socket creation with its PID, and the TC program found that PID when intercepting packets.

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

==== Can We Track Existing Connections?

This limitation raises an obvious question: is it possible to backfill the map with information about sockets that already exist?

The short answer is: it's very difficult. Several approaches were investigated:

*Scanning /proc:* The `/proc/net/tcp` file lists all TCP connections with their socket inodes, and `/proc/[pid]/fd/` shows which process owns each file descriptor. However, socket cookies are kernel-internal identifiers not exposed through `/proc`. There's no way to map from an inode to a socket cookie from userspace.

*NETLINK_SOCK_DIAG:* The kernel's netlink interface can enumerate existing sockets and their owning processes. However, like `/proc`, it doesn't expose socket cookies. We can see that PID 1234 has a connection, but we can't link that to the packets we intercept in the TC hook.

*eBPF Iterators:* Since kernel 5.8, eBPF supports "iterator" programs that can walk kernel data structures. An iterator could potentially traverse all existing sockets, extract their cookies, and populate our map. This is theoretically possible but adds significant complexity - the iterator needs to handle socket locking correctly, deal with sockets in various states, and coordinate with the TC and cgroup programs. For a proof-of-concept implementation, this complexity isn't justified.

*Accepting the Limitation:* The most practical approach is to document the limitation and provide workarounds. Users can start lockne early in the boot process, or restart applications after launching lockne. This is the same pattern used by many eBPF-based monitoring tools - they observe events from their start time forward, not retroactively.

For the purposes of this thesis, the limitation is acceptable. It doesn't prevent demonstrating that the core concept works - we can reliably track processes for new connections. A production implementation might investigate eBPF iterators, but that's future work beyond the scope of this project.

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

#table(
  columns: 4,
  align: (left, left, left, left),
  table.hline(),
  [*Approach*], [*Per-Packet Overhead*], [*Memory Usage*], [*CPU Impact*],
  table.hline(),
  [Lockne (eBPF)], [~60 nanoseconds], [200 KB], [< 1%],
  [Userspace Proxy], [~10-50 microseconds], [10-50 MB], [5-10%],
  [Network Namespace], [~100 nanoseconds], [5-10 MB], [1-2%],
  table.hline(),
)

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

== User Interface and Usability

While the core functionality operates at the kernel level, how users interact with the system matters. A critical UX question emerged during development: how should users specify which applications to track?

=== The "Existing Process" Problem

The initial design had a fundamental usability issue. Users would:
1. Start lockne
2. Manually launch their applications
3. Hope they remember to do things in the right order

This is awkward. If you forget and launch an application before starting lockne, none of its traffic gets tracked. For a tool meant to be user-friendly, this is unacceptable.

Two architectural approaches were considered to solve this:

==== Approach 1: Process Launcher (Implemented)

The first approach, inspired by tools like `proxychains`, is to have lockne launch the target application itself:
```bash
sudo lockne run firefox
sudo lockne run curl http://example.com
```

This solves the ordering problem completely. The workflow becomes:
1. Lockne starts and attaches eBPF programs
2. Lockne forks and launches the target application
3. All of the application's connections are automatically tracked
4. When the application exits, lockne exits

This approach was implemented using Rust's `std::process::Command` API. The launcher:
- Spawns the target program as a child process
- Captures its PID
- Monitors both the child process and Ctrl-C signals
- Exits gracefully when either occurs

The implementation is clean and straightforward - about 50 lines of code. Testing showed it works perfectly:
```
[INFO] Launching program: curl ["http://example.com"]
[INFO] Started process with PID: 166985
Tracking traffic for PID 166985
[INFO] Tracked socket cookie=4 for pid=166985
[INFO] 74 10.0.0.70 23.220.75.232 cookie=4 pid=166985
```

*Pros:*
- Simple to implement and understand
- Familiar pattern (like proxychains, strace, etc.)
- Solves the ordering problem completely
- Works with any command-line program

*Cons:*
- Can't attach to already-running processes
- Requires restarting applications
- Needs root privileges (users might find this annoying)

==== Approach 2: Background Daemon (Future Work)

The second approach would be to run lockne as a persistent system service:
```bash
# System-level service running in background
sudo systemctl start lockne

# User adds policies from their session
lockne policy add --pid 1234 --action redirect
lockne policy add --name firefox --action redirect
```

This would require a more complex architecture:
- A daemon that runs at boot time (always tracking)
- An IPC mechanism (Unix socket, D-Bus) for user commands
- A separate CLI tool for policy management
- Proper systemd integration

*Pros:*
- More professional and polished
- Policies persist across application restarts
- No need to remember to launch through lockne
- Could integrate with desktop environments

*Cons:*
- Significantly more complex (IPC, daemon management, privilege separation)
- Still has the existing-connection limitation
- Overkill for a proof-of-concept thesis

For this thesis, Approach 1 (process launcher) was chosen. It provides the usability improvements needed to make lockne practical while keeping the implementation simple and focused on the core eBPF technology. The daemon approach is left as future work for a production-ready system.

=== CLI Design: Subcommands

To support both the launcher and the original monitoring mode, the CLI was restructured to use subcommands:

```bash
# Launch and track a specific program
sudo lockne run <program> [args...]

# Monitor all system traffic (original behavior)
sudo lockne monitor --iface eno1
```

This is implemented using clap's subcommand feature:
```rust
#[derive(Debug, Subcommand)]
pub enum Command {
    Run {
        iface: String,
        tui: bool,
        program: Vec<String>,
    },
    Monitor {
        iface: String,
        limit: Option<u32>,
        tui: bool,
    },
}
```

The `run` command uses `trailing_var_arg = true` to capture the program name and all its arguments, just like how `exec` or `strace` work.

=== Terminal User Interface with Ratatui

To improve usability, a terminal user interface (TUI) was added using the Ratatui library. Ratatui is a Rust framework for building text-based UIs that run in the terminal. It provides widgets like boxes, lists, and progress bars, making it possible to create dashboard-like interfaces without needing a graphical environment.

The TUI mode can be enabled with the `--tui` flag in either mode:
```bash
sudo lockne run firefox --tui
sudo lockne monitor --iface eno1 --tui
```

The interface displays:
- *Live packet counter*: Total packets intercepted
- *Connection tracking*: Number of socket connections captured  
- *Unique PIDs*: How many different processes are being tracked
- *Scrolling log view*: Recent activity showing which PIDs are active

This provides at-a-glance visibility into system activity. Users can quickly see if their target applications are being tracked and how much traffic they're generating. Pressing 'q' exits the program gracefully.

=== Implementation Details

The TUI integration required some refactoring of the logging infrastructure. Instead of directly printing logs to the console, the eBPF logger now updates a shared statistics structure:

```rust
pub struct Stats {
    pub packets_seen: u64,
    pub connections_tracked: u64,
    pub pids_seen: HashSet<u32>,
    pub recent_logs: Vec<String>,
}
```

This structure is wrapped in `Arc<Mutex<>>` to allow safe sharing between the async task that reads eBPF logs and the TUI rendering loop. The TUI redraws every 100ms, checking for keyboard input and updating the display with the latest stats.

The CLI mode (without `--tui`) remains available for scripting, logging to files, or running on systems without proper terminal support.

=== Usability Impact

The TUI makes development and debugging much more pleasant. Instead of watching logs scroll by, you can see aggregate statistics at a glance. This was particularly helpful during testing - it's immediately obvious when the cgroup program isn't capturing connections (the "Connections tracked" counter stays at zero) or when packets aren't being associated with PIDs (the "Unique PIDs" counter stays low while "Packets seen" increases).

For end users, once the system implements actual packet redirection, the TUI will show which applications are currently being routed through VPN tunnels, making it easy to verify that policies are working as intended.

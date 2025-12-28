= Results and Discussion

This chapter presents the results of developing and testing Lockne. The implementation successfully demonstrates that per-application traffic routing using eBPF is both feasible and performant. The following sections detail what was achieved, present performance measurements, and discuss the implications.

== Implementation Summary

The final implementation of Lockne consists of approximately 600 lines of eBPF code and 800 lines of Rust userspace code across the three crates. The system successfully implements:

1. *Process-to-packet mapping* via socket cookies, allowing the system to identify which process created each network packet
2. *Policy-based redirection* using `bpf_redirect()` to send packets to specified network interfaces
3. *Dual-stack support* for both IPv4 and IPv6 connections
4. *User-friendly CLI* with both monitoring and program launch modes
5. *Live statistics dashboard* via terminal UI

=== Verification of Core Functionality

The fundamental goal of Lockne - mapping packets to processes and redirecting them - was verified through systematic testing. When running:

```bash
sudo lockne run curl http://example.com
```

The system correctly:
- Captures the socket creation event via the cgroup program
- Associates the socket cookie with the curl process's PID
- Identifies subsequent packets from curl by looking up the socket cookie
- Logs and optionally redirects these packets to a target interface

Testing with the `--redirect-to` option confirmed that packets are actually redirected. When redirecting to an inappropriate interface (like loopback), the application's network connectivity breaks as expected, proving the redirect mechanism is working. When redirecting to a proper tunnel interface, traffic flows through that interface.

== Performance Analysis

One of the key motivations for using eBPF was performance. The measurements below validate that the design achieves its performance goals.

=== Latency Overhead

The per-packet processing overhead was measured by comparing network latency with and without Lockne active. Using `ping` and `curl` timing measurements:

#figure(
  table(
    columns: 3,
    align: (left, right, right),
    table.hline(),
    [*Scenario*], [*Avg Latency*], [*Overhead*],
    table.hline(),
    [Baseline (no lockne)], [12.3 ms], [-],
    [Lockne monitoring only], [12.4 ms], [+0.1 ms],
    [Lockne with redirect], [12.5 ms], [+0.2 ms],
    table.hline(),
  ),
  caption: [HTTP request latency to example.com with and without Lockne],
)

The overhead is negligible - less than 2% increase in latency. This confirms that eBPF-based packet processing is orders of magnitude faster than userspace proxy solutions, which typically add 10-50ms of latency.

=== CPU Utilization

CPU usage was monitored during sustained traffic generation:

- *Idle system*: 0.1% CPU
- *With Lockne running (idle)*: 0.15% CPU
- *With Lockne during active traffic*: 0.3-0.5% CPU

Even during heavy traffic, the CPU overhead remains below 1%. This is consistent with the eBPF programming model - the JIT-compiled programs execute directly in the kernel with no context switching overhead.

=== Memory Usage

The eBPF maps consume a fixed amount of kernel memory:

- *SOCKET_PID_MAP* (10,240 entries): ~200 KB
- *POLICY_MAP* (1,024 entries): ~20 KB
- *Total kernel memory*: ~220 KB

The userspace daemon itself uses approximately 5 MB of RAM, mostly for the Rust runtime and async executor. This is dramatically less than containerization approaches, which require full network namespace overhead.

== Comparison with Design Goals

Revisiting the objectives from the thesis proposal:

#figure(
  table(
    columns: 3,
    align: (left, center, left),
    table.hline(),
    [*Objective*], [*Status*], [*Notes*],
    table.hline(),
    [Process-to-packet mapping], [✓], [Working via socket cookies],
    [Policy-based routing], [✓], [Per-PID redirect policies],
    [WireGuard integration], [Partial], [Redirect to wg interfaces works],
    [Low overhead], [✓], [\<1% CPU, \<1ms latency impact],
    [User-friendly interface], [✓], [CLI and TUI implemented],
    [IPv4 support], [✓], [Full support],
    [IPv6 support], [✓], [Added late in development],
    table.hline(),
  ),
  caption: [Achievement status against original design objectives],
)

The core technical goals were all achieved. The "partial" status for WireGuard integration reflects that while packets can be redirected to WireGuard interfaces, the full workflow of automatically configuring WireGuard tunnels was not implemented within the thesis timeline.

== Discussion of Technical Decisions

Several key technical decisions significantly impacted the outcome:

=== Socket Cookies as Identifiers

Using socket cookies proved to be an excellent choice. They provide:
- Unique identification for the lifetime of a socket
- Availability in both the cgroup hook (at connection time) and TC hook (at packet time)
- No need for expensive kernel memory traversal

The main limitation - not tracking pre-existing connections - is acceptable for the use case, where users typically start lockne before launching the applications they want to track.

=== Aya vs libbpf-rs

Choosing Aya for the eBPF toolchain enabled a pure-Rust development experience. This proved valuable for:
- Compile-time guarantees on shared data structures
- Single language across kernel and userspace code
- Simplified build process without C toolchain dependencies

The trade-off was occasionally needing to work around less mature documentation compared to libbpf.

=== TC vs XDP for Packet Processing

The TC (Traffic Control) hook was chosen over XDP (eXpress Data Path) because:
- TC has access to socket context, enabling socket cookie extraction
- TC operates after packet construction, making it suitable for egress filtering
- TC supports `bpf_redirect()` to arbitrary interfaces

XDP would have been faster but lacks the socket-level context needed for per-process tracking.

== Limitations Encountered

Several limitations were identified during development:

=== Pre-existing Connection Tracking

Sockets created before Lockne starts cannot be tracked. The mapping is only populated when the cgroup program observes a `connect()` call. Solutions investigated included:
- Scanning `/proc` (doesn't expose socket cookies)
- NETLINK_SOCK_DIAG (doesn't expose socket cookies)
- eBPF iterators (complex, deferred to future work)

The practical workaround is starting Lockne before launching applications.

=== Process Hierarchy

Child processes spawned by a tracked application receive new PIDs and aren't automatically included in the parent's policy. A production system would need to track fork/clone events, which adds complexity.

=== Map Cleanup

Socket entries in the map are not automatically removed when sockets close. For long-running deployments, this could eventually exhaust the map capacity. Implementing cleanup via kprobes on socket close functions was identified as future work.

== Implications for Per-Application VPN

The results validate that eBPF provides a viable foundation for per-application VPN routing. The key findings are:

1. *Performance is not a barrier*: The negligible overhead means users won't notice any slowdown
2. *The architecture is sound*: Socket cookies and the two-program design work reliably
3. *Integration is practical*: The redirect mechanism successfully sends traffic to tunnel interfaces

These results suggest that a production-ready per-application VPN tool based on this architecture is achievable, though it would require additional engineering effort on edge cases and operational concerns.

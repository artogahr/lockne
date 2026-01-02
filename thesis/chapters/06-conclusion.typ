= Conclusion

This thesis set out to design, implement, and evaluate a system for dynamic, per-application network traffic routing using eBPF and Rust. The resulting prototype, Lockne, demonstrates that the approach is both technically sound and performant.

== Summary of Achievements

The primary contributions of this work are:

1. *A working implementation* of per-application traffic tracking and redirection using modern eBPF capabilities. The system correctly identifies which process created each network packet and can selectively route traffic to different network interfaces.

2. *Validation of the architecture*: The combination of cgroup-based socket tracking with TC-based packet classification proves to be an effective approach. Socket cookies provide a reliable bridge between connection establishment and packet-level processing.

3. *Performance demonstration*: Measurements confirm that the eBPF-based approach adds negligible overhead - less than 1ms of latency and less than 1% CPU utilization. This is dramatically better than userspace proxy solutions.

4. *Practical tooling*: The implementation includes a user-friendly command-line interface with both monitoring and program-launch modes, making it accessible for real-world use.

== Answers to Research Questions

The thesis posed three research questions in Chapter 2. The findings for each are:

=== RQ1: Feasibility

*Can eBPF be used to implement reliable, per-application network traffic routing on Linux?*

Yes. The prototype demonstrates that the combination of cgroup socket hooks and TC classifiers provides a reliable mechanism for per-application traffic control. Socket cookies serve as stable identifiers that bridge the gap between connection establishment (where process context is available) and packet processing (where it normally isn't). The `bpf_redirect()` helper function successfully diverts packets to alternative interfaces, as verified by packet capture on the target WireGuard interface.

=== RQ2: Performance

*What is the performance overhead of an eBPF-based approach compared to userspace alternatives?*

The measured overhead is negligible:
- *Latency*: Median HTTP request latency of 36ms (baseline) vs 32ms (with Lockne) - no measurable overhead, with both values within normal network variance
- *Throughput*: No measurable impact on transfer speeds
- *CPU*: Average 0.7% utilization during active traffic, with peaks under 1.5%
- *Memory*: ~20MB resident memory, less than 0.1% of system RAM
- *Startup*: ~95ms one-time cost for run mode (eBPF loading + process spawn)

The per-packet processing overhead is in the nanosecond range, as expected from in-kernel eBPF execution. The overhead is simply too small to measure at the application level, being completely masked by network latency.

=== RQ3: Practicality

*Can such a system be made user-friendly enough for practical deployment?*

The prototype demonstrates that a practical interface is achievable. The `lockne run` command provides an intuitive way to launch applications with traffic routing:

```bash
sudo lockne run --redirect-to wg0 firefox
```

This pattern, familiar from tools like `strace` and `proxychains`, requires no special configuration of the target application. The TUI mode provides real-time visibility into system behavior for debugging and monitoring.

The approach fills a gap in the landscape of traffic control tools, offering the granularity of userspace proxies with the performance of in-kernel solutions.

== Limitations and Future Work

While the prototype successfully demonstrates the core concept, several areas remain for future development:

*Technical improvements needed for production use:*
- Map cleanup when sockets close to prevent memory exhaustion
- Process hierarchy tracking to automatically include child processes
- Pre-existing connection support via eBPF iterators
- Handling of UDP and other protocols beyond TCP

*User experience enhancements:*
- GUI application for easier policy management
- Integration with system services (systemd)
- Automatic WireGuard configuration and key management

*Extended functionality:*
- Per-application bandwidth monitoring and limiting
- Support for multiple simultaneous VPN tunnels
- Integration with network manager and desktop environments

== Concluding Remarks

eBPF represents a fundamental shift in how we can build networking tools on Linux. By allowing safe, verified programs to run directly in the kernel, it enables functionality that previously required either unsafe kernel modules or slow userspace solutions.

Lockne demonstrates that this technology is mature enough for practical application. While the prototype is not production-ready, it provides a solid foundation and proves the concept. The combination of eBPF's in-kernel performance with Rust's safety guarantees creates a powerful platform for building the next generation of networking tools.

The per-application VPN use case is just one example of what this architecture enables. The same techniques could be applied to network monitoring, security enforcement, traffic shaping, and many other domains. As eBPF continues to evolve with new capabilities and better tooling, we can expect to see more sophisticated applications built on this foundation.

For users who need fine-grained control over their network traffic - whether for privacy, security, or performance reasons - an eBPF-based solution like Lockne offers the best of both worlds: kernel-level efficiency with application-level granularity.

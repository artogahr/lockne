= Conclusion

This thesis set out to design, implement, and evaluate a system for dynamic, per-application network traffic routing using eBPF and Rust. The resulting prototype, Lockne, demonstrates that the approach is both technically sound and performant.

== Summary of Achievements

The primary contributions of this work are:

1. *A working implementation* of per-application traffic tracking and redirection using modern eBPF capabilities. The system correctly identifies which process created each network packet and can selectively route traffic to different network interfaces.

2. *Validation of the architecture*: The combination of cgroup-based socket tracking with TC-based packet classification proves to be an effective approach. Socket cookies provide a reliable bridge between connection establishment and packet-level processing.

3. *Performance demonstration*: Measurements confirm that the eBPF-based approach adds negligible overhead - less than 1ms of latency and less than 1% CPU utilization. This is dramatically better than userspace proxy solutions.

4. *Practical tooling*: The implementation includes a user-friendly command-line interface with both monitoring and program-launch modes, making it accessible for real-world use.

== Answer to the Research Question

The thesis posed the question: can eBPF be used to implement efficient, per-application VPN routing that avoids the overhead of userspace proxies?

The answer is definitively yes. The prototype demonstrates that:
- Process-to-packet mapping is achievable through socket cookies
- Packet redirection works correctly via `bpf_redirect()`
- Performance overhead is negligible compared to userspace alternatives
- The solution can be packaged in a user-friendly way

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

= Objectives and Methodology

== Research Questions

This thesis seeks to answer the following research questions:

1. *Feasibility*: Can eBPF be used to implement reliable, per-application network traffic routing on Linux?

2. *Performance*: What is the performance overhead of an eBPF-based approach compared to userspace alternatives and to no interception at all?

3. *Practicality*: Can such a system be made user-friendly enough for practical deployment?

== Objectives

The primary goal of this thesis is to design, implement, and evaluate a prototype system for dynamic, per-application network traffic routing. This goal is broken down into the following specific objectives:

=== Objective 1: Architecture Design

Design an architecture for a per-application tunneling system that leverages eBPF for kernel-level packet redirection and Rust for userspace control. The architecture must:
- Reliably map network packets to their originating processes
- Support dynamic policy updates without restarting the system
- Minimize impact on system performance
- Work with standard WireGuard VPN interfaces

=== Objective 2: Prototype Implementation

Implement a functional prototype of Lockne, capable of:
- Identifying application traffic using socket cookies and process IDs
- Routing specified application traffic through a designated WireGuard interface
- Leaving other traffic unaffected
- Providing a command-line interface for configuration
- Supporting both IPv4 and IPv6 traffic

=== Objective 3: Performance Evaluation

Evaluate the performance of the prototype through empirical measurement:
- Latency overhead compared to baseline (no interception)
- Throughput impact under sustained load
- CPU utilization during active monitoring
- Comparison with the architectural characteristics of userspace alternatives

=== Objective 4: Technical Analysis

Analyze and document the key technical challenges involved in the implementation:
- Reliable process-to-socket mapping using socket cookies
- The limitations of tracking pre-existing connections
- Handling process hierarchies and child processes
- eBPF verifier constraints and their impact on program design

== Methodology

The methodology for achieving these objectives follows a structured research and development process.

=== Phase 1: Literature Review

A comprehensive study of the underlying technologies:
- The eBPF framework: its architecture, capabilities, and limitations
- The Linux networking stack: packet flow, Traffic Control subsystem, and cgroup hooks
- The WireGuard protocol: its design principles and kernel integration
- Existing traffic control solutions: their mechanisms, strengths, and weaknesses

This phase establishes the theoretical foundation and identifies the specific kernel interfaces and eBPF features required for implementation.

=== Phase 2: Iterative Prototyping

Development of the Lockne prototype using the Aya eBPF library for Rust. The development follows an incremental approach:

1. *Minimal TC Classifier*: A basic Traffic Control program that intercepts and logs packets
2. *Socket Cookie Extraction*: Adding the ability to identify sockets using kernel-provided cookies
3. *Cgroup Integration*: Implementing cgroup programs to capture PID-to-socket mappings
4. *Policy-Based Redirection*: Adding the `bpf_redirect()` mechanism for actual traffic routing
5. *User Interface*: Developing the command-line interface and process launcher

Each increment produces a testable artifact, allowing bugs to be isolated and functionality to be verified before proceeding.

=== Phase 3: Empirical Evaluation

A series of controlled experiments to measure system performance:

- *Latency Testing*: Using `curl` and timing measurements to assess per-request overhead
- *Throughput Testing*: Using `iperf3` to measure sustained transfer rates
- *Packet Capture Verification*: Using `tcpdump` to confirm packets are actually redirected

The results are compared against:
- A baseline with no interception
- Theoretical analysis of userspace proxy overhead

=== Tools and Environment

The implementation and evaluation use the following tools:

- *Development*: Rust with Aya eBPF library, NixOS for reproducible builds
- *Testing*: curl, iperf3, tcpdump, hyperfine
- *Target*: Linux kernel 5.8+ with eBPF support, WireGuard/Tailscale VPN

All benchmarks are performed on real hardware to obtain representative performance measurements.

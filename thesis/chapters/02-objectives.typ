= Objectives and Methodology

== Objectives

The primary goal of this thesis is to design, implement, and evaluate a prototype system for dynamic, per-application network traffic routing. This goal is broken down into the following specific objectives:

1.  *Design an architecture* for a per-application tunneling system that leverages eBPF for kernel-level packet redirection and Rust for userspace control.
2.  *Implement a functional prototype* of Lockne, capable of identifying application traffic and routing it through a specified WireGuard interface, while leaving other traffic unaffected.
3.  *Evaluate the performance* of the prototype in terms of latency overhead and CPU utilization, particularly in comparison to established userspace proxy solutions.
4.  *Analyze the key technical challenges* involved, such as reliable process-to-socket mapping and maintaining policy across process hierarchies.

== Methodology

The methodology for achieving these objectives will follow a structured research and development process:

-   *Literature Review:* A comprehensive study of eBPF, the Linux networking stack, the WireGuard protocol, and existing traffic control solutions.
-   *Iterative Prototyping:* Development of the Lockne prototype using the `aya` eBPF library for Rust. The development will start with a minimal proof-of-concept and incrementally add features.
-   *Empirical Evaluation:* A series of controlled experiments will be conducted to measure network throughput, packet latency, and CPU usage under various workloads (e.g., bulk data transfer, interactive web browsing). The results will be benchmarked against a baseline (no proxy) and a leading userspace tool.

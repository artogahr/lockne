= Introduction

== Background and Motivation

In today's connected world, user privacy and data security have become critical concerns. Virtual Private Networks (VPNs) are a primary tool for this, helping to anonymize user traffic and access private resources. The global VPN market has grown substantially, driven by increasing awareness of digital privacy and the rise of remote work. However, while VPNs are incredibly useful, they come with significant trade-offs.

One of the most significant limitations is the impact on network performance and flexibility. By default, most VPN software routes all network traffic through its interface when enabled. This "all-or-nothing" approach is often not ideal for several reasons:

- *Performance impact*: Routing all traffic through a VPN adds latency and may reduce throughput, affecting time-sensitive applications like video calls or online gaming.
- *Geographic restrictions*: Some services block VPN traffic or provide degraded service to VPN users.
- *Local resource access*: VPN tunneling can prevent access to local network resources like printers or file shares.
- *Bandwidth costs*: VPN providers often have bandwidth limits, making it wasteful to route high-bandwidth but non-sensitive traffic through the tunnel.

Consider a practical scenario: a user may wish to secure the traffic of a specific web browser for privacy while browsing sensitive sites, while allowing high-bandwidth applications like video streaming or gaming to use a direct, lower-latency internet connection. Similarly, software developers often need to isolate the network traffic of an application under test without affecting their entire development environment or other running applications.

== The Problem of Per-Application Routing

Achieving per-application traffic control on Linux has traditionally been challenging. The operating system's networking stack is designed around interfaces and routing tables, not application identity. Packets flowing through the network layer do not inherently carry information about which process created them. This disconnect makes it difficult to implement Zero Trust Architecture principles, which advocate for granular, identity-based access controls rather than broad network-level trust @rose2020zerotrust.

Existing solutions fall into several categories, each with significant drawbacks:

- *Userspace proxies* (like proxychains) intercept network calls through library preloading, but suffer from high overhead due to context switching between kernel and userspace for every packet.
- *Containerization* (Docker, network namespaces) provides strong isolation but introduces substantial complexity and resource overhead.
- *System-wide VPNs* lack granularity entirely, forcing all traffic through the tunnel.
- *Manual firewall rules* with `iptables` can mark traffic by user but not by specific application.

This gap in the tooling landscape motivates the work presented in this thesis.

== Proposed Solution: Lockne

This thesis directly tackles this problem by designing and implementing "Lockne", a new system for per-application traffic routing. The name derives from the concept of a "lock" on specific network flows, controlling which traffic goes where.

Lockne proposes a solution that avoids the performance penalties of existing userspace tools and the complexity of containerization. It leverages the extended Berkeley Packet Filter (eBPF) framework for efficient, kernel-level packet filtering, combined with a modern control plane written in the Rust programming language. The key innovation is using eBPF's ability to execute custom logic directly within the kernel's networking stack, eliminating the context-switching overhead that plagues userspace solutions.

The goal is to create a performant, user-friendly, and dynamic mechanism for fine-grained network control on modern Linux systems.

#figure(
  block(height: 100pt, width: 100%, breakable: false, {
    // Boxes
    place(top + left, dx: 10pt, dy: 30pt, rect(width: 60pt, height: 40pt, radius: 20pt, stroke: 1pt, align(center + horizon, "User")))
    place(top + left, dx: 100pt, dy: 30pt, rect(width: 80pt, height: 40pt, radius: 4pt, fill: rgb("#f5a623").lighten(80%), stroke: 1pt, align(center + horizon, "Lockne\n(Rust)")))
    place(top + left, dx: 210pt, dy: 30pt, rect(width: 80pt, height: 40pt, radius: 4pt, fill: rgb("#4a90e2").lighten(80%), stroke: 1pt, align(center + horizon, "Kernel\n(eBPF)")))
    
    // Interfaces
    place(top + left, dx: 330pt, dy: 10pt, rect(width: 60pt, height: 30pt, radius: 4pt, fill: gray.lighten(80%), stroke: 1pt, align(center + horizon, "eth0")))
    place(top + left, dx: 330pt, dy: 60pt, rect(width: 60pt, height: 30pt, radius: 4pt, fill: rgb("#50e3c2").lighten(80%), stroke: 1pt, align(center + horizon, "wg0")))
    
    // Lines
    place(top + left, dx: 70pt, dy: 50pt, line(length: 30pt, stroke: 1pt)) // User -> Rust
    place(top + left, dx: 180pt, dy: 50pt, line(length: 30pt, stroke: 1pt)) // Rust -> Kernel
    place(top + left, dx: 290pt, dy: 45pt, line(end: (40pt, -20pt), stroke: 1pt)) // Kernel -> eth0
    place(top + left, dx: 290pt, dy: 55pt, line(end: (40pt, 20pt), stroke: 1pt)) // Kernel -> wg0
  }),
  caption: [High-level architecture of the Lockne system],
)

Specifically, Lockne enables users to:

1. Launch an application with its traffic automatically routed through a VPN
2. Monitor which processes are generating network traffic
3. Dynamically redirect traffic based on process identity

== Thesis Structure

This thesis is organized as follows:

*Chapter 2: Objectives and Methodology* defines the specific goals of this work and the research methodology employed.

*Chapter 3: Literature Review* provides comprehensive background on the technologies underlying Lockne: the eBPF framework, the WireGuard VPN protocol, and the Rust programming language. It also analyzes existing solutions for per-application traffic control.

*Chapter 4: Practical Part* details the implementation of Lockne, including the system architecture, the eBPF programs, and the userspace control plane.

*Chapter 5: Results and Discussion* presents performance measurements and evaluates the system against its design objectives.

*Chapter 6: Conclusion* summarizes the contributions, discusses limitations, and outlines directions for future work.


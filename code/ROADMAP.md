# Lockne Development Roadmap

This document outlines the planned features in priority order.

## Phase 1: Core Process Tracking ✅ DONE

- [x] Basic TC egress classifier
- [x] Socket cookie extraction
- [x] eBPF hash map for socket->PID mapping
- [x] Cgroup program to track socket creation
- [x] Userspace loader
- [x] Logging infrastructure
- [x] Basic tests
- [x] Code refactoring and documentation
- [x] Process launcher mode (`lockne run <program>`)
- [x] TUI interface with live statistics
- [x] Modular architecture (separate modules for config, loader, logger, runner, ui)

## Phase 2: Actual Packet Redirection 🔄 NEXT

This is the next major milestone - actually redirecting packets to WireGuard!

### Step 1: Policy Map
- [ ] Define a policy structure in `lockne-common`:
  ```rust
  pub struct Policy {
      pub pid: Pid,
      pub action: PolicyAction,
  }
  
  pub enum PolicyAction {
      Allow,              // Let packet through normally
      Redirect(u32),      // Redirect to interface with this ifindex
  }
  ```
- [ ] Add a `POLICY_MAP` in the eBPF code: `HashMap<Pid, PolicyAction>`
- [ ] Create functions in `loader.rs` to add/remove policies from userspace

### Step 2: Interface Index Lookup
- [ ] Add CLI option for WireGuard interface name (e.g., `--vpn-interface wg0`)
- [ ] Add function to get interface index from name:
  ```rust
  fn get_interface_index(name: &str) -> Result<u32>;
  ```
- [ ] Store the WireGuard interface index in the eBPF program

### Step 3: Implement bpf_redirect()
- [ ] Modify the TC classifier in `lockne-ebpf/src/main.rs`:
  ```rust
  // After looking up PID:
  if let Some(action) = unsafe { POLICY_MAP.get(&pid) } {
      match action {
          PolicyAction::Redirect(ifindex) => {
              return unsafe { bpf_redirect(*ifindex, 0) };
          }
          PolicyAction::Allow => {
              return Ok(TC_ACT_PIPE);
          }
      }
  }
  ```
  
### Step 4: Userspace Control Interface
- [ ] Add CLI commands:
  ```bash
  lockne add-policy --pid 1234 --action redirect
  lockne remove-policy --pid 1234
  lockne list-policies
  ```
- [ ] Implement policy management in `main.rs` or new `policy.rs` module

### Step 5: Testing
- [ ] Create test script that:
  1. Sets up WireGuard interface
  2. Starts lockne
  3. Adds policy for a test process
  4. Verifies traffic goes through WireGuard
- [ ] Document the testing process

## Phase 3: Map Cleanup and Lifecycle Management

- [ ] Add socket close tracking (kprobe on `tcp_close` or `sock_release`)
- [ ] Remove entries from SOCKET_PID_MAP when sockets close
- [ ] Add map statistics (number of tracked sockets, etc.)
- [ ] Add cleanup on program exit

## Phase 4: IPv6 Support

- [ ] Add IPv6 packet parsing in TC classifier
- [ ] Add `lockne_connect6` cgroup program for IPv6
- [ ] Update policy and map structures to handle both IPv4 and IPv6
- [ ] Test with IPv6 traffic

## Phase 5: Process Hierarchy Tracking

- [ ] Track process creation (kprobe on `fork`, `clone`)
- [ ] Maintain parent-child relationships
- [ ] Automatically inherit policies from parent to child
- [ ] Add CLI to view process trees

## Phase 6: Advanced Features

- [ ] UDP support (currently only tracks TCP connections)
- [ ] Per-application bandwidth monitoring
- [ ] Automatic policy based on executable path (not just PID)
- [ ] Integration with systemd for auto-start
- [ ] Web UI for policy management
- [ ] Performance benchmarking suite

## Phase 7: Production Readiness

- [ ] Comprehensive error handling
- [ ] Graceful degradation when maps are full
- [ ] Security audit of eBPF code
- [ ] Package for distribution (deb, rpm)
- [ ] Complete user documentation
- [ ] Performance tuning

## How to Use This Roadmap

1. Pick an item from "Phase 2" (the current phase)
2. Break it down into smaller tasks if needed
3. Implement it with tests
4. Write about it in the thesis
5. Commit with a clear message
6. Move to the next item

## Estimated Timeline

- **Phase 2**: 1-2 weeks (this is the critical one for thesis)
- **Phase 3**: 3-5 days
- **Phase 4**: 1 week
- **Phase 5**: 1-2 weeks
- **Phase 6+**: Future work (beyond thesis scope)

## For Your Thesis

**Minimum viable thesis**: Complete Phase 2
- This demonstrates the full concept works
- You can show packets being redirected based on process
- Gives you lots to write about

**Strong thesis**: Complete Phase 2 + 3
- Shows you can handle edge cases (cleanup)
- More robust implementation
- Better for evaluation section

**Excellent thesis**: Complete Phase 2 + 3 + 4
- Full IPv4 and IPv6 support
- Production-ready foundation
- Extensive evaluation possibilities
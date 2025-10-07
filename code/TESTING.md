# Testing Lockne

This document explains how to run the tests for Lockne.

## Unit Tests

Basic tests that don't require root or special permissions:

```bash
cd code
cargo test
```

This runs:
- Type tests for the common library
- Build verification tests
- eBPF compilation tests

## Integration Tests (Requires Root)

Some tests actually load eBPF programs and need root permissions:

### Test eBPF Loading

This verifies that the eBPF programs can be loaded:

```bash
cd code
sudo -E cargo test --test integration_test test_ebpf_loading -- --ignored --nocapture
```

### Test Process Tracking

This is a full integration test that:
1. Loads both eBPF programs
2. Attaches them to the network interface and cgroup
3. Makes an actual HTTP request with curl
4. Verifies everything works without crashing

```bash
cd code
sudo -E cargo test --test integration_test test_process_tracking -- --ignored --nocapture
```

**Note:** These tests use the `lo` (loopback) interface for safety.

## Manual Verification

### Method 1: Process Launcher Mode (Recommended)

1. Build and run lockne with a specific program:
```bash
cd code
cargo build --release
sudo -E RUST_LOG=info ./target/release/lockne run curl http://example.com
```

2. Check the output. You should see:
```
Launching program: curl
Started process with PID: 166985
Tracked socket cookie=XXXXX for pid=166985
74 10.0.0.70 ... cookie=XXXXX pid=166985
```

### Method 2: TUI Mode

1. Run with TUI for live statistics:
```bash
sudo ./target/release/lockne run curl http://example.com --tui
```

2. The TUI will show:
- Live packet count
- Connections tracked
- Unique PIDs seen
- Scrolling log view

### Method 3: Monitor Mode

1. Build and run lockne in monitor mode:
```bash
cd code
cargo build --release
sudo -E RUST_LOG=info ./target/release/lockne monitor --iface eno1
```

2. In another terminal, make HTTP requests:
```bash
curl http://example.com
```

3. Check the lockne output. You should see:
```
[INFO  lockne] Tracked socket cookie=XXXXX for pid=YYYYY
[INFO  lockne] 74 10.0.0.70 ... cookie=XXXXX pid=YYYYY
```

The PID (YYYYY) should match the PID of your curl process.

## Verifying a Specific PID

1. Run lockne in one terminal
2. In another terminal:
```bash
# Get the PID before making request
curl http://example.com & 
CURL_PID=$!
echo "Curl PID: $CURL_PID"
wait
```

3. Check lockne output for that specific PID

## Cleanup

If tests fail or hang, cleanup with:

```bash
sudo pkill -9 lockne
sudo tc qdisc del dev eno1 clsact
sudo tc qdisc del dev lo clsact
```
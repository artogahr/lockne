#!/bin/bash
# Script to verify process tracking is working

set -e

echo "=== Lockne Process Tracking Verification ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Error: This script must be run with sudo"
    echo "Usage: sudo ./verify_tracking.sh"
    exit 1
fi

# Cleanup any previous runs
echo "Step 1: Cleaning up previous instances..."
pkill -9 lockne 2>/dev/null || true
tc qdisc del dev eno1 clsact 2>/dev/null || true
sleep 1

# Build
echo "Step 2: Building lockne..."
cargo build --release --quiet 2>&1 | grep -v "warning:" || true

# Start lockne in background
echo "Step 3: Starting lockne..."
RUST_LOG=info ./target/release/lockne --iface eno1 > /tmp/lockne_verify.log 2>&1 &
LOCKNE_PID=$!
echo "   Lockne started with PID: $LOCKNE_PID"

# Wait for it to fully attach
echo "Step 4: Waiting for programs to attach..."
sleep 2

# Now make NEW connections that will be tracked
echo "Step 5: Making NEW HTTP request (after lockne started)..."
curl -s http://example.com > /dev/null &
CURL_PID=$!
echo "   Curl running with PID: $CURL_PID"

# Wait for curl to complete
wait $CURL_PID 2>/dev/null || true
sleep 1

# Stop lockne
echo "Step 6: Stopping lockne..."
kill $LOCKNE_PID 2>/dev/null || true
sleep 1

# Check results
echo ""
echo "=== Checking Results ==="
echo ""

# Show what we tracked
TRACKED=$(grep "Tracked socket cookie=" /tmp/lockne_verify.log | wc -l)
echo "Total socket connections tracked: $TRACKED"

# Check for our curl PID
if grep -q "pid=$CURL_PID" /tmp/lockne_verify.log; then
    echo "✓ SUCCESS! Found packets from curl (PID $CURL_PID)"
    echo ""
    echo "Sample output:"
    grep "pid=$CURL_PID" /tmp/lockne_verify.log | head -3
    echo ""
    PACKET_COUNT=$(grep -c "pid=$CURL_PID" /tmp/lockne_verify.log)
    echo "Total packets from curl: $PACKET_COUNT"
else
    echo "✗ FAILED - Did not find packets from curl (PID $CURL_PID)"
    echo ""
    echo "All tracked PIDs:"
    grep "Tracked socket" /tmp/lockne_verify.log || echo "None"
    echo ""
    echo "Full log:"
    cat /tmp/lockne_verify.log
fi

# Cleanup
tc qdisc del dev eno1 clsact 2>/dev/null || true

echo ""
echo "=== Verification Complete ==="
echo ""
echo "Key point: Connections made BEFORE lockne starts will show 'pid=unknown'"
echo "           Connections made AFTER lockne starts will show the actual PID"
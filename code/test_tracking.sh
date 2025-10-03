#!/bin/bash
# Simple test script to verify process tracking works

set -e

echo "=== Lockne Process Tracking Test ==="
echo ""

# Cleanup any previous runs
echo "[1/5] Cleaning up previous instances..."
sudo pkill -9 lockne 2>/dev/null || true
sudo tc qdisc del dev eno1 clsact 2>/dev/null || true
sleep 1

# Build if needed
echo "[2/5] Building lockne..."
cd "$(dirname "$0")"
cargo build --release --quiet

# Start lockne in background, capturing output
echo "[3/5] Starting lockne..."
sudo -E RUST_LOG=info ./target/release/lockne --iface eno1 > /tmp/lockne_test.log 2>&1 &
LOCKNE_PID=$!
echo "    Lockne running with PID: $LOCKNE_PID"
sleep 2

# Make HTTP request and capture the curl PID
echo "[4/5] Making test HTTP request..."
curl -s http://example.com > /dev/null &
CURL_PID=$!
echo "    Curl running with PID: $CURL_PID"

# Wait for curl to finish
wait $CURL_PID 2>/dev/null || true
sleep 1

# Stop lockne
echo "[5/5] Stopping lockne..."
sudo kill $LOCKNE_PID 2>/dev/null || true
sleep 1

# Analyze results
echo ""
echo "=== Results ==="
echo ""
echo "Looking for packets from curl (PID: $CURL_PID)..."
echo ""

# Check if we tracked the curl PID
if grep -q "pid=$CURL_PID" /tmp/lockne_test.log; then
    echo "✓ SUCCESS! Found packets from curl process!"
    echo ""
    echo "Sample tracked packets:"
    grep "pid=$CURL_PID" /tmp/lockne_test.log | head -5
    echo ""
    echo "Total packets tracked from curl: $(grep -c "pid=$CURL_PID" /tmp/lockne_test.log)"
else
    echo "✗ FAILED - Did not find packets from curl"
    echo ""
    echo "Full log output:"
    cat /tmp/lockne_test.log
fi

# Cleanup
sudo tc qdisc del dev eno1 clsact 2>/dev/null || true

echo ""
echo "=== Test Complete ==="
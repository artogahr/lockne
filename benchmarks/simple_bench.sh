#!/usr/bin/env bash
# Simple Lockne Benchmarks - Easy to understand and reproduce
# Usage: sudo bash benchmarks/simple_bench.sh

LOCKNE="./code/target/release/lockne"
RUNS=50

echo "=============================================="
echo "LOCKNE SIMPLE BENCHMARKS"
echo "=============================================="
echo ""

# Cleanup function
cleanup() {
    pkill -9 lockne 2>/dev/null
    tc qdisc del dev lo clsact 2>/dev/null
    tc qdisc del dev eno1 clsact 2>/dev/null
}
trap cleanup EXIT

#----------------------------------------------
# TEST 1: Latency to remote server
#----------------------------------------------
echo "TEST 1: Remote HTTP Latency (example.com)"
echo "  Running $RUNS requests..."

cleanup

# Baseline
echo -n "  Baseline: "
for i in $(seq 1 $RUNS); do
    curl -o /dev/null -s -w "%{time_total}\n" http://example.com
done | sort -n | awk '{a[NR]=$1; s+=$1} END {print "median=" a[int(NR/2)] "s, mean=" s/NR "s"}'

# With Lockne
$LOCKNE monitor --iface eno1 >/dev/null 2>&1 &
sleep 2
echo -n "  Lockne:   "
for i in $(seq 1 $RUNS); do
    curl -o /dev/null -s -w "%{time_total}\n" http://example.com
done | sort -n | awk '{a[NR]=$1; s+=$1} END {print "median=" a[int(NR/2)] "s, mean=" s/NR "s"}'

cleanup
echo ""

#----------------------------------------------
# TEST 2: Startup overhead (run mode)
#----------------------------------------------
echo "TEST 2: Startup Overhead (lockne run)"
echo "  Timing 10 runs of 'lockne run curl'..."

times=""
for i in $(seq 1 10); do
    START=$(date +%s.%N)
    $LOCKNE run curl -s -o /dev/null http://example.com 2>/dev/null
    END=$(date +%s.%N)
    t=$(echo "$END - $START" | bc)
    times="$times$t\n"
    tc qdisc del dev eno1 clsact 2>/dev/null
done

echo -e "$times" | grep -v '^$' | sort -n | awk '
{a[NR]=$1*1000; s+=$1*1000} 
END {printf "  Median: %.0fms, Mean: %.0fms\n", a[int(NR/2)], s/NR}'

echo ""

#----------------------------------------------
# TEST 3: CPU Usage
#----------------------------------------------
echo "TEST 3: CPU Usage During Load"
echo "  Generating 500 requests while monitoring CPU..."

cleanup
$LOCKNE monitor --iface eno1 >/dev/null 2>&1 &
LPID=$!
sleep 1

# Generate load in background
(for i in $(seq 1 500); do curl -s http://example.com >/dev/null; done) &
LOADPID=$!

# Sample CPU 5 times
cpu_samples=""
for i in $(seq 1 5); do
    cpu=$(ps -p $LPID -o %cpu= 2>/dev/null || echo "0")
    cpu_samples="$cpu_samples$cpu\n"
    sleep 1
done

wait $LOADPID 2>/dev/null
cleanup

echo -e "$cpu_samples" | grep -v '^$' | awk '{s+=$1} END {printf "  Lockne process CPU: %.1f%% average\n", s/NR}'

echo ""
echo "=============================================="
echo "DONE"
echo "=============================================="

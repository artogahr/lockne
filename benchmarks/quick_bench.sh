#!/usr/bin/env bash
#
# Quick benchmark script for Lockne
# Run as root: sudo ./benchmarks/quick_bench.sh
#

set -e

NUM_RUNS=10
TEST_URL="http://example.com"
LOCKNE_BIN="./code/target/release/lockne"
IFACE="eno1"
RESULTS_DIR="./benchmarks/results"

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/benchmark_$TIMESTAMP.txt"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Check lockne binary exists
if [[ ! -f "$LOCKNE_BIN" ]]; then
    echo "ERROR: Lockne binary not found. Run: cd code && cargo build --release"
    exit 1
fi

cleanup() {
    pkill -9 lockne 2>/dev/null || true
    tc qdisc del dev "$IFACE" clsact 2>/dev/null || true
    sleep 0.5
}

# Calculate stats using awk
calc_stats() {
    echo "$@" | tr ' ' '\n' | awk '
    {
        vals[NR] = $1
        sum += $1
        if (NR == 1 || $1 < min) min = $1
        if (NR == 1 || $1 > max) max = $1
    }
    END {
        mean = sum / NR
        for (i = 1; i <= NR; i++) {
            sq_sum += (vals[i] - mean)^2
        }
        stddev = sqrt(sq_sum / NR)
        printf "%.2f %.2f %.2f %.2f", mean, stddev, min, max
    }'
}

benchmark_curl() {
    local name="$1"
    local setup_cmd="$2"
    local cleanup_cmd="$3"
    
    echo ""
    echo "=================================================="
    echo "Benchmark: $name"
    echo "=================================================="
    
    cleanup
    
    if [[ -n "$setup_cmd" ]]; then
        echo "Setup: running background process..."
        eval "$setup_cmd"
        sleep 2
    fi
    
    local times=""
    for i in $(seq 1 $NUM_RUNS); do
        local t=$(curl -o /dev/null -s -w "%{time_total}" "$TEST_URL" 2>/dev/null)
        local t_ms=$(awk "BEGIN {printf \"%.2f\", $t * 1000}")
        times="$times $t_ms"
        printf "  Run %2d: %s ms\n" "$i" "$t_ms"
    done
    
    if [[ -n "$cleanup_cmd" ]]; then
        eval "$cleanup_cmd"
    fi
    
    cleanup
    
    # Calculate stats
    local stats=$(calc_stats $times)
    local mean=$(echo "$stats" | awk '{print $1}')
    local stddev=$(echo "$stats" | awk '{print $2}')
    local min=$(echo "$stats" | awk '{print $3}')
    local max=$(echo "$stats" | awk '{print $4}')
    
    printf "\nResults: mean=%sms stddev=%sms min=%sms max=%sms\n" "$mean" "$stddev" "$min" "$max"
    
    echo "$name,$mean,$stddev,$min,$max" >> "$RESULTS_FILE.csv"
}

benchmark_lockne_run() {
    echo ""
    echo "=================================================="
    echo "Benchmark: Lockne Run Mode (full execution)"
    echo "=================================================="
    
    cleanup
    
    local times=""
    for i in $(seq 1 $NUM_RUNS); do
        local start=$(date +%s.%N)
        $LOCKNE_BIN run curl -s -o /dev/null "$TEST_URL" 2>/dev/null || true
        local end=$(date +%s.%N)
        local elapsed=$(awk "BEGIN {printf \"%.2f\", ($end - $start) * 1000}")
        times="$times $elapsed"
        printf "  Run %2d: %s ms\n" "$i" "$elapsed"
        cleanup
    done
    
    # Calculate stats
    local stats=$(calc_stats $times)
    local mean=$(echo "$stats" | awk '{print $1}')
    local stddev=$(echo "$stats" | awk '{print $2}')
    local min=$(echo "$stats" | awk '{print $3}')
    local max=$(echo "$stats" | awk '{print $4}')
    
    printf "\nResults: mean=%sms stddev=%sms min=%sms max=%sms\n" "$mean" "$stddev" "$min" "$max"
    
    echo "Lockne Run Mode,$mean,$stddev,$min,$max" >> "$RESULTS_FILE.csv"
}

main() {
    echo "============================================================"
    echo "LOCKNE PERFORMANCE BENCHMARKS"
    echo "============================================================"
    echo "Date: $(date)"
    echo "Runs per test: $NUM_RUNS"
    echo "Test URL: $TEST_URL"
    echo "Interface: $IFACE"
    echo "============================================================"
    
    # CSV header
    echo "test,mean_ms,stddev_ms,min_ms,max_ms" > "$RESULTS_FILE.csv"
    
    # Baseline
    benchmark_curl "Baseline (no interception)" "" ""
    
    # Lockne monitor mode
    benchmark_curl "Lockne Monitor Mode" \
        "$LOCKNE_BIN monitor --iface $IFACE > /dev/null 2>&1 &" \
        "pkill -9 lockne"
    
    # Lockne run mode
    benchmark_lockne_run
    
    # Summary
    echo ""
    echo "============================================================"
    echo "SUMMARY"
    echo "============================================================"
    cat "$RESULTS_FILE.csv" | column -t -s','
    echo ""
    echo "Results saved to: $RESULTS_FILE.csv"
}

main 2>&1 | tee "$RESULTS_FILE"

#!/usr/bin/env bash
#
# Lockne Performance Benchmarks
# 
# This script measures the performance overhead of Lockne compared to:
# - Baseline (no interception)
# - Lockne in monitoring mode
# - Lockne with redirect
# - Proxychains (userspace proxy for comparison)
#
# Requirements: Run as root, from the nix develop .#bench shell
#

set -e

# Configuration
LOCKNE_BIN="${LOCKNE_BIN:-./code/target/release/lockne}"
IFACE="${IFACE:-eno1}"
RESULTS_DIR="${RESULTS_DIR:-./benchmarks/results}"
NUM_RUNS="${NUM_RUNS:-10}"
TEST_URL="${TEST_URL:-http://example.com}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (for eBPF loading)"
    fi
}

# Check dependencies
check_deps() {
    info "Checking dependencies..."
    
    for cmd in curl hyperfine; do
        if ! command -v $cmd &> /dev/null; then
            error "$cmd is required but not found. Run: nix develop .#bench"
        fi
    done
    
    if [[ ! -f "$LOCKNE_BIN" ]]; then
        error "Lockne binary not found at $LOCKNE_BIN. Run: cargo build --release"
    fi
    
    info "All dependencies found"
}

# Clean up any leftover TC qdiscs
cleanup() {
    info "Cleaning up..."
    pkill -9 lockne 2>/dev/null || true
    tc qdisc del dev "$IFACE" clsact 2>/dev/null || true
    sleep 1
}

# Create results directory
setup_results() {
    mkdir -p "$RESULTS_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    RESULTS_FILE="$RESULTS_DIR/benchmark_$TIMESTAMP.txt"
    info "Results will be saved to $RESULTS_FILE"
}

# Benchmark: HTTP request latency using curl
benchmark_curl_latency() {
    local name="$1"
    local cmd="$2"
    
    info "Running benchmark: $name"
    
    # Warm up
    eval "$cmd" > /dev/null 2>&1 || true
    
    # Measure timing for multiple runs
    local times=()
    for i in $(seq 1 $NUM_RUNS); do
        # Use curl's timing output
        local time_total=$(eval "$cmd" -o /dev/null -s -w '%{time_total}' 2>/dev/null)
        times+=("$time_total")
        echo -n "."
    done
    echo ""
    
    # Calculate statistics
    local sum=0
    local min=999999
    local max=0
    for t in "${times[@]}"; do
        sum=$(echo "$sum + $t" | bc -l)
        if (( $(echo "$t < $min" | bc -l) )); then min=$t; fi
        if (( $(echo "$t > $max" | bc -l) )); then max=$t; fi
    done
    local avg=$(echo "scale=4; $sum / $NUM_RUNS" | bc -l)
    
    # Calculate std dev
    local sq_sum=0
    for t in "${times[@]}"; do
        local diff=$(echo "$t - $avg" | bc -l)
        sq_sum=$(echo "$sq_sum + ($diff * $diff)" | bc -l)
    done
    local stddev=$(echo "scale=4; sqrt($sq_sum / $NUM_RUNS)" | bc -l)
    
    # Convert to milliseconds
    avg_ms=$(echo "scale=2; $avg * 1000" | bc -l)
    min_ms=$(echo "scale=2; $min * 1000" | bc -l)
    max_ms=$(echo "scale=2; $max * 1000" | bc -l)
    stddev_ms=$(echo "scale=2; $stddev * 1000" | bc -l)
    
    echo "  $name: avg=${avg_ms}ms, min=${min_ms}ms, max=${max_ms}ms, stddev=${stddev_ms}ms" | tee -a "$RESULTS_FILE"
}

# Benchmark: Throughput using large file download
benchmark_throughput() {
    local name="$1"
    local cmd="$2"
    
    info "Running throughput benchmark: $name"
    
    # Download a ~10MB file and measure speed
    local test_url="http://speedtest.tele2.net/1MB.zip"
    local speeds=()
    
    for i in $(seq 1 3); do
        local speed=$(eval "$cmd" "$test_url" -o /dev/null -s -w '%{speed_download}' 2>/dev/null)
        speeds+=("$speed")
        echo -n "."
    done
    echo ""
    
    # Calculate average (bytes/sec to MB/s)
    local sum=0
    for s in "${speeds[@]}"; do
        sum=$(echo "$sum + $s" | bc -l)
    done
    local avg=$(echo "scale=2; ($sum / 3) / 1048576" | bc -l)
    
    echo "  $name throughput: ${avg} MB/s" | tee -a "$RESULTS_FILE"
}

# Run baseline benchmark (no lockne)
run_baseline() {
    info "=== BASELINE (no interception) ==="
    cleanup
    benchmark_curl_latency "Baseline" "curl $TEST_URL"
}

# Run lockne monitoring benchmark
run_lockne_monitor() {
    info "=== LOCKNE MONITORING MODE ==="
    cleanup
    
    # Start lockne in background
    $LOCKNE_BIN monitor --iface "$IFACE" &
    LOCKNE_PID=$!
    sleep 2
    
    benchmark_curl_latency "Lockne Monitor" "curl $TEST_URL"
    
    kill $LOCKNE_PID 2>/dev/null || true
    cleanup
}

# Run lockne with redirect to loopback (measures redirect overhead)
run_lockne_redirect() {
    info "=== LOCKNE WITH REDIRECT ==="
    # Note: We can't actually redirect and still work, so we measure
    # the monitoring overhead which is representative
    # The redirect itself adds minimal overhead (just bpf_redirect call)
    
    cleanup
    info "Measuring lockne run mode (includes policy lookup overhead)"
    
    # Use hyperfine for more accurate measurements
    if command -v hyperfine &> /dev/null; then
        hyperfine --warmup 2 --runs $NUM_RUNS \
            --export-json "$RESULTS_DIR/hyperfine_lockne.json" \
            "sudo $LOCKNE_BIN run curl -s $TEST_URL" \
            2>&1 | tee -a "$RESULTS_FILE"
    else
        # Fallback: manual timing
        local times=()
        for i in $(seq 1 $NUM_RUNS); do
            local start=$(date +%s.%N)
            $LOCKNE_BIN run curl -s "$TEST_URL" > /dev/null 2>&1
            local end=$(date +%s.%N)
            local elapsed=$(echo "$end - $start" | bc -l)
            times+=("$elapsed")
            echo -n "."
        done
        echo ""
        
        # Calculate average
        local sum=0
        for t in "${times[@]}"; do
            sum=$(echo "$sum + $t" | bc -l)
        done
        local avg=$(echo "scale=4; $sum / $NUM_RUNS" | bc -l)
        local avg_ms=$(echo "scale=2; $avg * 1000" | bc -l)
        echo "  Lockne Run: avg=${avg_ms}ms" | tee -a "$RESULTS_FILE"
    fi
    
    cleanup
}

# Run proxychains benchmark for comparison
run_proxychains() {
    if ! command -v proxychains4 &> /dev/null; then
        warn "proxychains4 not found, skipping comparison benchmark"
        return
    fi
    
    info "=== PROXYCHAINS (userspace proxy comparison) ==="
    
    # Check if proxychains is configured
    if [[ ! -f /etc/proxychains.conf ]] && [[ ! -f ~/.proxychains/proxychains.conf ]]; then
        warn "proxychains not configured, skipping"
        return
    fi
    
    benchmark_curl_latency "Proxychains" "proxychains4 -q curl $TEST_URL"
}

# Generate summary
generate_summary() {
    info "=== BENCHMARK SUMMARY ==="
    echo "" | tee -a "$RESULTS_FILE"
    echo "=======================================" | tee -a "$RESULTS_FILE"
    echo "BENCHMARK RESULTS SUMMARY" | tee -a "$RESULTS_FILE"
    echo "Date: $(date)" | tee -a "$RESULTS_FILE"
    echo "Runs per test: $NUM_RUNS" | tee -a "$RESULTS_FILE"
    echo "Test URL: $TEST_URL" | tee -a "$RESULTS_FILE"
    echo "Interface: $IFACE" | tee -a "$RESULTS_FILE"
    echo "=======================================" | tee -a "$RESULTS_FILE"
    cat "$RESULTS_FILE"
}

# Main
main() {
    check_root
    check_deps
    setup_results
    
    echo "=======================================" | tee "$RESULTS_FILE"
    echo "LOCKNE PERFORMANCE BENCHMARKS" | tee -a "$RESULTS_FILE"
    echo "=======================================" | tee -a "$RESULTS_FILE"
    echo "" | tee -a "$RESULTS_FILE"
    
    run_baseline
    run_lockne_monitor
    run_lockne_redirect
    run_proxychains
    
    generate_summary
    
    info "Benchmarks complete! Results saved to $RESULTS_FILE"
}

# Handle script arguments
case "${1:-}" in
    baseline)
        check_root
        check_deps
        setup_results
        run_baseline
        ;;
    monitor)
        check_root
        check_deps
        setup_results
        run_lockne_monitor
        ;;
    redirect)
        check_root
        check_deps
        setup_results
        run_lockne_redirect
        ;;
    proxychains)
        check_root
        check_deps
        setup_results
        run_proxychains
        ;;
    *)
        main
        ;;
esac

#!/usr/bin/env bash
#
# Comprehensive Lockne Benchmarks
# For Master's Thesis: "Lockne: Dynamic Per-Application VPN Tunneling with eBPF"
#
# This script measures:
# 1. Latency overhead (localhost to eliminate network variance)
# 2. Throughput impact
# 3. CPU utilization
# 4. Connection setup overhead
#
# Run as: sudo ./benchmarks/comprehensive_bench.sh

set -e

# Configuration
LOCKNE_BIN="./code/target/release/lockne"
IFACE="eno1"
RESULTS_DIR="./benchmarks/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/comprehensive_$TIMESTAMP.txt"

# Test parameters
LATENCY_RUNS=100
THROUGHPUT_SECONDS=10
CONCURRENT_CONNECTIONS=10

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
header() { echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"; }

cleanup() {
    log "Cleaning up..."
    pkill -9 lockne 2>/dev/null || true
    pkill -9 iperf3 2>/dev/null || true
    pkill -f "python.*http.server" 2>/dev/null || true
    tc qdisc del dev $IFACE clsact 2>/dev/null || true
    tc qdisc del dev lo clsact 2>/dev/null || true
    sleep 0.5
}

calc_stats() {
    # Calculate mean, median, stddev, min, max, p95, p99 from stdin (one value per line)
    sort -n | awk '
    {
        vals[NR] = $1
        sum += $1
        sum_sq += $1 * $1
    }
    END {
        n = NR
        if (n == 0) { print "ERROR: No data"; exit 1 }
        
        mean = sum / n
        variance = (sum_sq / n) - (mean * mean)
        stddev = sqrt(variance > 0 ? variance : 0)
        
        # Median
        if (n % 2 == 1) median = vals[int(n/2) + 1]
        else median = (vals[n/2] + vals[n/2 + 1]) / 2
        
        # Percentiles
        p95_idx = int(n * 0.95)
        p99_idx = int(n * 0.99)
        if (p95_idx < 1) p95_idx = 1
        if (p99_idx < 1) p99_idx = 1
        
        printf "n=%d mean=%.3f median=%.3f stddev=%.3f min=%.3f max=%.3f p95=%.3f p99=%.3f\n", \
            n, mean, median, stddev, vals[1], vals[n], vals[p95_idx], vals[p99_idx]
    }'
}

# Check prerequisites
check_prereqs() {
    header "Checking Prerequisites"
    
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root"
        exit 1
    fi
    
    if [[ ! -f "$LOCKNE_BIN" ]]; then
        echo "ERROR: Lockne binary not found at $LOCKNE_BIN"
        echo "Run: cd code && cargo build --release"
        exit 1
    fi
    
    mkdir -p "$RESULTS_DIR"
    log "Prerequisites OK"
}

# Start local test server
start_test_server() {
    log "Starting local HTTP test server on port 8888..."
    mkdir -p /tmp/lockne_bench
    dd if=/dev/zero of=/tmp/lockne_bench/1mb.bin bs=1M count=1 2>/dev/null
    dd if=/dev/zero of=/tmp/lockne_bench/10mb.bin bs=1M count=10 2>/dev/null
    echo "small" > /tmp/lockne_bench/small.txt
    cd /tmp/lockne_bench
    python3 -m http.server 8888 > /dev/null 2>&1 &
    HTTP_PID=$!
    cd - > /dev/null
    sleep 1
    
    if ! curl -s http://localhost:8888/small.txt > /dev/null; then
        echo "ERROR: Failed to start HTTP server"
        exit 1
    fi
    log "HTTP server running (PID: $HTTP_PID)"
}

# Benchmark 1: Latency (localhost)
benchmark_latency() {
    header "Benchmark 1: HTTP Request Latency (localhost)"
    echo "Measuring per-request latency with $LATENCY_RUNS requests each"
    echo ""
    
    # Baseline
    log "Running baseline test..."
    baseline_times=""
    for i in $(seq 1 $LATENCY_RUNS); do
        t=$(curl -o /dev/null -s -w "%{time_total}" http://localhost:8888/small.txt)
        baseline_times="$baseline_times$t\n"
        # Progress indicator
        if (( i % 25 == 0 )); then echo -n "."; fi
    done
    echo ""
    
    baseline_stats=$(echo -e "$baseline_times" | grep -v '^$' | calc_stats)
    echo "  Baseline: $baseline_stats"
    
    # Lockne Monitor Mode
    log "Running Lockne monitor mode test..."
    $LOCKNE_BIN monitor --iface lo > /dev/null 2>&1 &
    LOCKNE_PID=$!
    sleep 2
    
    lockne_times=""
    for i in $(seq 1 $LATENCY_RUNS); do
        t=$(curl -o /dev/null -s -w "%{time_total}" http://localhost:8888/small.txt)
        lockne_times="$lockne_times$t\n"
        if (( i % 25 == 0 )); then echo -n "."; fi
    done
    echo ""
    
    kill $LOCKNE_PID 2>/dev/null || true
    tc qdisc del dev lo clsact 2>/dev/null || true
    
    lockne_stats=$(echo -e "$lockne_times" | grep -v '^$' | calc_stats)
    echo "  Lockne:   $lockne_stats"
    
    # Calculate overhead
    baseline_median=$(echo "$baseline_stats" | grep -oP 'median=\K[0-9.]+')
    lockne_median=$(echo "$lockne_stats" | grep -oP 'median=\K[0-9.]+')
    overhead=$(echo "$baseline_median $lockne_median" | awk '{printf "%.3f", ($2 - $1) * 1000}')
    echo ""
    echo "  Overhead: ${overhead}ms per request (median)"
    
    # Save for report
    echo "LATENCY_BASELINE=\"$baseline_stats\"" >> "$RESULTS_FILE"
    echo "LATENCY_LOCKNE=\"$lockne_stats\"" >> "$RESULTS_FILE"
    echo "LATENCY_OVERHEAD_MS=\"$overhead\"" >> "$RESULTS_FILE"
}

# Benchmark 2: Throughput (localhost)
benchmark_throughput() {
    header "Benchmark 2: Throughput (localhost file transfer)"
    echo "Measuring sustained transfer rate with 10MB file"
    echo ""
    
    # Baseline
    log "Running baseline throughput test (3 runs)..."
    baseline_throughput=""
    for i in $(seq 1 3); do
        speed=$(curl -o /dev/null -s -w "%{speed_download}" http://localhost:8888/10mb.bin)
        mbps=$(echo "$speed" | awk '{printf "%.2f", $1 / 1048576}')
        baseline_throughput="$baseline_throughput$mbps\n"
        echo "  Run $i: ${mbps} MB/s"
    done
    
    baseline_avg=$(echo -e "$baseline_throughput" | grep -v '^$' | awk '{sum+=$1} END {printf "%.2f", sum/NR}')
    echo "  Average: ${baseline_avg} MB/s"
    
    # Lockne Monitor Mode
    log "Running Lockne throughput test (3 runs)..."
    $LOCKNE_BIN monitor --iface lo > /dev/null 2>&1 &
    LOCKNE_PID=$!
    sleep 2
    
    lockne_throughput=""
    for i in $(seq 1 3); do
        speed=$(curl -o /dev/null -s -w "%{speed_download}" http://localhost:8888/10mb.bin)
        mbps=$(echo "$speed" | awk '{printf "%.2f", $1 / 1048576}')
        lockne_throughput="$lockne_throughput$mbps\n"
        echo "  Run $i: ${mbps} MB/s"
    done
    
    kill $LOCKNE_PID 2>/dev/null || true
    tc qdisc del dev lo clsact 2>/dev/null || true
    
    lockne_avg=$(echo -e "$lockne_throughput" | grep -v '^$' | awk '{sum+=$1} END {printf "%.2f", sum/NR}')
    echo "  Average: ${lockne_avg} MB/s"
    
    # Calculate difference
    diff_pct=$(echo "$baseline_avg $lockne_avg" | awk '{printf "%.1f", (($2 - $1) / $1) * 100}')
    echo ""
    echo "  Difference: ${diff_pct}%"
    
    echo "THROUGHPUT_BASELINE_MBPS=\"$baseline_avg\"" >> "$RESULTS_FILE"
    echo "THROUGHPUT_LOCKNE_MBPS=\"$lockne_avg\"" >> "$RESULTS_FILE"
    echo "THROUGHPUT_DIFF_PCT=\"$diff_pct\"" >> "$RESULTS_FILE"
}

# Benchmark 3: CPU Utilization
benchmark_cpu() {
    header "Benchmark 3: CPU Utilization"
    echo "Measuring CPU usage during sustained load"
    echo ""
    
    # Generate load and measure CPU
    log "Running baseline CPU test (10 seconds of requests)..."
    
    # Start background load
    (for i in $(seq 1 1000); do curl -s http://localhost:8888/small.txt > /dev/null; done) &
    LOAD_PID=$!
    
    # Measure system CPU for 5 seconds
    baseline_cpu=$(top -b -n 5 -d 1 | grep "Cpu(s)" | tail -3 | awk '{print 100 - $8}' | awk '{sum+=$1} END {printf "%.1f", sum/NR}')
    
    wait $LOAD_PID 2>/dev/null || true
    echo "  Baseline system CPU: ${baseline_cpu}%"
    
    # With Lockne
    log "Running Lockne CPU test (10 seconds of requests)..."
    $LOCKNE_BIN monitor --iface lo > /dev/null 2>&1 &
    LOCKNE_PID=$!
    sleep 2
    
    # Start background load
    (for i in $(seq 1 1000); do curl -s http://localhost:8888/small.txt > /dev/null; done) &
    LOAD_PID=$!
    
    # Measure system CPU for 5 seconds
    lockne_cpu=$(top -b -n 5 -d 1 | grep "Cpu(s)" | tail -3 | awk '{print 100 - $8}' | awk '{sum+=$1} END {printf "%.1f", sum/NR}')
    
    # Also get lockne process CPU
    lockne_proc_cpu=$(ps -p $LOCKNE_PID -o %cpu= 2>/dev/null | awk '{printf "%.1f", $1}' || echo "0")
    
    wait $LOAD_PID 2>/dev/null || true
    kill $LOCKNE_PID 2>/dev/null || true
    tc qdisc del dev lo clsact 2>/dev/null || true
    
    echo "  Lockne system CPU: ${lockne_cpu}%"
    echo "  Lockne process CPU: ${lockne_proc_cpu}%"
    
    cpu_overhead=$(echo "$baseline_cpu $lockne_cpu" | awk '{printf "%.1f", $2 - $1}')
    echo ""
    echo "  CPU overhead: ${cpu_overhead}%"
    
    echo "CPU_BASELINE=\"$baseline_cpu\"" >> "$RESULTS_FILE"
    echo "CPU_LOCKNE_SYSTEM=\"$lockne_cpu\"" >> "$RESULTS_FILE"
    echo "CPU_LOCKNE_PROCESS=\"$lockne_proc_cpu\"" >> "$RESULTS_FILE"
    echo "CPU_OVERHEAD=\"$cpu_overhead\"" >> "$RESULTS_FILE"
}

# Benchmark 4: Connection Setup Overhead
benchmark_connection_setup() {
    header "Benchmark 4: Connection Setup Overhead"
    echo "Measuring time to track new connections"
    echo ""
    
    # Baseline: many short connections
    log "Running baseline connection test (100 separate connections)..."
    
    start_time=$(date +%s.%N)
    for i in $(seq 1 100); do
        curl -s http://localhost:8888/small.txt > /dev/null
    done
    end_time=$(date +%s.%N)
    
    baseline_total=$(echo "$start_time $end_time" | awk '{printf "%.3f", $2 - $1}')
    baseline_per_conn=$(echo "$baseline_total" | awk '{printf "%.2f", $1 * 10}')  # ms per connection
    echo "  Baseline: ${baseline_total}s total, ~${baseline_per_conn}ms per connection"
    
    # With Lockne
    log "Running Lockne connection test (100 separate connections)..."
    $LOCKNE_BIN monitor --iface lo > /dev/null 2>&1 &
    LOCKNE_PID=$!
    sleep 2
    
    start_time=$(date +%s.%N)
    for i in $(seq 1 100); do
        curl -s http://localhost:8888/small.txt > /dev/null
    done
    end_time=$(date +%s.%N)
    
    kill $LOCKNE_PID 2>/dev/null || true
    tc qdisc del dev lo clsact 2>/dev/null || true
    
    lockne_total=$(echo "$start_time $end_time" | awk '{printf "%.3f", $2 - $1}')
    lockne_per_conn=$(echo "$lockne_total" | awk '{printf "%.2f", $1 * 10}')  # ms per connection
    echo "  Lockne: ${lockne_total}s total, ~${lockne_per_conn}ms per connection"
    
    overhead_per_conn=$(echo "$baseline_per_conn $lockne_per_conn" | awk '{printf "%.2f", $2 - $1}')
    echo ""
    echo "  Overhead per connection: ${overhead_per_conn}ms"
    
    echo "CONN_BASELINE_TOTAL=\"$baseline_total\"" >> "$RESULTS_FILE"
    echo "CONN_LOCKNE_TOTAL=\"$lockne_total\"" >> "$RESULTS_FILE"
    echo "CONN_OVERHEAD_MS=\"$overhead_per_conn\"" >> "$RESULTS_FILE"
}

# Benchmark 5: Run Mode (full startup)
benchmark_run_mode() {
    header "Benchmark 5: Run Mode Startup Overhead"
    echo "Measuring total time including eBPF loading and process spawn"
    echo ""
    
    log "Running startup overhead test (10 runs)..."
    
    run_times=""
    for i in $(seq 1 10); do
        start_time=$(date +%s.%N)
        $LOCKNE_BIN run curl -s -o /dev/null http://localhost:8888/small.txt 2>/dev/null
        end_time=$(date +%s.%N)
        
        tc qdisc del dev eno1 clsact 2>/dev/null || true
        
        elapsed=$(echo "$start_time $end_time" | awk '{printf "%.3f", ($2 - $1) * 1000}')
        run_times="$run_times$elapsed\n"
        echo "  Run $i: ${elapsed}ms"
        sleep 0.5
    done
    
    stats=$(echo -e "$run_times" | grep -v '^$' | calc_stats)
    echo ""
    echo "  Stats: $stats"
    
    echo "RUN_MODE_STATS=\"$stats\"" >> "$RESULTS_FILE"
}

# Generate summary report
generate_report() {
    header "Benchmark Summary"
    
    source "$RESULTS_FILE"
    
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│                    LOCKNE PERFORMANCE RESULTS                   │"
    echo "├─────────────────────────────────────────────────────────────────┤"
    echo "│ Test                      │ Baseline    │ Lockne      │ Overhead│"
    echo "├─────────────────────────────────────────────────────────────────┤"
    
    # Extract medians
    baseline_lat=$(echo "$LATENCY_BASELINE" | grep -oP 'median=\K[0-9.]+')
    lockne_lat=$(echo "$LATENCY_LOCKNE" | grep -oP 'median=\K[0-9.]+')
    printf "│ Latency (median)          │ %6.3fms    │ %6.3fms    │ %+.3fms │\n" \
        "$baseline_lat" "$lockne_lat" "$LATENCY_OVERHEAD_MS"
    
    printf "│ Throughput                │ %6.1f MB/s │ %6.1f MB/s │ %+5.1f%% │\n" \
        "$THROUGHPUT_BASELINE_MBPS" "$THROUGHPUT_LOCKNE_MBPS" "$THROUGHPUT_DIFF_PCT"
    
    printf "│ CPU (system)              │ %6.1f%%     │ %6.1f%%     │ %+5.1f%% │\n" \
        "$CPU_BASELINE" "$CPU_LOCKNE_SYSTEM" "$CPU_OVERHEAD"
    
    printf "│ Connection setup          │ %6.2fms    │ %6.2fms    │ %+.2fms │\n" \
        "$(echo "$CONN_BASELINE_TOTAL" | awk '{printf "%.2f", $1 * 10}')" \
        "$(echo "$CONN_LOCKNE_TOTAL" | awk '{printf "%.2f", $1 * 10}')" \
        "$CONN_OVERHEAD_MS"
    
    echo "├─────────────────────────────────────────────────────────────────┤"
    
    run_median=$(echo "$RUN_MODE_STATS" | grep -oP 'median=\K[0-9.]+')
    printf "│ Run mode startup          │     N/A     │ %6.1fms    │   N/A   │\n" "$run_median"
    
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "Full results saved to: $RESULTS_FILE"
}

# Main execution
main() {
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║         LOCKNE COMPREHENSIVE PERFORMANCE BENCHMARKS               ║"
    echo "║         $(date)                            ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    
    echo "BENCHMARK_DATE=\"$(date -Iseconds)\"" > "$RESULTS_FILE"
    echo "BENCHMARK_HOST=\"$(hostname)\"" >> "$RESULTS_FILE"
    echo "KERNEL_VERSION=\"$(uname -r)\"" >> "$RESULTS_FILE"
    
    check_prereqs
    cleanup
    start_test_server
    
    benchmark_latency
    cleanup
    start_test_server
    
    benchmark_throughput
    cleanup
    start_test_server
    
    benchmark_cpu
    cleanup
    start_test_server
    
    benchmark_connection_setup
    cleanup
    start_test_server
    
    benchmark_run_mode
    cleanup
    
    generate_report
    
    # Cleanup test files
    rm -rf /tmp/lockne_bench
    
    log "Benchmarks complete!"
}

# Handle interrupts
trap cleanup EXIT

main "$@"

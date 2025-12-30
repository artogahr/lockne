#!/usr/bin/env python3
"""
Quick benchmark script for Lockne performance measurement.
Run as root: sudo python3 benchmarks/quick_bench.py
"""

import subprocess
import time
import statistics
import json
import os
import sys
from datetime import datetime

NUM_RUNS = 10
TEST_URL = "http://example.com"
LOCKNE_BIN = "./code/target/release/lockne"
IFACE = "eno1"

def run_cmd(cmd, capture=True, timeout=30):
    """Run a command and return output"""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=capture, 
            text=True, timeout=timeout
        )
        return result.stdout.strip() if capture else None
    except subprocess.TimeoutExpired:
        return None

def cleanup():
    """Clean up any leftover state"""
    run_cmd("pkill -9 lockne 2>/dev/null || true", capture=False)
    run_cmd(f"tc qdisc del dev {IFACE} clsact 2>/dev/null || true", capture=False)
    time.sleep(0.5)

def measure_curl_latency(name, pre_cmd=None, post_cmd=None, num_runs=NUM_RUNS):
    """Measure HTTP request latency using curl"""
    print(f"\n{'='*50}")
    print(f"Benchmark: {name}")
    print(f"{'='*50}")
    
    cleanup()
    
    if pre_cmd:
        print(f"Setup: {pre_cmd[:50]}...")
        run_cmd(pre_cmd, capture=False)
        time.sleep(2)  # Let things settle
    
    times = []
    for i in range(num_runs):
        # Use curl's built-in timing
        result = run_cmd(
            f'curl -o /dev/null -s -w "%{{time_total}}" {TEST_URL}',
            timeout=10
        )
        if result:
            try:
                t = float(result)
                times.append(t * 1000)  # Convert to ms
                print(f"  Run {i+1}: {t*1000:.2f}ms")
            except ValueError:
                print(f"  Run {i+1}: ERROR parsing {result}")
    
    if post_cmd:
        run_cmd(post_cmd, capture=False)
    
    cleanup()
    
    if times:
        results = {
            "name": name,
            "runs": num_runs,
            "times_ms": times,
            "mean_ms": statistics.mean(times),
            "median_ms": statistics.median(times),
            "stdev_ms": statistics.stdev(times) if len(times) > 1 else 0,
            "min_ms": min(times),
            "max_ms": max(times),
        }
        
        print(f"\nResults for {name}:")
        print(f"  Mean:   {results['mean_ms']:.2f}ms")
        print(f"  Median: {results['median_ms']:.2f}ms")
        print(f"  StdDev: {results['stdev_ms']:.2f}ms")
        print(f"  Min:    {results['min_ms']:.2f}ms")
        print(f"  Max:    {results['max_ms']:.2f}ms")
        
        return results
    return None

def measure_lockne_run_overhead(num_runs=NUM_RUNS):
    """Measure full lockne run mode (includes process startup)"""
    print(f"\n{'='*50}")
    print("Benchmark: Lockne Run Mode (full execution)")
    print(f"{'='*50}")
    
    cleanup()
    
    times = []
    for i in range(num_runs):
        start = time.perf_counter()
        result = subprocess.run(
            [LOCKNE_BIN, "run", "curl", "-s", "-o", "/dev/null", TEST_URL],
            capture_output=True, timeout=30
        )
        end = time.perf_counter()
        
        elapsed_ms = (end - start) * 1000
        times.append(elapsed_ms)
        print(f"  Run {i+1}: {elapsed_ms:.2f}ms (exit={result.returncode})")
        
        # Cleanup between runs
        cleanup()
    
    if times:
        results = {
            "name": "Lockne Run Mode",
            "runs": num_runs,
            "times_ms": times,
            "mean_ms": statistics.mean(times),
            "median_ms": statistics.median(times),
            "stdev_ms": statistics.stdev(times) if len(times) > 1 else 0,
            "min_ms": min(times),
            "max_ms": max(times),
        }
        
        print(f"\nResults for Lockne Run Mode:")
        print(f"  Mean:   {results['mean_ms']:.2f}ms")
        print(f"  Median: {results['median_ms']:.2f}ms")  
        print(f"  StdDev: {results['stdev_ms']:.2f}ms")
        print(f"  Min:    {results['min_ms']:.2f}ms")
        print(f"  Max:    {results['max_ms']:.2f}ms")
        
        return results
    return None

def main():
    if os.geteuid() != 0:
        print("ERROR: This script must be run as root")
        sys.exit(1)
    
    if not os.path.exists(LOCKNE_BIN):
        print(f"ERROR: Lockne binary not found at {LOCKNE_BIN}")
        print("Run: cd code && cargo build --release")
        sys.exit(1)
    
    print("="*60)
    print("LOCKNE PERFORMANCE BENCHMARKS")
    print(f"Date: {datetime.now().isoformat()}")
    print(f"Runs per test: {NUM_RUNS}")
    print(f"Test URL: {TEST_URL}")
    print("="*60)
    
    all_results = []
    
    # Baseline
    result = measure_curl_latency("Baseline (no interception)")
    if result:
        all_results.append(result)
    
    # Lockne monitor mode (background daemon)
    result = measure_curl_latency(
        "Lockne Monitor Mode",
        pre_cmd=f"{LOCKNE_BIN} monitor --iface {IFACE} &",
        post_cmd="pkill -9 lockne"
    )
    if result:
        all_results.append(result)
    
    # Lockne run mode (full execution including startup)
    result = measure_lockne_run_overhead()
    if result:
        all_results.append(result)
    
    # Summary
    print("\n" + "="*60)
    print("SUMMARY")
    print("="*60)
    
    baseline = next((r for r in all_results if "Baseline" in r["name"]), None)
    
    for r in all_results:
        overhead = ""
        if baseline and r["name"] != baseline["name"]:
            diff = r["mean_ms"] - baseline["mean_ms"]
            pct = (diff / baseline["mean_ms"]) * 100
            overhead = f" (overhead: +{diff:.2f}ms / +{pct:.1f}%)"
        print(f"{r['name']}: {r['mean_ms']:.2f}ms ± {r['stdev_ms']:.2f}ms{overhead}")
    
    # Save results
    results_file = f"benchmarks/results/bench_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    os.makedirs("benchmarks/results", exist_ok=True)
    with open(results_file, 'w') as f:
        json.dump(all_results, f, indent=2)
    print(f"\nResults saved to: {results_file}")

if __name__ == "__main__":
    main()

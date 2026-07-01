#!/usr/bin/env python3
"""
Analyze Trinity Rust optimization benchmarks.
Extracts timing info from /usr/bin/time output and generates comparison plots.
"""

import os
import re
import csv
import sys
from pathlib import Path
from collections import defaultdict
from datetime import datetime

def parse_time_output(log_file):
    """Parse /usr/bin/time verbose output."""
    metrics = {}
    try:
        with open(log_file, 'r') as f:
            content = f.read()

            # Extract elapsed time
            match = re.search(r'Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): ([\d:]+\.[\d]+)', content)
            if match:
                time_str = match.group(1)
                metrics['elapsed'] = time_str
                # Try to convert to seconds for comparison
                parts = time_str.split(':')
                if len(parts) == 2:
                    mins, secs = parts
                    metrics['elapsed_seconds'] = float(mins) * 60 + float(secs)
                elif len(parts) == 3:
                    hours, mins, secs = parts
                    metrics['elapsed_seconds'] = float(hours) * 3600 + float(mins) * 60 + float(secs)

            # Extract maximum resident set size (peak memory)
            match = re.search(r'Maximum resident set size \(kbytes\): (\d+)', content)
            if match:
                metrics['max_rss_kb'] = int(match.group(1))

            # Extract CPU percentage
            match = re.search(r'Percent of CPU this job got: ([\d.]+)%', content)
            if match:
                metrics['cpu_percent'] = float(match.group(1))

            # Extract page faults
            match = re.search(r'Major \(requiring I/O\) page faults: (\d+)', content)
            if match:
                metrics['page_faults_major'] = int(match.group(1))

            # Extract user and system time
            match = re.search(r'User time \(seconds\): ([\d.]+)', content)
            if match:
                metrics['user_time'] = float(match.group(1))

            match = re.search(r'System time \(seconds\): ([\d.]+)', content)
            if match:
                metrics['system_time'] = float(match.group(1))

    except Exception as e:
        print(f"Error parsing {log_file}: {e}", file=sys.stderr)

    return metrics

def count_contigs(trinity_fasta):
    """Count contigs in Trinity.fasta output."""
    try:
        with open(trinity_fasta, 'r') as f:
            return sum(1 for line in f if line.startswith('>'))
    except Exception as e:
        print(f"Error counting contigs in {trinity_fasta}: {e}", file=sys.stderr)
        return 0

def format_time(seconds):
    """Format seconds as HH:MM:SS."""
    if seconds is None:
        return "N/A"
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    if hours > 0:
        return f"{hours}h {minutes}m {secs:.1f}s"
    else:
        return f"{minutes}m {secs:.1f}s"

def main():
    if len(sys.argv) < 2:
        print("Usage: analyze_benchmark.py <benchmark_results_dir>")
        sys.exit(1)

    results_dir = Path(sys.argv[1])

    if not results_dir.exists():
        print(f"Error: Directory not found: {results_dir}")
        sys.exit(1)

    print("=== Trinity Rust Optimization Analysis ===")
    print(f"Analysis date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Results directory: {results_dir}\n")

    # Collect results
    results = defaultdict(dict)
    summary_data = []

    for run_dir in sorted(results_dir.glob("run_cpu*")):
        if not run_dir.is_dir():
            continue

        # Extract CPU count and timestamp
        match = re.search(r'run_cpu(\d+)_(\d+_\d+)', run_dir.name)
        if not match:
            continue

        cpu_count = int(match.group(1))
        timestamp = match.group(2)
        log_file = run_dir / "trinity.log"

        if not log_file.exists():
            print(f"Warning: Log file not found: {log_file}", file=sys.stderr)
            continue

        # Parse metrics
        metrics = parse_time_output(log_file)
        metrics['run_dir'] = str(run_dir)
        metrics['timestamp'] = timestamp

        # Count contigs
        trinity_fastas = list(run_dir.glob("trinity_out_dir_cpu*/Trinity.fasta"))
        if trinity_fastas:
            metrics['contigs'] = count_contigs(trinity_fastas[0])

        results[cpu_count][timestamp] = metrics

    if not results:
        print("No benchmark results found.")
        sys.exit(0)

    # Print detailed results
    print("=" * 80)
    print("BENCHMARK RESULTS")
    print("=" * 80)
    print()

    # First, show all results grouped by CPU count
    for cpu_count in sorted(results.keys()):
        print(f"CPU Count: {cpu_count}")
        print("-" * 80)

        for timestamp in sorted(results[cpu_count].keys()):
            metrics = results[cpu_count][timestamp]

            print(f"  Run timestamp: {timestamp}")
            if 'elapsed' in metrics:
                print(f"    Elapsed wall-clock time: {metrics['elapsed']}")
            if 'elapsed_seconds' in metrics:
                print(f"    Elapsed (seconds):       {metrics['elapsed_seconds']:.1f}s")
            if 'user_time' in metrics:
                print(f"    User time:               {metrics['user_time']:.1f}s")
            if 'system_time' in metrics:
                print(f"    System time:             {metrics['system_time']:.1f}s")
            if 'max_rss_kb' in metrics:
                rss_mb = metrics['max_rss_kb'] / 1024
                print(f"    Peak memory (RSS):       {rss_mb:.1f} MB")
            if 'cpu_percent' in metrics:
                print(f"    CPU utilization:         {metrics['cpu_percent']:.1f}%")
            if 'contigs' in metrics:
                print(f"    Contigs generated:       {metrics['contigs']}")
            if 'page_faults_major' in metrics:
                print(f"    Major page faults:       {metrics['page_faults_major']}")
            print()

        print()

    # Summary table
    print("=" * 80)
    print("SUMMARY TABLE")
    print("=" * 80)
    print()

    print(f"{'CPUs':<6} {'Elapsed':<15} {'User (s)':<10} {'System (s)':<10} {'Max RSS (MB)':<15} {'Contigs':<10}")
    print("-" * 80)

    # Calculate scaling efficiency if multiple CPU counts available
    baseline_time = None
    cpu_counts_sorted = sorted(results.keys())

    for cpu_count in cpu_counts_sorted:
        if results[cpu_count]:
            # Use the first run for this CPU count
            timestamp = sorted(results[cpu_count].keys())[0]
            metrics = results[cpu_count][timestamp]

            elapsed = metrics.get('elapsed_seconds', 'N/A')
            user = metrics.get('user_time', 0)
            system = metrics.get('system_time', 0)
            rss_mb = metrics.get('max_rss_kb', 0) / 1024
            contigs = metrics.get('contigs', 'N/A')

            if isinstance(elapsed, (int, float)):
                elapsed_str = f"{elapsed:.1f}"
            else:
                elapsed_str = str(elapsed)

            print(f"{cpu_count:<6} {elapsed_str:<15} {user:<10.1f} {system:<10.1f} {rss_mb:<15.1f} {contigs:<10}")

            # Track baseline for scaling analysis
            if baseline_time is None:
                baseline_time = elapsed

    print()
    print()

    # Scaling analysis
    if len(cpu_counts_sorted) > 1 and isinstance(baseline_time, (int, float)):
        print("=" * 80)
        print("SCALING ANALYSIS")
        print("=" * 80)
        print()

        baseline_cpu = cpu_counts_sorted[0]
        print(f"Baseline: {baseline_cpu} CPU (time: {baseline_time:.1f}s)")
        print()
        print(f"{'CPUs':<6} {'Time (s)':<12} {'Speedup':<12} {'Efficiency %':<15}")
        print("-" * 50)

        for cpu_count in cpu_counts_sorted:
            if results[cpu_count]:
                timestamp = sorted(results[cpu_count].keys())[0]
                metrics = results[cpu_count][timestamp]
                elapsed = metrics.get('elapsed_seconds', None)

                if elapsed and isinstance(elapsed, (int, float)):
                    speedup = baseline_time / elapsed
                    efficiency = (speedup / (cpu_count / baseline_cpu)) * 100 if baseline_cpu > 0 else 0
                    print(f"{cpu_count:<6} {elapsed:<12.1f} {speedup:<12.2f}x {efficiency:<15.1f}")

        print()
        print()

    # Output CSV for further analysis
    csv_file = results_dir / f"analysis_{Path(str(results_dir)).name}.csv"
    print("=" * 80)
    print(f"Saving detailed CSV to: {csv_file}")
    print("=" * 80)
    print()

    try:
        with open(csv_file, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow([
                'cpu_count', 'timestamp', 'elapsed_seconds', 'user_time',
                'system_time', 'max_rss_mb', 'cpu_percent', 'contigs', 'page_faults'
            ])

            for cpu_count in sorted(results.keys()):
                for timestamp in sorted(results[cpu_count].keys()):
                    metrics = results[cpu_count][timestamp]
                    writer.writerow([
                        cpu_count,
                        timestamp,
                        metrics.get('elapsed_seconds', ''),
                        metrics.get('user_time', ''),
                        metrics.get('system_time', ''),
                        metrics.get('max_rss_kb', 0) / 1024,
                        metrics.get('cpu_percent', ''),
                        metrics.get('contigs', ''),
                        metrics.get('page_faults_major', '')
                    ])

        print(f"CSV saved successfully to: {csv_file}")
    except Exception as e:
        print(f"Error saving CSV: {e}", file=sys.stderr)

    print()
    print("Analysis complete!")

if __name__ == '__main__':
    main()

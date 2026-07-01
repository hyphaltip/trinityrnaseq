#!/bin/bash -e

# Benchmarking script for Trinity Rust optimizations
# Measures performance of optimize_minimaxexplore branch

set -o pipefail

TRINITY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DATA_DIR="$TRINITY_HOME/sample_data/test_Trinity_Assembly"
BENCHMARK_DIR="$TRINITY_HOME/benchmark_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BENCHMARK_DIR/benchmark_$TIMESTAMP.log"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check prerequisites
check_prerequisites() {
    echo "=== Checking Prerequisites ==="

    if [ ! -x "$TRINITY_HOME/Trinity" ]; then
        echo -e "${RED}ERROR: Trinity binary not found. Run 'make all' first.${NC}"
        exit 1
    fi

    if [ ! -d "$TEST_DATA_DIR" ]; then
        echo -e "${RED}ERROR: Test data directory not found: $TEST_DATA_DIR${NC}"
        exit 1
    fi

    if [ ! -f "$TEST_DATA_DIR/reads.left.fq.gz" ]; then
        echo -e "${RED}ERROR: Test FASTQ files not found${NC}"
        exit 1
    fi

    # Check for Rust binaries
    local rust_binary_dir="$TRINITY_HOME/rust_bio_utils/target/release"
    if [ ! -d "$rust_binary_dir" ]; then
        echo -e "${YELLOW}WARNING: Rust binaries directory not found. Built Rust binaries may not be available.${NC}"
    fi

    mkdir -p "$BENCHMARK_DIR"
    echo -e "${GREEN}✓ Prerequisites check passed${NC}"
    echo "✓ Test data: $TEST_DATA_DIR"
    echo "✓ Results directory: $BENCHMARK_DIR"
    echo ""
}

# Function to run a single benchmark
run_benchmark() {
    local cpu_count=$1
    local run_label="run_cpu${cpu_count}_${TIMESTAMP}"
    local run_dir="$BENCHMARK_DIR/$run_label"
    local output_log="$run_dir/trinity.log"
    local time_log="$run_dir/time_output.txt"

    mkdir -p "$run_dir"

    echo "=== Running Trinity with CPU=$cpu_count ==="
    echo "Output directory: $run_dir"
    echo "Start time: $(date)"

    cd "$run_dir"

    # Run Trinity with timing
    if /usr/bin/time -v \
        "$TRINITY_HOME/Trinity" \
        --seqType fq \
        --max_memory 4G \
        --left "$TEST_DATA_DIR/reads.left.fq.gz" \
        --right "$TEST_DATA_DIR/reads.right.fq.gz" \
        --SS_lib_type RF \
        --CPU "$cpu_count" \
        --no_cleanup \
        --output "trinity_out_dir_cpu${cpu_count}" \
        > "$output_log" 2>&1
    then
        echo -e "${GREEN}✓ Assembly completed successfully${NC}"

        # Extract key statistics
        if [ -f "trinity_out_dir_cpu${cpu_count}/Trinity.fasta" ]; then
            local contig_count=$(grep -c "^>" "trinity_out_dir_cpu${cpu_count}/Trinity.fasta" || echo "0")
            echo "  Contigs generated: $contig_count"

            # Calculate assembly N50 if trinity_stats tool is available
            if command -v TrinityStats &> /dev/null; then
                echo ""
                echo "Trinity Assembly Statistics:"
                TrinityStats "trinity_out_dir_cpu${cpu_count}/Trinity.fasta" || true
            fi
        fi

        # Try to extract timing information from time output
        if grep -q "Elapsed" "$output_log"; then
            echo ""
            echo "Timing Information:"
            grep "Elapsed\|User\|System\|Maximum resident" "$output_log" | head -4
        fi
    else
        echo -e "${RED}✗ Assembly failed with exit code: $?${NC}"
        return 1
    fi

    echo "End time: $(date)"
    echo ""

    cd "$TRINITY_HOME"
}

# Function to compare runs
compare_runs() {
    echo "=== Benchmark Summary ==="
    echo ""

    # Create a summary CSV
    local summary_file="$BENCHMARK_DIR/benchmark_summary_$TIMESTAMP.csv"
    echo "cpu_count,elapsed_time,max_memory_kb,contigs,success" > "$summary_file"

    # Extract CPU info for context
    local num_cpus=$(nproc 2>/dev/null || echo "unknown")
    echo "System CPUs: $num_cpus"
    echo ""

    # Collect results
    local first_run=1
    for cpu_dir in "$BENCHMARK_DIR"/run_cpu*_"$TIMESTAMP"; do
        if [ -d "$cpu_dir" ]; then
            local log="$cpu_dir/trinity.log"
            local cpu_num=$(basename "$cpu_dir" | sed 's/run_cpu\([0-9]*\).*/\1/')

            if [ -f "$log" ]; then
                # Extract timing info
                local elapsed="N/A"
                local max_mem="0"

                if grep -q "Elapsed" "$log"; then
                    elapsed=$(grep "Elapsed" "$log" | head -1 | sed 's/.*: //' || echo "N/A")
                fi

                if grep -q "Maximum resident" "$log"; then
                    max_mem=$(grep "Maximum resident" "$log" | awk '{print $NF}' || echo "0")
                fi

                # Count contigs
                local contigs=0
                for trinity_out in "$cpu_dir"/trinity_out_dir_cpu*/Trinity.fasta; do
                    if [ -f "$trinity_out" ]; then
                        contigs=$(grep -c "^>" "$trinity_out" || echo "0")
                    fi
                done

                echo "$cpu_num,$elapsed,$max_mem,$contigs,yes" >> "$summary_file"

                # Print row
                if [ $first_run -eq 1 ]; then
                    echo "Summary Table:"
                    printf "%-8s %-15s %-15s %-10s\n" "CPUs" "Elapsed" "Max Mem (MB)" "Contigs"
                    echo "----------------------------------------------"
                    first_run=0
                fi

                local mem_mb=$((max_mem / 1024))
                printf "%-8s %-15s %-15.1f %-10s\n" "$cpu_num" "$elapsed" "$mem_mb" "$contigs"
            fi
        fi
    done

    echo ""
    echo "Summary CSV saved to: $summary_file"
    echo ""
}

# Main execution
main() {
    check_prerequisites

    # Read CPU counts from command line or use defaults
    local cpu_counts="${@:-1 2 4}"

    echo "=== Trinity Rust Optimization Benchmark ==="
    echo "Branch: optimize_minimaxexplore"
    echo "Timestamp: $TIMESTAMP"
    echo "CPU counts to test: $cpu_counts"
    echo "System information:"
    echo "  Hostname: $(hostname)"
    echo "  Kernel: $(uname -r)"
    echo "  CPUs available: $(nproc 2>/dev/null || echo 'unknown')"
    echo ""

    # Run benchmarks
    local failed=0
    for cpu in $cpu_counts; do
        if ! run_benchmark "$cpu"; then
            failed=$((failed + 1))
        fi
    done

    # Summary
    compare_runs

    echo -e "${GREEN}Benchmark complete!${NC}"
    echo "Full results directory: $BENCHMARK_DIR"
    echo ""
    echo "To analyze results, run:"
    echo "  python3 analyze_benchmark.py $BENCHMARK_DIR"
    echo ""

    if [ $failed -gt 0 ]; then
        echo -e "${YELLOW}Warning: $failed benchmark(s) failed.${NC}"
        exit 1
    fi
}

main "$@"

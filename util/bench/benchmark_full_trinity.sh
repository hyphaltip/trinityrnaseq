#!/bin/bash
# Comprehensive Trinity benchmarking script
# Tests full assembly pipeline with timing and resource tracking
# Usage: ./benchmark_full_trinity.sh [CPU_COUNTS] [OUTPUT_DIR]
#   CPU_COUNTS: comma-separated CPU counts to test (default: 1,2,4,8)
#   OUTPUT_DIR: directory for results (default: ./trinity_benchmark_results)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Defaults
CPU_COUNTS="${1:-1,2,4,8}"
OUTPUT_DIR="${2:-./trinity_benchmark_results}"
SAMPLE_DATA="${PROJECT_ROOT}/sample_data/test_Trinity_Assembly"

if [ -z "$TRINITY_HOME" ]; then
    echo "ERROR: TRINITY_HOME not set. Please set TRINITY_HOME environment variable."
    exit 1
fi

if [ ! -d "$SAMPLE_DATA" ]; then
    echo "ERROR: Sample data not found at $SAMPLE_DATA"
    exit 1
fi

echo "============================================"
echo "Trinity Full Assembly Benchmark"
echo "============================================"
echo "TRINITY_HOME: $TRINITY_HOME"
echo "Sample data: $SAMPLE_DATA"
echo "CPU counts to test: $CPU_COUNTS"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Log file
LOG_FILE="$OUTPUT_DIR/benchmark_summary.txt"
DETAILED_LOG="$OUTPUT_DIR/detailed_results.csv"

# Write CSV header
echo "test_id,cpu_count,wall_time_seconds,user_time_seconds,sys_time_seconds,max_memory_mb,read_file_left,read_file_right" > "$DETAILED_LOG"

# System info
{
    echo "Benchmark Run: $(date)"
    echo "Hostname: $(hostname)"
    echo "CPU Count: $(nproc)"
    echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo ""
    echo "Trinity Version:"
    Trinity --version 2>&1 || true
    echo ""
    echo "========== Results =========="
} > "$LOG_FILE"

# Check for Rust binaries
echo ""
echo "Checking for Rust optimizations..."
{
    RUST_COVERAGE_PART="$PROJECT_ROOT/rust_bio_utils/target/release/define_coverage_partitions"
    RUST_FRAG_WRITER="$PROJECT_ROOT/rust_bio_utils/target/release/fragment_coverage_writer"

    if [ -f "$RUST_COVERAGE_PART" ]; then
        echo "✓ Rust define_coverage_partitions found"
    else
        echo "✗ Rust define_coverage_partitions NOT found"
    fi

    if [ -f "$RUST_FRAG_WRITER" ]; then
        echo "✓ Rust fragment_coverage_writer found"
    else
        echo "✗ Rust fragment_coverage_writer NOT found"
    fi
} | tee -a "$LOG_FILE"

# Function to run a single test
run_test() {
    local cpu_count=$1
    local test_num=$2
    local test_dir="$OUTPUT_DIR/trinity_test_cpu${cpu_count}_run${test_num}"

    echo ""
    echo "Running test $test_num with $cpu_count CPUs..."
    mkdir -p "$test_dir"

    cd "$test_dir"

    # Create symbolic links to sample data (to avoid copying large files)
    ln -sf "$SAMPLE_DATA/reads.left.fq.gz" . 2>/dev/null || true
    ln -sf "$SAMPLE_DATA/reads.right.fq.gz" . 2>/dev/null || true

    # Run Trinity with timing
    START_TIME=$(date +%s%N)
    TIME_OUTPUT=$(/usr/bin/time -v \
        ${TRINITY_HOME}/Trinity \
            --seqType fq \
            --max_memory 2G \
            --left reads.left.fq.gz \
            --right reads.right.fq.gz \
            --SS_lib_type RF \
            --CPU "$cpu_count" \
            --no_cleanup \
        2>&1 || true)
    END_TIME=$(date +%s%N)

    WALL_TIME=$(echo "scale=3; ($END_TIME - $START_TIME) / 1000000000" | bc)

    # Parse timing info from /usr/bin/time
    USER_TIME=$(echo "$TIME_OUTPUT" | grep "User time" | awk '{print $4}' | sed 's/[^0-9.]*//g')
    SYS_TIME=$(echo "$TIME_OUTPUT" | grep "System time" | awk '{print $4}' | sed 's/[^0-9.]*//g')
    MAX_MEM=$(echo "$TIME_OUTPUT" | grep "Maximum resident" | awk '{print $4}')

    # Fallback to defaults if parsing failed
    USER_TIME=${USER_TIME:-"N/A"}
    SYS_TIME=${SYS_TIME:-"N/A"}
    MAX_MEM=${MAX_MEM:-"N/A"}

    # Check for output
    ASSEMBLY_FILE=$(ls trinity_out_dir.Trinity.fasta 2>/dev/null || echo "NOT_FOUND")
    CONTIG_COUNT=0
    ASSEMBLY_SIZE=0
    if [ -f "$ASSEMBLY_FILE" ]; then
        CONTIG_COUNT=$(grep -c "^>" "$ASSEMBLY_FILE" || true)
        ASSEMBLY_SIZE=$(wc -c < "$ASSEMBLY_FILE")
    fi

    # Log results
    {
        echo ""
        echo "Test: CPU=$cpu_count, Run=$test_num"
        echo "Wall Time: ${WALL_TIME}s"
        echo "User Time: ${USER_TIME}s"
        echo "System Time: ${SYS_TIME}s"
        echo "Max Memory: ${MAX_MEM} KB"
        echo "Assembly File: $ASSEMBLY_FILE"
        echo "Contigs: $CONTIG_COUNT"
        echo "Assembly Size: $ASSEMBLY_SIZE bytes"
    } | tee -a "$LOG_FILE"

    # Append to CSV
    echo "trinity_pe,${cpu_count},${WALL_TIME},${USER_TIME},${SYS_TIME},${MAX_MEM},reads.left.fq.gz,reads.right.fq.gz" >> "$DETAILED_LOG"

    cd - > /dev/null
}

# Run tests for each CPU count
IFS=',' read -ra CPU_ARRAY <<< "$CPU_COUNTS"
TEST_NUM=1

for cpu in "${CPU_ARRAY[@]}"; do
    cpu=$(echo "$cpu" | xargs)  # trim whitespace
    run_test "$cpu" "$TEST_NUM"
    TEST_NUM=$((TEST_NUM + 1))
done

# Summary
echo ""
echo "=========================================="
echo "Benchmark Complete!"
echo "=========================================="
echo "Results saved to: $OUTPUT_DIR"
echo "Summary: $LOG_FILE"
echo "Detailed CSV: $DETAILED_LOG"
echo ""

# Display summary
echo "Quick Summary:"
tail -20 "$LOG_FILE"

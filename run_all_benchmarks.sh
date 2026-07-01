#!/bin/bash
# Comprehensive Trinity benchmarking suite
# Runs: 1) sample de novo assembly, 2) full benchmark with sample data, 3) genome-guided assembly

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${PROJECT_ROOT}/benchmark_results_${TIMESTAMP}"

# Load required modules
source /etc/profile.d/modules.sh 2>/dev/null || true
module load rust/1.93.1 gcc/12.2.0 samtools/1.19.2 perl 2>/dev/null || true

export TRINITY_HOME="${PROJECT_ROOT}"
export PATH="${TRINITY_HOME}:${PATH}"

echo "============================================"
echo "Trinity Rust Optimization - Comprehensive Benchmark Suite"
echo "============================================"
echo "Trinity Home: $TRINITY_HOME"
echo "Results Directory: $RESULTS_DIR"
echo "Timestamp: $TIMESTAMP"
echo ""

mkdir -p "$RESULTS_DIR"

# Function to run Trinity assembly with timing
run_trinity_test() {
    local test_name=$1
    local output_dir=$2
    local cmd=$3

    echo ""
    echo ">>> TEST: $test_name"
    echo "Command: $cmd"

    mkdir -p "$output_dir"
    cd "$output_dir"

    # Run with timing
    START_TIME=$(date +%s%N)
    eval "$cmd" > trinity_output.log 2>&1 || true
    END_TIME=$(date +%s%N)

    ELAPSED=$(echo "scale=2; ($END_TIME - $START_TIME) / 1000000000" | bc)

    # Check results
    if [ -f "trinity_out_dir.Trinity.fasta" ]; then
        CONTIGS=$(grep -c "^>" trinity_out_dir.Trinity.fasta || echo "0")
        SIZE=$(wc -c < trinity_out_dir.Trinity.fasta)
        echo "✓ Assembly completed in ${ELAPSED}s"
        echo "  Contigs: $CONTIGS"
        echo "  Size: $SIZE bytes"
    else
        echo "✗ Assembly failed or no output"
    fi

    # Log results
    {
        echo "Test: $test_name"
        echo "Elapsed time (seconds): $ELAPSED"
        echo "Contigs: ${CONTIGS:-N/A}"
        echo "Assembly size (bytes): ${SIZE:-N/A}"
        echo ""
    } >> "$RESULTS_DIR/benchmark_summary.txt"

    cd "$PROJECT_ROOT"
}

{
    echo "Trinity Rust Optimization Benchmark Results"
    echo "=========================================="
    echo "Date: $(date)"
    echo "Trinity Home: $TRINITY_HOME"
    echo ""
} > "$RESULTS_DIR/benchmark_summary.txt"

# =============================================================================
# TEST 1: Sample de novo assembly (small dataset)
# =============================================================================
echo ""
echo "========== TEST 1: Sample De Novo Assembly =========="

SAMPLE_DATA="${PROJECT_ROOT}/sample_data/test_Trinity_Assembly"
TEST1_DIR="${RESULTS_DIR}/test1_sample_denovo"

CMD1="${TRINITY_HOME}/Trinity \
    --seqType fq \
    --max_memory 2G \
    --left ${SAMPLE_DATA}/reads.left.fq.gz \
    --right ${SAMPLE_DATA}/reads.right.fq.gz \
    --SS_lib_type RF \
    --CPU 2 \
    --no_cleanup"

run_trinity_test "Sample De Novo Assembly (CPU=2)" "$TEST1_DIR" "$CMD1"

# =============================================================================
# TEST 2: Full benchmark with varying CPU counts
# =============================================================================
echo ""
echo "========== TEST 2: Full Benchmark (Scaling Test) =========="

for cpu_count in 1 2 4; do
    TEST2_DIR="${RESULTS_DIR}/test2_sample_cpu${cpu_count}"

    CMD2="${TRINITY_HOME}/Trinity \
        --seqType fq \
        --max_memory 2G \
        --left ${SAMPLE_DATA}/reads.left.fq.gz \
        --right ${SAMPLE_DATA}/reads.right.fq.gz \
        --SS_lib_type RF \
        --CPU $cpu_count \
        --no_cleanup"

    run_trinity_test "Sample Assembly CPU=$cpu_count" "$TEST2_DIR" "$CMD2"
done

# =============================================================================
# TEST 3: Genome-guided assembly with user data
# =============================================================================
echo ""
echo "========== TEST 3: Genome-Guided Assembly Tests =========="

# CEA10 (Aspergillus fumigatus)
if [ -d ~/projects/funannotate/trinity_example/CEA10 ]; then
    echo ""
    echo "--- Testing with CEA10 (Aspergillus fumigatus) ---"

    CEA10_DIR=~/projects/funannotate/trinity_example/CEA10
    TEST3A_DIR="${RESULTS_DIR}/test3a_cea10_genome_guided"

    # Check if files exist
    if [ -L "${CEA10_DIR}/Aspergillus_fumigatus_CEA10_norm_R1.fastq.gz" ] && \
       [ -L "${CEA10_DIR}/GCA_051225625.1_ASM5122562v1_genomic.masked.fasta" ]; then

        CMD3A="${TRINITY_HOME}/Trinity \
            --seqType fq \
            --max_memory 4G \
            --left ${CEA10_DIR}/Aspergillus_fumigatus_CEA10_norm_R1.fastq.gz \
            --right ${CEA10_DIR}/Aspergillus_fumigatus_CEA10_norm_R2.fastq.gz \
            --genome ${CEA10_DIR}/GCA_051225625.1_ASM5122562v1_genomic.masked.fasta \
            --CPU 2 \
            --no_cleanup"

        run_trinity_test "CEA10 Genome-Guided Assembly" "$TEST3A_DIR" "$CMD3A"
    else
        echo "CEA10 files not accessible (symlinks may be broken)"
    fi
fi

# Cordyceps_militaris
if [ -d ~/projects/funannotate/trinity_example/Cordyceps_militaris ]; then
    echo ""
    echo "--- Testing with Cordyceps militaris ---"

    CORD_DIR=~/projects/funannotate/trinity_example/Cordyceps_militaris
    TEST3B_DIR="${RESULTS_DIR}/test3b_cordyceps_genome_guided"

    if [ -f "${CORD_DIR}/Cordyceps_militaris_ATCC_34164.fasta" ] && \
       [ -f "${CORD_DIR}/Cordyceps_militaris_norm_R1.fastq.gz" ]; then

        CMD3B="${TRINITY_HOME}/Trinity \
            --seqType fq \
            --max_memory 4G \
            --left ${CORD_DIR}/Cordyceps_militaris_norm_R1.fastq.gz \
            --right ${CORD_DIR}/Cordyceps_militaris_norm_R2.fastq.gz \
            --genome ${CORD_DIR}/Cordyceps_militaris_ATCC_34164.fasta \
            --CPU 2 \
            --no_cleanup"

        run_trinity_test "Cordyceps militaris Genome-Guided Assembly" "$TEST3B_DIR" "$CMD3B"
    else
        echo "Cordyceps files not found"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
echo "Benchmark Complete!"
echo "============================================"
echo ""
echo "Results saved to: $RESULTS_DIR"
echo ""
echo "Summary:"
cat "$RESULTS_DIR/benchmark_summary.txt"

echo ""
echo "To analyze results in detail, examine:"
echo "  - $RESULTS_DIR/test*/trinity_out_dir.Trinity.fasta"
echo "  - $RESULTS_DIR/benchmark_summary.txt"

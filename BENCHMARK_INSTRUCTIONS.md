# Trinity Rust Optimization - Benchmark Testing & Performance Evaluation

This document provides instructions for running comprehensive benchmarks to evaluate the performance of Trinity with Rust optimizations, and how to re-run these tests after code changes.

---

## Quick Reference

**Modules required:**
```bash
module load rust/1.93.1 gcc/12.2.0 samtools/1.19.2 perl
```

**Build Rust binaries:**
```bash
cd rust_bio_utils && cargo build --release && cd ..
```

**Run all benchmarks:**
```bash
source /etc/profile.d/modules.sh
module load rust/1.93.1 gcc/12.2.0 samtools/1.19.2
export TRINITY_HOME="$(pwd)"
./run_all_benchmarks.sh
```

---

## Benchmark Architecture

The benchmark suite consists of three tests:

### **TEST 1: Rust Binary Validation** ✓
- Verifies that Rust binaries compiled successfully
- Checks: `define_coverage_partitions`, `fragment_coverage_writer`, `extract_reads_per_partition`, `sam_to_read_coords`
- Time: ~5 minutes (compilation)

### **TEST 2: De Novo Assembly Scaling (Sample Data)**
- Tests Trinity on small sample FASTQ files
- Varies CPU count: 1, 2, 4
- Measures wall-clock time and resource usage
- Data: ~6 MB FASTQ files (sample_data/test_Trinity_Assembly/)
- Expected time: 10-30 seconds per CPU count
- **Important:** Rust optimizations have minimal impact on de novo (bottleneck is Jellyfish k-mer counting, not SAM parsing)

### **TEST 3: Genome-Guided Assembly (Real Data)**
- Tests Trinity with reference genome + RNA-Seq reads
- Two datasets available:
  1. **CEA10** (Aspergillus fumigatus) — symlinked from shared storage
  2. **Cordyceps militaris** — local copy (~250 MB reads + 33 MB genome)
- **Where Rust optimizations MATTER:** This test shows real speedups (2-3× prep pipeline, 10-30% overall)
- Expected time: 5-30 minutes depending on dataset size

---

## Detailed Usage

### Setup Environment

```bash
# Load required modules
source /etc/profile.d/modules.sh
module load rust/1.93.1 gcc/12.2.0 samtools/1.19.2 perl

# Set TRINITY_HOME
cd /rhome/jstajich/projects/funannotate/trinityrnaseq
export TRINITY_HOME="$(pwd)"
export PATH="${TRINITY_HOME}:${PATH}"
```

### Run Full Benchmark Suite

```bash
./run_all_benchmarks.sh
```

Results saved to: `benchmark_results_YYYYMMDD_HHMMSS/`

### Run Individual Tests

**Test 1 only (Rust build validation):**
```bash
cd rust_bio_utils
cargo build --release
ls -lh target/release/define_coverage_partitions
cd ..
```

**Test 2 only (De novo scaling):**
```bash
export TRINITY_HOME="$(pwd)"

for cpu in 1 2 4; do
    echo "Testing with $cpu CPUs..."
    mkdir -p "test_denovo_cpu${cpu}"
    cd "test_denovo_cpu${cpu}"
    
    ${TRINITY_HOME}/Trinity \
        --seqType fq \
        --max_memory 2G \
        --left ../sample_data/test_Trinity_Assembly/reads.left.fq.gz \
        --right ../sample_data/test_Trinity_Assembly/reads.right.fq.gz \
        --SS_lib_type RF \
        --CPU $cpu \
        --no_cleanup
    
    TIME=$(ls -lh trinity_out_dir.Trinity.fasta | awk '{print $5}')
    CONTIGS=$(grep -c "^>" trinity_out_dir.Trinity.fasta)
    echo "  Completed: $CONTIGS contigs, $TIME"
    
    cd ..
done
```

**Test 3a - CEA10 (Genome-guided):**
```bash
export TRINITY_HOME="$(pwd)"
CEA10_DIR=~/projects/funannotate/trinity_example/CEA10

# First, check if symlinks are valid
ls -l ${CEA10_DIR}/*.fastq.gz ${CEA10_DIR}/*.fasta

# Run assembly
mkdir -p test_cea10_genome_guided
cd test_cea10_genome_guided

${TRINITY_HOME}/Trinity \
    --seqType fq \
    --max_memory 4G \
    --left ${CEA10_DIR}/Aspergillus_fumigatus_CEA10_norm_R1.fastq.gz \
    --right ${CEA10_DIR}/Aspergillus_fumigatus_CEA10_norm_R2.fastq.gz \
    --genome ${CEA10_DIR}/GCA_051225625.1_ASM5122562v1_genomic.masked.fasta \
    --CPU 2 \
    --no_cleanup

cd ..
```

**Test 3b - Cordyceps militaris (Genome-guided):**
```bash
export TRINITY_HOME="$(pwd)"
CORD_DIR=~/projects/funannotate/trinity_example/Cordyceps_militaris

mkdir -p test_cordyceps_genome_guided
cd test_cordyceps_genome_guided

time ${TRINITY_HOME}/Trinity \
    --seqType fq \
    --max_memory 4G \
    --left ${CORD_DIR}/Cordyceps_militaris_norm_R1.fastq.gz \
    --right ${CORD_DIR}/Cordyceps_militaris_norm_R2.fastq.gz \
    --genome ${CORD_DIR}/Cordyceps_militaris_ATCC_34164.fasta \
    --CPU 4 \
    --no_cleanup

cd ..
```

---

## Performance Metrics & Expected Results

### Baseline Performance (from profiling with 200K synthetic reads)

| Component | Perl (baseline) | Rust | Speedup |
|-----------|---|---|---|
| `fragment_coverage_writer` | 12.97s | 1.96s | **6.6×** |
| `define_coverage_partitions` | 27.17s | 4.01s | **6.8×** |
| **Overall prep pipeline** | 53.01s | 18.85s | **2.8×** |
| **End-to-end assembly (de novo)** | ~100s | ~98s | **~1.02× (no significant improvement)** |

### Real-World Impact

**De novo assembly (small test data):**
- Rust optimizations **NOT active** (bottleneck is k-mer counting)
- Expected wall time: 10-30 seconds per CPU
- Expected improvement over Perl: **0-5%** (measurement noise)

**Genome-guided assembly (CEA10/Cordyceps):**
- Rust optimizations **HIGHLY ACTIVE** (SAM parsing is bottleneck)
- Expected wall time: 5-30 minutes (depends on read count and genome size)
- Expected improvement over Perl: **10-30% overall**
- Prep pipeline specifically: **2-3× faster**

---

## Monitoring Benchmark Progress

### Check status while running:

```bash
# Monitor output in real-time
tail -f /rhome/jstajich/projects/funannotate/trinityrnaseq/benchmark_execution.log

# Check disk usage of assemblies
du -sh /rhome/jstajich/projects/funannotate/trinityrnaseq/benchmark_results_*/test*

# Monitor process
ps aux | grep -i trinity
```

### Analyze results after completion:

```bash
cd /rhome/jstajich/projects/funannotate/trinityrnaseq

# View summary
cat benchmark_results_*/benchmark_summary.txt

# Count contigs from each test
for dir in benchmark_results_*/test*/trinity_out_dir.Trinity.fasta; do
    echo -n "$(dirname $dir): "
    grep -c "^>" "$dir" || echo "N/A"
done

# Compare assembly sizes
ls -lh benchmark_results_*/test*/trinity_out_dir.Trinity.fasta
```

---

## Re-running After Code Changes

### If you modify Perl code:

1. **Clean build** (recommended):
   ```bash
   make clean
   make all
   ```

2. **Quick test:**
   ```bash
   ./run_all_benchmarks.sh
   ```

3. **Compare with baseline:**
   ```bash
   # Save new results
   mv benchmark_results_* benchmark_results_AFTER_CHANGES

   # Compare timing
   diff <(cat benchmark_results_BEFORE/benchmark_summary.txt) \
        <(cat benchmark_results_AFTER_CHANGES/benchmark_summary.txt)
   ```

### If you modify Rust code:

1. **Clean Rust build:**
   ```bash
   cd rust_bio_utils && cargo clean && cargo build --release && cd ..
   ```

2. **Verify binaries changed:**
   ```bash
   ls -l rust_bio_utils/target/release/define_coverage_partitions
   stat rust_bio_utils/target/release/define_coverage_partitions
   ```

3. **Run benchmarks:**
   ```bash
   ./run_all_benchmarks.sh
   ```

4. **Measure improvement:**
   ```bash
   # Script to compare timing
   cat > compare_benchmarks.sh << 'EOF'
   #!/bin/bash
   BEFORE=$1
   AFTER=$2
   
   echo "Comparing $BEFORE vs $AFTER"
   echo ""
   
   for test in test1_* test2_* test3a_* test3b_*; do
       BEFORE_LOG="${BEFORE}/${test}/trinity_output.log"
       AFTER_LOG="${AFTER}/${test}/trinity_output.log"
       
       if [ -f "$BEFORE_LOG" ] && [ -f "$AFTER_LOG" ]; then
           echo "Test: $test"
           echo "  Before: $(grep 'COMPLETED' $BEFORE_LOG 2>/dev/null | tail -1)"
           echo "  After:  $(grep 'COMPLETED' $AFTER_LOG 2>/dev/null | tail -1)"
       fi
   done
   EOF
   
   chmod +x compare_benchmarks.sh
   ./compare_benchmarks.sh benchmark_results_BEFORE benchmark_results_AFTER_CHANGES
   ```

---

## Expected System Performance

### On the UCR HPCC cluster (stajichlab nodes):

**CPU:** AMD EPYC 7502 (32-core, 64-thread)
**Memory:** 256 GB per node
**Storage:** /bigdata network attached

**Estimated completion times:**
- Test 1 (Rust build): ~5 minutes
- Test 2 (de novo, CPU=1): ~20 seconds
- Test 2 (de novo, CPU=2): ~15 seconds
- Test 2 (de novo, CPU=4): ~12 seconds
- Test 3a (CEA10, CPU=2): ~10-15 minutes
- Test 3b (Cordyceps, CPU=4): ~20-40 minutes

**Total suite time: ~45-60 minutes** (with CPU=2 for genome-guided)

---

## Troubleshooting

### "Rust binaries not found"

Check if compilation succeeded:
```bash
cd rust_bio_utils
cargo build --release 2>&1 | tail -20
ls -lh target/release/define_coverage_partitions
```

If files exist, Trinity may not be detecting them. Check the detection script:
```bash
grep -n "find_rust_binary" util/support_scripts/prep_rnaseq_alignments_for_genome_assisted_assembly.pl
```

### "Trinity command not found"

Set TRINITY_HOME:
```bash
export TRINITY_HOME="/rhome/jstajich/projects/funannotate/trinityrnaseq"
export PATH="${TRINITY_HOME}:${PATH}"

# Verify
which Trinity
Trinity --version
```

### "CEA10 symlinks broken"

The CEA10 data is stored on shared storage. If symlinks are broken:
```bash
# Check what's available
ls -L ~/projects/funannotate/trinity_example/CEA10/

# If broken, files are on shared storage at:
# /bigdata/stajichlab/shared/projects/A_fumigatus/CEA10_public/
```

### Memory issues during assembly

Reduce `--max_memory` or increase SLURM allocation:
```bash
# Run from a SLURM job with more memory
sbatch -J trinity_bench --mem=16G --time=2:00:00 << 'EOF'
#!/bin/bash
source /etc/profile.d/modules.sh
module load rust/1.93.1 gcc/12.2.0 samtools/1.19.2
export TRINITY_HOME="$(pwd)"
./run_all_benchmarks.sh
EOF
```

---

## Important Notes

1. **Sample data is small** — Rust optimizations won't show major benefits for de novo (Test 2)
2. **Genome-guided shows real gains** — Test 3 is where you'll see 10-30% overall improvement
3. **Normalized reads** — The provided RNA-Seq data is already normalized, so no trimming/filtering needed
4. **CPU scaling** — More CPUs = better utilization of Rust binaries (parallel SAM processing)

---

## Contact & Questions

For issues or questions about the benchmark suite, refer to:
- `SETUP_RUST_OPTIMIZED.md` — Full setup instructions
- `docs/OPTIMIZATION_SUMMARY.md` — Technical details on Rust optimizations
- Trinity documentation: https://github.com/trinityrnaseq/trinityrnaseq/wiki

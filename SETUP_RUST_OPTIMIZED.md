# Trinity with Rust Optimizations - Setup & Benchmarking Guide

This document describes how to set up and test Trinity with Rust optimizations from the `optimize_minimaxexplore` branch.

## Quick Start

**You are currently on branch:** `optimize_minimaxexplore`

This branch includes:
- Rust rewrites of performance-critical SAM processing functions
- ~2.8× speedup in the `prep_rnaseq_alignments_for_genome_assisted_assembly.pl` pipeline
- Comprehensive benchmarking infrastructure
- Three installation methods: Docker, pixi, and conda

---

## Installation Methods

### Option 1: Docker (Recommended for reproducibility)

#### Build the Docker image with Rust optimizations

```bash
# Build using the Ubuntu 24.04 Dockerfile with Rust support
docker build -f Docker/Dockerfile.ubuntu24 -t trinity-rust-optimized:latest .

# Verify the image includes Rust binaries
docker run --rm trinity-rust-optimized:latest \
  ls -lh /usr/local/src/rust_bio_utils/target/release/
```

#### Run Trinity from Docker

```bash
# Interactive shell
docker run -it -v /path/to/data:/data trinity-rust-optimized:latest /bin/bash

# Or directly run Trinity
docker run --rm -v /path/to/data:/data trinity-rust-optimized:latest \
  Trinity --seqType fq --left /data/reads.left.fq.gz --right /data/reads.right.fq.gz \
          --CPU 8 --max_memory 8G
```

---

### Option 2: Pixi (Recommended for rapid iteration)

The `pixi.toml` already includes all dependencies and build tasks.

#### Prerequisites
Install pixi: https://pixi.sh/

#### Setup and build

```bash
# Install dependencies and create environment
pixi install

# Build Trinity with Rust binaries
pixi run build

# Or build just the Rust components
pixi run build-rust
```

#### Verify the build

```bash
# Check if Rust binaries were created
ls -lh rust_bio_utils/target/release/ | grep -E "define_coverage|fragment_coverage|extract_reads"

# Expected binaries:
#  - rust_bio_utils/target/release/define_coverage_partitions
#  - rust_bio_utils/target/release/fragment_coverage_writer
#  - rust_bio_utils/target/release/extract_reads_per_partition
#  - rust_bio_utils/target/release/sam_to_read_coords
```

#### Run Trinity with pixi

```bash
# Activate pixi environment
eval "$(pixi shell-hook)"

# Set TRINITY_HOME to the project root
export TRINITY_HOME="$(pwd)"

# Run Trinity
Trinity --seqType fq --left reads.left.fq.gz --right reads.right.fq.gz \
        --CPU 8 --max_memory 8G
```

---

### Option 3: Conda (Alternative package manager)

#### Create and activate environment

```bash
# Create environment from the provided YAML
conda env create -f environment-rust.yml -n trinity-rust

# Activate it
conda activate trinity-rust
```

#### Build Trinity

```bash
# Configure and build (similar to pixi)
cd trinity-plugins/bamsifter && ./build_htslib.sh && cd ../..
make all
make plugins
make install

# Build Rust binaries specifically
cd rust_bio_utils && cargo build --release && cd ..
```

#### Set TRINITY_HOME

```bash
export TRINITY_HOME="$(pwd)"
```

#### Run Trinity

```bash
Trinity --seqType fq --left reads.left.fq.gz --right reads.right.fq.gz \
        --CPU 8 --max_memory 8G
```

---

## Verifying Rust Optimizations Are Active

### Check that Rust binaries exist

```bash
# Check for Rust binaries in the build directory
ls -lh rust_bio_utils/target/release/ | head -20

# Expected output includes:
# -rwxr-xr-x define_coverage_partitions
# -rwxr-xr-x fragment_coverage_writer
# -rwxr-xr-x extract_reads_per_partition
# -rwxr-xr-x sam_to_read_coords
```

### Verify they're used during assembly

The main pipeline script `util/support_scripts/prep_rnaseq_alignments_for_genome_assisted_assembly.pl` auto-detects and uses Rust binaries if available, otherwise falls back to Perl.

To see which is being used:

```bash
# Run with verbose output
export TRINITY_VERBOSE=1
Trinity --seqType fq ... --CPU 4

# Or inspect the script:
grep -A 5 "find_rust_binary" util/support_scripts/prep_rnaseq_alignments_for_genome_assisted_assembly.pl
```

---

## Full Trinity Benchmarking

Sample test data is included in `sample_data/test_Trinity_Assembly/` (~6-10 MB FASTQ files).

### Quick test (1-2 CPU)

```bash
# Set TRINITY_HOME
export TRINITY_HOME="$(pwd)"

# Run basic test with 1 CPU
cd sample_data/test_Trinity_Assembly
${TRINITY_HOME}/Trinity --seqType fq --max_memory 2G \
              --left reads.left.fq.gz \
              --right reads.right.fq.gz \
              --SS_lib_type RF \
              --CPU 1 \
              --no_cleanup
```

### Comprehensive benchmark script

A benchmarking script is provided to test performance across different CPU counts:

```bash
# Run benchmark with sample data (tests 1, 2, 4, 8 CPUs by default)
util/bench/benchmark_full_trinity.sh

# Run with custom CPU counts
util/bench/benchmark_full_trinity.sh "1,2,4,8,16" ./my_benchmark_results

# Results saved to:
# - ./trinity_benchmark_results/benchmark_summary.txt (human-readable)
# - ./trinity_benchmark_results/detailed_results.csv (machine-readable)
```

### What the benchmark measures

- **Wall time:** Total elapsed time for assembly
- **User/System time:** CPU time breakdown
- **Memory usage:** Peak resident set size
- **Output quality:** Number of contigs, assembly size
- **Scaling:** Performance across 1, 2, 4, 8+ CPUs

### Expected performance improvements

Based on profiling with synthetic data (200K SAM records):

| Pipeline Step | Perl | Rust | Speedup |
|---|---|---|---|
| `fragment_coverage_writer.pl` | 12.97s | 1.96s | 6.6× |
| `define_coverage_partitions.pl` | 27.17s | 4.01s | 6.8× |
| Overall prep pipeline | 53.01s | 18.85s | **2.8×** |

**Real-world impact depends on:**
- Input data size (more reads = more SAM processing)
- Whether genome-guided assembly is used (triggers the optimized pipeline)
- CPU count (speedup compounds with parallelization)

For de novo assembly (no genome), the Rust optimizations may have minimal impact since the bottleneck is Inchworm/Chrysalis, not SAM processing.

---

## Profiling sub-steps (Optional)

### Benchmark just SAM parsing (Perl vs Rust)

```bash
# Generate synthetic SAM file for testing
perl util/bench/generate_synthetic_sam.pl \
    --num_reads 100000 --num_scaffolds 50 \
    --out /tmp/synthetic.sam --paired

# Compare Perl vs Rust SAM parsing
perl util/bench/benchmark_sam_parsing.pl \
    --sam /tmp/synthetic.sam --iterations 3
```

### Micro-benchmarks (Rust CIGAR parsing)

```bash
# Run Criterion benchmarks
cd rust_bio_utils
cargo bench --bench cigar_benchmark
cd ..
```

### Profile the full pipeline step-by-step

```bash
# Use the included profiling harness
perl util/bench/profile_prep_rnaseq.pl \
    --coord_sorted_SAM /tmp/synthetic.sam \
    --max_intron_length 10000 \
    --min_coverage 1 \
    --backend rust  # or 'perl' to use Perl implementation
```

---

## Troubleshooting

### Issue: Rust binaries not found

```
ERROR: Could not find Rust binary for define_coverage_partitions
Falling back to Perl implementation...
```

**Solution:**
- Verify `rust_bio_utils/target/release/define_coverage_partitions` exists
- Rebuild with `make rust_bio_target` or `pixi run build-rust`
- Check that cargo built successfully: `cd rust_bio_utils && cargo build --release`

### Issue: Trinity not found or TRINITY_HOME not set

```
Must set env var TRINITY_HOME
```

**Solution:**
```bash
export TRINITY_HOME="/path/to/trinityrnaseq"
# Or on your system:
export TRINITY_HOME="$(pwd)"  # if you're in the Trinity root
```

### Issue: Build fails due to missing dependencies

**For Pixi:**
```bash
pixi install  # installs all dependencies
```

**For Conda:**
```bash
conda install -c bioconda -c conda-forge rust cmake make autoconf automake libtool
```

**For Docker:**
All dependencies are included in the Dockerfile.

### Issue: Docker image too large

The Ubuntu 24.04 Dockerfile includes many optional tools (GATK, STAR, Salmon, etc.). To create a minimal image:

```bash
# Create a minimal Dockerfile with just core Trinity
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y perl samtools bowtie2 jellyfish make cmake rust git
# ... add Trinity build steps ...
```

---

## Performance Expectations

### For de novo assembly (no genome)
- Rust optimizations have **minimal impact** since bottleneck is k-mer counting (Jellyfish) and graph construction (Inchworm/Chrysalis)
- Expect <5% improvement

### For genome-guided assembly (with genome)
- Rust optimizations have **significant impact** since bottleneck is SAM parsing and coverage calculation
- Expect 2-3× speedup for the prep pipeline
- Overall assembly speedup: 10-30% (depending on genome size and alignment volume)

### Test data (sample_data/test_Trinity_Assembly/)
- Small ~6 MB FASTQ files
- De novo assembly (no genome)
- Expect to run in **10-30 seconds** on a single CPU
- Rust optimizations unlikely to show dramatic impact on this small dataset

---

## Integration with Funannotate

When integrating Trinity into the Funannotate pipeline:

1. **Export PATH with Trinity binaries:**
   ```bash
   export PATH="/path/to/trinityrnaseq:${PATH}"
   export TRINITY_HOME="/path/to/trinityrnaseq"
   ```

2. **Run Trinity from Funannotate:**
   ```bash
   funannotate train --RNA_bam trinity_aligned.bam --genome genome.fa
   ```

3. **For best performance:**
   - Use genome-guided Trinity assembly (enables Rust optimizations)
   - Use 8+ CPUs for SAM processing
   - Pre-sort alignments by coordinate

---

## Next Steps

1. **Verify installation:** Follow the "Verifying Rust Optimizations" section above
2. **Run test assembly:** `sample_data/test_Trinity_Assembly/runMe.sh`
3. **Benchmark performance:** `util/bench/benchmark_full_trinity.sh`
4. **Compare with original:** Run same tests on `master` branch Trinity for comparison
5. **Integrate into Funannotate:** Set `TRINITY_HOME` and `PATH` when running Funannotate

---

## References

- **Optimization summary:** `docs/OPTIMIZATION_SUMMARY.md`
- **Benchmark infrastructure:** `util/bench/`
- **Rust source:** `rust_bio_utils/`
- **Main pipeline:** `util/support_scripts/prep_rnaseq_alignments_for_genome_assisted_assembly.pl`

---

## Questions or Issues?

Refer to the Trinity documentation: https://github.com/trinityrnaseq/trinityrnaseq/wiki

For Rust-specific issues, check:
- `rust_bio_utils/benches/` for benchmarking code
- `rust_bio_utils/src/` for implementation details

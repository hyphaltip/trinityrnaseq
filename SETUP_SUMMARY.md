# Trinity Rust Optimization - Complete Setup Summary

## What's Been Done

### 1. **Updated Docker Setup** ✅
- **File:** `Docker/Dockerfile.ubuntu24`
- **Base:** Ubuntu 24.04 (modern, updated versions of all tools)
- **Includes:** Rust toolchain, all build dependencies, optimized tool versions
- **Trinity branch:** `optimize_minimaxexplore` (with Rust optimizations)

**Key features:**
- Automatically builds Rust binaries during Docker build
- Verifies Rust binaries exist post-build
- Updated tool versions: R 4.3.3, Samtools 1.19, Bowtie2 2.5.3, Salmon 1.10.3, etc.

**Build and test:**
```bash
docker build -f Docker/Dockerfile.ubuntu24 -t trinity-rust-optimized:latest .
docker run --rm trinity-rust-optimized:latest Trinity --version
```

---

### 2. **Pixi Environment Setup** ✅
- **File:** `pixi.toml` (already exists on branch)
- **Status:** Ready to use — all dependencies configured
- **Build tasks:** `build`, `build-rust`, `test`, `test-trinity`, `clean`
- **Activation script:** `activation.sh` (sets TRINITY_HOME and PATH)

**Quick start:**
```bash
pixi install
pixi run build
export TRINITY_HOME="$(pwd)"
Trinity --version
```

---

### 3. **Conda Environment Alternative** ✅
- **File:** `environment-rust.yml`
- **Includes:** All dependencies (compiler, Perl, R, bioinformatics tools)
- **Lighter weight** than Docker for local development

**Setup:**
```bash
conda env create -f environment-rust.yml -n trinity-rust
conda activate trinity-rust
make all && make plugins
export TRINITY_HOME="$(pwd)"
```

---

### 4. **Comprehensive Benchmarking Infrastructure** ✅
- **Script:** `util/bench/benchmark_full_trinity.sh`
- **Purpose:** Test Trinity performance across different CPU counts
- **Metrics:** Wall time, CPU time, memory usage, assembly quality
- **Input:** Sample data included (6-10 MB FASTQ files)

**Features:**
- Tests multiple CPU counts (1, 2, 4, 8 by default)
- Captures memory usage and timing breakdown
- Detects Rust vs Perl implementation
- CSV output for easy analysis
- Results organized by test run

**Run it:**
```bash
export TRINITY_HOME="$(pwd)"
util/bench/benchmark_full_trinity.sh "1,2,4,8" ./benchmark_results
```

---

### 5. **Documentation** ✅
- **File:** `SETUP_RUST_OPTIMIZED.md`
- **Comprehensive guide** covering:
  - All 3 installation methods (Docker, pixi, conda)
  - How to verify Rust optimizations are active
  - Full benchmarking workflow
  - Performance expectations
  - Troubleshooting
  - Integration with Funannotate

---

## Expected Performance Gains

### From Profiling Data (synthetic 200K reads):

| Component | Perl | Rust | Speedup |
|---|---|---|---|
| fragment_coverage_writer | 12.97s | 1.96s | **6.6×** |
| define_coverage_partitions | 27.17s | 4.01s | **6.8×** |
| **Overall prep pipeline** | 53.01s | 18.85s | **2.8×** |

### Real-world impact:

- **De novo assembly** (no genome): ~0-5% improvement (bottleneck is k-mer counting)
- **Genome-guided assembly** (with genome): **10-30% overall speedup** (SAM processing is bottleneck)
- **With 8+ CPUs:** Better scaling and resource utilization

---

## Next Steps to Test

### 1. **Verify Rust Build**
```bash
cd /rhome/jstajich/projects/funannotate/trinityrnaseq
git checkout origin/optimize_minimaxexplore

# Using pixi
pixi install
pixi run build

# Check Rust binaries
ls -lh rust_bio_utils/target/release/define_coverage_partitions
ls -lh rust_bio_utils/target/release/fragment_coverage_writer
```

### 2. **Quick Test with Sample Data**
```bash
export TRINITY_HOME="$(pwd)"

cd sample_data/test_Trinity_Assembly
${TRINITY_HOME}/Trinity --seqType fq --max_memory 2G \
                        --left reads.left.fq.gz \
                        --right reads.right.fq.gz \
                        --SS_lib_type RF \
                        --CPU 2 \
                        --no_cleanup
```

### 3. **Run Full Benchmark**
```bash
export TRINITY_HOME="$(pwd)"
util/bench/benchmark_full_trinity.sh "1,2,4,8" ./benchmark_results
```

### 4. **Compare Results**
```bash
# View summary
cat trinity_benchmark_results/benchmark_summary.txt

# Or detailed CSV for analysis
cat trinity_benchmark_results/detailed_results.csv
```

---

## Files Created/Modified

| File | Purpose | Status |
|---|---|---|
| `Docker/Dockerfile.ubuntu24` | Ubuntu 24.04 Docker image with Rust | ✅ Created |
| `environment-rust.yml` | Conda environment specification | ✅ Created |
| `pixi.toml` | Pixi workspace config | ✅ Already exists |
| `activation.sh` | Pixi activation script | ✅ Already exists |
| `util/bench/benchmark_full_trinity.sh` | Full assembly benchmarking | ✅ Created |
| `SETUP_RUST_OPTIMIZED.md` | Comprehensive setup guide | ✅ Created |

---

## Integration Points for Funannotate

When running from Funannotate:

1. **Set environment variables:**
   ```bash
   export TRINITY_HOME="/path/to/trinityrnaseq"
   export PATH="${TRINITY_HOME}:${PATH}"
   ```

2. **Funannotate will use Trinity** for:
   - RNA-Seq assembly (if `--trinity` flag used)
   - Genome-guided assembly (if BAM file provided)

3. **Rust optimizations benefit:**
   - Genome-guided workflows most (SAM processing is optimized)
   - Large genome assemblies (more alignment data = more speedup)

---

## Recommended Test Dataset

The included sample data is small (de novo). For testing Rust optimizations:

**Ideal test case:**
- Genome-guided assembly (Trinity --genome reference.fa)
- ~50M-100M RNA-Seq reads aligned to genome
- Would show 2-3× speedup in prep pipeline

**Quick test (included):**
- De novo assembly with 6-10 MB sample data
- Runs in 10-30 seconds
- Limited Rust optimization benefit (bottleneck is k-mer counting)

Do you have a specific dataset you'd like to test with? I can help set up a benchmark with your actual data.


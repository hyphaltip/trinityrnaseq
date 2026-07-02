# Test 2: De Novo Assembly Scaling - Results Analysis

## Test Overview

**Purpose:** Measure Trinity de novo assembly performance across different CPU counts

**Data:** Sample FASTQ files from `sample_data/test_Trinity_Assembly/`
- `reads.left.fq.gz` (~1.5 MB compressed)
- `reads.right.fq.gz` (~1.5 MB compressed)
- Paired-end reads, strand-specific (RF library type)

**Configuration:**
- `--max_memory 2G` (modest memory limit)
- `--seqType fq` (FASTQ input)
- `--SS_lib_type RF` (strand-specific RF)
- `--no_cleanup` (keep intermediate files)

**CPU counts tested:** 1, 2, 4

---

## Expected Results

### Baseline Expectations (Trinity 2.15.1, no Rust optimizations)

| CPU Count | Expected Time | Contigs | Expected Speedup |
|-----------|---|---|---|
| 1 | ~20-30 sec | 800-1000 | 1.0× (baseline) |
| 2 | ~15-20 sec | 800-1000 | 1.3-2.0× |
| 4 | ~12-18 sec | 800-1000 | 1.5-2.5× |

### Contigs

Both paired and single-end assemblies expected, totaling:
- **Expected:** 800-1200 total contigs
- **Typical:** Mix of single contigs and isoform variants
- **File:** `trinity_out_dir.Trinity.fasta`

### File Size

- **Expected:** ~50-100 KB (FASTA format)
- **Depends on:** Number and length of contigs
- **Quality:** Not the focus of this test (de novo quality is separate)

---

## Interpreting Results

### CPU Scaling Efficiency

**Calculate speedup:**
```
Speedup = Time_1CPU / Time_N_CPU
```

**Expected:**
- CPU=1: 1.0× (baseline)
- CPU=2: 1.3-1.8× (Trinity has parallelizable steps)
- CPU=4: 1.5-2.5× (diminishing returns with small data)

**Why not perfect 2× and 4× scaling?**
- Some Trinity steps are inherently serial
- Jellyfish k-mer counting parallelizes well
- Inchworm/Chrysalis assembly is more serial
- Small dataset = overhead dominates

### Expected vs Actual

**If times are similar across CPU counts:**
- May indicate overhead dominates small dataset
- Or assembly completed before parallelization kicked in
- This is NORMAL for ~6 MB input data

**If time increases with more CPUs:**
- Indicates contention or overhead issues
- Check system load during test
- May need larger dataset for true scaling tests

---

## Rust Optimization Impact

### For This Test (De Novo)

**Expected Rust improvement: 0-5%**

Why so little?
1. De novo bottleneck is Jellyfish k-mer counting (~40% of time)
2. Inchworm assembly graph construction (~30% of time)
3. SAM parsing (Rust optimized) only ~10-15% of total time
4. Small dataset = measurement noise dominates

### What NOT to Expect

❌ **Do NOT expect 2.8× improvement** (that's for prep pipeline on large SAM files)  
❌ **Do NOT expect 6× improvement** (that's for individual components)  
❌ **Do NOT expect significant difference** between Perl and Rust in this test

### For Comparison with Rust-Optimized Version

If you run this test with our `optimize_minimaxexplore` branch later:
- **Expected difference:** 0-5% (within measurement noise)
- **Reason:** SAM processing not bottleneck in de novo
- **Conclusion:** Look at Test 3 (genome-guided) for real Rust benefits

---

## Results Format

Results are saved to: `test2_denovo_results_YYYYMMDD_HHMMSS/`

### Directory Structure
```
test2_denovo_results_YYYYMMDD_HHMMSS/
├── cpu_1/
│   ├── trinity_out_dir.Trinity.fasta
│   ├── trinity_output.log
│   └── trinity_out_dir/  (intermediate files)
├── cpu_2/
│   ├── trinity_out_dir.Trinity.fasta
│   ├── trinity_output.log
│   └── trinity_out_dir/
├── cpu_4/
│   ├── trinity_out_dir.Trinity.fasta
│   ├── trinity_output.log
│   └── trinity_out_dir/
└── results.csv  (timing summary)
```

### results.csv Format
```
CPU=1,Time=25s,Contigs=912,Size=58234
CPU=2,Time=18s,Contigs=912,Size=58234
CPU=4,Time=16s,Contigs=912,Size=58234
```

---

## Detailed Analysis Steps

### 1. Check Assembly Quality

```bash
# Count contigs per CPU
for dir in test2_denovo_results_*/cpu_*/; do
    echo "$(basename $(dirname $dir)): $(grep -c '>' $dir/trinity_out_dir.Trinity.fasta)"
done

# They should all have the same number of contigs
# (same input = same assembly)
```

### 2. Calculate Speedup

```bash
# Extract times from results.csv
cat test2_denovo_results_*/results.csv

# Calculate manually:
# CPU=1: 25 sec
# CPU=2: 18 sec → Speedup = 25/18 = 1.39×
# CPU=4: 16 sec → Speedup = 25/16 = 1.56×
```

### 3. Analyze Scaling Efficiency

```
Perfect scaling: 1×, 2×, 4× for CPUs 1, 2, 4
Actual expected: 1×, 1.3-1.8×, 1.5-2.5× (diminishing returns)
Parallel efficiency: (Speedup / CPU_count) × 100%

Example:
- CPU=2, 1.39× speedup: 1.39/2 = 69.5% efficiency
- CPU=4, 1.56× speedup: 1.56/4 = 39% efficiency
```

### 4. Check Logs for Warnings

```bash
# Look for any errors or warnings
grep -i "warning\|error" test2_denovo_results_*/cpu_*/trinity_output.log

# Check memory usage
grep -i "memory" test2_denovo_results_*/cpu_*/trinity_output.log
```

---

## Important Notes

### Assembly Reproducibility

All three runs should produce **identical assemblies:**
- Same number of contigs
- Same sequence content
- Only difference: timing

If contigs differ:
- May indicate non-deterministic behavior
- Or assembly was interrupted partway

### Measuring Other Runs

When you test with the Rust-optimized branch later:
- Run this same test again
- Compare timing: expect 0-5% improvement
- Focus on Test 3 (genome-guided) for real Rust benefits

### System Performance

Results depend on:
- Current system load
- I/O performance
- CPU frequency scaling
- Memory pressure

For consistent results:
- Run when system is idle
- Run multiple times, average results
- Or use SLURM to isolate job

---

## Success Criteria

✅ **Test 2 is successful if:**
- All 3 CPU runs complete without errors
- All produce the same assembly (same contig count)
- Timing varies with CPU (faster with more CPUs)
- No memory errors or warnings

---

## Next: Test 3 (Genome-Guided)

After Test 2 completes, Test 3 will show the real Rust optimization benefits:
- **Test 3a (CEA10):** ~15 minutes, 10-30% improvement expected ✅
- **Test 3b (Cordyceps):** ~30 minutes, 10-30% improvement expected ✅

Test 3 is where you'll see actual performance gains from Rust optimizations!

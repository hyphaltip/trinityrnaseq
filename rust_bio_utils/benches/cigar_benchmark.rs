use criterion::{black_box, criterion_group, criterion_main, Criterion, BenchmarkId};
use trinity_bio::sam::{SAMEntry, CigarString};

fn benchmark_cigar_parsing(c: &mut Criterion) {
    let test_cigars = vec![
        "10M",
        "50M",
        "100M",
        "10M5I10M5D10M",
        "25M100N25M",
        "5S10M5S",
        "10H10M10H",
        "10M2I5M2D5M3I2M",
    ];
    
    let mut group = c.benchmark_group("CIGAR parsing");
    for cigar in &test_cigars {
        group.bench_with_input(
            BenchmarkId::from_parameter(cigar),
            cigar,
            |b, cigar| {
                b.iter(|| {
                    CigarString::parse(black_box(cigar)).unwrap()
                });
            },
        );
    }
    group.finish();
}

fn benchmark_sam_entry_full_parse(c: &mut Criterion) {
    let test_lines = vec![
        "read001\t0\tchr1\t100\t255\t10M\t*\t0\t0\tACGTACGTAC\tIIIIIIIIII",
        "read002\t16\tchr1\t1000\t60\t50M\tchr1\t950\t0\tNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN\tIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII",
        "read003\t99\tchr1\t100\t255\t25M100N25M\tchr1\t200\t300\tACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\t!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
        "read004\t147\tchr2\t5000\t30\t10M5I10M5D10M\t=\t5100\t200\tACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\t!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
    ];
    
    c.bench_function("SAM entry full parse", |b| {
        b.iter(|| {
            for line in &test_lines {
                let entry = SAMEntry::parse(black_box(line)).unwrap();
                let _ = entry.get_genome_span();
                let _ = entry.get_read_span();
                let _ = entry.get_alignment_length();
            }
        });
    });
}

fn benchmark_sam_entry_cached(c: &mut Criterion) {
    let test_lines = vec![
        "read001\t0\tchr1\t100\t255\t10M\t*\t0\t0\tACGTACGTAC\tIIIIIIIIII",
        "read002\t16\tchr1\t1000\t60\t50M\tchr1\t950\t0\tNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN\tIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII",
        "read003\t99\tchr1\t100\t255\t25M100N25M\tchr1\t200\t300\tACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\t!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
        "read004\t147\tchr2\t5000\t30\t10M5I10M5D10M\t=\t5100\t200\tACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\t!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
    ];
    
    c.bench_function("SAM entry cached CIGAR", |b| {
        b.iter(|| {
            for line in &test_lines {
                let entry = SAMEntry::parse_with_cached_cigar(black_box(line)).unwrap();
                // Multiple accesses - should use cache
                let _ = entry.get_genome_span();
                let _ = entry.get_genome_span();
                let _ = entry.get_read_span();
                let _ = entry.get_read_span();
                let _ = entry.get_alignment_length();
                let _ = entry.get_alignment_length();
            }
        });
    });
}

fn benchmark_high_volume(c: &mut Criterion) {
    let line = "read001\t0\tchr1\t100\t255\t50M\t*\t0\t0\tNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN\tIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII";
    
    c.bench_function("high_volume_parsing", |b| {
        b.iter(|| {
            let _entry = SAMEntry::parse_with_cached_cigar(black_box(line)).unwrap();
        });
    });
}

criterion_group!(
    benches,
    benchmark_cigar_parsing,
    benchmark_sam_entry_full_parse,
    benchmark_sam_entry_cached,
    benchmark_high_volume
);
criterion_main!(benches);
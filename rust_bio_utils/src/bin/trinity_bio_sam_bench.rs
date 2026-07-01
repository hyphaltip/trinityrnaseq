use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::time::Instant;
use trinity_bio::sam::{SAMEntry, SAMEntryOptimized};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: trinity_bio_sam_bench <sam_file> [iterations=3]");
        std::process::exit(1);
    }
    let sam_file = &args[1];
    let iterations: u32 = args.get(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(3);

    let file = File::open(sam_file).expect("Cannot open SAM file");
    let reader = BufReader::with_capacity(64 * 1024, file);
    let lines: Vec<String> = reader.lines()
        .filter_map(Result::ok)
        .collect();
    let n = lines.len();
    eprintln!("Rust bench: {} records, {} iterations", n, iterations);

    let mut best_orig = u64::MAX;
    let mut best_opt = u64::MAX;
    for _ in 0..iterations {
        let t0 = Instant::now();
        let mut count = 0u64;
        for line in &lines {
            if let Ok(entry) = SAMEntry::parse(line) {
                let _ = entry.get_genome_span();
                let _ = entry.get_read_span();
                let _ = entry.get_alignment_length();
                count += 1;
            }
        }
        let elapsed = t0.elapsed().as_nanos() as u64;
        if elapsed < best_orig { best_orig = elapsed; }
        eprintln!("  original: {:.3}s ({} parsed)", elapsed as f64 / 1e9, count);
    }
    for _ in 0..iterations {
        let t0 = Instant::now();
        for line in &lines {
            if let Ok(entry) = SAMEntryOptimized::parse(line) {
                let _ = entry.get_genome_span();
                let _ = entry.get_read_span();
                let _ = entry.get_alignment_length();
            }
        }
        let elapsed = t0.elapsed().as_nanos() as u64;
        if elapsed < best_opt { best_opt = elapsed; }
        eprintln!("  optimized: {:.3}s", elapsed as f64 / 1e9);
    }

    println!("rust_original\t{:.6}\t{}", best_orig as f64 / 1e9, n);
    println!("rust_optimized\t{:.6}\t{}", best_opt as f64 / 1e9, n);
    let _ = std::io::stdout().flush();
}

// Rust replacement for util/support_scripts/define_coverage_partitions.pl
//
// Reads a WIG coverage file and outputs GFF partition regions where
// coverage >= min_coverage.
//
// Usage:
//   define_coverage_partitions <wig_file> <min_coverage> <strand[+-]>
//
// I/O contract matches define_coverage_partitions.pl exactly:
//   Input:  WIG file with "variableStep chrom=<scaffold>" headers
//           followed by "<pos>\t<cov>" lines.
//   Output: GFF lines to stdout:
//           <scaffold>\tpartition\tregion\t<lend>\t<rend>\t.\t<strand>\t.\t.\t<len>

use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Write};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!(
            "usage: {} <strand_coverage.wig> <min_coverage> <strand[+-]>",
            args.get(0).map(|s| s.as_str()).unwrap_or("define_coverage_partitions")
        );
        std::process::exit(1);
    }

    let wig_file = &args[1];
    let min_coverage: u32 = args[2].parse().unwrap_or(1);
    let strand = &args[3];

    let input: Box<dyn BufRead> = if wig_file == "-" {
        Box::new(BufReader::new(io::stdin()))
    } else {
        let file = File::open(wig_file).unwrap_or_else(|e| {
            eprintln!("Error, cannot open file {}: {}", wig_file, e);
            std::process::exit(1);
        });
        Box::new(BufReader::with_capacity(256 * 1024, file))
    };

    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(256 * 1024, stdout.lock());

    let mut scaffold = String::new();
    let mut lend: Option<u32> = None;
    let mut rend: u32 = 0;

    for line in input.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };

        // Skip lines without any word characters (blank lines, etc.)
        let has_word = line.bytes().any(|b| b.is_ascii_alphanumeric() || b == b'_');
        if !has_word {
            continue;
        }

        // Check for "variableStep chrom=<scaffold>"
        if let Some(rest) = line.strip_prefix("variableStep chrom=") {
            // Close any open block before switching scaffold
            if let Some(l) = lend {
                let len = rend - l + 1;
                let _ = writeln!(
                    out,
                    "{}\tpartition\tregion\t{}\t{}\t.\t{}\t.\t.\t{}",
                    scaffold, l, rend, strand, len
                );
            }
            lend = None;
            rend = 0;
            scaffold = rest.trim().to_string();
            continue;
        }

        // Parse "pos\tcov"
        let mut parts = line.split('\t');
        let pos_str = parts.next().unwrap_or("");
        let cov_str = parts.next().unwrap_or("");

        let pos: u32 = match pos_str.trim().parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let cov: u32 = match cov_str.trim().parse() {
            Ok(c) => c,
            Err(_) => continue,
        };

        if cov >= min_coverage {
            if lend.is_none() {
                lend = Some(pos);
                rend = pos;
            } else {
                rend = pos;
            }
        } else if let Some(l) = lend {
            // Coverage dropped below threshold — close the block
            let len = rend - l + 1;
            let _ = writeln!(
                out,
                "{}\tpartition\tregion\t{}\t{}\t.\t{}\t.\t.\t{}",
                scaffold, l, rend, strand, len
            );
            lend = None;
        }
    }

    // Close last block
    if let Some(l) = lend {
        let len = rend - l + 1;
        let _ = writeln!(
            out,
            "{}\tpartition\tregion\t{}\t{}\t.\t{}\t.\t.\t{}",
            scaffold, l, rend, strand, len
        );
    }

    let _ = out.flush();
}

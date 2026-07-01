// Rust replacement for util/support_scripts/fragment_coverage_writer.pl
//
// Reads a frag_coords file (scaffold, frag_name, lend, rend per line)
// and outputs WIG coverage per scaffold.
//
// Usage:
//   fragment_coverage_writer <file.sam.frag_coords>
//
// I/O contract matches fragment_coverage_writer.pl exactly:
//   Input:  tab-separated frag_coords: scaffold\tfrag_name\tlend\trend
//           (must be sorted by scaffold, then by position)
//   Output: WIG format to stdout:
//           variableStep chrom=<scaffold>
//           <pos>\t<cov>
//           ...

use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Write};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!(
            "usage: {} <file.sam.frag_coords>",
            args.get(0).map(|s| s.as_str()).unwrap_or("fragment_coverage_writer")
        );
        std::process::exit(1);
    }

    let frag_coords_file = &args[1];

    let input: Box<dyn BufRead> = if frag_coords_file == "-" {
        Box::new(BufReader::new(io::stdin()))
    } else {
        let file = File::open(frag_coords_file).unwrap_or_else(|e| {
            eprintln!("Error, cannot open file {}: {}", frag_coords_file, e);
            std::process::exit(1);
        });
        Box::new(BufReader::with_capacity(256 * 1024, file))
    };

    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(256 * 1024, stdout.lock());

    // Coverage array indexed by genomic position.
    // Reused (cleared) for each scaffold, matching the Perl implementation
    // which only retains one scaffold's coverage at a time.
    let mut coverage: Vec<u32> = Vec::new();
    let mut current_scaff: Option<String> = None;
    let mut counter: u64 = 0;

    for line in input.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };

        counter += 1;
        if counter % 100_000 == 0 {
            eprint!("\r[{} lines read]", counter);
        }

        // Parse: scaffold\tfrag_name\tlend\trend
        let mut parts = line.split('\t');
        let scaff = parts.next().unwrap_or("").to_string();
        let _frag_name = parts.next();
        let lend_str = parts.next().unwrap_or("0");
        let rend_str = parts.next().unwrap_or("0");

        // Check for scaffold change
        if let Some(ref current) = current_scaff {
            if scaff != *current {
                // Report coverage for the previous scaffold
                report_coverage(current, &coverage, &mut out);
                coverage.clear();
            }
        }

        current_scaff = Some(scaff);

        // Parse lend and rend
        let lend: usize = lend_str.trim().parse().unwrap_or(0);
        let rend: usize = rend_str.trim().parse().unwrap_or(0);

        if rend == 0 || lend > rend {
            continue;
        }

        // Ensure coverage array is large enough
        if coverage.len() <= rend {
            coverage.resize(rend + 1, 0);
        }

        // Add coverage from lend to rend inclusive
        for i in lend..=rend {
            coverage[i] += 1;
        }
    }

    eprintln!("\r[{} lines read]", counter);

    // Report coverage for the last scaffold
    if let Some(ref scaff) = current_scaff {
        report_coverage(scaff, &coverage, &mut out);
    }

    let _ = out.flush();
}

fn report_coverage<W: Write>(scaffold: &str, coverage: &[u32], out: &mut W) {
    // Skip empty or non-word scaffold names (matches Perl: $scaffold =~ /\w/)
    if scaffold.is_empty() || !scaffold.bytes().any(|b| b.is_ascii_alphanumeric() || b == b'_') {
        return;
    }

    let _ = writeln!(out, "variableStep chrom={}", scaffold);

    // Find first position with coverage (matches Perl find_first_cov_pos)
    let first_cov_pos = coverage
        .iter()
        .position(|&c| c > 0)
        .unwrap_or(coverage.len().saturating_sub(1));

    for i in first_cov_pos..coverage.len() {
        let _ = writeln!(out, "{}\t{}", i, coverage[i]);
    }
}

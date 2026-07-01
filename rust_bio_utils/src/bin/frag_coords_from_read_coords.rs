// Rust replacement for the read-pairing scan in extract_frag_coords() within
// util/support_scripts/SAM_to_frag_coords.pl
//
// Reads a read_coords file (already sorted by scaffold, then read name) and
// emits paired/unpaired fragment coordinate spans.
//
// Usage:
//   frag_coords_from_read_coords <read_coords_sorted_file> <output_frag_coords_file> <min_insert_size> <max_insert_size> <no_single:0|1>
//
// I/O contract matches extract_frag_coords()'s inner scan exactly:
//   Input:  tab-separated read_coords, sorted by (scaffold, read name, pair_side... position):
//           scaffold\tread_name\tpair_side\tlend\trend
//   Output: tab-separated frag_coords (NOT coordinate-sorted; caller sorts afterward):
//           scaffold\tfrag_name\tlend\trend
//
// Note: the caller is responsible for the final `sort -k1,1 -k3,3n` pass,
// exactly as the original Perl script does.

use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Write};

struct ReadCoordRecord {
    scaffold: String,
    read_name: String,
    pair_side: String,
    lend: i64,
    rend: i64,
}

fn parse_record(line: &str) -> ReadCoordRecord {
    let mut parts = line.split('\t');
    let scaffold = parts.next().unwrap_or("").to_string();
    let read_name = parts.next().unwrap_or("").to_string();
    let pair_side = parts.next().unwrap_or("").to_string();
    let lend: i64 = parts.next().unwrap_or("0").parse().unwrap_or(0);
    let rend: i64 = parts.next().unwrap_or("0").parse().unwrap_or(0);
    ReadCoordRecord { scaffold, read_name, pair_side, lend, rend }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 6 {
        eprintln!(
            "usage: {} <read_coords_sorted_file> <output_frag_coords_file> <min_insert_size> <max_insert_size> <no_single:0|1>",
            args.get(0).map(|s| s.as_str()).unwrap_or("frag_coords_from_read_coords")
        );
        std::process::exit(1);
    }

    let read_coords_file = &args[1];
    let output_file = &args[2];
    let min_insert_size: i64 = args[3].parse().unwrap_or_else(|_| {
        eprintln!("Error, invalid min_insert_size: {}", args[3]);
        std::process::exit(1);
    });
    let max_insert_size: i64 = args[4].parse().unwrap_or_else(|_| {
        eprintln!("Error, invalid max_insert_size: {}", args[4]);
        std::process::exit(1);
    });
    let no_single = args[5] == "1";

    if let Err(e) = extract_frag_coords(
        read_coords_file,
        output_file,
        min_insert_size,
        max_insert_size,
        no_single,
    ) {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

fn extract_frag_coords(
    read_coords_file: &str,
    output_file: &str,
    min_insert_size: i64,
    max_insert_size: i64,
    no_single: bool,
) -> io::Result<()> {
    let file = File::open(read_coords_file)?;
    let mut lines = BufReader::with_capacity(256 * 1024, file).lines();

    let out_file = File::create(output_file)?;
    let mut out = BufWriter::with_capacity(256 * 1024, out_file);

    let mut prev_reported_pair = String::new();
    let mut prev_reported_single = String::new();

    // Prime "first" (matches Perl: my $first = <$fh>; chomp $first;)
    let mut first: Option<String> = match lines.next() {
        Some(l) => Some(l?),
        None => None,
    };

    loop {
        let second = match lines.next() {
            Some(l) => l?,
            None => break,
        };

        let first_line = match &first {
            Some(f) => f,
            None => break,
        };

        // Matches Perl: next if ($first =~ /^\*/ && $second =~ /^\*/); (both unmapped)
        // In practice unreachable, since scaffold '*' entries are filtered out
        // upstream, but preserved here for fidelity with the raw-line check.
        if first_line.starts_with('*') && second.starts_with('*') {
            continue;
        }

        let rec_a = parse_record(first_line);
        let rec_b = parse_record(&second);

        let is_pair = rec_a.read_name == rec_b.read_name
            && rec_a.scaffold == rec_b.scaffold
            && rec_a.pair_side != rec_b.pair_side
            && rec_a.pair_side.bytes().any(|b| b.is_ascii_digit())
            && rec_b.pair_side.bytes().any(|b| b.is_ascii_digit());

        if is_pair {
            let mut coords = [rec_a.lend, rec_a.rend, rec_b.lend, rec_b.rend];
            coords.sort_unstable();
            let min = coords[0];
            let max = coords[3];
            let insert_size = max - min + 1;

            if insert_size >= min_insert_size
                && insert_size <= max_insert_size
                && rec_a.read_name != prev_reported_pair
            {
                writeln!(out, "{}\t{}\t{}\t{}", rec_a.scaffold, rec_a.read_name, min, max)?;
                prev_reported_pair = rec_a.read_name.clone();
            } else if !no_single {
                if prev_reported_single != rec_a.read_name {
                    writeln!(
                        out,
                        "{}\t{}/{}\t{}\t{}",
                        rec_a.scaffold, rec_a.read_name, rec_a.pair_side, rec_a.lend, rec_a.rend
                    )?;
                    writeln!(
                        out,
                        "{}\t{}/{}\t{}\t{}",
                        rec_b.scaffold, rec_b.read_name, rec_b.pair_side, rec_b.lend, rec_b.rend
                    )?;
                }
                prev_reported_single = rec_a.read_name.clone();
            }

            // prime new "first" (matches Perl: $first = <$fh>; chomp $first if $first;)
            first = match lines.next() {
                Some(l) => Some(l?),
                None => None,
            };
        } else {
            if !no_single {
                if prev_reported_single != rec_a.read_name {
                    writeln!(
                        out,
                        "{}\t{}/{}\t{}\t{}",
                        rec_a.scaffold, rec_a.read_name, rec_a.pair_side, rec_a.lend, rec_a.rend
                    )?;
                }
                prev_reported_single = rec_a.read_name.clone();
            }

            first = Some(second);
        }
    }

    out.flush()?;
    Ok(())
}

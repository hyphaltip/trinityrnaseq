// Rust replacement for the extract_read_coords() phase of
// util/support_scripts/SAM_to_frag_coords.pl
//
// Reads a SAM file and outputs read coordinates:
//   scaffold\tcore_read_name\tpair_side\tread_start\tread_end
//
// Usage:
//   sam_to_read_coords <input.sam> [output_file]
//
// If output_file is omitted, writes to stdout.
// If input.sam is "-", reads from stdin.

use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Write};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!(
            "usage: {} <input.sam> [output_file]",
            args.get(0).map(|s| s.as_str()).unwrap_or("sam_to_read_coords")
        );
        std::process::exit(1);
    }

    let input_file = &args[1];
    let output_file = args.get(2).map(|s| s.as_str());

    let input: Box<dyn BufRead> = if input_file == "-" {
        Box::new(BufReader::with_capacity(256 * 1024, io::stdin()))
    } else {
        let file = File::open(input_file).unwrap_or_else(|e| {
            eprintln!("Error, cannot open file {}: {}", input_file, e);
            std::process::exit(1);
        });
        Box::new(BufReader::with_capacity(256 * 1024, file))
    };

    let out: Box<dyn Write> = match output_file {
        Some("-") => Box::new(BufWriter::with_capacity(256 * 1024, io::stdout())),
        None => Box::new(BufWriter::with_capacity(256 * 1024, io::stdout())),
        Some(path) => {
            let file = File::create(path).unwrap_or_else(|e| {
                eprintln!("Error, cannot create file {}: {}", path, e);
                std::process::exit(1);
            });
            Box::new(BufWriter::with_capacity(256 * 1024, file))
        }
    };

    process_sam(input, out);
}

fn process_sam<R: BufRead, W: Write>(input: R, mut out: W) {
    let reader = BufReader::with_capacity(256 * 1024, input);
    let mut line_buf = String::with_capacity(4096);
    let mut counter: u64 = 0;

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };

        // Skip SAM header lines and empty lines
        if line.is_empty() || line.starts_with('@') {
            continue;
        }

        counter += 1;
        if counter % 100_000 == 0 {
            eprint!("\r[{} lines processed]", counter);
        }

        line_buf.clear();
        line_buf.push_str(&line);

        let result = parse_sam_line(&line_buf);
        if let Some(output_line) = result {
            let _ = out.write_all(output_line.as_bytes());
            let _ = out.write_all(b"\n");
        }
    }

    eprintln!("\r[{} lines processed]", counter);
}

fn parse_sam_line(line: &str) -> Option<String> {
    // Split into fields
    let fields: Vec<&str> = line.split('\t').collect();

    // SAM requires at least 11 fields
    if fields.len() < 11 {
        return None;
    }

    // Get scaffold name (field 2, index 2)
    let scaffold = fields[2];

    // Skip if scaffold is '*'
    if scaffold == "*" {
        return None;
    }

    // Get flag (field 1, index 1)
    let flag: u16 = fields[1].parse().unwrap_or(0);

    // Get position (field 3, index 3)
    let position: i64 = fields[3].parse().unwrap_or(0);

    // Get CIGAR (field 5, index 5)
    let cigar = fields[5];

    // Compute genome span from CIGAR
    let (genome_start, genome_end) = compute_genome_span(cigar, position);

    // Skip if read_start or read_end is 0 (matches Perl truthiness check)
    if genome_start == 0 || genome_end == 0 {
        return None;
    }

    // Get read name (field 0, index 0)
    let read_name = fields[0];

    // Compute core_read_name: strip trailing /\d (matches Perl s|/\d$||)
    let core_read_name = strip_pair_suffix(read_name);

    // Compute full_read_name: core_read_name + /1 or /2 based on flag
    let is_first = flag & 0x40 != 0;
    let is_second = flag & 0x80 != 0;

    let full_read_name: String = if is_first {
        format!("{}/1", core_read_name)
    } else if is_second {
        format!("{}/2", core_read_name)
    } else {
        core_read_name.to_string()
    };

    // Determine pair_side
    let pair_side = if full_read_name.ends_with("/1") {
        "1"
    } else if full_read_name.ends_with("/2") {
        "2"
    } else if read_name.ends_with("/1") {
        "1"
    } else if read_name.ends_with("/2") {
        "2"
    } else {
        "."
    };

    Some(format!(
        "{}\t{}\t{}\t{}\t{}",
        scaffold, core_read_name, pair_side, genome_start, genome_end
    ))
}

fn compute_genome_span(cigar: &str, position: i64) -> (i32, i32) {
    if cigar == "*" || cigar.is_empty() {
        return (position as i32, position as i32);
    }

    let mut genome_pos: i64 = position - 1; // Convert to 0-based

    let mut first_start: i64 = 0;
    let mut last_end: i64 = 0;
    let mut has_coords = false;

    let mut current_num: i64 = 0;
    for b in cigar.as_bytes() {
        if b.is_ascii_digit() {
            current_num = current_num * 10 + (*b - b'0') as i64;
        } else if b.is_ascii_alphabetic() {
            let code = *b as char;

            match code {
                'M' | '=' | 'X' => {
                    let genome_end = genome_pos + current_num;
                    let genome_start = genome_pos + 1;

                    if !has_coords {
                        first_start = genome_start;
                        has_coords = true;
                    }
                    last_end = genome_end;

                    genome_pos = genome_end;
                }
                'D' | 'N' => {
                    genome_pos += current_num;
                }
                'I' | 'S' | 'H' | 'P' => {
                    // Only query advances, genome position unchanged
                }
                _ => {}
            }

            current_num = 0;
        }
    }

    if has_coords {
        (first_start as i32, last_end as i32)
    } else {
        (position as i32, position as i32)
    }
}

fn strip_pair_suffix(read_name: &str) -> &str {
    let bytes = read_name.as_bytes();
    if bytes.len() >= 2 && bytes[bytes.len() - 2] == b'/' && bytes[bytes.len() - 1].is_ascii_digit() {
        &read_name[..bytes.len() - 2]
    } else {
        read_name
    }
}

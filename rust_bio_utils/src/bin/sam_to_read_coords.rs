// Rust replacement for the extract_read_coords() phase of
// util/support_scripts/SAM_to_frag_coords.pl
//
// Reads a SAM or BAM file and outputs read coordinates:
//   scaffold\tcore_read_name\tpair_side\tread_start\tread_end
//
// Usage:
//   sam_to_read_coords <input.sam|input.bam> [output_file]
//
// If output_file is omitted, writes to stdout.
// If input is "-", reads from stdin.
// BAM (BGZF-compressed) input is detected by its gzip magic bytes, not by
// file extension, so it works for both file paths and stdin/pipes.

use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};

use flate2::read::MultiGzDecoder;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!(
            "usage: {} <input.sam|input.bam> [output_file]",
            args.get(0).map(|s| s.as_str()).unwrap_or("sam_to_read_coords")
        );
        std::process::exit(1);
    }

    let input_file = &args[1];
    let output_file = args.get(2).map(|s| s.as_str());

    let mut input: Box<dyn BufRead> = if input_file == "-" {
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

    if is_gzip(input.as_mut()) {
        process_bam(input, out);
    } else {
        process_sam(input, out);
    }
}

// Peeks (without consuming) the first two bytes to check for the gzip magic
// number 0x1f 0x8b. BAM files are BGZF, which is a series of concatenated
// gzip members, so this also flags BAM input correctly.
fn is_gzip(input: &mut dyn BufRead) -> bool {
    match input.fill_buf() {
        Ok(buf) => buf.len() >= 2 && buf[0] == 0x1f && buf[1] == 0x8b,
        Err(_) => false,
    }
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
    let (genome_start, genome_end) = compute_genome_span_from_cigar_str(cigar, position);

    // Skip if read_start or read_end is 0 (matches Perl truthiness check)
    if genome_start == 0 || genome_end == 0 {
        return None;
    }

    // Get read name (field 0, index 0)
    let read_name = fields[0];

    build_output_line(scaffold, read_name, flag, genome_start, genome_end)
}

fn build_output_line(
    scaffold: &str,
    read_name: &str,
    flag: u16,
    genome_start: i32,
    genome_end: i32,
) -> Option<String> {
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

fn compute_genome_span_from_cigar_str(cigar: &str, position: i64) -> (i32, i32) {
    // Matches Perl SAM_entry::get_alignment_coords(), which returns ([], [])
    // for cigar '*'/empty, making get_genome_span() return (undef, undef) --
    // i.e. no aligned genome span, not a single-base span at POS.
    if cigar == "*" || cigar.is_empty() {
        return (0, 0);
    }

    let mut ops: Vec<(i64, u8)> = Vec::new();
    let mut current_num: i64 = 0;
    for b in cigar.as_bytes() {
        if b.is_ascii_digit() {
            current_num = current_num * 10 + (*b - b'0') as i64;
        } else if b.is_ascii_alphabetic() || *b == b'=' {
            ops.push((current_num, *b));
            current_num = 0;
        }
    }

    compute_genome_span_from_ops(&ops, position)
}

// Shared by both the SAM (text CIGAR) and BAM (binary CIGAR ops) parsing
// paths. `ops` is a list of (op_len, op_char) pairs using SAM's op letters
// (M, I, D, N, S, H, P, =, X).
fn compute_genome_span_from_ops(ops: &[(i64, u8)], position: i64) -> (i32, i32) {
    let mut genome_pos: i64 = position - 1; // Convert to 0-based

    let mut first_start: i64 = 0;
    let mut last_end: i64 = 0;
    let mut has_coords = false;

    for &(len, code) in ops {
        match code {
            b'M' | b'=' | b'X' => {
                let genome_end = genome_pos + len;
                let genome_start = genome_pos + 1;

                if !has_coords {
                    first_start = genome_start;
                    has_coords = true;
                }
                last_end = genome_end;

                genome_pos = genome_end;
            }
            b'D' | b'N' => {
                genome_pos += len;
            }
            b'I' | b'S' | b'H' | b'P' => {
                // Only query advances, genome position unchanged
            }
            _ => {}
        }
    }

    if has_coords {
        (first_start as i32, last_end as i32)
    } else {
        // No M/=/X op in the CIGAR (e.g. all soft-clip): Perl's loop never
        // pushes a genome coord in this case either, so there is no span.
        (0, 0)
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

// BAM CIGAR op codes (SAM spec section 4.2), in MIDNSHP=X order.
const BAM_CIGAR_OPS: [u8; 9] = [b'M', b'I', b'D', b'N', b'S', b'H', b'P', b'=', b'X'];

fn process_bam<R: Read, W: Write>(input: R, mut out: W) {
    let decoder = MultiGzDecoder::new(input);
    let mut reader = BufReader::with_capacity(256 * 1024, decoder);
    let mut counter: u64 = 0;

    let ref_names = match read_bam_header(&mut reader) {
        Ok(names) => names,
        Err(e) => {
            eprintln!("Error, failed to parse BAM header: {}", e);
            std::process::exit(1);
        }
    };

    let mut block_size_buf = [0u8; 4];
    let mut record_buf: Vec<u8> = Vec::with_capacity(4096);

    loop {
        if let Err(e) = reader.read_exact(&mut block_size_buf) {
            if e.kind() == io::ErrorKind::UnexpectedEof {
                break;
            }
            eprintln!("Error reading BAM record: {}", e);
            std::process::exit(1);
        }
        let block_size = i32::from_le_bytes(block_size_buf) as usize;

        record_buf.resize(block_size, 0);
        if let Err(e) = reader.read_exact(&mut record_buf) {
            eprintln!("Error reading BAM record body: {}", e);
            std::process::exit(1);
        }

        counter += 1;
        if counter % 100_000 == 0 {
            eprint!("\r[{} records processed]", counter);
        }

        if let Some(output_line) = parse_bam_record(&record_buf, &ref_names) {
            let _ = out.write_all(output_line.as_bytes());
            let _ = out.write_all(b"\n");
        }
    }

    eprintln!("\r[{} records processed]", counter);
}

fn read_bam_header<R: Read>(reader: &mut R) -> io::Result<Vec<String>> {
    let mut magic = [0u8; 4];
    reader.read_exact(&mut magic)?;
    if &magic != b"BAM\x01" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "not a BAM file (bad magic)",
        ));
    }

    let l_text = read_i32_le(reader)?;
    let mut text = vec![0u8; l_text.max(0) as usize];
    reader.read_exact(&mut text)?;

    let n_ref = read_i32_le(reader)?;
    let mut ref_names = Vec::with_capacity(n_ref.max(0) as usize);
    for _ in 0..n_ref {
        let l_name = read_i32_le(reader)?;
        let mut name_buf = vec![0u8; l_name.max(0) as usize];
        reader.read_exact(&mut name_buf)?;
        // name_buf includes a trailing NUL terminator
        if name_buf.last() == Some(&0) {
            name_buf.pop();
        }
        let name = String::from_utf8_lossy(&name_buf).into_owned();
        ref_names.push(name);

        let _l_ref = read_i32_le(reader)?; // reference length, unused
    }

    Ok(ref_names)
}

fn read_i32_le<R: Read>(reader: &mut R) -> io::Result<i32> {
    let mut buf = [0u8; 4];
    reader.read_exact(&mut buf)?;
    Ok(i32::from_le_bytes(buf))
}

fn parse_bam_record(buf: &[u8], ref_names: &[String]) -> Option<String> {
    if buf.len() < 32 {
        return None;
    }

    let ref_id = i32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
    let pos_0based = i32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]) as i64;
    let l_read_name = buf[8] as usize;
    let n_cigar_op = u16::from_le_bytes([buf[12], buf[13]]) as usize;
    let flag = u16::from_le_bytes([buf[14], buf[15]]);

    if ref_id < 0 {
        return None; // unmapped, matches scaffold == '*' skip in SAM path
    }
    let scaffold = ref_names.get(ref_id as usize)?;

    let read_name_start = 32;
    let read_name_end = read_name_start + l_read_name;
    if buf.len() < read_name_end || l_read_name == 0 {
        return None;
    }
    // read_name field includes a trailing NUL terminator
    let read_name = std::str::from_utf8(&buf[read_name_start..read_name_end - 1]).ok()?;

    let cigar_start = read_name_end;
    let cigar_end = cigar_start + n_cigar_op * 4;
    if buf.len() < cigar_end {
        return None;
    }

    let mut ops: Vec<(i64, u8)> = Vec::with_capacity(n_cigar_op);
    for i in 0..n_cigar_op {
        let off = cigar_start + i * 4;
        let raw = u32::from_le_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]]);
        let op_len = (raw >> 4) as i64;
        let op_code_idx = (raw & 0xF) as usize;
        let op_char = *BAM_CIGAR_OPS.get(op_code_idx)?;
        ops.push((op_len, op_char));
    }

    let (genome_start, genome_end) = compute_genome_span_from_ops(&ops, pos_0based + 1);
    if genome_start == 0 || genome_end == 0 {
        return None;
    }

    build_output_line(scaffold, read_name, flag, genome_start, genome_end)
}

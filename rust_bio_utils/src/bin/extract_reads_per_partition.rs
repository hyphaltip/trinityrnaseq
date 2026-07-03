// Rust replacement for util/support_scripts/extract_reads_per_partition.pl
//
// Reads a coordinate-sorted SAM file and a partitions GFF file,
// extracts reads into partition directories.
//
// Usage:
//   extract_reads_per_partition --partitions_gff <gff> --coord_sorted_SAM <sam>
//                               [--parts_per_directory <int>] [--min_reads_per_partition <int>]

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, BufWriter, Write};

#[derive(Clone)]
struct Partition {
    scaff: String,
    lend: i64,
    rend: i64,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: extract_reads_per_partition --partitions_gff <gff> --coord_sorted_SAM <sam>");
        std::process::exit(1);
    }

    let mut partitions_gff: Option<String> = None;
    let mut coord_sorted_sam: Option<String> = None;
    let mut parts_per_dir: i64 = 100;
    let mut min_reads_per_partition: i64 = 10;
    let mut ss_lib_type: Option<String> = None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--partitions_gff" => {
                partitions_gff = Some(args[i + 1].clone());
                i += 2;
            }
            "--coord_sorted_SAM" => {
                coord_sorted_sam = Some(args[i + 1].clone());
                i += 2;
            }
            "--parts_per_directory" => {
                parts_per_dir = args[i + 1].parse().unwrap_or(100);
                i += 2;
            }
            "--min_reads_per_partition" => {
                min_reads_per_partition = args[i + 1].parse().unwrap_or(10);
                i += 2;
            }
            "--SS_lib_type" => {
                ss_lib_type = Some(args[i + 1].clone());
                i += 2;
            }
            _ => {
                i += 1;
            }
        }
    }

    let partitions_file = partitions_gff.expect("Error, need --partitions_gff");
    let alignments_sam = coord_sorted_sam.expect("Error, need --coord_sorted_SAM");

    let partitions_dir = format!("Dir_{}", basename(&partitions_file));
    fs::create_dir_all(&partitions_dir).unwrap_or_else(|e| {
        eprintln!("Error, cannot mkdir {}: {}", partitions_dir, e);
        std::process::exit(1);
    });

    let track_path = format!("{}.listing", partitions_dir);
    let track_fh = File::create(&track_path).unwrap_or_else(|e| {
        eprintln!("Error, cannot create {}: {}", track_path, e);
        std::process::exit(1);
    });
    let mut track_writer = BufWriter::new(track_fh);

    let scaff_to_partitions = parse_partitions(&partitions_file);

    // "-" reads from stdin, so a caller can pipe `samtools view` output in
    // for BAM input instead of us having to link against htslib.
    let sam_reader: Box<dyn BufRead> = if alignments_sam == "-" {
        Box::new(BufReader::with_capacity(256 * 1024, io::stdin()))
    } else {
        let sam_file = File::open(&alignments_sam).unwrap_or_else(|e| {
            eprintln!("Error, cannot open file {}: {}", alignments_sam, e);
            std::process::exit(1);
        });
        Box::new(BufReader::with_capacity(256 * 1024, sam_file))
    };

    let mut current_scaff = String::new();
    let mut ordered_partitions: Vec<Partition> = Vec::new();
    let mut partition_idx: usize = 0;
    let mut current_partition: Option<usize> = None;
    let mut new_partition_flag;

    let mut ofh: Option<BufWriter<File>> = None;
    let mut sam_ofh: Option<BufWriter<File>> = None;
    let mut part_file = String::new();
    let mut sam_part_file = String::new();
    let mut read_counter: i64 = 0;

    for line in sam_reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };

        if line.is_empty() || line.starts_with('@') {
            continue;
        }

        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 11 {
            continue;
        }

        let scaff = fields[2];
        if scaff == "*" {
            continue;
        }

        let seq = fields[9];
        if seq == "*" {
            continue;
        }

        let flag: u16 = fields[1].parse().unwrap_or(0);
        let position: i64 = fields[3].parse().unwrap_or(0);

        let read_name = fields[0];
        let acc = reconstruct_full_read_name(read_name, flag);

        let is_reverse = flag & 0x10 != 0;
        let is_paired = flag & 0x01 != 0;
        let _is_first = flag & 0x40 != 0;
        let is_long_read = is_long_read_status(&fields);

        let mut seq_owned = seq.to_string();
        if is_reverse {
            seq_owned = reverse_complement(&seq_owned);
        }

        let _query_strand = if is_reverse { '-' } else { '+' };

        if let Some(ref ss) = ss_lib_type {
            if !is_paired {
                if !is_long_read {
                    if ss != "F" && ss != "R" {
                        eprintln!("Error, read is not paired but SS_lib_type set to paired: {}", ss);
                        std::process::exit(1);
                    }
                    if ss == "R" {
                        seq_owned = reverse_complement(&seq_owned);
                    }
                }
            } else {
                if ss != "FR" && ss != "RF" {
                    eprintln!("Error, read is paired but SS_lib_type set to unpaired: {}", ss);
                    std::process::exit(1);
                }
                let first_in_pair = flag & 0x40 != 0;
                if (first_in_pair && ss == "RF")
                    || (!first_in_pair && ss == "FR")
                {
                    seq_owned = reverse_complement(&seq_owned);
                }
            }
        }

        if scaff != current_scaff {
            current_scaff = scaff.to_string();
            ordered_partitions = scaff_to_partitions
                .get(scaff)
                .cloned()
                .unwrap_or_default();
            partition_idx = 0;
            current_partition = if !ordered_partitions.is_empty() { Some(0) } else { None };
            new_partition_flag = true;
        } else if let Some(cp) = current_partition {
            if cp < ordered_partitions.len() && position > ordered_partitions[cp].rend {
                partition_idx += 1;
                current_partition = Some(partition_idx);
                new_partition_flag = true;
            } else {
                new_partition_flag = false;
            }
        } else {
            new_partition_flag = false;
        }

        if new_partition_flag {
            if let Some(ofh) = ofh.take() {
                let _ = ofh.into_inner().map_err(|e| {
                    eprintln!("Error flushing output: {}", e);
                    e
                });
            }
            if let Some(sam_ofh) = sam_ofh.take() {
                let _ = sam_ofh.into_inner().map_err(|e| {
                    eprintln!("Error flushing SAM output: {}", e);
                    e
                });
            }
            if read_counter < min_reads_per_partition {
                let _ = fs::remove_file(&part_file);
                let _ = fs::remove_file(&sam_part_file);
            }
            read_counter = 0;
        }

        if let Some(cp) = current_partition {
            if cp < ordered_partitions.len() {
                let part = &ordered_partitions[cp];
                if position >= part.lend && position <= part.rend {
                    if ofh.is_none() {
                        let file_part_count = partition_idx / (parts_per_dir as usize);
                        let outdir = format!(
                            "{}/{}/{}",
                            partitions_dir, part.scaff, file_part_count
                        );
                        fs::create_dir_all(&outdir).unwrap_or_else(|e| {
                            eprintln!("Error, cannot mkpath {}: {}", outdir, e);
                            std::process::exit(1);
                        });

                        part_file = format!(
                            "{}/{}_{}.trinity.reads",
                            outdir, part.lend, part.rend
                        );
                        sam_part_file = format!(
                            "{}/{}_{}.sam",
                            outdir, part.lend, part.rend
                        );

                        let pf = File::create(&part_file).unwrap_or_else(|e| {
                            eprintln!("Error, cannot write to {}: {}", part_file, e);
                            std::process::exit(1);
                        });
                        ofh = Some(BufWriter::with_capacity(64 * 1024, pf));

                        let sf = File::create(&sam_part_file).unwrap_or_else(|e| {
                            eprintln!("Error, cannot write to {}: {}", sam_part_file, e);
                            std::process::exit(1);
                        });
                        sam_ofh = Some(BufWriter::with_capacity(64 * 1024, sf));

                        let _ = writeln!(
                            track_writer,
                            "{}\t{}\t{}\t{}",
                            scaff, part.lend, part.rend, part_file
                        );
                        let _ = track_writer.flush();
                    }

                    let final_acc = if is_long_read {
                        format!("LR$|{}", acc)
                    } else {
                        acc.clone()
                    };

                    if let Some(ref mut ofh) = ofh {
                        let _ = writeln!(ofh, ">{}", final_acc);
                        let _ = writeln!(ofh, "{}", seq_owned);
                    }

                    if let Some(ref mut sam_ofh) = sam_ofh {
                        let _ = writeln!(sam_ofh, "{}", line);
                    }

                    read_counter += 1;
                }
            }
        }
    }

    let _ = track_writer.flush();
    let _ = fs::remove_file(&part_file).ok();
    let _ = fs::remove_file(&sam_part_file).ok();

    if let Some(ofh) = ofh.take() {
        let _ = ofh.into_inner();
    }
    if let Some(sam_ofh) = sam_ofh.take() {
        let _ = sam_ofh.into_inner();
    }
}

fn basename(path: &str) -> String {
    let p = std::path::Path::new(path);
    p.file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string())
}

fn reconstruct_full_read_name(read_name: &str, flag: u16) -> String {
    let core = strip_pair_suffix(read_name);
    if flag & 0x40 != 0 {
        format!("{}/1", core)
    } else if flag & 0x80 != 0 {
        format!("{}/2", core)
    } else {
        core.to_string()
    }
}

fn strip_pair_suffix(read_name: &str) -> &str {
    let bytes = read_name.as_bytes();
    if bytes.len() >= 2 && bytes[bytes.len() - 2] == b'/' && bytes[bytes.len() - 1].is_ascii_digit()
    {
        &read_name[..bytes.len() - 2]
    } else {
        read_name
    }
}

fn reverse_complement(seq: &str) -> String {
    seq.bytes()
        .rev()
        .map(|b| match b {
            b'A' => b'T',
            b'T' => b'A',
            b'C' => b'G',
            b'G' => b'C',
            b'N' => b'N',
            b'a' => b't',
            b't' => b'a',
            b'c' => b'g',
            b'g' => b'c',
            b'n' => b'n',
            other => other,
        })
        .map(|b| b as char)
        .collect()
}

fn is_long_read_status(fields: &[&str]) -> bool {
    if fields.len() <= 11 {
        return false;
    }
    for f in &fields[11..] {
        if *f == "RG:Z:PBLR" {
            return true;
        }
    }
    false
}

fn parse_partitions(partitions_file: &str) -> HashMap<String, Vec<Partition>> {
    let mut scaff_to_parts: HashMap<String, Vec<Partition>> = HashMap::new();

    let fh = File::open(partitions_file).unwrap_or_else(|e| {
        eprintln!("Error, cannot open file {}: {}", partitions_file, e);
        std::process::exit(1);
    });

    let reader = BufReader::new(fh);
    let mut counter = 0;

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };

        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }

        counter += 1;
        if counter % 100 == 0 {
            eprint!("\r[{}]  ", counter);
        }

        let x: Vec<&str> = line.split('\t').collect();
        if x.len() < 5 {
            continue;
        }

        let scaff = x[0].to_string();
        let lend: i64 = x[3].parse().unwrap_or(0);
        let rend: i64 = x[4].parse().unwrap_or(0);

        scaff_to_parts
            .entry(scaff.clone())
            .or_insert_with(Vec::new)
            .push(Partition {
                scaff: scaff.clone(),
                lend,
                rend,
            });
    }

    eprintln!("\r[{}]  ", counter);

    for partitions in scaff_to_parts.values_mut() {
        partitions.sort_by_key(|p| p.lend);
    }

    scaff_to_parts
}

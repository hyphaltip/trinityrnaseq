// Rust replacement for the compute_jaccard_wig() sliding-window scanner in
// util/support_scripts/ordered_fragment_coords_to_jaccard.pl
//
// Only covers the default WIG output path (with optional -e extended counts).
// The --full / --full_extreme / -M flags remain Perl-only; the calling script
// must not dispatch to this binary when those flags are set.
//
// Usage:
//   ordered_fragment_coords_to_jaccard <lend_sorted_frags_file> <rend_sorted_frags_file> <window_length> <pseudocounts> <extended:0|1>
//
// I/O contract matches ordered_fragment_coords_to_jaccard.pl's compute_jaccard_wig():
//   Input: two copies of the frag_coords file, one sorted by (scaffold, lend),
//          one sorted by (scaffold, rend); 4 tab-separated columns:
//          scaffold, frag_name, lend, rend
//   Output: WIG-like format to stdout:
//          variableStep chrom=<scaffold>
//          <pos>\t<jaccard>[\t<num_single>\t<num_both>]

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Lines, Write};

#[derive(Clone)]
struct FragRecord {
    scaffold: String,
    acc: String,
    lend: i64,
    rend: i64,
}

fn parse_record(line: &str) -> FragRecord {
    let mut parts = line.split('\t');
    let scaffold = parts.next().unwrap_or("").to_string();
    let acc = parts.next().unwrap_or("").to_string();
    let lend: i64 = parts.next().unwrap_or("0").parse().unwrap_or(0);
    let rend: i64 = parts.next().unwrap_or("0").parse().unwrap_or(0);
    FragRecord { scaffold, acc, lend, rend }
}

struct ReadReader {
    lines: Lines<BufReader<File>>,
    current: Option<FragRecord>,
}

impl ReadReader {
    fn new(path: &str) -> io::Result<Self> {
        let file = File::open(path)?;
        let mut lines = BufReader::with_capacity(256 * 1024, file).lines();
        // Matches Perl _init(): the very first line is taken unfiltered.
        let current = lines.next().map(|l| parse_record(&l.unwrap_or_default()));
        Ok(ReadReader { lines, current })
    }

    // Matches Perl advance_line(): skip lines whose raw text ends in "/1" or "/2".
    // (In practice this never triggers for well-formed 4-column frag_coords
    // input, since the line always ends in the numeric rend field.)
    fn advance_line(&mut self) {
        loop {
            match self.lines.next() {
                None => {
                    self.current = None;
                    return;
                }
                Some(Err(_)) => continue,
                Some(Ok(line)) => {
                    if line.ends_with("/1") || line.ends_with("/2") {
                        continue;
                    }
                    self.current = Some(parse_record(&line));
                    return;
                }
            }
        }
    }

    fn curr_scaffold(&self) -> Option<&str> {
        self.current.as_ref().map(|r| r.scaffold.as_str())
    }

    fn curr_lend(&self) -> Option<i64> {
        self.current.as_ref().map(|r| r.lend)
    }

    fn advance_to_scaffold(&mut self, scaffold: &str) {
        while let Some(cur) = self.curr_scaffold() {
            if cur == scaffold {
                break;
            }
            self.advance_line();
        }
    }

    // type_is_lend: true => compare against lend, false => compare against rend
    fn advance_get_accessions(
        &mut self,
        scaffold: &str,
        position: i64,
        type_is_lend: bool,
    ) -> Vec<(String, i64, i64)> {
        let mut accs = Vec::new();
        loop {
            let (cur_scaffold, cur_acc, cur_lend, cur_rend) = match &self.current {
                None => return accs,
                Some(r) => (r.scaffold.clone(), r.acc.clone(), r.lend, r.rend),
            };
            if cur_scaffold != scaffold {
                return accs;
            }
            let pos = if type_is_lend { cur_lend } else { cur_rend };
            if pos <= position {
                accs.push((cur_acc, cur_lend, cur_rend));
                self.advance_line();
            } else {
                return accs;
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 6 {
        eprintln!(
            "usage: {} <lend_sorted_frags_file> <rend_sorted_frags_file> <window_length> <pseudocounts> <extended:0|1>",
            args.get(0).map(|s| s.as_str()).unwrap_or("ordered_fragment_coords_to_jaccard")
        );
        std::process::exit(1);
    }

    let lend_file = &args[1];
    let rend_file = &args[2];
    let window_length: i64 = args[3].parse().unwrap_or_else(|_| {
        eprintln!("Error, invalid window_length: {}", args[3]);
        std::process::exit(1);
    });
    let pseudocounts: i64 = args[4].parse().unwrap_or_else(|_| {
        eprintln!("Error, invalid pseudocounts: {}", args[4]);
        std::process::exit(1);
    });
    let extended_flag: bool = args[5] == "1";

    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(256 * 1024, stdout.lock());

    if let Err(e) = compute_jaccard_wig(
        lend_file,
        rend_file,
        window_length,
        pseudocounts,
        extended_flag,
        &mut out,
    ) {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }

    let _ = out.flush();
}

fn compute_jaccard_wig<W: Write>(
    lend_file: &str,
    rend_file: &str,
    window_length: i64,
    pseudocounts: i64,
    extended_flag: bool,
    out: &mut W,
) -> io::Result<()> {
    let mut left_scan_lend = ReadReader::new(lend_file)?;
    let mut left_scan_rend = ReadReader::new(rend_file)?;
    let mut right_scan_lend = ReadReader::new(lend_file)?;
    let mut right_scan_rend = ReadReader::new(rend_file)?;

    let mut curr_molecule = left_scan_lend.curr_scaffold().unwrap_or("").to_string();
    writeln!(out, "variableStep chrom={}", curr_molecule)?;

    let mut window_lend = left_scan_lend.curr_lend().unwrap_or(0);
    let mut window_rend;

    let mut frag_counter: HashMap<String, i32> = HashMap::new();
    let mut num_single: i64 = 0;
    let mut num_both: i64 = 0;
    let mut rend_tracker: Vec<i64> = Vec::new();
    let mut prev_pos: i64 = 0;
    let mut prev_ok = false;

    while left_scan_lend.current.is_some() {
        let left_scaffold = left_scan_lend.curr_scaffold().unwrap().to_string();

        if left_scaffold.as_str() > curr_molecule.as_str()
            && Some(left_scaffold.as_str()) == right_scan_lend.curr_scaffold()
        {
            curr_molecule = left_scaffold;
            writeln!(out, "variableStep chrom={}", curr_molecule)?;

            left_scan_rend.advance_to_scaffold(&curr_molecule);
            right_scan_lend.advance_to_scaffold(&curr_molecule);
            right_scan_rend.advance_to_scaffold(&curr_molecule);

            frag_counter.clear();
            num_single = 0;
            num_both = 0;
            prev_pos = 0;
            prev_ok = false;
            rend_tracker.clear();

            window_lend = left_scan_lend.curr_lend().unwrap();
        }

        let next_cand_lend = left_scan_lend.curr_lend().unwrap();
        let curr_rend = left_scan_lend.current.as_ref().unwrap().rend;

        rend_tracker.push(curr_rend);
        rend_tracker.sort_unstable();
        while !rend_tracker.is_empty() && rend_tracker[0] <= window_lend {
            rend_tracker.remove(0);
        }
        if !rend_tracker.is_empty() && rend_tracker[0] < next_cand_lend {
            window_lend = rend_tracker[0];
        } else {
            window_lend = next_cand_lend;
        }

        window_rend = window_lend + window_length - 1;

        // Fragment entering right window (lend of frag <= window_rend)
        {
            let accs = right_scan_lend.advance_get_accessions(&curr_molecule, window_rend, true);
            for (acc, _lend, _rend) in accs {
                let count = {
                    let c = frag_counter.entry(acc.clone()).or_insert(0);
                    *c += 1;
                    *c
                };
                if count == 1 {
                    num_single += 1;
                } else {
                    panic!(
                        "Error, lend of frag {} entering REND marker, should be seen for first time, but count is: {}",
                        acc, count
                    );
                }
            }
        }

        // Fragment exiting right window (rend of frag <= window_rend - 1)
        {
            let accs =
                right_scan_rend.advance_get_accessions(&curr_molecule, window_rend - 1, false);
            for (acc, _lend, _rend) in accs {
                match frag_counter.get_mut(&acc) {
                    Some(c) => {
                        *c -= 1;
                        let count = *c;
                        if count == 1 {
                            num_single += 1;
                            num_both -= 1;
                        } else if count == 0 {
                            num_single -= 1;
                            frag_counter.remove(&acc);
                        } else {
                            panic!("Error, count of {} is {}", acc, count);
                        }
                    }
                    None => panic!(
                        "Error, frag {} exiting rend marker and hasn't been logged",
                        acc
                    ),
                }
            }
        }

        // Fragment entering left window (lend of frag <= window_lend) - drives the loop
        {
            let accs = left_scan_lend.advance_get_accessions(&curr_molecule, window_lend, true);
            for (acc, _lend, _rend) in accs {
                let count = {
                    let c = frag_counter.entry(acc.clone()).or_insert(0);
                    *c += 1;
                    *c
                };
                if count == 2 {
                    num_single -= 1;
                    num_both += 1;
                } else if count == 1 {
                    num_single += 1;
                } else {
                    panic!("weird error, count: {}", count);
                }
            }
        }

        // Fragment exiting left window (rend of frag <= window_lend - 1)
        {
            let accs =
                left_scan_rend.advance_get_accessions(&curr_molecule, window_lend - 1, false);
            for (acc, _lend, _rend) in accs {
                match frag_counter.get_mut(&acc) {
                    Some(c) => {
                        *c -= 1;
                        let count = *c;
                        if count == 0 {
                            num_single -= 1;
                            frag_counter.remove(&acc);
                        } else {
                            panic!("Error, frag: {} rend passed left edge of window and count is: {}", acc, count);
                        }
                    }
                    None => panic!("Error, left marker has frag passing thats not logged."),
                }
            }
        }

        // compute jaccard coeff
        if window_lend >= 1 {
            let jaccard =
                (num_both + pseudocounts) as f64 / (num_single + num_both + pseudocounts) as f64;
            let jaccard_str = format!("{:.4}", jaccard);
            let mid = (window_lend + window_rend) / 2;

            // MIN_FRAGS default is 0, so this condition always holds; -M is not
            // supported by this fast path (see module doc comment).
            if prev_ok && prev_pos > 0 {
                for i in (prev_pos + 1)..mid {
                    write!(out, "{}\t{}", i, jaccard_str)?;
                    if extended_flag {
                        write!(out, "\t{}\t{}", num_single, num_both)?;
                    }
                    writeln!(out)?;
                }
            }

            write!(out, "{}\t{}", mid, jaccard_str)?;
            if extended_flag {
                write!(out, "\t{}\t{}", num_single, num_both)?;
            }
            writeln!(out)?;
            prev_ok = true;
            prev_pos = mid;
        }
    }

    Ok(())
}

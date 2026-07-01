use serde::{Deserialize, Serialize};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CigarOp {
    M,
    I,
    D,
    N,
    S,
    H,
    P,
    EQ,
    X,
}

impl CigarOp {
    fn from_char(c: char) -> Option<Self> {
        match c {
            'M' => Some(Self::M),
            'I' => Some(Self::I),
            'D' => Some(Self::D),
            'N' => Some(Self::N),
            'S' => Some(Self::S),
            'H' => Some(Self::H),
            'P' => Some(Self::P),
            '=' => Some(Self::EQ),
            'X' => Some(Self::X),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct CigarUnit {
    pub len: u32,
    pub op: CigarOp,
}

impl CigarUnit {
    #[inline]
    pub fn is_match(&self) -> bool {
        matches!(self.op, CigarOp::M | CigarOp::EQ | CigarOp::X)
    }

    #[inline]
    pub fn consumes_query(&self) -> bool {
        matches!(self.op, CigarOp::M | CigarOp::I | CigarOp::S | CigarOp::EQ | CigarOp::X)
    }

    #[inline]
    pub fn consumes_reference(&self) -> bool {
        matches!(self.op, CigarOp::M | CigarOp::D | CigarOp::N | CigarOp::EQ | CigarOp::X)
    }
}

#[derive(Debug, Clone, Default)]
pub struct CigarString {
    pub ops: Vec<CigarUnit>,
}

impl CigarString {
    pub fn parse(cigar: &str) -> Result<Self, String> {
        let mut ops = Vec::with_capacity(16);
        let mut current_num: u32 = 0;

        for b in cigar.as_bytes() {
            if b.is_ascii_digit() {
                current_num = current_num * 10 + (*b - b'0') as u32;
            } else if b.is_ascii_alphabetic() {
                if current_num == 0 {
                    return Err(format!("CIGAR has zero-length operation at: {}", cigar));
                }
                let op = CigarOp::from_char(*b as char)
                    .ok_or_else(|| format!("Unknown CIGAR op: {}", *b as char))?;
                ops.push(CigarUnit { len: current_num, op });
                current_num = 0;
            } else {
                return Err(format!("Invalid character in CIGAR: {}", *b as char));
            }
        }

        Ok(Self { ops })
    }

    #[inline]
    pub fn alignment_length(&self) -> u32 {
        self.ops.iter()
            .filter(|op| op.is_match())
            .map(|op| op.len)
            .sum()
    }

    pub fn get_alignment_coords(&self, position: i32, _read_len: u32) -> (Vec<(i32, i32)>, Vec<(i32, i32)>) {
        let mut genome_coords = Vec::with_capacity(8);
        let mut query_coords = Vec::with_capacity(8);

        let mut genome_pos = (position - 1) as i64;
        let mut query_pos: i64 = 0;

        for unit in &self.ops {
            match unit.op {
                CigarOp::M | CigarOp::EQ | CigarOp::X => {
                    let genome_end = genome_pos + unit.len as i64;
                    let query_end = query_pos + unit.len as i64;

                    genome_coords.push(((genome_pos + 1) as i32, genome_end as i32));
                    query_coords.push(((query_pos + 1) as i32, query_end as i32));

                    genome_pos = genome_end;
                    query_pos = query_end;
                }
                CigarOp::D | CigarOp::N => {
                    genome_pos += unit.len as i64;
                }
                CigarOp::I | CigarOp::S | CigarOp::P => {
                    query_pos += unit.len as i64;
                }
                CigarOp::H => {
                    query_pos += unit.len as i64;
                }
            }
        }

        (genome_coords, query_coords)
    }

    pub fn get_genome_span(&self, position: i32) -> (i32, i32) {
        let (genome_coords, _) = self.get_alignment_coords(position, 0);

        if genome_coords.is_empty() {
            return (position, position);
        }

        let first = genome_coords.first().unwrap().0;
        let last = genome_coords.last().unwrap().1;
        (first, last)
    }

    pub fn get_read_span(&self, read_len: u32) -> (i32, i32) {
        let (_, query_coords) = self.get_alignment_coords(0, read_len);

        if query_coords.is_empty() {
            return (1, read_len as i32);
        }

        let first = query_coords.first().unwrap().0;
        let last = query_coords.last().unwrap().1;
        (first, last)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SAMField {
    pub name: String,
    pub flag: u16,
    pub rname: String,
    pub pos: i32,
    pub mapq: u8,
    pub cigar: String,
    pub rnext: String,
    pub pnext: i32,
    pub tlen: i32,
    pub seq: String,
    pub qual: String,
}

impl fmt::Display for SAMField {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            self.name, self.flag, self.rname, self.pos, self.mapq,
            self.cigar, self.rnext, self.pnext, self.tlen, self.seq, self.qual)
    }
}

/// Original SAM entry: lazy CIGAR parsing, no caching.
/// Mirrors the behavior of PerlLib/SAM_entry.pm.
pub struct SAMEntry {
    fields: Vec<String>,
}

impl SAMEntry {
    pub fn parse(line: &str) -> Result<Self, String> {
        let fields: Vec<String> = line.trim_end().split('\t').map(String::from).collect();

        if fields.len() < 11 {
            return Err(format!("SAM entry has {} fields, expected at least 11", fields.len()));
        }

        Ok(Self { fields })
    }

    #[inline]
    fn field(&self, idx: usize) -> &str {
        self.fields.get(idx).map(|s| s.as_str()).unwrap_or("")
    }

    #[inline]
    pub fn get_name(&self) -> &str { self.field(0) }
    #[inline]
    pub fn get_flag(&self) -> u16 { self.field(1).parse().unwrap_or(0) }
    #[inline]
    pub fn get_rname(&self) -> &str { self.field(2) }
    #[inline]
    pub fn get_position(&self) -> i32 { self.field(3).parse().unwrap_or(0) }
    #[inline]
    pub fn get_mapq(&self) -> u8 { self.field(4).parse().unwrap_or(255) }
    #[inline]
    pub fn get_cigar(&self) -> &str { self.field(5) }
    #[inline]
    pub fn get_rnext(&self) -> &str { self.field(6) }
    #[inline]
    pub fn get_pnext(&self) -> i32 { self.field(7).parse().unwrap_or(0) }
    #[inline]
    pub fn get_tlen(&self) -> i32 { self.field(8).parse().unwrap_or(0) }
    #[inline]
    pub fn get_seq(&self) -> &str { self.field(9) }
    #[inline]
    pub fn get_qual(&self) -> &str { self.field(10) }

    #[inline]
    pub fn is_paired(&self) -> bool { self.get_flag() & 0x1 != 0 }
    #[inline]
    pub fn is_proper_pair(&self) -> bool { self.get_flag() & 0x2 != 0 }
    #[inline]
    pub fn is_unmapped(&self) -> bool { self.get_flag() & 0x4 != 0 }
    #[inline]
    pub fn is_reverse_strand(&self) -> bool { self.get_flag() & 0x10 != 0 }
    #[inline]
    pub fn is_first_in_pair(&self) -> bool { self.get_flag() & 0x40 != 0 }
    #[inline]
    pub fn is_second_in_pair(&self) -> bool { self.get_flag() & 0x80 != 0 }

    pub fn parse_cigar(&self) -> Result<CigarString, String> {
        CigarString::parse(self.get_cigar())
    }

    pub fn get_alignment_coords(&self) -> (Vec<(i32, i32)>, Vec<(i32, i32)>) {
        let cigar = match self.parse_cigar() {
            Ok(c) => c,
            Err(_) => return (Vec::new(), Vec::new()),
        };
        let read_len = self.get_seq().len() as u32;
        cigar.get_alignment_coords(self.get_position(), read_len)
    }

    pub fn get_genome_span(&self) -> (i32, i32) {
        match self.parse_cigar() {
            Ok(c) => c.get_genome_span(self.get_position()),
            Err(_) => (self.get_position(), self.get_position()),
        }
    }

    pub fn get_read_span(&self) -> (i32, i32) {
        let read_len = self.get_seq().len() as u32;
        match self.parse_cigar() {
            Ok(c) => c.get_read_span(read_len),
            Err(_) => (1, read_len as i32),
        }
    }

    pub fn get_alignment_length(&self) -> u32 {
        match self.parse_cigar() {
            Ok(c) => c.alignment_length(),
            Err(_) => 0,
        }
    }
}

/// Optimized SAM entry: pre-parses CIGAR and caches all span/length
/// calculations at parse time.  Mirrors PerlLib/SAM_entry_optimized.pm.
pub struct SAMEntryOptimized {
    fields: Vec<String>,
    cigar: CigarString,
    genome_span: (i32, i32),
    read_span: (i32, i32),
    alignment_length: u32,
}

impl SAMEntryOptimized {
    pub fn parse(line: &str) -> Result<Self, String> {
        let fields: Vec<String> = line.trim_end().split('\t').map(String::from).collect();

        if fields.len() < 11 {
            return Err(format!("SAM entry has {} fields, expected at least 11", fields.len()));
        }

        // Build a temporary SAMEntry to extract fields for cigar/span calc
        let entry = SAMEntry { fields: fields.clone() };
        let cigar = entry.parse_cigar().unwrap_or(CigarString::default());
        let read_len = entry.get_seq().len() as u32;

        let genome_span = cigar.get_genome_span(entry.get_position());
        let read_span = cigar.get_read_span(read_len);
        let alignment_length = cigar.alignment_length();

        Ok(Self {
            fields,
            cigar,
            genome_span,
            read_span,
            alignment_length,
        })
    }

    #[inline]
    fn field(&self, idx: usize) -> &str {
        self.fields.get(idx).map(|s| s.as_str()).unwrap_or("")
    }

    #[inline]
    pub fn get_name(&self) -> &str { self.field(0) }
    #[inline]
    pub fn get_flag(&self) -> u16 { self.field(1).parse().unwrap_or(0) }
    #[inline]
    pub fn get_rname(&self) -> &str { self.field(2) }
    #[inline]
    pub fn get_position(&self) -> i32 { self.field(3).parse().unwrap_or(0) }
    #[inline]
    pub fn get_mapq(&self) -> u8 { self.field(4).parse().unwrap_or(255) }
    #[inline]
    pub fn get_cigar(&self) -> &str { self.field(5) }
    #[inline]
    pub fn get_rnext(&self) -> &str { self.field(6) }
    #[inline]
    pub fn get_pnext(&self) -> i32 { self.field(7).parse().unwrap_or(0) }
    #[inline]
    pub fn get_tlen(&self) -> i32 { self.field(8).parse().unwrap_or(0) }
    #[inline]
    pub fn get_seq(&self) -> &str { self.field(9) }
    #[inline]
    pub fn get_qual(&self) -> &str { self.field(10) }

    #[inline]
    pub fn is_paired(&self) -> bool { self.get_flag() & 0x1 != 0 }
    #[inline]
    pub fn is_proper_pair(&self) -> bool { self.get_flag() & 0x2 != 0 }
    #[inline]
    pub fn is_unmapped(&self) -> bool { self.get_flag() & 0x4 != 0 }
    #[inline]
    pub fn is_reverse_strand(&self) -> bool { self.get_flag() & 0x10 != 0 }
    #[inline]
    pub fn is_first_in_pair(&self) -> bool { self.get_flag() & 0x40 != 0 }
    #[inline]
    pub fn is_second_in_pair(&self) -> bool { self.get_flag() & 0x80 != 0 }

    #[inline]
    pub fn get_cigar_parsed(&self) -> &CigarString { &self.cigar }
    #[inline]
    pub fn get_genome_span(&self) -> (i32, i32) { self.genome_span }
    #[inline]
    pub fn get_read_span(&self) -> (i32, i32) { self.read_span }
    #[inline]
    pub fn get_alignment_length(&self) -> u32 { self.alignment_length }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cigar_parsing() {
        let cigar = CigarString::parse("10M5I10M").unwrap();
        assert_eq!(cigar.ops.len(), 3);
        assert_eq!(cigar.ops[0].len, 10);
        assert_eq!(cigar.ops[0].op, CigarOp::M);
    }

    #[test]
    fn test_sam_entry() {
        let line = "read001\t0\tchr1\t100\t255\t10M\t*\t0\t0\tACGTACGTAC\tIIIIIIIIII";
        let entry = SAMEntry::parse(line).unwrap();

        assert_eq!(entry.get_name(), "read001");
        assert_eq!(entry.get_position(), 100);
        assert_eq!(entry.get_cigar(), "10M");

        let span = entry.get_genome_span();
        assert_eq!(span, (100, 109));
    }

    #[test]
    fn test_optimized_entry() {
        let line = "read001\t0\tchr1\t100\t255\t10M\t*\t0\t0\tACGTACGTAC\tIIIIIIIIII";
        let entry = SAMEntryOptimized::parse(line).unwrap();

        assert_eq!(entry.get_genome_span(), (100, 109));
        assert_eq!(entry.get_alignment_length(), 10);
    }

    #[test]
    fn test_complex_cigar() {
        let line = "read002\t16\tchr2\t5000\t60\t10M5I10M5D10M\t=\t5100\t200\tACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\t!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";
        let entry = SAMEntryOptimized::parse(line).unwrap();
        let span = entry.get_genome_span();
        assert!(span.1 > span.0);
    }
}

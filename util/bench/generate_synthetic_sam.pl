#!/usr/bin/env perl

# Generates a coordinate-sorted SAM file for benchmarking the
# prep_rnaseq_alignments_for_genome_assisted_assembly.pl pipeline.
#
# Usage:
#   generate_synthetic_sam.pl --num_reads 1000000 --num_scaffolds 100 \
#       --out synthetic.sam [--paired] [--max_intron 10000]
#
# The output is a valid SAM file (no header) that is coordinate-sorted,
# making it suitable for exercising SAM_to_frag_coords.pl,
# fragment_coverage_writer.pl, define_coverage_partitions.pl, and
# extract_reads_per_partition.pl.

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case bundling);

my $num_reads      = 1_000_000;
my $num_scaffolds  = 100;
my $scaffold_len   = 1_000_000;
my $read_len       = 75;
my $out            = "synthetic.sam";
my $paired         = 0;
my $max_intron     = 10_000;
my $seed           = 42;

GetOptions(
    'num_reads=i'      => \$num_reads,
    'num_scaffolds=i'  => \$num_scaffolds,
    'scaffold_len=i'   => \$scaffold_len,
    'read_len=i'       => \$read_len,
    'out=s'            => \$out,
    'paired'           => \$paired,
    'max_intron=i'     => \$max_intron,
    'seed=i'           => \$seed,
);

# Simple deterministic PRNG (linear congruential) so runs are reproducible.
my $state = $seed;
sub rand_int {
    my ($max) = @_;
    $state = ($state * 1103515245 + 12345) & 0x7fffffff;
    return $state % $max;
}

my @cigar_templates = (
    "${read_len}M",
    "25M100N${\($read_len-25)}M",
    "10M5I${\($read_len-15)}M",
    "50M5D${\($read_len-50)}M",
    "5S${\($read_len-10)}M5S",
);

my @nucleotides = ('A','C','G','T','N');
my @qual_chars  = map { chr(33 + $_) } (0..41);

sub random_seq {
    my $n = shift;
    my $seq = '';
    for (1..$n) { $seq .= $nucleotides[rand_int(scalar @nucleotides)]; }
    return $seq;
}

sub random_qual {
    my $n = shift;
    my $q = '';
    for (1..$n) { $q .= $qual_chars[rand_int(scalar @qual_chars)]; }
    return $q;
}

# Generate read records, then sort by scaffold and position.
my @records;

for my $i (1..$num_reads) {
    my $scaff_idx  = rand_int($num_scaffolds);
    my $scaff      = "scaffold_${scaff_idx}";
    my $pos        = 1 + rand_int($scaffold_len - $read_len - $max_intron);
    my $cigar      = $cigar_templates[rand_int(scalar @cigar_templates)];
    my $seq        = random_seq($read_len);
    my $qual       = random_qual($read_len);
    my $read_name  = "read_${i}";

    if ($paired) {
        # Mate position downstream within insert
        my $mate_pos   = $pos + 200 + rand_int(300);
        my $insert_len = $mate_pos + $read_len - $pos;
        my $flag_first = 0x01 | 0x02 | 0x40;          # paired, proper, first
        my $flag_sec   = 0x01 | 0x02 | 0x80 | 0x10;   # paired, proper, second, reverse
        push @records, [
            $scaff_idx, $pos,
            join("\t", $read_name, $flag_first, $scaff, $pos, 60,
                $cigar, "=", $mate_pos, $insert_len, $seq, $qual),
        ];
        push @records, [
            $scaff_idx, $mate_pos,
            join("\t", $read_name, $flag_sec, $scaff, $mate_pos, 60,
                $cigar, "=", $pos, -$insert_len, $seq, $qual),
        ];
    }
    else {
        my $flag = 0;  # unpaired forward
        push @records, [
            $scaff_idx, $pos,
            join("\t", $read_name, $flag, $scaff, $pos, 60,
                $cigar, "*", 0, 0, $seq, $qual),
        ];
    }
}

# Coordinate sort: by scaffold idx, then position
@records = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @records;

open(my $fh, '>', $out) or die "Cannot open $out: $!";
for my $rec (@records) {
    print $fh $rec->[2], "\n";
}
close $fh;

my $total = scalar @records;
print STDERR "Generated $total SAM records across $num_scaffolds scaffolds -> $out\n";

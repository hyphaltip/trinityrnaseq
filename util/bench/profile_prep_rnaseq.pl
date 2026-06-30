#!/usr/bin/env perl

# Profiles the prep_rnaseq_alignments_for_genome_assisted_assembly.pl pipeline.
# Times each sub-script (SAM_to_frag_coords.pl, fragment_coverage_writer.pl,
# define_coverage_partitions.pl, extract_reads_per_partition.pl) so we can
# identify which step dominates wall-clock time and target Rust rewrites
# accordingly.
#
# Usage:
#   profile_prep_rnaseq.pl --coord_sorted_SAM <sam> --max_intron_length <int> \
#       [--SS_lib_type <F|R|FR|RF>] [--CPU <int>] [--sort_buffer 10G] \
#       [--min_coverage 1] [--min_reads_per_partition 10] \
#       [--parts_per_directory 100] [--backend perl|rust]
#
# Output: a single line per stage to STDERR prefixed with "PROFILE<TAB>",
# followed by a summary table.

use strict;
use warnings;
use Time::HiRes qw(gettimeofday tv_interval);
use File::Basename;
use FindBin;
use lib "$FindBin::RealBin/../../PerlLib";
use Getopt::Long qw(:config no_ignore_case bundling);

my $SAM_file;
my $SS_lib_type    = "";
my $max_intron_length;
my $min_coverage   = 1;
my $min_reads_per_partition = 10;
my $parts_per_dir  = 100;
my $CPU            = 2;
my $sort_buffer    = '10G';
my $backend        = 'perl';  # 'perl' or 'rust'

GetOptions(
    'coord_sorted_SAM=s' => \$SAM_file,
    'SS_lib_type=s'      => \$SS_lib_type,
    'I=i'                => \$max_intron_length,
    'max_intron_length=i'=> \$max_intron_length,
    'C=i'                => \$min_coverage,
    'min_coverage=i'     => \$min_coverage,
    'min_reads_per_partition=i' => \$min_reads_per_partition,
    'parts_per_directory=i'     => \$parts_per_dir,
    'CPU=i'              => \$CPU,
    'sort_buffer=s'      => \$sort_buffer,
    'backend=s'          => \$backend,
);

die "Usage: $0 --coord_sorted_SAM <sam> --max_intron_length <int> [options]\n"
    unless $SAM_file && defined $max_intron_length;

my $UTIL_DIR = "$FindBin::RealBin/../support_scripts";
my $RUST_DIR = "$FindBin::RealBin/../../rust_bio_utils/target/release";
my @stages;  # array of [name, elapsed_seconds]

# Locate Rust binaries
my $rust_frag_writer    = "$RUST_DIR/fragment_coverage_writer";
my $rust_define_parts   = "$RUST_DIR/define_coverage_partitions";

sub run_timed {
    my ($name, $cmd) = @_;
    print STDERR "CMD: $cmd\n";
    my $t0 = [gettimeofday];
    my $ret = system($cmd);
    my $elapsed = tv_interval($t0);
    push @stages, [$name, $elapsed];
    print STDERR "PROFILE\t$name\t${elapsed}s\n";
    if ($ret) { die "Error, command failed ($ret): $cmd\n"; }
    return $elapsed;
}

sub profile_strand {
    my ($sam, $strand) = @_;
    my $sam_basename = basename($sam);

    # 1. SAM_to_frag_coords.pl  -- THE noted bottleneck
    my $cmd = "$UTIL_DIR/SAM_to_frag_coords.pl --CPU $CPU --sort_buffer $sort_buffer "
            . "--sam $sam --min_insert_size 1 --max_insert_size $max_intron_length";
    run_timed("SAM_to_frag_coords[$strand]", $cmd) unless (-s "$sam.frag_coords");

    # 2. fragment_coverage_writer.pl
    $cmd = "$UTIL_DIR/fragment_coverage_writer.pl $sam.frag_coords > $sam.frag_coverage.wig";
    run_timed("fragment_coverage_writer[$strand]", $cmd) unless (-s "$sam.frag_coverage.wig.ok");

    # 3. define_coverage_partitions.pl
    my $partitions_file = "$sam.minC$min_coverage.gff";
    $cmd = "$UTIL_DIR/define_coverage_partitions.pl $sam.frag_coverage.wig $min_coverage $strand > $partitions_file";
    run_timed("define_coverage_partitions[$strand]", $cmd) unless (-s "$partitions_file.ok");

    # 4. extract_reads_per_partition.pl
    $cmd = "$UTIL_DIR/extract_reads_per_partition.pl --partitions_gff $partitions_file "
         . "--coord_sorted_SAM $sam --parts_per_directory $parts_per_dir "
         . "--min_reads_per_partition $min_reads_per_partition";
    if ($SS_lib_type) { $cmd .= " --SS_lib_type $SS_lib_type"; }
    my $partitions_dir = "Dir_" . basename($partitions_file);
    run_timed("extract_reads_per_partition[$strand]", $cmd) unless (-d $partitions_dir && -e "$partitions_dir.ok");
}

sub profile_strand_rust {
    my ($sam, $strand) = @_;

    # 1. SAM_to_frag_coords.pl (internally uses Rust sam_to_read_coords)
    my $cmd = "$UTIL_DIR/SAM_to_frag_coords.pl --CPU $CPU --sort_buffer $sort_buffer "
            . "--sam $sam --min_insert_size 1 --max_insert_size $max_intron_length";
    run_timed("SAM_to_frag_coords[$strand]", $cmd) unless (-s "$sam.frag_coords");

    # 2. fragment_coverage_writer (Rust)
    $cmd = "$rust_frag_writer $sam.frag_coords > $sam.frag_coverage.wig";
    run_timed("fragment_coverage_writer[$strand]", $cmd) unless (-s "$sam.frag_coverage.wig.ok");

    # 3. define_coverage_partitions (Rust)
    my $partitions_file = "$sam.minC$min_coverage.gff";
    $cmd = "$rust_define_parts $sam.frag_coverage.wig $min_coverage $strand > $partitions_file";
    run_timed("define_coverage_partitions[$strand]", $cmd) unless (-s "$partitions_file.ok");

    # 4. extract_reads_per_partition (Rust)
    my $rust_extract = "$RUST_DIR/extract_reads_per_partition";
    $cmd = "$rust_extract --partitions_gff $partitions_file "
         . "--coord_sorted_SAM $sam --parts_per_directory $parts_per_dir "
         . "--min_reads_per_partition $min_reads_per_partition";
    if ($SS_lib_type) { $cmd .= " --SS_lib_type $SS_lib_type"; }
    my $partitions_dir = "Dir_" . basename($partitions_file);
    run_timed("extract_reads_per_partition[$strand]", $cmd) unless (-d $partitions_dir && -e "$partitions_dir.ok");
}

# Optional strand separation
if ($SS_lib_type) {
    my $sam_basename = basename($SAM_file);
    my ($plus_sam, $minus_sam) = ("$sam_basename.+.sam", "$sam_basename.-.sam");
    my $cmd = "$UTIL_DIR/SAM_strand_separator.pl $SAM_file $SS_lib_type";
    run_timed("SAM_strand_separator", $cmd) unless (-s $plus_sam && -s $minus_sam);
    if ($backend eq 'rust') {
        profile_strand_rust($plus_sam, '+');
        profile_strand_rust($minus_sam, '-');
    } else {
        profile_strand($plus_sam, '+');
        profile_strand($minus_sam, '-');
    }
} else {
    # Symlink to cwd if needed
    unless (-e basename($SAM_file)) {
        symlink($SAM_file, basename($SAM_file)) or die "symlink: $!";
    }
    if ($backend eq 'rust') {
        profile_strand_rust(basename($SAM_file), '+');
    } else {
        profile_strand(basename($SAM_file), '+');
    }
}

# Summary
print STDERR "\n", "=" x 70, "\n";
print STDERR "PIPELINE PROFILE SUMMARY (backend: $backend)\n";
print STDERR "=" x 70, "\n";
my $total = 0;
for my $s (@stages) {
    printf STDERR "%-50s %10.3fs\n", $s->[0], $s->[1];
    $total += $s->[1];
}
print STDERR "-" x 70, "\n";
printf STDERR "%-50s %10.3fs\n", "TOTAL", $total;
print STDERR "=" x 70, "\n";

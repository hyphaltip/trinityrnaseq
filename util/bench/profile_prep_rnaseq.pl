#!/usr/bin/env perl

# Profiles the prep_rnaseq_alignments_for_genome_assisted_assembly.pl pipeline.
# Times each sub-script/stage (SAM_to_frag_coords.pl's read-coords extraction
# and fragment-pairing sub-stages, ordered_fragment_coords_to_jaccard.pl,
# fragment_coverage_writer.pl, define_coverage_partitions.pl,
# extract_reads_per_partition.pl) so we can identify which step dominates
# wall-clock time and measure the effect of the Rust rewrites.
#
# Every stage's sub-script decides for itself whether to use its Rust binary
# (via find_rust_binary(), which checks rust_bio_utils/target/release), so
# the true way to compare backends is to disable Rust everywhere at once.
# --no-rust does this by setting TRINITY_NO_RUST=1 in the environment for
# every command this script runs; every find_rust_binary() implementation in
# the codebase checks that variable and falls back to Perl when it is set.
#
# Usage:
#   profile_prep_rnaseq.pl --coord_sorted_SAM <sam> --max_intron_length <int> \
#       [--SS_lib_type <F|R|FR|RF>] [--CPU <int>] [--sort_buffer 10G] \
#       [--min_coverage 1] [--min_reads_per_partition 10] \
#       [--parts_per_directory 100] [--no-rust] [--jaccard_win_length 100]
#
#   # Compare both backends in one run:
#   profile_prep_rnaseq.pl --coord_sorted_SAM <sam> --max_intron_length <int> --compare
#
# Output: a single line per stage to STDERR prefixed with "PROFILE<TAB>",
# followed by a summary table (and a side-by-side comparison with --compare).

use strict;
use warnings;
use Time::HiRes qw(gettimeofday tv_interval);
use File::Basename;
use Cwd;
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
my $jaccard_win_length = 100;
my $no_rust        = 0;
my $compare        = 0;

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
    'jaccard_win_length=i' => \$jaccard_win_length,
    'no-rust'            => \$no_rust,
    'compare'            => \$compare,
);

die "Usage: $0 --coord_sorted_SAM <sam> --max_intron_length <int> [--no-rust] [--compare] [options]\n"
    unless $SAM_file && defined $max_intron_length;

# Resolve to an absolute path up front: --compare/per-backend runs chdir into
# separate workdirs, so a relative $SAM_file would no longer resolve there.
$SAM_file = Cwd::abs_path($SAM_file) or die "Error, cannot resolve path to $SAM_file";

my $UTIL_DIR = "$FindBin::RealBin/../support_scripts";
my $RUST_DIR = "$FindBin::RealBin/../../rust_bio_utils/target/release";

my @stages;  # array of [name, elapsed_seconds]

# Same convention as the rest of the codebase: honors TRINITY_NO_RUST so a
# single toggle disables Rust everywhere, including for stages in this script
# that invoke a Rust binary directly rather than through a dispatching .pl.
sub find_rust_binary {
    my ($name) = @_;
    return undef if $ENV{TRINITY_NO_RUST};
    my $path = "$RUST_DIR/$name";
    return (-x $path) ? $path : undef;
}

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

# Runs the full sam->frag_coords->jaccard/coverage->partitions->extraction
# pipeline for one strand, timing each stage. All sub-scripts decide
# internally (via find_rust_binary()/TRINITY_NO_RUST) whether to use Rust.
sub profile_strand {
    my ($sam, $strand) = @_;

    # 1. SAM_to_frag_coords.pl -- internally: sam_to_read_coords (Rust) +
    #    frag_coords_from_read_coords (Rust), each falling back to Perl.
    my $cmd = "$UTIL_DIR/SAM_to_frag_coords.pl --CPU $CPU --sort_buffer $sort_buffer "
            . "--sam $sam --min_insert_size 1 --max_insert_size $max_intron_length";
    run_timed("SAM_to_frag_coords[$strand]", $cmd) unless (-s "$sam.frag_coords");

    # 2. fragment_coverage_writer -- fragment_coverage_writer.pl itself has no
    #    Rust dispatch (only its *callers* do), so pick the binary here.
    my $frag_writer = find_rust_binary("fragment_coverage_writer") || "$UTIL_DIR/fragment_coverage_writer.pl";
    $cmd = "$frag_writer $sam.frag_coords > $sam.frag_coverage.wig";
    run_timed("fragment_coverage_writer[$strand]", $cmd) unless (-s "$sam.frag_coverage.wig.ok");

    # 3. define_coverage_partitions -- same caveat as fragment_coverage_writer:
    #    the .pl script has no internal Rust dispatch, only its callers do.
    my $partitions_file = "$sam.minC$min_coverage.gff";
    my $define_parts = find_rust_binary("define_coverage_partitions") || "$UTIL_DIR/define_coverage_partitions.pl";
    $cmd = "$define_parts $sam.frag_coverage.wig $min_coverage $strand > $partitions_file";
    run_timed("define_coverage_partitions[$strand]", $cmd) unless (-s "$partitions_file.ok");

    # 4. extract_reads_per_partition -- same caveat.
    my $extract_reads = find_rust_binary("extract_reads_per_partition") || "$UTIL_DIR/extract_reads_per_partition.pl";
    $cmd = "$extract_reads --partitions_gff $partitions_file "
         . "--coord_sorted_SAM $sam --parts_per_directory $parts_per_dir "
         . "--min_reads_per_partition $min_reads_per_partition";
    if ($SS_lib_type) { $cmd .= " --SS_lib_type $SS_lib_type"; }
    my $partitions_dir = "Dir_" . basename($partitions_file);
    run_timed("extract_reads_per_partition[$strand]", $cmd) unless (-d $partitions_dir && -e "$partitions_dir.ok");

    # 5. ordered_fragment_coords_to_jaccard.pl (dispatches to Rust binary if present)
    $cmd = "$UTIL_DIR/ordered_fragment_coords_to_jaccard.pl --lend_sorted_frags $sam.frag_coords "
         . "-W $jaccard_win_length --pseudocounts 1 -e > $sam.frag_coords.jaccard.wig";
    run_timed("ordered_fragment_coords_to_jaccard[$strand]", $cmd) unless (-s "$sam.frag_coords.jaccard.wig");
}

sub run_pipeline {
    @stages = ();

    if ($SS_lib_type) {
        my $sam_basename = basename($SAM_file);
        my ($plus_sam, $minus_sam) = ("$sam_basename.+.sam", "$sam_basename.-.sam");
        my $cmd = "$UTIL_DIR/SAM_strand_separator.pl $SAM_file $SS_lib_type";
        run_timed("SAM_strand_separator", $cmd) unless (-s $plus_sam && -s $minus_sam);
        profile_strand($plus_sam, '+');
        profile_strand($minus_sam, '-');
    } else {
        unless (-e basename($SAM_file)) {
            symlink($SAM_file, basename($SAM_file)) or die "symlink: $!";
        }
        profile_strand(basename($SAM_file), '+');
    }

    my $total = 0;
    $total += $_->[1] for @stages;
    return ($total, [@stages]);
}

sub print_summary {
    my ($label, $total, $stages_aref) = @_;
    print STDERR "\n", "=" x 70, "\n";
    print STDERR "PIPELINE PROFILE SUMMARY ($label)\n";
    print STDERR "=" x 70, "\n";
    for my $s (@$stages_aref) {
        printf STDERR "%-50s %10.3fs\n", $s->[0], $s->[1];
    }
    print STDERR "-" x 70, "\n";
    printf STDERR "%-50s %10.3fs\n", "TOTAL", $total;
    print STDERR "=" x 70, "\n";
}

# Work directories are kept separate per backend so a --compare run doesn't
# reuse cached intermediate files (.ok markers etc.) across backends.
sub run_in_workdir {
    my ($label, $env_no_rust) = @_;

    my $workdir = "profile_workdir.$label";
    unless (-d $workdir) {
        mkdir($workdir) or die "Error, cannot mkdir $workdir: $!";
    }
    my $orig_dir = Cwd::getcwd();
    chdir($workdir) or die "Error, cannot chdir $workdir: $!";

    local $ENV{TRINITY_NO_RUST} = $env_no_rust ? 1 : 0;

    my ($total, $stages_aref) = run_pipeline();

    chdir($orig_dir) or die "Error, cannot chdir back to $orig_dir: $!";

    return ($total, $stages_aref);
}

if ($compare) {
    my ($rust_total, $rust_stages)   = run_in_workdir("rust", 0);
    print_summary("backend: rust (default)", $rust_total, $rust_stages);

    my ($perl_total, $perl_stages)   = run_in_workdir("perl", 1);
    print_summary("backend: perl (TRINITY_NO_RUST=1)", $perl_total, $perl_stages);

    print STDERR "\n", "=" x 70, "\n";
    print STDERR "RUST vs PERL PER-STAGE COMPARISON\n";
    print STDERR "=" x 70, "\n";
    printf STDERR "%-40s %10s %10s %10s\n", "STAGE", "RUST(s)", "PERL(s)", "SPEEDUP";
    for (my $i = 0; $i < @$rust_stages; $i++) {
        my $name       = $rust_stages->[$i][0];
        my $rust_time  = $rust_stages->[$i][1];
        my $perl_time  = $perl_stages->[$i][1];
        my $speedup    = $rust_time > 0 ? $perl_time / $rust_time : 0;
        printf STDERR "%-40s %10.3f %10.3f %9.2fx\n", $name, $rust_time, $perl_time, $speedup;
    }
    my $total_speedup = $rust_total > 0 ? $perl_total / $rust_total : 0;
    print STDERR "-" x 70, "\n";
    printf STDERR "%-40s %10.3f %10.3f %9.2fx\n", "TOTAL", $rust_total, $perl_total, $total_speedup;
    print STDERR "=" x 70, "\n";
}
else {
    local $ENV{TRINITY_NO_RUST} = $no_rust ? 1 : 0;
    my ($total, $stages_aref) = run_pipeline();
    print_summary($no_rust ? "backend: perl (--no-rust)" : "backend: rust (default)", $total, $stages_aref);
}

#!/usr/bin/env perl

# Head-to-head benchmark of Perl SAM_entry.pm vs the Rust trinity_bio SAM
# parser, on a real (synthetic) SAM file.  Uses Time::HiRes to measure
# end-to-end parse time for:
#   1. Perl SAM_entry.pm (original)
#   2. Perl SAM_entry_optimized.pm (cached CIGAR)
#   3. Rust trinity_bio (via the `trinity_bio_sam_bench` binary)
#
# This complements the micro-benchmarks in rust_bio_utils/benches/ by
# exercising the parser on a full SAM file with mixed CIGAR types.
#
# Usage:
#   benchmark_sam_parsing.pl --sam <sam_file> [--iterations 3]
#
# Requirements:
#   - Rust binary: cargo run --release --bin trinity_bio_sam_bench
#     (built automatically when present in rust_bio_utils/target/release)

use strict;
use warnings;
use Time::HiRes qw(gettimeofday tv_interval);
use FindBin;
use lib "$FindBin::RealBin/../../PerlLib";
use Getopt::Long qw(:config no_ignore_case bundling);

my $sam_file;
my $iterations = 3;

GetOptions(
    'sam=s'        => \$sam_file,
    'iterations=i' => \$iterations,
);

die "Usage: $0 --sam <sam_file> [--iterations 3]\n" unless $sam_file;
die "SAM file not found: $sam_file\n" unless -f $sam_file;

# Count lines once for reporting
my $line_count = 0;
{
    open my $fh, '<', $sam_file or die "Cannot open $sam_file: $!";
    $line_count++ while <$fh>;
    close $fh;
}
print STDERR "Benchmarking on $sam_file ($line_count records, $iterations iterations)\n\n";

# --- Perl original (SAM_entry.pm) ---
sub bench_perl_original {
    require SAM_entry;
    my $t0 = [gettimeofday];
    open my $fh, '<', $sam_file or die $!;
    my $n = 0;
    while (my $line = <$fh>) {
        chomp $line;
        my $entry = SAM_entry->new($line);
        my ($gl, $gr) = $entry->get_genome_span();
        my ($rl, $rr) = $entry->get_read_span();
        my $len = $entry->get_alignment_length();
        $n++;
    }
    close $fh;
    return tv_interval($t0);
}

# --- Perl optimized (SAM_entry_cached.pm) ---
sub bench_perl_optimized {
    require SAM_entry_cached;
    my $t0 = [gettimeofday];
    open my $fh, '<', $sam_file or die $!;
    while (my $line = <$fh>) {
        chomp $line;
        my $entry = SAM_entry_cached->new($line);
        my ($gl, $gr) = $entry->get_genome_span();
        my ($rl, $rr) = $entry->get_read_span();
        my $len = $entry->get_alignment_length();
    }
    close $fh;
    return tv_interval($t0);
}

# --- Rust trinity_bio (external binary) ---
sub bench_rust {
    my $rust_bin = "$FindBin::RealBin/../../rust_bio_utils/target/release/trinity_bio_sam_bench";
    die "Rust benchmark binary not found. Run: cargo build --release --bin trinity_bio_sam_bench\n"
        unless -x $rust_bin;

    my $t0 = [gettimeofday];
    my $ret = system("$rust_bin $sam_file $iterations");
    my $elapsed = tv_interval($t0);
    die "Rust benchmark failed ($ret)\n" if $ret;
    return $elapsed;
}

# Run benchmarks
print "=" x 65, "\n";
print "SAM Parsing Benchmark: Perl vs Rust\n";
print "=" x 65, "\n\n";

my @results;
for my $impl (['perl_original', \&bench_perl_original],
              ['perl_optimized', \&bench_perl_optimized]) {
    my @times;
    for (1..$iterations) {
        push @times, $impl->[1]->();
    }
    my $min = min(@times);
    push @results, [$impl->[0], $min, $line_count];
    printf "%-20s  best: %8.3fs  (%6.0f records/s)\n",
        $impl->[0], $min, $line_count / $min;
}

# Rust benchmark (runs all iterations internally)
eval {
    my $rust_time = bench_rust();
    push @results, ['rust', $rust_time, $line_count];
    printf "%-20s  best: %8.3fs  (%6.0f records/s)\n",
        'rust', $rust_time, $line_count / $rust_time;
};
if ($@) {
    print STDERR "Rust benchmark skipped: $@";
}

# Summary
print "\n", "=" x 65, "\n";
print "Summary (best of $iterations runs, $line_count records each)\n";
print "=" x 65, "\n";
printf "%-20s  %12s  %12s\n", 'Implementation', 'Time (s)', 'Records/s';
print "-" x 65, "\n";
for my $r (@results) {
    printf "%-20s  %12.3f  %12.0f\n", $r->[0], $r->[1], $r->[2]/$r->[1];
}
print "=" x 65, "\n";

if (@results >= 3) {
    my $rust_speedup = $results[0]->[1] / $results[2]->[1];
    my $opt_speedup  = $results[0]->[1] / $results[1]->[1];
    printf "Speedup: optimized vs original = %.2fx, Rust vs original = %.2fx\n",
        $opt_speedup, $rust_speedup;
}

sub min { my $m = $_[0]; for (@_) { $m = $_ if $_ < $m; } return $m; }

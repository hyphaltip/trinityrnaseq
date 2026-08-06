#!/usr/bin/env perl

# Microbenchmark: old shell-backtick subprocess patterns vs. the native-Perl
# replacements applied in this branch's subprocess-overhead review.
#
# Not a correctness test (no .t suffix, prove won't pick it up) -- run
# directly: perl t/bench_subprocess_patterns.pl [iterations]

use strict;
use warnings;

use Time::HiRes qw(time);
use File::Temp qw(tempdir);
use File::Which qw(which);

my $N = shift @ARGV || 300;

my $workdir = tempdir(CLEANUP => 1);
chdir($workdir) or die "Error, cannot chdir to $workdir: $!";

print "Running $N iterations per pattern in $workdir\n\n";

my @results;

# --- Pattern 1: checkpoint touch ---
{
    my $t0 = time();
    for my $i (1..$N) {
        my $f = "old_touch_$i.ok";
        `touch $f`;
    }
    my $old_elapsed = time() - $t0;

    $t0 = time();
    for my $i (1..$N) {
        my $f = "new_touch_$i.ok";
        open(my $ofh, ">", $f) or die $!;
        close $ofh;
    }
    my $new_elapsed = time() - $t0;

    push (@results, ["checkpoint touch (Pipeliner.pm, ~25 sites in Trinity/util)", $old_elapsed, $new_elapsed]);
}

# --- Pattern 2: tool lookup via PATH ---
{
    my $t0 = time();
    for (1..$N) {
        my $loc = `sh -c "command -v perl"`;
    }
    my $old_elapsed = time() - $t0;

    $t0 = time();
    for (1..$N) {
        my $loc = which("perl");
    }
    my $new_elapsed = time() - $t0;

    push (@results, ["tool PATH lookup (Trinity/COMMON.pm/align_and_estimate_abundance.pl)", $old_elapsed, $new_elapsed]);
}

# --- Pattern 3: small-file read (checkpoint/count files) ---
{
    open(my $sfh, ">", "small.txt") or die $!;
    print $sfh "12345\n";
    close $sfh;

    my $t0 = time();
    for (1..$N) {
        my $content = `cat small.txt`;
    }
    my $old_elapsed = time() - $t0;

    $t0 = time();
    for (1..$N) {
        open(my $ifh, "<", "small.txt") or die $!;
        local $/;
        my $content = <$ifh>;
        close $ifh;
    }
    my $new_elapsed = time() - $t0;

    push (@results, ["small-file read (Pipeliner kmer/read counts, quant_files list, acc list)", $old_elapsed, $new_elapsed]);
}

# --- Pattern 4: mkdir -p vs File::Path::make_path ---
{
    require File::Path;
    File::Path->import(qw(make_path));

    my $t0 = time();
    for my $i (1..$N) {
        system("mkdir -p old_dir_$i/a/b");
    }
    my $old_elapsed = time() - $t0;

    $t0 = time();
    for my $i (1..$N) {
        make_path("new_dir_$i/a/b");
    }
    my $new_elapsed = time() - $t0;

    push (@results, ["mkdir -p (align_and_estimate_abundance.pl)", $old_elapsed, $new_elapsed]);
}

printf("%-70s %12s %12s %10s %8s\n", "pattern", "old (ms/call)", "new (ms/call)", "delta ms", "speedup");
printf("%-70s %12s %12s %10s %8s\n", "-" x 70, "-" x 12, "-" x 12, "-" x 10, "-" x 8);

my $total_old = 0;
my $total_new = 0;

foreach my $r (@results) {
    my ($label, $old_elapsed, $new_elapsed) = @$r;
    my $old_ms = 1000 * $old_elapsed / $N;
    my $new_ms = 1000 * $new_elapsed / $N;
    my $delta_ms = $old_ms - $new_ms;
    my $speedup = $new_ms > 0 ? $old_ms / $new_ms : 0;

    printf("%-70s %12.4f %12.4f %10.4f %7.1fx\n", $label, $old_ms, $new_ms, $delta_ms, $speedup);

    $total_old += $old_elapsed;
    $total_new += $new_elapsed;
}

print "\n";
printf("Total wall time, old patterns: %.3fs for %d calls per pattern (%d patterns)\n", $total_old, $N, scalar(@results));
printf("Total wall time, new patterns: %.3fs\n", $total_new);
printf("Aggregate speedup this run:    %.1fx\n", $total_old / $total_new);

chdir("/");

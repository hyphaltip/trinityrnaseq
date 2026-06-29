#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib ("$FindBin::Bin/../PerlLib");
use Benchmark qw(timethese cmpthese);

use SAM_entry qw();
use SAM_entry_cached qw();

my $test_line = "read001\t99\tchr1\t10000\t255\t50M\t=\t10100\t200\t"
              . "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTAC\t"
              . "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";

my $test_line2 = "read002\t16\tchr2\t50000\t60\t10M5I10M5D10M25N10M\tchr2\t49900\t-300\t"
               . "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN\t"
               . "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII";

my $num_iterations = $ARGV[0] // 100000;

print "=" x 60, "\n";
print "SAM_entry Performance Benchmark\n";
print "Iterations: $num_iterations per test\n";
print "=" x 60, "\n\n";

print "Test 1: Simple alignment (50M)\n";
print "-" x 40, "\n";

cmpthese(timethese($num_iterations, {
    'original' => sub {
        my $entry = SAM_entry->new($test_line);
        my ($g_l, $g_r) = $entry->get_genome_span();
        my ($r_l, $r_r) = $entry->get_read_span();
        my $len = $entry->get_alignment_length();
        return ($g_l, $g_r, $r_l, $r_r, $len);
    },
    'cached' => sub {
        my $entry = SAM_entry_cached->new($test_line);
        my ($g_l, $g_r) = $entry->get_genome_span();
        my ($r_l, $r_r) = $entry->get_read_span();
        my $len = $entry->get_alignment_length();
        return ($g_l, $g_r, $r_l, $r_r, $len);
    },
}));

print "\nTest 2: Complex alignment (10M5I10M5D10M25N10M)\n";
print "-" x 40, "\n";

cmpthese(timethese($num_iterations, {
    'original' => sub {
        my $entry = SAM_entry->new($test_line2);
        my ($g_l, $g_r) = $entry->get_genome_span();
        my ($r_l, $r_r) = $entry->get_read_span();
        my $len = $entry->get_alignment_length();
        return ($g_l, $g_r, $r_l, $r_r, $len);
    },
    'cached' => sub {
        my $entry = SAM_entry_cached->new($test_line2);
        my ($g_l, $g_r) = $entry->get_genome_span();
        my ($r_l, $r_r) = $entry->get_read_span();
        my $len = $entry->get_alignment_length();
        return ($g_l, $g_r, $r_l, $r_r, $len);
    },
}));

print "\nTest 3: Multiple accesses (cache effectiveness)\n";
print "-" x 40, "\n";

cmpthese(timethese($num_iterations, {
    'original' => sub {
        my $entry = SAM_entry->new($test_line);
        my ($g1_l, $g1_r) = $entry->get_genome_span();
        my ($g2_l, $g2_r) = $entry->get_genome_span();
        my ($r1_l, $r1_r) = $entry->get_read_span();
        my ($r2_l, $r2_r) = $entry->get_read_span();
        my $len1 = $entry->get_alignment_length();
        my $len2 = $entry->get_alignment_length();
        return ($g1_l, $r1_l, $len1);
    },
    'cached' => sub {
        my $entry = SAM_entry_cached->new($test_line);
        my ($g1_l, $g1_r) = $entry->get_genome_span();
        my ($g2_l, $g2_r) = $entry->get_genome_span();
        my ($r1_l, $r1_r) = $entry->get_read_span();
        my ($r2_l, $r2_r) = $entry->get_read_span();
        my $len1 = $entry->get_alignment_length();
        my $len2 = $entry->get_alignment_length();
        return ($g1_l, $r1_l, $len1);
    },
}));

print "\n" . "=" x 60, "\n";
print "Benchmark Complete\n";
print "=" x 60, "\n";
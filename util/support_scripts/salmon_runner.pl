#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::Bin/../../PerlLib");
use Process_cmd;

my $usage = "\n\n\tusage: $0 Trinity.fasta reads.fa [threads=1]\n\n";

my $trin_fa = $ARGV[0] or die $usage;
my $reads_fa = $ARGV[1] or die $usage;
my $CPU = $ARGV[2] || 1;




main: {

    my $salmon_index = "$trin_fa.salmon.idx";
    my $salmon_stderr = "_salmon.$$.stderr";
    my $cmd = "salmon --no-version-check index -t $trin_fa -i $salmon_index -k 25 -p $CPU  > $salmon_stderr 2>&1";
    &run_cmd_capture_stderr($cmd, $salmon_stderr);

    # salmon 2.x is the Rust rewrite. Behaviour verified 2026-09-19 against
    # salmon 0.14.1, 1.10.3, 2.3.1 and 2.7.0 with a 200-read single-end set:
    #
    #   salmon      -r FASTA   -r FASTQ   --validateMappings   --minAssignedFrags
    #   0.14.1        ok         ok        accepted             accepted
    #   1.10.3        ok         ok        accepted             accepted
    #   2.3.1         ok         ok        accepted (no-op)     REJECTED
    #   2.7.0       REJECTED     ok        accepted (no-op)     REJECTED
    #
    # Two independent breaks, so two gates -- both keyed on the MAJOR version:
    #
    #  1) --minAssignedFrags was dropped in 2.x (fails on 2.3.1 and 2.7.0).
    #  2) -r stopped accepting FASTA somewhere in (2.3.1, 2.7.0]. salmon 2.7.0
    #     parses -r strictly as FASTQ and rejects a FASTA, reporting it as a
    #     damaged FASTQ rather than as a format mismatch:
    #       "Error: <reads>.fa looks truncated: it holds 305 lines, which is
    #        not a whole number of 4-line FASTQ records"
    #     Trinity hands this script single.fa.SR_supp.fa, which is FASTA, so
    #     every genome-guided partition died in salmon_expr_filtering and the
    #     assembly silently produced "0 transcripts derived from Trinity".
    #
    # The exact release that dropped FASTA has NOT been bisected, so gate (2)
    # deliberately does not test for 2.7.0. Converting to FASTQ is accepted by
    # every version above, so applying it to all of 2.x is both sufficient and
    # safe, and stays correct whichever 2.x release actually made the change.
    # salmon 1.x and 0.x keep the original FASTA path untouched, so existing
    # results with a pinned older salmon are bit-for-bit unaffected.
    my $salmon_major = &salmon_major_version();

    my $min_assigned_frags_opt = ($salmon_major < 2) ? "--minAssignedFrags 1" : "";
    # --validateMappings is selective-alignment-by-default in 2.x; it is still
    # accepted but warns "has no effect" on every invocation, so drop it there.
    my $validate_mappings_opt  = ($salmon_major < 2) ? "--validateMappings" : "";

    my $quant_reads = $reads_fa;
    my $synthetic_fastq;
    if ($salmon_major >= 2 && &is_fasta($reads_fa)) {
        $synthetic_fastq = "$reads_fa.as_fastq.fq";
        &fasta_to_fastq($reads_fa, $synthetic_fastq);
        $quant_reads = $synthetic_fastq;
    }

    $cmd = "salmon --no-version-check quant -i $salmon_index -l U -r $quant_reads -o salmon_outdir -p $CPU $min_assigned_frags_opt $validate_mappings_opt > $salmon_stderr 2>&1";
    &run_cmd_capture_stderr($cmd, $salmon_stderr);

    unlink($salmon_stderr);
    unlink($synthetic_fastq) if ($synthetic_fastq && -e $synthetic_fastq);

    exit(0);

}


####
sub is_fasta {
    my ($file) = @_;
    open(my $fh, "<", $file) or die "Error, cannot open $file";
    my $first;
    while (my $line = <$fh>) {
        next if ($line =~ /^\s*$/);
        $first = $line;
        last;
    }
    close $fh;
    return (defined $first && $first =~ /^>/) ? 1 : 0;
}


####
sub fasta_to_fastq {
    # salmon 2.x only reads FASTQ via -r. Trinity's supporting-reads file is
    # FASTA, so emit an equivalent FASTQ with a uniform high quality string.
    # Quality is not used for selective alignment here, only for parsing.
    my ($fasta, $fastq) = @_;

    open(my $in,  "<", $fasta) or die "Error, cannot open $fasta";
    open(my $out, ">", $fastq) or die "Error, cannot write $fastq";

    my $name = undef;
    my $seq  = "";

    my $flush = sub {
        return unless (defined $name && length($seq));
        print $out "\@$name\n$seq\n+\n" . ("I" x length($seq)) . "\n";
    };

    while (my $line = <$in>) {
        chomp $line;
        next if ($line =~ /^\s*$/);
        if ($line =~ /^>(.*)/) {
            $flush->();
            $name = $1;
            $seq  = "";
        }
        else {
            $seq .= $line;
        }
    }
    $flush->();

    close $in;
    close $out;

    return;
}


####
sub salmon_major_version {
    my $version_string = `salmon --no-version-check --version 2>&1`;
    if ($version_string =~ /salmon\s+(\d+)\./) {
        return $1;
    }
    die "Error, cannot parse salmon version from: $version_string";
}


####
sub run_cmd_capture_stderr {
    my ($cmd, $stderr_file) = @_; 
    eval {
        &process_cmd($cmd);
    };
    if ($@) {
        my $errmsg = `cat $stderr_file`;
        die "Error, cmd: $cmd failed with msg: $errmsg $@";
    }
    return;
}

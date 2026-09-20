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

# Cleaned up on any exit path, including die, via the END block below --
# not just the success path, so a failing partition doesn't leak a
# same-size-as-input temp file (and, incidentally, the pre-existing
# per-invocation stderr capture file) into the partition workdir.
my $tmp_fastq;
my $salmon_stderr;
END {
    unlink($tmp_fastq) if $tmp_fastq;
    unlink($salmon_stderr) if $salmon_stderr;
}


main: {

    my $salmon_index = "$trin_fa.salmon.idx";
    $salmon_stderr = "_salmon.$$.stderr";
    my $cmd = "salmon --no-version-check index -t $trin_fa -i $salmon_index -k 25 -p $CPU  > $salmon_stderr 2>&1";
    &run_cmd_capture_stderr($cmd, $salmon_stderr);

    # salmon >=2.0 is the Rust rewrite and dropped --minAssignedFrags (and
    # possibly other legacy flags); only pass it to the C++ (<2.0) line this
    # script was written against, so Trinity still works if a newer salmon
    # ever ends up on PATH (e.g. an unpinned env).
    my $salmon_major = &salmon_major_version();
    my $min_assigned_frags_opt = ($salmon_major < 2) ? "--minAssignedFrags 1" : "";

    # salmon >=2.0 also dropped FASTA auto-detection for -r/-1/-2: quant
    # always parses reads as strict 4-line FASTQ now, so our 2-line FASTA
    # reads.fa (Trinity-internal, no real quality scores -- these reads are
    # extracted straight from the genome-guided BAM, not raw sequencer
    # output; see extract_reads_per_partition.pl) get misread as
    # truncated/malformed FASTQ records: every second record's '>header'
    # line lands where '+' should be, its sequence line lands where quality
    # should be, and the whole file "looks truncated" to salmon's stricter
    # parser. See util/support_scripts/tests/salmon_gg_fasta_reads_bug/ for
    # a minimal repro/regression test. Feed it a synthetic FASTQ (dummy
    # max-quality string) instead, only on this path.
    my $quant_reads_fa = $reads_fa;
    if ($salmon_major >= 2) {
        $tmp_fastq = "$reads_fa.salmon_fq.$$.fastq";
        &fasta_to_fastq($reads_fa, $tmp_fastq);
        $quant_reads_fa = $tmp_fastq;
    }

    $cmd = "salmon --no-version-check quant -i $salmon_index -l U -r $quant_reads_fa -o salmon_outdir -p $CPU $min_assigned_frags_opt --validateMappings > $salmon_stderr 2>&1";
    &run_cmd_capture_stderr($cmd, $salmon_stderr);

    exit(0);

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
sub fasta_to_fastq {
    my ($fasta_file, $fastq_file) = @_;

    open(my $in, $fasta_file) or die "Error, cannot open $fasta_file: $!";
    open(my $out, ">$fastq_file") or die "Error, cannot write $fastq_file: $!";

    my ($acc, $seq);
    while (my $line = <$in>) {
        chomp $line;
        if ($line =~ /^>(\S+)/) {
            &write_fastq_record($out, $acc, $seq) if defined $acc;
            $acc = $1;
            $seq = "";
        }
        else {
            $seq .= $line;
        }
    }
    &write_fastq_record($out, $acc, $seq) if defined $acc;

    close $in;
    close $out;

    return;
}


####
sub write_fastq_record {
    my ($out, $acc, $seq) = @_;
    return unless length($seq);
    my $qual = "I" x length($seq);  # Phred+33 'I' = Q40, placeholder only -- no real quality info exists for these reads
    print $out "\@$acc\n$seq\n+\n$qual\n";
    return;
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

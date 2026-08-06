#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use Test::More tests => 3;
use File::Temp qw(tempdir);

my $utildir = "$FindBin::RealBin/../util";

# --- abundance_estimates_to_matrix.pl: --quant_files list-file reading (was `cat $quant_files`) ---
{
    my $dir = tempdir(CLEANUP => 1);

    # minimal fake quant file so the script has something to fail on *after*
    # it has successfully read the file list -- proves the file-list reading
    # itself (our change) works, independent of downstream quant-file parsing.
    open(my $lfh, ">", "$dir/quant_files.txt") or die $!;
    print $lfh "$dir/does_not_exist.quant.sf\n";
    close $lfh;

    my $out = `cd $dir && perl $utildir/abundance_estimates_to_matrix.pl --est_method salmon --quant_files quant_files.txt --gene_trans_map none 2>&1`;

    unlike($out, qr/Can't locate|Global symbol|syntax error/, "abundance_estimates_to_matrix.pl runs past compilation with --quant_files list file");
    like($out, qr/does_not_exist\.quant\.sf|Error/, "script correctly read the single filename out of quant_files.txt and attempted to use it");
}

# --- retrieve_sequences_from_fasta.pl: acc-list-file reading (was `cat $acc_list_file`) ---
{
    my $dir = tempdir(CLEANUP => 1);

    open(my $afh, ">", "$dir/accs.txt") or die $!;
    print $afh "seq1\nseq2\n";
    close $afh;

    open(my $ffh, ">", "$dir/target.fasta") or die $!;
    print $ffh ">seq1\nACGT\n>seq2\nTTTT\n";
    close $ffh;

    my $out = `cd $dir && perl $utildir/retrieve_sequences_from_fasta.pl accs.txt target.fasta 2>&1`;

    unlike($out, qr/Can't locate|Global symbol|syntax error/, "retrieve_sequences_from_fasta.pl runs past compilation and reads the acc list file");
}

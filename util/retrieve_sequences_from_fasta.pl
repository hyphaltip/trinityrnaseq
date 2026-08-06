#!/usr/bin/env perl

use strict;
use warnings;
use File::Which qw(which);

my $usage = "\n\n\tusage: $0 acc_list_file.txt target_db.fasta\n\n";

my $acc_list_file = $ARGV[0] or die $usage;
my $target_db = $ARGV[1] or die $usage;


main: {

    my $samtools = which("samtools");
    unless ($samtools) {
        die "Error, need samtools in your PATH setting.";
    }

    open (my $afh, "<", $acc_list_file) or die "Error, cannot open file: $acc_list_file, $!";
    my @accs = <$afh>;
    close $afh;
    chomp @accs;
    
    if (! -s "$target_db.fasta.fai") {
        my $cmd = "$samtools faidx $target_db";
        my $ret = system $cmd;
        if ($ret) {
            die "Error, cmd: $cmd died with ret $ret";
        }
    }
    
    my $ret = 0;
    
    foreach my $acc (@accs) {
        $acc =~ s/\s//g;

        unless ($acc =~ /\w/) { next; } 

        my $cmd = "$samtools faidx $target_db \"$acc\"";
        
        my $result = `$cmd`;
        if ($result) {
            print $result;
        }
        else {
            print STDERR "No entry retrieved for acc: $acc\n";
            $ret = 1;
        }
    }

    exit($ret);

}
    

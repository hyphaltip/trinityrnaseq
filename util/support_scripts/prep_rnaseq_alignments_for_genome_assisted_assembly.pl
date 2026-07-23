#!/usr/bin/env perl

use strict;
use warnings;

use Carp;
use threads;

use File::Basename;
use File::Spec;
use FindBin;
use Getopt::Long qw(:config no_ignore_case bundling);
use List::Util qw(min);
use lib("$FindBin::Bin/../../PerlLib");
use Thread_helper;
use Cwd;

my $CPU = 2;

my $usage = <<_EOUSAGE_;

########################################################################################################
#
#  Required:
#
#  --coord_sorted_SAM <string>      coordinate-sorted SAM file.
#
#  -I  <int>                       maximum intron length  
#                                     (reads with longer intron lengths are ignored, and fragment reads 
#                                      farther apart on the genome are treated as unpaired))
#  -C  <int>                       min coverage for region boundary (default: 1)
#                             
#  *If Strand-specific, specify:
#  --SS_lib_type <string>          library type:  if single: F or R,  if paired:  FR or RF
#
#
#  Optional:
#
#  --min_reads_per_partition <int>      default: 10 
#  --parts_per_directory <int>          default: 100
#
#  --sort_buffer <string>               default: '10G'  amount of RAM to allocate to sorting.
#
#  --CPU <int>                        number of threads
#
########################################################################################################


_EOUSAGE_

	;

#  -J  <int>                       region join length (neighboring coverage bins within this range are merged into larger piles)



my $help_flag;

#my $partition_join_size;
my $max_intron_length;
my $SAM_file;
my $SS_lib_type = "";
my $min_coverage = 1;
my $min_reads_per_partition = 10;
my $parts_per_dir = 100;
my $sort_buffer = '10G';

my $SYMLINK = ($ENV{NO_SYMLINK}) ? "cp" : "ln -sf";

&GetOptions ( 'h' => \$help_flag,

			  'coord_sorted_SAM=s' => \$SAM_file,
			  'SS_lib_type=s' => \$SS_lib_type,
			  
			  #'J=i' => \$partition_join_size,
			  'I=i' => \$max_intron_length,
              'C=i' => \$min_coverage,
              
              'min_reads_per_partition=i' => \$min_reads_per_partition,
              'parts_per_directory=i' => \$parts_per_dir,
              'CPU=i' => \$CPU,

              'sort_buffer=s' => \$sort_buffer,
              );


if ($help_flag) {
	die $usage;
}

unless (
	$SAM_file
        # && $partition_join_size
	&& $max_intron_length
		) {
	die $usage;
}

if ($SS_lib_type && $SS_lib_type !~ /^(F|R|FR|RF)$/) {
	die "Error, invalid --SS_lib_type, only F, R, FR, or RF are possible values";
}

my $UTIL_DIR = "$FindBin::RealBin/";

main: {

	## Shard the (indexed, coordinate-sorted) input by contig/scaffold so that the
    ## SAM_to_frag_coords -> fragment_coverage_writer -> define_coverage_partitions ->
    ## extract_reads_per_partition chain below runs N-wide instead of as a single whole-genome
    ## pass. Each of those tools already resets its internal state at scaffold-name boundaries
    ## (confirmed by reading rust_bio_utils sources), so contig shards can be processed fully
    ## independently and their outputs (already namespaced by scaffold/partition file) require
    ## no merge step beyond the existing "find Dir_*" glob done by the caller.
    my @shard_bams = &compute_contig_shard_bams($SAM_file, $CPU);

	my @sam_info;

	foreach my $shard_bam (@shard_bams) {

		if ($SS_lib_type) {
			my ($plus_strand_sam, $minus_strand_sam) = &strand_separate($shard_bam, $SS_lib_type);
			push (@sam_info, [$plus_strand_sam, '+'], [$minus_strand_sam, '-']);
		}
		else {
			push (@sam_info, [$shard_bam, '+']);
		}
	}


    my $thread_helper = new Thread_helper($CPU);
    
	foreach my $sam_info_aref (@sam_info) {
				
		my ($sam, $strand) = @$sam_info_aref;
				
		my $thread = threads->create('prep_read_partitions', $sam, $strand);
        #push (@threads, $thread);

        $thread_helper->add_thread($thread);
        
	}
    
    $thread_helper->wait_for_all_threads_to_complete();

    my @failures = $thread_helper->get_failed_threads();
    my $ret = 0;
    if (@failures) {
        foreach my $thread (@failures) {
            if (my $error = $thread->error()) {
                print STDERR "Error, thread exited with error $error\n";
                $ret++;
            }
        }
    }
    
	print "##\nDone\n##\n\n" unless($ret);
    
	exit($ret);

	
	

}


sub find_rust_binary {
    my ($name) = @_;
    return undef if $ENV{TRINITY_NO_RUST};
    my $rust_dir = "$FindBin::RealBin/../../rust_bio_utils/target/release";
    my $path = "$rust_dir/$name";
    return (-x $path) ? $path : undef;
}


####
# Splits an indexed, coordinate-sorted BAM into up to $num_shards sub-BAMs, each holding a
# disjoint set of whole contigs/scaffolds, balanced by mapped-read count (greedy longest-
# processing-time bin packing via `samtools idxstats`). Falls back to returning the input
# unchanged (single "shard") when it isn't an indexable BAM, or there's nothing to gain from
# sharding (CPU <= 1, or only one contig with mapped reads).
sub compute_contig_shard_bams {
    my ($bam_file, $num_shards) = @_;

    my $bam_basename = basename($bam_file);

    unless (-e $bam_basename) {
        &process_cmd("$SYMLINK $bam_file $bam_basename");
        if (-s "$bam_file.bai" && ! -e "$bam_basename.bai") {
            &process_cmd("$SYMLINK $bam_file.bai $bam_basename.bai");
        }
    }
    $bam_file = $bam_basename;

    unless ($bam_file =~ /\.bam$/ && -s $bam_file && $num_shards > 1) {
        # not an indexable BAM, or sharding wouldn't help: process as a single whole-file unit
        return ($bam_file);
    }

    unless (-s "$bam_file.bai" || -s "$bam_file.csi") {
        &process_cmd("samtools index $bam_file");
    }

    my @contigs; # [ name, length, mapped_read_count ]
    open (my $fh, "samtools idxstats $bam_file |") or die "Error, cannot run samtools idxstats on $bam_file: $!";
    while (<$fh>) {
        chomp;
        my ($name, $len, $mapped, $unmapped) = split(/\t/);
        next if (!defined($name) || $name eq '*');
        next unless ($mapped && $mapped > 0);
        push (@contigs, [$name, $len, $mapped]);
    }
    close $fh;

    if (scalar(@contigs) <= 1) {
        # nothing to gain from contig-sharding a single-scaffold genome
        return ($bam_file);
    }

    # greedy LPT bin-packing: sort contigs by mapped-read count descending, always add the next
    # contig to the currently-lightest bucket, so the N shards finish in roughly the same time.
    @contigs = sort { $b->[2] <=> $a->[2] } @contigs;
    my $n = min($num_shards, scalar(@contigs));
    my @buckets = map { { load => 0, contigs => [] } } (1..$n);
    foreach my $contig (@contigs) {
        @buckets = sort { $a->{load} <=> $b->{load} } @buckets;
        $buckets[0]->{load} += $contig->[2];
        push (@{$buckets[0]->{contigs}}, $contig);
    }

    my @shard_bams;
    for (my $i = 0; $i < scalar(@buckets); $i++) {
        my $bucket = $buckets[$i];
        next unless (scalar(@{$bucket->{contigs}}));

        my $shard_bed = "$bam_file.shard_$i.bed";
        my $shard_bam = "$bam_file.shard_$i.bam";

        unless (-s "$shard_bam.ok") {
            open (my $bed_fh, ">$shard_bed") or die "Error, cannot write $shard_bed: $!";
            foreach my $contig (@{$bucket->{contigs}}) {
                my ($name, $len, $mapped) = @$contig;
                print $bed_fh join("\t", $name, 0, $len) . "\n";
            }
            close $bed_fh;

            &process_cmd("samtools view -b -L $shard_bed $bam_file > $shard_bam");
            &process_cmd("samtools index $shard_bam");
            &process_cmd("touch $shard_bam.ok");
        }

        push (@shard_bams, $shard_bam);
    }

    return @shard_bams;
}


####
# Strand-separates a single shard (BAM or SAM), naming outputs after the shard so that
# multiple shards running concurrently never collide on the same plus/minus filenames.
sub strand_separate {
    my ($shard_file, $ss_lib_type) = @_;

    my $shard_basename = basename($shard_file);
    my ($plus_strand_sam, $minus_strand_sam) = ("$shard_basename.+.sam", "$shard_basename.-.sam");

    if (-s $plus_strand_sam && -s $minus_strand_sam) {
        print STDERR "-strand partitioned SAM files already exist for $shard_file, so using them instead of re-creating them.\n";
    }
    else {
        my $cmd = "$UTIL_DIR/SAM_strand_separator.pl $shard_file $ss_lib_type";
        &process_cmd($cmd);
    }

    return ($plus_strand_sam, $minus_strand_sam);
}


sub prep_read_partitions {
    my ($sam, $strand) = @_;

    ## define fragments
    my $cmd = "$UTIL_DIR/SAM_to_frag_coords.pl --CPU $CPU --sort_buffer $sort_buffer --sam $sam --min_insert_size 1 --max_insert_size $max_intron_length "; ## writes file: $sam_file.frag_coords
    &process_cmd($cmd) unless (-s "$sam.frag_coords");
    
    ## define coverage
    my $frag_writer = &find_rust_binary("fragment_coverage_writer") || "$UTIL_DIR/fragment_coverage_writer.pl";
    $cmd = "$frag_writer $sam.frag_coords > $sam.frag_coverage.wig";

    unless (-s "$sam.frag_coverage.wig.ok") {
        &process_cmd($cmd);
        &process_cmd("touch $sam.frag_coverage.wig.ok");
    }

    my $partitions_file = "$sam.minC$min_coverage.gff";

    ## define partitions
    my $define_parts = &find_rust_binary("define_coverage_partitions") || "$UTIL_DIR/define_coverage_partitions.pl";
    $cmd = "$define_parts $sam.frag_coverage.wig $min_coverage $strand > $partitions_file";
    unless (-s "$partitions_file.ok") {
        &process_cmd($cmd);
        &process_cmd("touch $partitions_file.ok");
    }


    ## extract reads per partition
    my $extract_reads = &find_rust_binary("extract_reads_per_partition") || "$UTIL_DIR/extract_reads_per_partition.pl";
    my $using_rust = ($extract_reads !~ /\.pl$/);
    $cmd = ($using_rust && $sam =~ /\.bam$/)
        ? "samtools view $sam | $extract_reads --partitions_gff $partitions_file --coord_sorted_SAM -"
        : "$extract_reads --partitions_gff $partitions_file --coord_sorted_SAM $sam";
    $cmd .= " --parts_per_directory $parts_per_dir"
        . " --min_reads_per_partition $min_reads_per_partition ";

    if ($SS_lib_type) {
        $cmd .= " --SS_lib_type $SS_lib_type ";
    }
    
    my $partitions_dir = "Dir_" . basename($partitions_file);
    unless (-d $partitions_dir && -e "$partitions_dir.ok") {
        &process_cmd($cmd);
        &process_cmd("touch $partitions_dir.ok");
    }
    
    return;
   
    
}


####
sub process_cmd {
	my ($cmd) = @_;

	print STDERR "CMD: $cmd\n";
	
	my $ret = system($cmd);

	if ($ret) {
	    confess "Error, command $cmd died with ret $ret";
	}

	return;
}

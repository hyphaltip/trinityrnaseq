#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::RealBin/../PerlLib");

use Test::More tests => 8;
use File::Temp qw(tempdir);
use Cwd;

use Pipeliner;

my $orig_cwd = cwd();
my $workdir = tempdir(CLEANUP => 1);
chdir($workdir) or die "Error, cannot chdir to $workdir: $!";

# --- Test 1: successful command creates its checkpoint file (item 1 fix: touch via open, not backticks) ---
{
    my $pipeliner = new Pipeliner(-verbose => 0);
    my $marker = "$workdir/ran.txt";
    my $checkpoint = "$workdir/step1.ok";

    $pipeliner->add_commands( Command->new("echo hello > \"$marker\"", $checkpoint) );
    $pipeliner->run();

    ok(-e $checkpoint, "checkpoint file created after successful command");
    ok(-e $marker, "command side effect occurred");
}

# --- Test 2: checkpoint causes the command to be skipped on a re-run ---
{
    my $pipeliner = new Pipeliner(-verbose => 0);
    my $marker = "$workdir/counter.txt";
    my $checkpoint = "$workdir/step2.ok";

    # command appends a line each time it actually runs
    my $cmd = "echo run >> \"$marker\"";

    my $p1 = new Pipeliner(-verbose => 0);
    $p1->add_commands( Command->new($cmd, $checkpoint) );
    $p1->run();

    my $p2 = new Pipeliner(-verbose => 0);
    $p2->add_commands( Command->new($cmd, $checkpoint) );
    $p2->run();

    open(my $fh, "<", $marker) or die $!;
    my @lines = <$fh>;
    close $fh;

    is(scalar(@lines), 1, "command only executed once; second run was skipped via checkpoint");
}

# --- Test 3: failing command dies with a useful error, stderr capture works (item 2 fix: open-based read, not `cat` backtick) ---
{
    my $pipeliner = new Pipeliner(-verbose => 0);
    my $checkpoint = "$workdir/step3.ok";

    $pipeliner->add_commands( Command->new('echo "boom failure message" 1>&2; exit 1', $checkpoint) );

    my $died = eval {
        $pipeliner->run();
        1;
    };

    ok(!$died, "pipeliner->run() dies on command failure");
    ok(!-e $checkpoint, "no checkpoint file created for a failed command");
    like($@, qr/died with ret/, "error message reports nonzero exit status");
}

# --- Test 4: multiple independent commands in one run() execute in order and all get checkpointed ---
{
    my $pipeliner = new Pipeliner(-verbose => 0);
    my $out = "$workdir/multi.txt";
    unlink($out) if -e $out;

    $pipeliner->add_commands(
        Command->new("echo a >> \"$out\"", "$workdir/multi_a.ok"),
        Command->new("echo b >> \"$out\"", "$workdir/multi_b.ok"),
    );
    $pipeliner->run();

    ok(-e "$workdir/multi_a.ok" && -e "$workdir/multi_b.ok", "both checkpoints created");

    open(my $fh, "<", $out) or die $!;
    my @lines = <$fh>;
    close $fh;
    is_deeply(\@lines, ["a\n", "b\n"], "commands ran in the order added");
}

chdir($orig_cwd);

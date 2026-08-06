#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::RealBin/../PerlLib");

use Test::More tests => 11;
use File::Temp qw(tempdir);
use Cwd;

use Pipeliner;

my $orig_cwd = cwd();
my $workdir = tempdir(CLEANUP => 1);
chdir($workdir) or die "Error, cannot chdir to $workdir: $!";

# --- Test 1: a batch of independent successful commands all run and all get checkpointed under -max_proc ---
{
    my $pipeliner = new Pipeliner(-verbose => 0);
    my $out = "$workdir/parallel_out";
    mkdir($out);

    my @cmds;
    for my $i (1..6) {
        push (@cmds, Command->new("echo $i > \"$out/$i.txt\"", "$workdir/parallel_$i.ok"));
    }
    $pipeliner->add_commands(@cmds);
    $pipeliner->run(-max_proc => 4);

    my $all_checkpoints_exist = 1;
    my $all_outputs_exist = 1;
    for my $i (1..6) {
        $all_checkpoints_exist = 0 unless (-e "$workdir/parallel_$i.ok");
        $all_outputs_exist = 0 unless (-e "$out/$i.txt");
    }
    ok($all_checkpoints_exist, "all 6 commands got checkpointed under -max_proc => 4");
    ok($all_outputs_exist, "all 6 commands actually ran (side effects present)");
}

# --- Test 2: checkpoint-skip still works in parallel mode ---
{
    my $marker = "$workdir/parallel_counter.txt";
    unlink($marker) if -e $marker;
    my $checkpoint = "$workdir/parallel_skip.ok";
    my $cmd = "echo run >> \"$marker\"";

    my $p1 = new Pipeliner(-verbose => 0);
    $p1->add_commands( Command->new($cmd, $checkpoint) );
    $p1->run(-max_proc => 3);

    my $p2 = new Pipeliner(-verbose => 0);
    $p2->add_commands( Command->new($cmd, $checkpoint) );
    $p2->run(-max_proc => 3);

    open(my $fh, "<", $marker) or die $!;
    my @lines = <$fh>;
    close $fh;
    is(scalar(@lines), 1, "checkpoint-skip honored under -max_proc, command only ran once across two run() calls");
}

# --- Test 3: two commands that both fail within the same instant get distinct, uncorrupted stderr capture ---
# regression test for the tmp_stderr filename-collision bug: the old
# "tmp.$$.<time>.stderr" naming used the parent's PID and 1s-resolution
# time(), which collides when >1 child is in flight at once.
{
    my $pipeliner = new Pipeliner(-verbose => 0);

    $pipeliner->add_commands(
        Command->new('echo "distinct failure message ONE" 1>&2; exit 1', "$workdir/fail1.ok"),
        Command->new('echo "distinct failure message TWO" 1>&2; exit 1', "$workdir/fail2.ok"),
    );

    my $stderr_capture = "";
    {
        local *OLDERR;
        open(OLDERR, ">&STDERR") or die $!;
        open(STDERR, ">", "$workdir/captured_stderr.txt") or die $!;

        eval { $pipeliner->run(-max_proc => 2); };

        open(STDERR, ">&OLDERR") or die $!;
    }

    open(my $cfh, "<", "$workdir/captured_stderr.txt") or die $!;
    { local $/; $stderr_capture = <$cfh>; }
    close $cfh;

    like($stderr_capture, qr/distinct failure message ONE/, "first failing command's stderr was captured");
    like($stderr_capture, qr/distinct failure message TWO/, "second failing command's stderr was captured independently (no filename collision)");
    ok(!-e "$workdir/fail1.ok" && !-e "$workdir/fail2.ok", "no checkpoints created for either failed command");
}

# --- Test 4: fail-fast -- an early failure prevents not-yet-launched queued commands from running,
#     while already-completed successful commands keep their checkpoints. ---
{
    my $pipeliner = new Pipeliner(-verbose => 0);
    my $never_run_marker = "$workdir/should_not_run.txt";
    unlink($never_run_marker) if -e $never_run_marker;

    # max_proc => 1 makes ordering deterministic: cmd1 succeeds, cmd2 fails,
    # cmd3 must never launch because admission stops after cmd2's failure.
    $pipeliner->add_commands(
        Command->new("true", "$workdir/ff_1.ok"),
        Command->new("false", "$workdir/ff_2.ok"),
        Command->new("touch \"$never_run_marker\"", "$workdir/ff_3.ok"),
    );

    my $died = eval {
        $pipeliner->run(-max_proc => 1);
        1;
    };

    ok(!$died, "run() dies when a command in the batch fails");
    ok(-e "$workdir/ff_1.ok", "earlier successful command's checkpoint is preserved");
    ok(!-e "$workdir/ff_2.ok", "failed command has no checkpoint");
    ok(!-e "$never_run_marker" && !-e "$workdir/ff_3.ok", "queued command after the failure never launched (fail-fast)");
}

# --- Test 5: no zombie/orphaned children remain after a run with failures ---
{
    my $pipeliner = new Pipeliner(-verbose => 0);
    $pipeliner->add_commands(
        Command->new("true", "$workdir/zz_1.ok"),
        Command->new("false", "$workdir/zz_2.ok"),
        Command->new("true", "$workdir/zz_3.ok"),
    );

    eval { $pipeliner->run(-max_proc => 3); };

    # a non-blocking reap should find nothing left to collect
    my $reaped = waitpid(-1, 1); # WNOHANG=1
    ok($reaped <= 0, "no leftover children to reap after a failed parallel run");
}

chdir($orig_cwd);

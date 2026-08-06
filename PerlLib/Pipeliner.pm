package Pipeliner;

use strict;
use warnings;
use Carp;
use Cwd;
use POSIX qw(_exit);

################################
## Verbose levels:
## 1: see CMD string
## 2: see stderr during process
################################


####################
## Static methods:
####################

####
sub ensure_full_path {
    my ($path, $ADD_GZ_FIFO_FLAG) = @_;

    unless ($path =~ m|^/|) {
        $path = cwd() . "/$path";
    }

    if ($ADD_GZ_FIFO_FLAG && $path =~ /\.gz$/) {
        $path = "<(zcat $path)";
    }
    
    return($path);
}

####
sub process_cmd {
    my ($cmd) = @_;

    print STDERR "CMD: $cmd\n";
    my $ret = system($cmd);
    if ($ret) {
        die "Error, CMD: $cmd died with ret $ret";
    }
    return;
}


################
## Obj methods:
################

####
sub new {
    my $packagename = shift;
    my %params = @_;

    my $VERBOSE = 0;
    if ($params{-verbose}) {
        $VERBOSE = $params{-verbose};
    }
    my $cmds_log = $params{-cmds_log};
    
    
    my $self = { 
        cmd_objs => [],
        checkpoint_dir => undef,
        cmds_log_ofh => undef,
        VERBOSE => $VERBOSE,
    };
    
    bless ($self, $packagename);

    if (my $checkpoint_dir = $params{-checkpoint_dir}) {
        $self->set_checkpoint_dir($checkpoint_dir);
    }

    unless ($cmds_log) {
        $cmds_log = "pipeliner.$$.cmds";

        if (my $checkpoint_dir = $self->get_checkpoint_dir) {
            $cmds_log = "$checkpoint_dir/$cmds_log";
        }
    }

    # open cmds log 
    open (my $ofh, ">$cmds_log") or confess "Error, cannot write to $cmds_log";
    $self->{cmds_log_ofh} = $ofh; 
    

    return($self);
}


sub add_commands {
    my $self = shift;
    my @cmds = @_;
    
    foreach my $cmd (@cmds) {
        unless (ref($cmd) =~ /Command/) {
            confess "Error, need Command object as param";
        }

        my $checkpoint_file = $cmd->get_checkpoint_file();
        if ($checkpoint_file !~ m|^/|) {
            if (my $checkpoint_dir = $self->get_checkpoint_dir()) {
                $checkpoint_file = "$checkpoint_dir/$checkpoint_file";
                $cmd->reset_checkpoint_file($checkpoint_file);
            }
        }
        

        push (@{$self->{cmd_objs}}, $cmd);
    }
    
    return $self;

}

sub set_checkpoint_dir {
    my $self = shift;
    my ($checkpoint_dir) = @_;
    $checkpoint_dir = &ensure_full_path($checkpoint_dir);
    if (! -d $checkpoint_dir) {
        mkdir($checkpoint_dir) or die "Error, cannot mkdir $checkpoint_dir";
    }
    $self->{checkpoint_dir} = $checkpoint_dir;
}

sub get_checkpoint_dir {
    my $self = shift;
    return($self->{checkpoint_dir});
}

sub has_commands {
    my $self = shift;
    if ($self->_get_commands()) {
        return(1);
    }
    else {
        return(0);
    }
}

####
## run(-max_proc => $N)
##   $N defaults to 1 (sequential, original behavior).
##   $N > 1 opts into a bounded-concurrency worker pool: all commands
##   currently queued are treated as mutually independent (no dependency
##   graph exists between Command objects), so callers that need partial
##   ordering must call run() in separate batches.
sub run {
    my $self = shift;
    my %opts = @_;

    my $max_proc = $opts{-max_proc} || 1;

    if ($max_proc > 1) {
        return $self->_run_parallel($max_proc);
    }
    else {
        return $self->_run_serial();
    }
}

sub _run_serial {
    my $self = shift;
    my $VERBOSE = $self->{VERBOSE};

    my $cmds_log_ofh = $self->{cmds_log_ofh};

    foreach my $cmd_obj ($self->_get_commands()) {

        my $cmdstr = $cmd_obj->get_cmdstr();
        print $cmds_log_ofh "$cmdstr\n";

        my $msg = $cmd_obj->{msg};

        my $checkpoint_file = $cmd_obj->get_checkpoint_file();

        if (-e $checkpoint_file) {
            print STDERR "-- Skipping CMD: $cmdstr, checkpoint [$checkpoint_file] exists.\n" if $VERBOSE;
        }
        else {
            my $datestamp = localtime();
            print STDERR "* [$datestamp] Running CMD: $cmdstr\n" if $VERBOSE;

            my $tmp_stderr = "tmp.$$." . time() . ".stderr";
            if (-e $tmp_stderr) {
                unlink($tmp_stderr);
            }

            if ($VERBOSE < 2 && $cmdstr !~ / 2>/ ) {
                $cmdstr .= " 2>$tmp_stderr";
            }

            print STDERR $msg if $msg;

            my $ret = system($cmdstr);
            if ($ret) {

                if (-e $tmp_stderr) {
                    my $errmsg = "";
                    if (open(my $efh, "<", $tmp_stderr)) {
                        local $/;
                        $errmsg = <$efh>;
                        close $efh;
                    }
                    if ($errmsg =~ /\w/) {
                        print STDERR "\n\nError encountered::  <!----\nCMD: $cmdstr\n\nErrmsg:\n$errmsg\n--->\n\n";
                    }
                    unlink($tmp_stderr);
                }

                confess "Error, cmd: $cmdstr died with ret $ret $!";
            }
            else {
                open(my $ofh, ">", $checkpoint_file) or confess "Error creating checkpoint file: $checkpoint_file, $!";
                close $ofh;
            }

            if (-e $tmp_stderr) {
                unlink($tmp_stderr);
            }
        }
    }


    # reset in case reusing the pipeline obj
    $self->{cmd_objs} = []; # reinit


    return;
}

####
## Bounded-concurrency worker pool. Bookkeeping (checkpoint-skip check,
## cmds_log logging) happens here in the parent, sequentially, before any
## fork -- children only ever execute a single already-decided command.
sub _run_parallel {
    my $self = shift;
    my $max_proc = shift;

    my $VERBOSE = $self->{VERBOSE};
    my $cmds_log_ofh = $self->{cmds_log_ofh};

    my @queue;
    foreach my $cmd_obj ($self->_get_commands()) {

        my $cmdstr = $cmd_obj->get_cmdstr();
        print $cmds_log_ofh "$cmdstr\n";

        my $checkpoint_file = $cmd_obj->get_checkpoint_file();
        if (-e $checkpoint_file) {
            print STDERR "-- Skipping CMD: $cmdstr, checkpoint [$checkpoint_file] exists.\n" if $VERBOSE;
        }
        else {
            push (@queue, $cmd_obj);
        }
    }

    my %inflight;      # pid => cmdstr, for commands currently running
    my @failed_cmds;   # cmdstrs of commands that returned nonzero
    my $admit_new = 1; # fail-fast: stop launching once a failure is seen
    my $launch_counter = 0;

    while (@queue || %inflight) {

        while ($admit_new && @queue && scalar(keys %inflight) < $max_proc) {

            my $cmd_obj = shift @queue;
            my $cmdstr = $cmd_obj->get_cmdstr();
            my $checkpoint_file = $cmd_obj->get_checkpoint_file();
            my $msg = $cmd_obj->{msg};
            $launch_counter++;

            my $pid = fork();
            confess "Error, cannot fork: $!" unless defined $pid;

            if ($pid == 0) {
                # child: run exactly one command, then _exit() -- never
                # `exit()`, which would re-run Perl global destruction
                # (including on filehandles inherited from the parent,
                # e.g. cmds_log_ofh) a second time in this process.
                my $datestamp = localtime();
                print STDERR "* [$datestamp] Running CMD: $cmdstr\n" if $VERBOSE;
                print STDERR $msg if $msg;

                # Keyed on this child's own post-fork PID plus a launch
                # counter, so concurrently-running siblings can never
                # collide on the same tmp_stderr filename (the serial
                # code's "tmp.$$.<time>.stderr" scheme relies on only ever
                # having one command in flight at a time to stay unique).
                my $tmp_stderr = "tmp.$$.$launch_counter.stderr";
                if (-e $tmp_stderr) {
                    unlink($tmp_stderr);
                }

                my $child_cmdstr = $cmdstr;
                if ($VERBOSE < 2 && $child_cmdstr !~ / 2>/ ) {
                    $child_cmdstr .= " 2>$tmp_stderr";
                }

                my $ret = system($child_cmdstr);
                if ($ret) {
                    if (-e $tmp_stderr) {
                        my $errmsg = "";
                        if (open(my $efh, "<", $tmp_stderr)) {
                            local $/;
                            $errmsg = <$efh>;
                            close $efh;
                        }
                        if ($errmsg =~ /\w/) {
                            print STDERR "\n\nError encountered::  <!----\nCMD: $cmdstr\n\nErrmsg:\n$errmsg\n--->\n\n";
                        }
                        unlink($tmp_stderr);
                    }
                    _exit(1);
                }
                else {
                    unless (open(my $ofh, ">", $checkpoint_file)) {
                        print STDERR "Error creating checkpoint file: $checkpoint_file, $!\n";
                        _exit(1);
                    }
                    else {
                        close $ofh;
                    }
                    if (-e $tmp_stderr) {
                        unlink($tmp_stderr);
                    }
                    _exit(0);
                }
            }
            else {
                # parent
                $inflight{$pid} = $cmdstr;
            }
        }

        if (%inflight) {
            my $pid = waitpid(-1, 0);
            my $status = $?;
            if ($pid > 0 && exists $inflight{$pid}) {
                my $cmdstr = delete $inflight{$pid};
                if ($status != 0) {
                    push (@failed_cmds, $cmdstr);
                    if ($admit_new) {
                        # stop admitting new work; drop what's still queued
                        # but let already-running siblings finish below.
                        $admit_new = 0;
                        @queue = ();
                    }
                }
            }
        }
    }

    if (@failed_cmds) {
        my $n = scalar(@failed_cmds);
        confess "Error, $n command(s) failed:\n"
            . join("\n", map { "  $_" } @failed_cmds)
            . "\nSee error output above for details.";
    }

    # reset in case reusing the pipeline obj
    $self->{cmd_objs} = []; # reinit

    return;
}

sub _get_commands {
    my $self = shift;

    return(@{$self->{cmd_objs}});
}





package Command;
use strict;
use warnings;
use Carp;

sub new {
    my $packagename = shift;
    
    my ($cmdstr, $checkpoint_file, $message) = @_;

    unless ($cmdstr && $checkpoint_file) {
        confess "Error, need cmdstr and checkpoint filename as params";
    }

    my $self = { cmdstr => $cmdstr,
                 checkpoint_file => $checkpoint_file,
                 msg => $message,
    };

    bless ($self, $packagename);

    return($self);
}
    
####
sub get_cmdstr {
    my $self = shift;
    return($self->{cmdstr});
}

####
sub get_checkpoint_file {
    my $self = shift;
    return($self->{checkpoint_file});
}

####
sub reset_checkpoint_file {
    my $self = shift;
    my $checkpoint_file = shift;

    $self->{checkpoint_file} = $checkpoint_file;
}

1; #EOM

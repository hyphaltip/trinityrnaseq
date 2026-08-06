#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 4;
use File::Which qw(which);

# Verifies the semantics that Trinity / retrieve_sequences_from_fasta.pl now rely on
# after replacing `sh -c "command -v $tool"` backticks with File::Which::which().

my $found = which("perl");
ok(defined($found) && length($found), "which() finds a tool that is on PATH (perl)");
ok(-x $found, "path returned by which() is executable");

my $missing = which("this_tool_almost_certainly_does_not_exist_xyz123");
ok(!defined($missing), "which() returns undef (not empty string) for a missing tool");

# guard-pattern equivalence check: old code used `unless ($loc =~ /\w/)`,
# new code uses `unless ($loc)` -- confirm both reject the missing case identically.
my $old_style_reject = !(defined($missing) && $missing =~ /\w/);
my $new_style_reject = !$missing;
is($old_style_reject, $new_style_reject, "old regex guard and new truthiness guard agree on missing tool");

#!/usr/bin/bash
# Demonstrates and regression-tests the salmon>=2.0 FASTA/FASTQ incompatibility
# in salmon_runner.pl (used by Trinity's genome-guided super-reads/expression
# filtering step, Trinity:1899 onward).
#
# Root cause: salmon >=2.0 (the Rust rewrite) dropped FASTA auto-detection
# for `quant -r/-1/-2` -- it now requires strict 4-line FASTQ. Trinity's
# genome-guided per-partition reads (extract_reads_per_partition.pl) are
# plain 2-line FASTA (no quality scores -- extracted straight from the
# alignment BAM). Under salmon <2.0 this worked via auto-detection; under
# salmon >=2.0 the 2-line records get misread as truncated 4-line FASTQ
# records, and this script's `quant` call fails.
#
# On its own this is recoverable -- Trinity's caller normally catches a
# salmon failure here and falls back to unfiltered transcripts. What made
# genome-guided assembly produce 0 transcripts in practice is a separate,
# now also-fixed Trinity bug: the "already filtered" flag was only set
# *after* a successful run, so a failure here left it unset and a second,
# un-eval'd call site retried the same doomed command and killed the whole
# partition. See Trinity's salmon_expr_filtering().
#
# Usage: ./run_test.sh /path/to/salmon_runner.pl
#   (defaults to the copy in this repo two directories up)
#
# Requires salmon on PATH. Exit 0 if salmon_runner.pl succeeds against
# whatever salmon major version is on PATH; exit 1 otherwise. Run it once
# with an unpatched salmon_runner.pl + salmon>=2.0 on PATH to see the bug
# reproduce; run it with the patched script to confirm the fix.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${1:-$HERE/../../salmon_runner.pl}"

if ! command -v salmon >/dev/null 2>&1; then
    echo "[SKIP] salmon not found on PATH" >&2
    exit 77
fi

echo "[INFO] salmon: $(salmon --no-version-check --version 2>&1)"
echo "[INFO] testing: $SCRIPT"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cp "$HERE/transcript.fa" "$HERE/reads.fa" "$WORKDIR/"
cd "$WORKDIR"

if perl "$SCRIPT" transcript.fa reads.fa 1 > run.log 2>&1; then
    if [ -s salmon_outdir/quant.sf ] && grep -q "toy_transcript_1" salmon_outdir/quant.sf; then
        if compgen -G "reads.fa.salmon_fq.*" > /dev/null || compgen -G "_salmon.*.stderr" > /dev/null; then
            echo "[FAIL] salmon_runner.pl succeeded but left temp files behind:"
            ls -la reads.fa.salmon_fq.* _salmon.*.stderr 2>/dev/null >&2
            exit 1
        fi
        echo "[PASS] salmon_runner.pl succeeded, produced quant.sf, cleaned up temp files"
        exit 0
    fi
    echo "[FAIL] salmon_runner.pl exited 0 but quant.sf is missing/empty"
    cat run.log >&2
    exit 1
fi

echo "[FAIL] salmon_runner.pl failed"
cat run.log >&2
if grep -q "final FASTQ record is incomplete\|looks truncated" run.log; then
    echo "[INFO] this is the known salmon>=2.0 FASTA/FASTQ bug" >&2
fi
exit 1

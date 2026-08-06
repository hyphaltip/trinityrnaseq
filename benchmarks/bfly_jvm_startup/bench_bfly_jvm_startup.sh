#!/bin/bash
# Measures per-launch JVM startup overhead for Butterfly.jar under the pre-optimization
# flag set vs. the post-optimization flag set (serial GC, capped JIT tiering, CDS class
# sharing - see Trinity's --bflyGCType / --bflyTieredStopAtLevel / --bfly_cds_archive).
#
# This isolates *JVM launch cost*, which is what those flags target: genome-guided
# Trinity runs can launch Butterfly (a JVM) many thousands of times (once per assembled
# locus), so per-launch startup overhead dominates wall time when individual graphs are
# small. It intentionally does not run a full Trinity assembly - full end-to-end
# benchmarking requires jellyfish/bowtie2/samtools, which are not guaranteed to be on
# PATH wherever this is run (they weren't, in the environment this was authored in - see
# ../../benchmark_execution.log for a prior attempt that failed for that reason). Feeding
# Butterfly.jar with no assembly args exercises real JVM boot + jar class loading (the
# mechanism these flags target) without needing real read/graph input; it does NOT
# exercise Butterfly's assembly-algorithm classes, so it's a conservative lower bound -
# real per-launch savings on production data are expected to be at least this large.
#
# Usage: ./bench_bfly_jvm_startup.sh [N_ITERATIONS] [path/to/Butterfly.jar]

set -euo pipefail

N=${1:-30}
BFLY=${2:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../../Butterfly" && pwd)/Butterfly.jar"}
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if [ ! -s "$BFLY" ]; then
    echo "Error: Butterfly.jar not found at $BFLY" >&2
    exit 1
fi

echo "Butterfly.jar: $BFLY"
echo "Java:          $(java -version 2>&1 | head -1)"
echo "Iterations:    $N (interleaved, to spread out shared-node load noise)"
echo

# --- flag sets under test ---
OLD_FLAGS="-Xmx10G -Xms1G   -Xss1G -XX:ParallelGCThreads=2"
INTERIM_FLAGS="-Xmx10G -Xms256M -Xss1G -XX:ParallelGCThreads=2"                      # small-init-heap change only (commit 87c71eb)
NEW_FLAGS="-Xmx10G -Xms256M -Xss1G -XX:+UseSerialGC -XX:TieredStopAtLevel=1"          # + serial GC + capped JIT tiering
CDS_ARCHIVE="$WORKDIR/bfly_cds.jsa"

# --- train the CDS archive once, the same way maybe_setup_bfly_cds() does in Trinity ---
java $NEW_FLAGS -XX:ArchiveClassesAtExit="$CDS_ARCHIVE" -jar "$BFLY" >/dev/null 2>&1 || true
if [ -s "$CDS_ARCHIVE" ]; then
    NEW_CDS_FLAGS="$NEW_FLAGS -XX:SharedArchiveFile=$CDS_ARCHIVE"
    echo "CDS archive trained OK: $CDS_ARCHIVE ($(stat -c%s "$CDS_ARCHIVE") bytes)"
else
    echo "CDS archive training FAILED/unsupported on this JVM - CDS arm will be skipped." >&2
    NEW_CDS_FLAGS=""
fi
echo

declare -A TIMES
for cfg in old interim new new_cds; do
    TIMES[$cfg]=""
done

time_one() {
    local flags="$1"
    local start end
    start=$(date +%s.%N)
    java $flags -jar "$BFLY" >/dev/null 2>&1 || true
    end=$(date +%s.%N)
    awk -v s="$start" -v e="$end" 'BEGIN{printf "%.4f", e-s}'
}

for i in $(seq 1 "$N"); do
    t=$(time_one "$OLD_FLAGS");      TIMES[old]+="$t "
    t=$(time_one "$INTERIM_FLAGS");  TIMES[interim]+="$t "
    t=$(time_one "$NEW_FLAGS");      TIMES[new]+="$t "
    if [ -n "$NEW_CDS_FLAGS" ]; then
        t=$(time_one "$NEW_CDS_FLAGS"); TIMES[new_cds]+="$t "
    fi
done

summarize() {
    local label="$1"; shift
    local vals="$1"
    echo "$vals" | tr ' ' '\n' | grep -v '^$' | awk -v label="$label" '
        { sum+=$1; sumsq+=$1*$1; n++; a[n]=$1 }
        END {
            if (n==0) { print label": no data"; exit }
            mean=sum/n
            sd = (n>1) ? sqrt((sumsq - sum*sum/n)/(n-1)) : 0
            asort(a)
            med = (n%2==1) ? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2
            printf "%-22s n=%-3d mean=%7.4fs  median=%7.4fs  stdev=%6.4fs\n", label, n, mean, med, sd
        }'
}

echo "=== Results (wall-clock seconds per JVM launch of Butterfly.jar) ==="
summarize "baseline (pre-optim)"        "${TIMES[old]}"
summarize "interim (small init-heap)"   "${TIMES[interim]}"
summarize "optimized (GC+JIT)"          "${TIMES[new]}"
if [ -n "$NEW_CDS_FLAGS" ]; then
    summarize "optimized (GC+JIT+CDS)"      "${TIMES[new_cds]}"
fi

echo
echo "Flag sets used:"
echo "  baseline (pre-optim):      $OLD_FLAGS"
echo "  interim (small init-heap): $INTERIM_FLAGS"
echo "  optimized (GC+JIT):        $NEW_FLAGS"
[ -n "$NEW_CDS_FLAGS" ] && echo "  optimized (GC+JIT+CDS):    $NEW_CDS_FLAGS"

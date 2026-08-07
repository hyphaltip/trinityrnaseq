#!/bin/bash
# Build a static JDK Class Data Sharing (CDS) archive for Butterfly.
#
# Genome-guided/de novo Trinity runs launch Butterfly (java -jar Butterfly.jar)
# once per assembly component - often tens of thousands of times in a single
# run, each a short-lived JVM. A CDS archive amortizes JVM class-loading and
# verification cost across all of those launches.
#
# This builds a *static* archive (java -Xshare:dump) once, at package build
# time, from Butterfly's own bundled example data. A static archive has no
# runtime training step and no cross-process coordination: every Butterfly
# launch just references the same pre-built, read-only archive via
# -XX:SharedArchiveFile. Re-run this script whenever Butterfly.jar is rebuilt.
#
# Usage: build_butterfly_cds_archive.sh [path/to/Butterfly.jar]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUTTERFLY_DIR="$(cd "$SCRIPT_DIR/../../Butterfly" && pwd)"
BFLY_JAR="${1:-$BUTTERFLY_DIR/Butterfly.jar}"
SAMPLE_DIR="$BUTTERFLY_DIR/Butterfly/src/sample_data"
OUT_CLASSLIST="$BUTTERFLY_DIR/butterfly_cds.classlist"
OUT_ARCHIVE="$BUTTERFLY_DIR/butterfly_cds.jsa"

if [ ! -s "$BFLY_JAR" ]; then
    echo "Error: Butterfly jar not found at $BFLY_JAR" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Deliberately run the training launches from a scratch directory that is
# *not* $BUTTERFLY_DIR: this exercises the jar's "Class-Path: ." manifest
# entry (which resolves relative to the jar's own location, not the JVM's
# CWD) under realistic conditions, and confirms the resulting archive isn't
# accidentally depending on being loaded from any particular CWD.
mkdir -p "$WORKDIR/sample_data"
cp "$SAMPLE_DIR"/c1.graph.* "$WORKDIR/sample_data/"

echo "-dumping loaded-class list from a representative Butterfly run..."
( cd "$WORKDIR" && java -Xshare:off \
    -XX:DumpLoadedClassList="$OUT_CLASSLIST" \
    -jar "$BFLY_JAR" -N 10000 -L 300 -F 300 -C sample_data/c1.graph -V 20 \
    > "$WORKDIR/train.log" 2>&1 ) \
    || { echo "Error: classlist training run failed, see below:" >&2; cat "$WORKDIR/train.log" >&2; exit 1; }

echo "-building static CDS archive..."
java -Xshare:dump \
    -XX:SharedClassListFile="$OUT_CLASSLIST" \
    -XX:SharedArchiveFile="$OUT_ARCHIVE" \
    -cp "$BFLY_JAR" \
    > "$WORKDIR/dump.log" 2>&1 \
    || { echo "Error: -Xshare:dump failed, see below:" >&2; cat "$WORKDIR/dump.log" >&2; exit 1; }

# Sanity check: verify the archive is actually usable (-Xshare:on fails hard
# on any validation problem, unlike -Xshare:auto's silent fallback), and from
# a *different* working directory than either the jar or the training run,
# to catch any accidental CWD-dependence before this ships.
mkdir -p "$WORKDIR/verify_cwd/sample_data"
cp "$SAMPLE_DIR"/c1.graph.* "$WORKDIR/verify_cwd/sample_data/"
( cd "$WORKDIR/verify_cwd" && java -Xshare:on \
    -XX:SharedArchiveFile="$OUT_ARCHIVE" \
    -jar "$BFLY_JAR" -N 10000 -L 300 -F 300 -C sample_data/c1.graph -V 20 \
    > "$WORKDIR/verify.log" 2>&1 ) \
    || { echo "Error: archive failed strict reuse verification, see below:" >&2; cat "$WORKDIR/verify.log" >&2; exit 1; }

echo "-butterfly CDS archive built and verified: $OUT_ARCHIVE"

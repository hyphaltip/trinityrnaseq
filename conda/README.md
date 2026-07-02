# Conda package build — `trinity-rust`

A conda-build recipe for the Rust-optimized Trinity fork (`v2.16.1_rust`).
It compiles the C++ (Inchworm/Chrysalis/plugins) and Rust helper binaries from
source and installs the full Trinity tree under
`$PREFIX/opt/trinity-<version>/`, wiring up `Trinity` + the Rust helpers on
`PATH` and setting `TRINITY_HOME` through a conda activation hook.

## Prerequisites

- `conda-build` (or `boa`/`rattler-build`), e.g. `conda install -n base conda-build`
- The submodules must be checked out before building (the recipe builds from
  the local working tree, `source: path: ..`):

  ```bash
  git submodule update --init --recursive
  ```

## Build

From the repository root:

```bash
conda build -c bioconda -c conda-forge conda/
```

or with the faster mamba solver:

```bash
conda mambabuild -c bioconda -c conda-forge conda/
```

> **Network note:** `cargo build` fetches crates from crates.io during the
> build. In an offline builder, pre-populate a vendored cache:
> `cd rust_bio_utils && cargo vendor` and add a `.cargo/config.toml`, then set
> `CARGO_NET_OFFLINE=true`.

## Install the built package

```bash
conda create -n trinity -c local -c bioconda -c conda-forge trinity-rust
conda activate trinity
Trinity --version
```

## What is / isn't included

**Hard runtime deps** (baked into the package `run:` list, because Trinity
aborts at startup without them): `samtools`, `jellyfish` (v2), `bowtie2`,
`salmon`, `perl` (+`perl-threaded`, `perl-db_file`, `perl-uri`), `python`
(+`numpy`), `openjdk`.

**Downstream / optional** (kept out of the package to stay lean — install
alongside): `rsem`, `kallisto`, `bowtie` (v1), genome-guided aligners
(`hisat2`, `star`, `gmap`), `fastqc`, and the R/Bioconductor differential-
expression stack. The full set is in the top-level `environment.yml`, or:

```bash
conda install -c bioconda -c conda-forge \
  rsem kallisto bowtie hisat2 star gmap fastqc \
  bioconductor-edger bioconductor-deseq2 bioconductor-qvalue \
  bioconductor-ctc bioconductor-goseq bioconductor-dexseq \
  r-fastcluster r-ape r-gplots r-argparse
```

## Publishing to a channel

This is an unofficial fork, so do **not** submit it to the official
bioconda `trinity` recipe. Host the built `.conda`/`.tar.bz2` on a personal
channel (e.g. `anaconda upload`) or a self-hosted channel and install with
`-c <yourchannel>`.

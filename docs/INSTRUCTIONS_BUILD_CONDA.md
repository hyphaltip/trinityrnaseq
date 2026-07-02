# Building the `trinity-rust` conda package

Commands to build the Rust-optimized Trinity fork (`v2.16.1_rust`) as a conda
package on a **linux-64** host. Run everything from the **repository root**.

The recipe (`conda/`) builds from the local working tree, compiles the C++
(Inchworm/Chrysalis/plugins) and Rust helper binaries, and installs the whole
Trinity tree under `$PREFIX/opt/trinity-<version>/` (preserving the relative
path Trinity uses to locate its Rust helpers).

## 1. One-time prerequisites

```bash
# conda-build (+ mamba solver) in your base env
conda install -n base -c conda-forge conda-build boa

# make sure the fork's submodules are present — the recipe builds from the
# local working tree, so Inchworm/Chrysalis/trinity-plugins/* must be checked out
git submodule update --init --recursive
```

## 2. Build the package

```bash
# from the repo root (fast mamba solver)
conda mambabuild -c bioconda -c conda-forge conda/
```

or with plain conda-build (slower solver, same result):

```bash
conda build -c bioconda -c conda-forge conda/
```

The finished package lands in
`$(conda info --base)/conda-bld/linux-64/trinity-rust-2.16.1-*.conda`.
Print its exact path with:

```bash
conda mambabuild -c bioconda -c conda-forge conda/ --output
```

## 3. Install & smoke-test what you built

```bash
conda create -n trinity -c local -c bioconda -c conda-forge trinity-rust
conda activate trinity
Trinity --version
sam_to_read_coords --help        # confirms the Rust helper is on PATH
```

## If the build host has no internet (cargo can't reach crates.io)

`cargo build` fetches crates during the build. Vendor them **before** building,
while you still have network:

```bash
cd rust_bio_utils
cargo vendor vendor > /tmp/cargo-vendor.toml     # prints the [source] config
mkdir -p .cargo
cp /tmp/cargo-vendor.toml .cargo/config.toml
cd ..
```

then build with cargo forced offline:

```bash
CARGO_NET_OFFLINE=true conda mambabuild -c bioconda -c conda-forge conda/
```

(The recipe already passes `CARGO_NET_OFFLINE` through via `script_env`, and
`cargo build --locked` in `build.sh` will use the vendored crates.)

## Optional: publish to a channel

Since this is an unofficial fork, host it on your own channel rather than
bioconda:

```bash
conda install -n base anaconda-client
anaconda login
anaconda upload $(conda mambabuild conda/ --output)
# then others install with:  conda install -c <youruser> trinity-rust
```

## Notes / gotchas

- **Platform:** must be **linux-64**. The recipe skips other platforms because
  it compiles C++/Rust.
- **Toolchain pinning:** the build pulls the compiler toolchain pinned in
  `conda/conda_build_config.yaml` (gcc/gxx 12). Adjust that file if your target
  needs a different generation.
- **Downstream tools are intentionally NOT bundled** in the package to keep it
  lean (RSEM, kallisto, bowtie v1, genome-guided aligners, the R/Bioconductor
  DE stack). Install them alongside via the repo's `environment.yml`, or see
  `conda/README.md` for the explicit `conda install` line.

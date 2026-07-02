#!/bin/bash
set -euxo pipefail

# ---------------------------------------------------------------------------
# conda-build script for the Rust-optimized Trinity fork.
#
# Trinity is not a set of standalone binaries -- the `Trinity` driver and its
# util/ scripts locate helpers by RELATIVE path from the package root, e.g.
# the Rust binaries at  rust_bio_utils/target/release/  and the plugin tools at
# trinity-plugins/BIN/ . We therefore install the whole tree under
# $PREFIX/opt/trinity-<version>/ and expose entry points via wrappers + an
# activate.d hook that sets TRINITY_HOME and PATH.
# ---------------------------------------------------------------------------

export TRINITY_HOME="${SRC_DIR}"

# Use the conda compilers explicitly.
export CC="${CC:-$GCC}"
export CXX="${CXX:-$GXX}"

# ---- 1. Compile C++ components -------------------------------------------
make -C Inchworm
make -C Chrysalis

# Configure + build bamsifter's bundled htslib, then the plugins.
make -C trinity-plugins trinity_essentials
make -C trinity-plugins plugins

# ---- 2. Compile Rust acceleration binaries -------------------------------
# (needs crates.io access unless a vendored .cargo is provided)
pushd rust_bio_utils
cargo build --release --locked
popd

# ---- 3. Install the tree -------------------------------------------------
DEST="${PREFIX}/opt/trinity-${PKG_VERSION}"
mkdir -p "${DEST}"

# Copy everything the runtime needs; exclude VCS, tests and build scratch.
tar --exclude='./.git' \
    --exclude='./.pixi' \
    --exclude='./conda' \
    --exclude='./benchmark*' \
    --exclude='./test2_*' --exclude='./test3*' \
    --exclude='./*_results_*' \
    --exclude='./rust_bio_utils/target/debug' \
    --exclude='./rust_bio_utils/target/release/deps' \
    --exclude='./rust_bio_utils/target/release/build' \
    --exclude='./rust_bio_utils/target/release/incremental' \
    --exclude='./rust_bio_utils/target/release/examples' \
    -cf - . | ( cd "${DEST}" && tar -xf - )

# ---- 4. Entry points -----------------------------------------------------
mkdir -p "${PREFIX}/bin"

# Main driver wrapper.
cat > "${PREFIX}/bin/Trinity" <<EOF
#!/bin/bash
export TRINITY_HOME="${DEST}"
exec "${DEST}/Trinity" "\$@"
EOF
chmod +x "${PREFIX}/bin/Trinity"

# Expose the Rust helper binaries on PATH too (they are also found by relative
# path, but this is convenient for direct use / benchmarking).
for b in "${DEST}"/rust_bio_utils/target/release/*; do
    [ -x "$b" ] && [ -f "$b" ] || continue
    case "$(basename "$b")" in
        *.d|*.rlib|*.so) continue ;;
    esac
    ln -sf "$b" "${PREFIX}/bin/$(basename "$b")"
done

# ---- 5. Activation hook (sets TRINITY_HOME for the whole env) -------------
mkdir -p "${PREFIX}/etc/conda/activate.d" "${PREFIX}/etc/conda/deactivate.d"

cat > "${PREFIX}/etc/conda/activate.d/trinity.sh" <<EOF
export TRINITY_HOME="${DEST}"
export PATH="${DEST}/trinity-plugins/BIN:\${PATH}"
EOF

cat > "${PREFIX}/etc/conda/deactivate.d/trinity.sh" <<'EOF'
unset TRINITY_HOME
EOF

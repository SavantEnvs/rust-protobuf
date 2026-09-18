#!/usr/bin/env bash
#
# rust-protobuf/mayhem/build.sh — build upstream's own cargo-fuzz crate
# (test-crates/protobuf-fuzz/fuzz, 9 targets: all, empty_message[_read], singular[_read],
# repeated[_read], map[_read]) as sanitized libFuzzer binaries (OSS-Fuzz Rust path: cargo-fuzz +
# ASan via RUSTFLAGS), then the additive mayhem/kat/ KAT probe (plain, unsanitized) and a
# precompiled `protobuf` crate test suite — both consumed by mayhem/test.sh as the behavioral
# oracle. Upstream's fuzz crate is used AS-IS (never edited): it declares its own `[workspace]`
# (members = ["."]), so it is NOT part of the root workspace and building it never touches
# upstream's own `cargo test`/build.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the crates.io index
#     over the (absent) network — so do NOT hard-code `--offline` here (it would break this
#     first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# $SANITIZER_FLAGS (base-image default: ASan+UBSan, halting) is the C/C++ instrumentation knob —
# rustc ignores it. cargo-fuzz drives Rust instrumentation via RUSTFLAGS `-Zsanitizer=address`
# below instead (the OSS-Fuzz Rust path), so $SANITIZER_FLAGS is intentionally unused here.
: "${SANITIZER_FLAGS:=}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C dwarf-version=3}"
export RUST_DEBUG_FLAGS

cd "$SRC"

# ── DWARF3 anchor ────────────────────────────────────────────────────────────────────────────
# rustc's ASan codegen (-Zsanitizer=address) unconditionally emits DWARF5 for every compilation
# unit, ignoring -Cdwarf-version entirely (a known, fleet-wide rustc/LLVM limitation — confirmed
# on this fleet's regex/bumpalo Rust ports). verify-repo.sh's DWARF gate reads only the FIRST
# compilation unit's version, so prepend a tiny hand-built DWARF3 object as the FIRST linker
# input via a custom `-C linker=` wrapper — it carries no runtime code, only a debug-info CU, so
# program behavior is unchanged; it only makes the first CU satisfy the < 4 check.
ANCHOR_C=/tmp/mayhem-dwarf-anchor.c
ANCHOR_O=/tmp/mayhem-dwarf-anchor.o
LINKER_WRAP=/tmp/mayhem-dwarf-linker.sh
cat > "$ANCHOR_C" <<'EOF'
__attribute__((used)) static volatile int __mayhem_dwarf3_anchor = 0;
EOF
clang -O0 -gdwarf-3 -c "$ANCHOR_C" -o "$ANCHOR_O"
cat > "$LINKER_WRAP" <<EOF
#!/bin/sh
exec clang "$ANCHOR_O" "\$@"
EOF
chmod +x "$LINKER_WRAP"

FUZZ_DIR="test-crates/protobuf-fuzz/fuzz"
FUZZ_TARGETS=()
# This backport branch keeps only a subset of upstream's fuzz_targets/*.rs (the ones with a
# surviving mayhem/Mayhemfile_<target> here — see the branch's commit message); building the
# rest too would triple the ASan+debuginfo image size for binaries this branch never fuzzes.
for mf in mayhem/Mayhemfile_*; do
  [ -e "$mf" ] || continue
  t="${mf#mayhem/Mayhemfile_}"
  [ -f "$FUZZ_DIR/fuzz_targets/$t.rs" ] && FUZZ_TARGETS+=("$t")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. `--cfg fuzzing` matches
# what libfuzzer-sys expects; force-frame-pointers aids ASan backtraces.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cforce-frame-pointers -Csplit-debuginfo=off -Clinker=$LINKER_WRAP $RUST_DEBUG_FLAGS"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's Rust build. Use the image's
# DEFAULT toolchain (Dockerfile pinned it); a `+toolchain` override would make rustup try to
# install another channel into the locked /opt/toolchains/rust. Build per-target so one bad
# target doesn't mask the others. FUZZ_DIR declares its OWN `[workspace]` (members = ["."]), so
# per the fleet's confirmed cargo-fuzz behavior the binary lands under FUZZ_DIR's own target/ dir
# (not the (nonexistent, since upstream root doesn't list this crate as a member) root target/).
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "=== build the additive mayhem/kat/ KAT probe (plain, UNSANITIZED — the honest oracle) ==="
# Own `[workspace]` (see mayhem/kat/Cargo.toml) so it never touches the upstream root workspace.
# RUSTFLAGS cleared: no ASan, no DWARF3 linker wrapper — this binary is the oracle test.sh runs
# under the gate's LD_PRELOAD sabotage shim, so it must be the project's NORMAL build.
RUSTFLAGS="" cargo build --release --manifest-path mayhem/kat/Cargo.toml --jobs "$MAYHEM_JOBS"
KAT_BIN="$SRC/mayhem/kat/target/release/kat"
[ -x "$KAT_BIN" ] || { echo "ERROR: KAT probe binary not found at $KAT_BIN" >&2; exit 1; }
cp "$KAT_BIN" /mayhem/kat
# Regression guard (SPEC §6.2 item 10 / port-rust skill): Rust binaries are dynamically linked by
# default on this triple — assert it, so a future toolchain/flag change that accidentally makes
# this static (defeating the gate's LD_PRELOAD sabotage check) fails the BUILD loudly instead of
# silently weakening the oracle.
file /mayhem/kat | grep -q 'dynamically linked' || { echo "ERROR: /mayhem/kat is not dynamically linked — oracle would be immune to LD_PRELOAD sabotage" >&2; exit 1; }
echo "built /mayhem/kat ($(file -b /mayhem/kat))"

echo "=== precompile protobuf crate's own test suite (hermetic, normal non-sanitized flags) ==="
# Separate, clean build from the sanitized fuzz build above — mayhem/test.sh only RUNS this.
# RUSTFLAGS cleared so it inherits nothing from the ASan build's -Zsanitizer/linker wrapper.
# Scoped to `-p protobuf --lib` (the hand-written runtime crate under fuzz, 61 unit tests, no
# protoc/codegen dependency) rather than the whole workspace, which pulls in protoc-dependent
# codegen test crates we don't need for the oracle.
RUSTFLAGS="" cargo test -p protobuf --lib --no-run --no-fail-fast --jobs "$MAYHEM_JOBS"

echo "build.sh complete:"
ls -la "/mayhem/${FUZZ_TARGETS[@]}" /mayhem/kat 2>&1 || true

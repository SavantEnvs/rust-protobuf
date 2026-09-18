#!/usr/bin/env bash
#
# rust-protobuf/mayhem/test.sh — RUN (never build) the two-part behavioral oracle mayhem/build.sh
# already compiled:
#   1. mayhem/kat/target/release/kat (copied to /mayhem/kat) — the LOAD-BEARING oracle. A small,
#      dynamically linked binary asserting EXACT computed values (varint encoding, a real
#      generated-message parse/round-trip, a malformed-input rejection) from FIXED inputs through
#      the actual `protobuf` crate wire-format code every fuzz target exercises. This is what
#      makes the oracle behavioral rather than exit-code-only: test.sh greps its stdout for the
#      literal expected marker lines, so a neutered/no-op binary (empty stdout) fails here
#      regardless of its exit code.
#   2. `cargo test -p protobuf --lib` — the project's own 61 hand-written unit tests over the
#      wire-format/reflect/coded-stream code (precompiled by build.sh --no-run). Kept as a SECOND,
#      supplementary signal layered on top of the KAT probe (never the sole oracle — see
#      docs/netnew-worker-prompt.md §4: a `cargo test` binary can in principle end up outside the
#      gate's LD_PRELOAD sabotage shim's reach, so it must never be trusted alone).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TOTAL_PASSED=0
TOTAL_FAILED=0

# ── 1. KAT probe (load-bearing, behavioral) ─────────────────────────────────────────────────
KAT_BIN="$SRC/kat"
if [ ! -x "$KAT_BIN" ]; then
  echo "mayhem/kat binary missing — build.sh should have produced it" >&2
  emit_ctrf "rust-protobuf-oracle" 0 1
  exit 2
fi

kat_out="$("$KAT_BIN" 2>&1)"; kat_rc=$?
echo "=== mayhem/kat output ==="
echo "$kat_out"

kat_fail=0
for marker in KAT1_VARINT_OK KAT2_MESSAGE_OK KAT3_REJECT_OK KAT_ALL_PASS; do
  if printf '%s\n' "$kat_out" | grep -qF "$marker"; then
    TOTAL_PASSED=$(( TOTAL_PASSED + 1 ))
  else
    echo "MISSING expected KAT marker: $marker" >&2
    TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
    kat_fail=1
  fi
done
if [ "$kat_rc" -ne 0 ]; then
  echo "mayhem/kat exited non-zero ($kat_rc)" >&2
  kat_fail=1
  # The exit itself isn't separately counted — a nonzero rc always also means the trailing
  # KAT_ALL_PASS marker is missing (kat's own asserts panic before printing it), which the
  # marker loop above already counted as a failure.
fi
[ "$kat_fail" -eq 0 ] && echo "KAT probe: all assertions verified"

# ── 2. protobuf crate's own unit tests (supplementary; precompiled by build.sh --no-run) ────
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the protobuf crate test suite" >&2
  TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
else
  echo "=== running cargo test -p protobuf --lib (precompiled by build.sh --no-run) ==="
  out="$(RUSTFLAGS="" cargo test -p protobuf --lib --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
  echo "$out"

  PASSED=0; FAILED=0; IGNORED=0
  while read -r p f i; do
    PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
  done < <(printf '%s\n' "$out" \
    | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

  if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
    echo "could not parse any 'test result:' lines from cargo test; using cargo exit code $rc" >&2
    if [ "$rc" -eq 0 ]; then TOTAL_FAILED=$(( TOTAL_FAILED + 1 )); echo "cargo test rc=0 but produced no parseable results — treating as a failure (silent-collapse guard)" >&2
    else TOTAL_FAILED=$(( TOTAL_FAILED + 1 )); fi
  else
    TOTAL_PASSED=$(( TOTAL_PASSED + PASSED + IGNORED ))
    TOTAL_FAILED=$(( TOTAL_FAILED + FAILED ))
    echo "cargo test -p protobuf --lib: $PASSED passed, $FAILED failed, $IGNORED ignored"
  fi
fi

emit_ctrf "rust-protobuf-oracle" "$TOTAL_PASSED" "$TOTAL_FAILED"

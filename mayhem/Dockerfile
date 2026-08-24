# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz). rust-protobuf is a pure-Rust
# implementation of Google's protocol buffers (stepancheg/rust-protobuf). It already ships its
# own OSS-Fuzz-style cargo-fuzz harnesses at test-crates/protobuf-fuzz/fuzz/ (9 targets covering
# byte/reader/JSON/text-format parse + write round-trip over singular/repeated/map field kinds),
# which build cleanly on a pinned nightly, so mayhem/build.sh drives THAT crate as-is (never
# edited — purely additive integration). This Dockerfile installs a pinned Rust nightly +
# cargo-fuzz under /opt/toolchains/rust on top of the org C/C++ base, then runs build.sh
# (cargo fuzz build for each target + the additive mayhem/kat/ KAT probe + a precompiled
# `protobuf` crate test suite) and test.sh (runs both as the behavioral oracle).
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t rust-protobuf-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the nightly by DATE (-Zsanitizer=address needs nightly). nightly-2025-06-01 is the
# fleet-documented known-good pin (nightly-2025-01-15 ICEs compiling `log` under ASan).
ARG RUST_CHANNEL=nightly-2025-06-01
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN set -eux; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_CHANNEL"; \
    rustup component add rust-src --toolchain "$RUST_CHANNEL"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    # The non-root `mayhem` user runs `cargo fuzz build`, which WRITES into CARGO_HOME (registry
    # cache, git checkouts) — must be readable/writable for the build (and the offline PATCH re-run).
    chmod -R a+rX /opt/toolchains/rust; \
    mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git" && chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    rustc --version; cargo --version; cargo fuzz --version

USER mayhem
WORKDIR /mayhem

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build), builds the sanitized fuzz targets + the KAT
# probe + precompiles the protobuf crate's own test suite.
RUN bash mayhem/build.sh

# Run the functional oracle at build time — a failing suite fails the build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem

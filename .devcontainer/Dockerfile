# SIXX Vault — contract-audit devcontainer.
# Deterministic, fully version-pinned audit toolchain so a Codespace rebuild
# reproduces the exact same audit gates that run on a local (macOS) machine.
# Every tool below maps to a stage in scripts/contract-audit.sh:
#   forge/cast/anvil -> build/test/coverage/invariant/fork
#   slither          -> Stage 6 (hard gate)
#   solc-select/solc -> Stage 0 pin (0.8.28)
#   crytic-compile   -> echidna's compile backend (must be on PATH)
#   echidna          -> Stage 5 (property fuzzing)
#   aderyn           -> Stage 7 (static analysis)
#   gambit           -> Stage 8 (mutation, scripts/mutation-test.sh)
#   halmos           -> Stage 8b (symbolic)
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# ─── Pinned versions (single source of truth; mirrored in verify-audit-toolchain.sh) ───
ARG FOUNDRY_VERSION=v1.7.1
ARG SLITHER_VERSION=0.11.5
ARG SOLC_SELECT_VERSION=1.2.0
ARG SOLC_VERSION=0.8.28
ARG HALMOS_VERSION=0.3.3
# crytic-compile is echidna's compilation backend; it ships as a slither dep but
# its CLI entrypoint must be on PATH or echidna FAILs to compile the target.
ARG CRYTIC_COMPILE_VERSION=0.3.11
ARG ADERYN_VERSION=0.6.8
ARG ECHIDNA_VERSION=2.3.2
ARG GAMBIT_VERSION=1.0.6

ENV DEBIAN_FRONTEND=noninteractive
# Foundry + solc-select artifacts live in world-readable /opt so any container
# user (root at build, vscode at runtime) resolves the same binaries.
ENV FOUNDRY_DIR=/opt/foundry
ENV SOLC_SELECT_INSTALL_DIR=/opt/solc-select
ENV PATH=/opt/foundry/bin:/usr/local/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git xz-utils tar gzip unzip jq \
      python3 python3-pip python3-venv libgmp10 \
    && rm -rf /var/lib/apt/lists/*

# ─── Python audit tools (isolated venv, entrypoints symlinked onto PATH) ───
RUN python3 -m venv /opt/audit-venv \
    && /opt/audit-venv/bin/pip install --no-cache-dir \
         "slither-analyzer==${SLITHER_VERSION}" \
         "solc-select==${SOLC_SELECT_VERSION}" \
         "crytic-compile==${CRYTIC_COMPILE_VERSION}" \
         "halmos==${HALMOS_VERSION}" \
    && for b in slither solc-select solc crytic-compile halmos; do \
         ln -sf /opt/audit-venv/bin/$b /usr/local/bin/$b; \
       done

# ─── solc pinned to 0.8.28 (shared install dir; world-writable so postCreate can re-pin) ───
# a+rwX (not just a+rX) lets the runtime user re-run `solc-select use 0.8.28`, so the
# 0.8.28 global-version always wins over any 0.8.36 default (fixes verify MISMATCH).
RUN mkdir -p "${SOLC_SELECT_INSTALL_DIR}" \
    && solc-select install "${SOLC_VERSION}" \
    && solc-select use "${SOLC_VERSION}" \
    && chmod -R a+rwX "${SOLC_SELECT_INSTALL_DIR}"

# ─── Foundry pinned to v1.7.1 (matches local forge 1.7.1) ───
RUN curl -L https://foundry.paradigm.xyz | bash \
    && "${FOUNDRY_DIR}/bin/foundryup" -i "${FOUNDRY_VERSION}" \
    && for b in forge cast anvil chisel; do \
         ln -sf "${FOUNDRY_DIR}/bin/$b" /usr/local/bin/$b; \
       done \
    && chmod -R a+rX "${FOUNDRY_DIR}"

# ─── aderyn (prebuilt linux binary, no rust toolchain needed) ───
RUN curl -fsSL -o /tmp/aderyn.tar.xz \
      "https://github.com/Cyfrin/aderyn/releases/download/aderyn-v${ADERYN_VERSION}/aderyn-x86_64-unknown-linux-gnu.tar.xz" \
    && tar -xJf /tmp/aderyn.tar.xz -C /tmp \
    && install -m0755 "$(find /tmp -maxdepth 2 -name aderyn -type f | head -1)" /usr/local/bin/aderyn \
    && rm -rf /tmp/aderyn*

# ─── echidna (prebuilt linux binary; uses slither/crytic-compile at runtime) ───
RUN curl -fsSL -o /tmp/echidna.tar.gz \
      "https://github.com/crytic/echidna/releases/download/v${ECHIDNA_VERSION}/echidna-${ECHIDNA_VERSION}-x86_64-linux.tar.gz" \
    && tar -xzf /tmp/echidna.tar.gz -C /tmp \
    && install -m0755 "$(find /tmp -maxdepth 2 -name echidna -type f | head -1)" /usr/local/bin/echidna \
    && rm -rf /tmp/echidna*

# ─── gambit (Certora, bare linux binary) ───
RUN curl -fsSL -o /usr/local/bin/gambit \
      "https://github.com/Certora/gambit/releases/download/v${GAMBIT_VERSION}/gambit-linux-v${GAMBIT_VERSION}" \
    && chmod +x /usr/local/bin/gambit

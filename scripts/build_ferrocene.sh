#!/usr/bin/env bash
#
# *******************************************************************************
# Copyright (c) 2025 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Apache License Version 2.0 which is available at
# https://www.apache.org/licenses/LICENSE-2.0
#
# SPDX-License-Identifier: Apache-2.0
# *******************************************************************************
#
# Build Ferrocene from source at a specific commit and package it as a Bazel-friendly archive.
#
# Example:
#   ./scripts/build_ferrocene.sh --sha <commit> --target x86_64-unknown-linux-gnu
#
set -euo pipefail

REPO_URL=${FERROCENE_REPO_URL:-"https://github.com/ferrocene/ferrocene.git"}
SRC_DIR=${FERROCENE_SRC_DIR:-".cache/ferrocene-src"}
OUT_DIR=${FERROCENE_OUT_DIR:-"out/ferrocene"}

TARGET_TRIPLE="x86_64-unknown-linux-gnu"
EXEC_TRIPLE="x86_64-unknown-linux-gnu"
FERROCENE_SHA="${FERROCENE_SHA:-}"
JOBS="${FERROCENE_JOBS:-}"
BOOTSTRAP_TOML="${FERROCENE_BOOTSTRAP_TOML:-}"
DIST_PACKAGES="${FERROCENE_DIST_PACKAGES:-rustc rust-std cargo rustfmt clippy}"
INSTALL_PACKAGES="${FERROCENE_INSTALL_PACKAGES:-rustc library/std cargo rustfmt clippy}"
GIT_DEPTH="${FERROCENE_GIT_DEPTH:-1}"

usage() {
  cat <<'EOF'
Build Ferrocene and emit a tar.gz archive of the installed toolchain.

Required:
  --sha <commit>          Commit or tag to check out (FERROCENE_SHA)

Optional:
  --target <triple>       Target triple to build (default: x86_64-unknown-linux-gnu)
  --exec <triple>         Exec/host triple (default: x86_64-unknown-linux-gnu)
  --repo-url <url>        Git repo to clone (default: https://github.com/ferrocene/ferrocene.git)
  --src-dir <path>        Cache directory for the git checkout (default: .cache/ferrocene-src)
  --out-dir <path>        Output directory for artifacts (default: out/ferrocene)
  --jobs <n>              Parallel jobs passed to x.py (-j)
  --bootstrap <path>      Path to write bootstrap.toml (default: <src-dir>/bootstrap.toml)
  --dist-packages "<pkgs>" Space-separated list of dist/install packages (default: "rustc rust-std cargo rustfmt clippy")
  --install-packages "<pkgs>" Space-separated list of install packages (default: "rustc library/std cargo rustfmt clippy")
  --git-depth <n>         Git clone/fetch depth (default: 1). Use 0 for full history.
  --full                  Alias for --git-depth 0

Environment overrides:
  FERROCENE_REPO_URL, FERROCENE_SRC_DIR, FERROCENE_OUT_DIR, FERROCENE_SHA, FERROCENE_JOBS,
  FERROCENE_BOOTSTRAP_TOML, FERROCENE_DIST_PACKAGES, FERROCENE_INSTALL_PACKAGES, FERROCENE_GIT_DEPTH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) FERROCENE_SHA="$2"; shift 2 ;;
    --target) TARGET_TRIPLE="$2"; shift 2 ;;
    --exec) EXEC_TRIPLE="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --bootstrap) BOOTSTRAP_TOML="$2"; shift 2 ;;
    --dist-packages) DIST_PACKAGES="$2"; shift 2 ;;
    --install-packages) INSTALL_PACKAGES="$2"; shift 2 ;;
    --git-depth) GIT_DEPTH="$2"; shift 2 ;;
    --full) GIT_DEPTH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${FERROCENE_SHA}" ]]; then
  echo "ERROR: --sha (or FERROCENE_SHA) is required." >&2
  usage
  exit 1
fi

if ! [[ "${GIT_DEPTH}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --git-depth must be a non-negative integer (0 for full history)." >&2
  exit 1
fi

for cmd in git python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

if ! command -v uv >/dev/null 2>&1; then
  cat <<'EOF' >&2
Missing required command: uv
Ferrocene's bootstrap expects the `uv` package manager (https://github.com/astral-sh/uv) on PATH.
Install it (e.g., curl -LsSf https://astral.sh/uv/install.sh | sh) or provide a locally built binary.
EOF
  exit 1
fi

mkdir -p "${SRC_DIR}" "${OUT_DIR}"

IFS=',' read -r -a TARGETS_ARR <<< "${TARGET_TRIPLE}"
NEEDS_QNX=0
NEEDS_LINUX_AARCH64=0
for t in "${TARGETS_ARR[@]}"; do
  if [[ "${t}" == *qnx* ]]; then
    NEEDS_QNX=1
  fi
  if [[ "${t}" == "aarch64-unknown-linux-gnu" || "${t}" == "aarch64-unknown-ferrocene.subset" ]]; then
    NEEDS_LINUX_AARCH64=1
  fi
done

if [[ "${NEEDS_QNX}" -eq 1 ]]; then
  if [[ -z "${QNX_HOST:-}" || -z "${QNX_TARGET:-}" ]]; then
    cat <<'EOF' >&2
ERROR: QNX targets requested but QNX environment is not configured.
Hint: source your SDP environment first (e.g. `source /path/to/qnxsdp-env.sh`),
      then re-run the build.
EOF
    exit 1
  fi
fi

if [[ "${NEEDS_LINUX_AARCH64}" -eq 1 ]]; then
  if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    cat <<'EOF' >&2
ERROR: target aarch64-unknown-linux-gnu requested but aarch64-linux-gnu-gcc is missing.
On Debian/Ubuntu, install it with: sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
EOF
    exit 1
  fi
fi

X_ENV=()
if [[ "${NEEDS_QNX}" -eq 1 ]]; then
  # Ensure QNX tools are on PATH even if the user exported QNX_HOST/QNX_TARGET manually.
  X_ENV+=("PATH=${QNX_HOST}/usr/bin:${PATH}")

  if ! command -v qcc >/dev/null 2>&1; then
    echo "ERROR: QNX targets requested but qcc is not on PATH (is QNX_HOST set correctly?)" >&2
    exit 1
  fi

  # For QNX targets, rustc expects to link with `qcc` and to receive the correct `-V...`
  # variant flag (see `src/doc/rustc/src/platform-support/nto-qnx.md` in the Ferrocene checkout).
  for t in "${TARGETS_ARR[@]}"; do
    case "${t}" in
      aarch64-unknown-nto-qnx7*|aarch64-unknown-nto-qnx8*)
        QNX_CFLAGS="-Vgcc_ntoaarch64le_cxx"
        QNX_AR="ntoaarch64-ar"
        ;;
      x86_64-pc-nto-qnx7*|x86_64-pc-nto-qnx8*)
        QNX_CFLAGS="-Vgcc_ntox86_64_cxx"
        QNX_AR="ntox86_64-ar"
        ;;
      *)
        continue
        ;;
    esac

    if ! command -v "${QNX_AR}" >/dev/null 2>&1; then
      echo "ERROR: couldn't find ${QNX_AR} on PATH (check QNX_HOST and sourced environment)" >&2
      exit 1
    fi

    t_underscored="${t//-/_}"
    X_ENV+=("CC_${t_underscored}=qcc")
    X_ENV+=("CXX_${t_underscored}=qcc")
    X_ENV+=("CFLAGS_${t_underscored}=${QNX_CFLAGS}")
    X_ENV+=("CXXFLAGS_${t_underscored}=${QNX_CFLAGS}")
    X_ENV+=("AR_${t_underscored}=${QNX_AR}")
  done
fi

if [[ "${NEEDS_LINUX_AARCH64}" -eq 1 ]]; then
  for t in "${TARGETS_ARR[@]}"; do
    case "${t}" in
      aarch64-unknown-linux-gnu|aarch64-unknown-ferrocene.subset)
        t_underscored="${t//-/_}"
        X_ENV+=("CC_${t_underscored}=aarch64-linux-gnu-gcc")
        X_ENV+=("CXX_${t_underscored}=aarch64-linux-gnu-g++")
        X_ENV+=("AR_${t_underscored}=aarch64-linux-gnu-ar")
        ;;
      *)
        ;;
    esac
  done

  # Ferrocene subset/facade target compiler detection maps back to `aarch64-unknown-none`.
  # Provide explicit tools for that triple to avoid `cc` guessing.
  X_ENV+=("CC_aarch64_unknown_none=aarch64-linux-gnu-gcc")
  X_ENV+=("CXX_aarch64_unknown_none=aarch64-linux-gnu-g++")
  X_ENV+=("AR_aarch64_unknown_none=aarch64-linux-gnu-ar")
fi

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  if [[ "${GIT_DEPTH}" -gt 0 ]]; then
    git clone --no-checkout --depth "${GIT_DEPTH}" "${REPO_URL}" "${SRC_DIR}"
  else
    git clone "${REPO_URL}" "${SRC_DIR}"
  fi
else
  git -C "${SRC_DIR}" remote set-url origin "${REPO_URL}"
fi

if [[ "${GIT_DEPTH}" -gt 0 ]]; then
  git -C "${SRC_DIR}" fetch --depth "${GIT_DEPTH}" origin "${FERROCENE_SHA}"
else
  git -C "${SRC_DIR}" fetch --all
fi
git -C "${SRC_DIR}" checkout --detach "${FERROCENE_SHA}"

BOOTSTRAP_TOML="${BOOTSTRAP_TOML:-${SRC_DIR}/bootstrap.toml}"
if [[ -f "${BOOTSTRAP_TOML}" ]]; then
  echo "Using existing ${BOOTSTRAP_TOML} (not overwriting)."
else
  TARGET_TOML_LIST=""
  for t in "${TARGETS_ARR[@]}"; do
    if [[ -z "${TARGET_TOML_LIST}" ]]; then
      TARGET_TOML_LIST="\"${t}\""
    else
      TARGET_TOML_LIST="${TARGET_TOML_LIST}, \"${t}\""
    fi
  done

  cat > "${BOOTSTRAP_TOML}" <<EOF
# Auto-generated by build_ferrocene.sh to avoid CI artifact downloads and to target explicit triples.
change-id = "ignore"
profile = "dist"

[build]
host = ["${EXEC_TRIPLE}"]
target = [${TARGET_TOML_LIST}]
extended = true

[llvm]
download-ci-llvm = false

[gcc]
download-ci-gcc = false

[rust]
download-rustc = false
EOF
  echo "Wrote ${BOOTSTRAP_TOML} (download-ci-llvm/gcc/rustc disabled)"
fi

J_FLAG=()
if [[ -n "${JOBS}" ]]; then
  J_FLAG=(-j "${JOBS}")
fi

CONFIG_FLAG=(--config "${BOOTSTRAP_TOML}")
DIST_ARGS=(${DIST_PACKAGES})
INSTALL_ARGS=(${INSTALL_PACKAGES})

env "${X_ENV[@]}" python3 "${SRC_DIR}/x.py" "${J_FLAG[@]}" "${CONFIG_FLAG[@]}" dist --host "${EXEC_TRIPLE}" --target "${TARGET_TRIPLE}" "${DIST_ARGS[@]}"
rm -rf "${OUT_DIR}/install"
env "${X_ENV[@]}" DESTDIR="${OUT_DIR}/install" python3 "${SRC_DIR}/x.py" "${J_FLAG[@]}" "${CONFIG_FLAG[@]}" install --host "${EXEC_TRIPLE}" --target "${TARGET_TRIPLE}" "${INSTALL_ARGS[@]}"

if [[ "${TARGET_TRIPLE}" == *","* ]]; then
  TARGETS_HASH="$(printf %s "${TARGET_TRIPLE}" | sha256sum | cut -c1-8)"
  ARCHIVE_BASENAME="ferrocene-${FERROCENE_SHA}-${EXEC_TRIPLE}-multi-${TARGETS_HASH}"
  printf '%s\n' "${TARGET_TRIPLE}" > "${OUT_DIR}/${ARCHIVE_BASENAME}.targets.txt"
  ARCHIVE_NAME="${ARCHIVE_BASENAME}.tar.gz"
else
  ARCHIVE_NAME="ferrocene-${FERROCENE_SHA}-${TARGET_TRIPLE}.tar.gz"
fi
tar -C "${OUT_DIR}/install" -czf "${OUT_DIR}/${ARCHIVE_NAME}" .
sha256sum "${OUT_DIR}/${ARCHIVE_NAME}" | tee "${OUT_DIR}/${ARCHIVE_NAME}.sha256"

cat <<EOF

Built archive: ${OUT_DIR}/${ARCHIVE_NAME}
SHA256 file  : ${OUT_DIR}/${ARCHIVE_NAME}.sha256

Use the archive URL and SHA256 in your consuming repository (for example as a pinned toolchain archive).
EOF

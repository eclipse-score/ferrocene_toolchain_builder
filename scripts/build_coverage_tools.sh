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
# Build the Ferrocene coverage helpers for a given host triple. This packages
# the Ferrocene-specific tools (symbol-report and blanket) together with the
# LLVM coverage tools from the same build tree (llvm-cov, llvm-profdata, and
# optionally llvm-cxxfilt).
#
# Example:
#   ./scripts/build_coverage_tools.sh --sha <commit> --host x86_64-unknown-linux-gnu
#
set -euo pipefail

REPO_URL=${FERROCENE_REPO_URL:-"https://github.com/ferrocene/ferrocene.git"}
SRC_DIR=${FERROCENE_SRC_DIR:-".cache/ferrocene-src"}
OUT_DIR=${FERROCENE_TOOLS_OUT_DIR:-"out/ferrocene/tools"}
BUILD_DIR=${FERROCENE_BUILD_DIR:-"build"}

HOST_TRIPLE="x86_64-unknown-linux-gnu"
FERROCENE_SHA="${FERROCENE_SHA:-}"
JOBS="${FERROCENE_JOBS:-}"
BOOTSTRAP_TOML="${FERROCENE_BOOTSTRAP_TOML:-}"
GIT_DEPTH="${FERROCENE_GIT_DEPTH:-1}"
STAGE="${FERROCENE_STAGE:-2}"

usage() {
  cat <<'EOF'
Build Ferrocene's coverage tools for a host triple.

Required:
  --sha <commit>          Commit or tag to check out (FERROCENE_SHA)

Optional:
  --host <triple>         Host/exec triple for the tools (default: x86_64-unknown-linux-gnu)
  --repo-url <url>        Git repo to clone (default: https://github.com/ferrocene/ferrocene.git)
  --src-dir <path>        Cache directory for the git checkout (default: .cache/ferrocene-src)
  --out-dir <path>        Where to copy the built binaries (default: out/ferrocene/tools)
  --build-dir <path>      x.py build directory (default: ./build relative to CWD)
  --jobs <n>              Parallel jobs passed to x.py (-j)
  --bootstrap <path>      Path to bootstrap/config toml (default: <src-dir>/bootstrap.toml)
  --stage <n>             x.py stage to build with (default: 2)
  --git-depth <n>         Git clone/fetch depth (default: 1). Use 0 for full history.
  --full                  Alias for --git-depth 0

Environment overrides:
  FERROCENE_REPO_URL, FERROCENE_SRC_DIR, FERROCENE_TOOLS_OUT_DIR, FERROCENE_SHA, FERROCENE_JOBS,
  FERROCENE_BOOTSTRAP_TOML, FERROCENE_STAGE, FERROCENE_GIT_DEPTH, FERROCENE_BUILD_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) FERROCENE_SHA="$2"; shift 2 ;;
    --host) HOST_TRIPLE="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --bootstrap) BOOTSTRAP_TOML="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
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

if ! [[ "${STAGE}" =~ ^[0-9]+$ ]] || [[ "${STAGE}" -lt 1 ]]; then
  echo "ERROR: --stage must be an integer >= 1." >&2
  exit 1
fi

for cmd in git python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

X_ENV=()
case "${HOST_TRIPLE}" in
  aarch64-unknown-linux-gnu)
    if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
      cat <<'EOF' >&2
ERROR: host aarch64-unknown-linux-gnu requested but aarch64-linux-gnu-gcc is missing.
On Debian/Ubuntu, install it with: sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
EOF
      exit 1
    fi
    X_ENV+=("CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc")
    X_ENV+=("CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++")
    X_ENV+=("AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar")
    ;;
  *qnx*)
    cat <<EOF >&2
ERROR: coverage tools are host-executed binaries. Building a ${HOST_TRIPLE} coverage-tools archive is not supported here.
Build a Linux host archive instead (for example x86_64-unknown-linux-gnu or aarch64-unknown-linux-gnu).
EOF
    exit 1
    ;;
esac

mkdir -p "${SRC_DIR}" "${OUT_DIR}"

BUILD_DIR_ABS=$(python3 - <<'PY' "$BUILD_DIR"
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
)
mkdir -p "${BUILD_DIR_ABS}"

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  if [[ "${GIT_DEPTH}" -gt 0 ]]; then
    git clone --no-checkout --depth "${GIT_DEPTH}" "${REPO_URL}" "${SRC_DIR}"
  else
    git clone "${REPO_URL}" "${SRC_DIR}"
  fi
else
  git -C "${SRC_DIR}" remote set-url origin "${REPO_URL}"
fi

if git -C "${SRC_DIR}" rev-parse --verify "${FERROCENE_SHA}^{commit}" >/dev/null 2>&1; then
  echo "Found ${FERROCENE_SHA} locally; skipping fetch."
else
  if [[ "${GIT_DEPTH}" -gt 0 ]]; then
    git -C "${SRC_DIR}" fetch --depth "${GIT_DEPTH}" origin "${FERROCENE_SHA}"
  else
    git -C "${SRC_DIR}" fetch --all
  fi
fi
git -C "${SRC_DIR}" checkout --detach "${FERROCENE_SHA}"

BOOTSTRAP_TOML="${BOOTSTRAP_TOML:-${SRC_DIR}/bootstrap.toml}"
if [[ -f "${BOOTSTRAP_TOML}" ]]; then
  echo "Using existing ${BOOTSTRAP_TOML} (not overwriting)."
else
  cat > "${BOOTSTRAP_TOML}" <<EOF
# Auto-generated by build_coverage_tools.sh to avoid CI artifact downloads.
change-id = "ignore"
profile = "dist"

[build]
host = ["${HOST_TRIPLE}"]
target = ["${HOST_TRIPLE}"]
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

TOOLS_DIR="${BUILD_DIR_ABS}/${HOST_TRIPLE}/stage${STAGE}-tools-bin"
LLVM_TOOLS_DIR="${BUILD_DIR_ABS}/${HOST_TRIPLE}/llvm/bin"
EXT=""
if [[ "${HOST_TRIPLE}" == *"windows"* ]]; then
  EXT=".exe"
fi

SYMBOL_BIN="${TOOLS_DIR}/symbol-report${EXT}"
BLANKET_TOOLS_DIR="${TOOLS_DIR}"
if [[ "${STAGE}" -gt 1 ]]; then
  FALLBACK_BLANKET_DIR="${BUILD_DIR_ABS}/${HOST_TRIPLE}/stage1-tools-bin"
  if [[ ! -x "${BLANKET_TOOLS_DIR}/blanket${EXT}" && -x "${FALLBACK_BLANKET_DIR}/blanket${EXT}" ]]; then
    echo "NOTE: blanket is built with the bootstrap compiler; using stage1 blanket at ${FALLBACK_BLANKET_DIR}"
    BLANKET_TOOLS_DIR="${FALLBACK_BLANKET_DIR}"
  fi
fi
BLANKET_BIN="${BLANKET_TOOLS_DIR}/blanket${EXT}"

resolve_llvm_binary() {
  local tool_name="$1"
  local candidate=""

  for candidate in \
    "${LLVM_TOOLS_DIR}/${tool_name}${EXT}" \
    "${BUILD_DIR_ABS}/llvm/bin/${tool_name}${EXT}"
  do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

collect_package_bins() {
  local llvm_cov_bin=""
  local llvm_profdata_bin=""
  local llvm_cxxfilt_bin=""

  if [[ ! -x "${SYMBOL_BIN}" || ! -x "${BLANKET_BIN}" ]]; then
    return 1
  fi

  llvm_cov_bin="$(resolve_llvm_binary llvm-cov)" || return 1
  llvm_profdata_bin="$(resolve_llvm_binary llvm-profdata)" || return 1
  llvm_cxxfilt_bin="$(resolve_llvm_binary llvm-cxxfilt 2>/dev/null || true)"

  PACKAGE_BINS=(
    "${SYMBOL_BIN}"
    "${BLANKET_BIN}"
    "${llvm_cov_bin}"
    "${llvm_profdata_bin}"
  )
  if [[ -n "${llvm_cxxfilt_bin}" ]]; then
    PACKAGE_BINS+=("${llvm_cxxfilt_bin}")
  fi

  return 0
}

J_FLAG=()
if [[ -n "${JOBS}" ]]; then
  J_FLAG=(-j "${JOBS}")
fi

if collect_package_bins; then
  echo "Reusing cached coverage-tool build outputs from ${BUILD_DIR_ABS}."
else
  env "${X_ENV[@]}" python3 "${SRC_DIR}/x.py" "${J_FLAG[@]}" --config "${BOOTSTRAP_TOML}" --build-dir "${BUILD_DIR_ABS}" \
    build --stage "${STAGE}" --host "${HOST_TRIPLE}" --target "${HOST_TRIPLE}" \
    ferrocene/tools/symbol-report ferrocene/tools/blanket

  if ! collect_package_bins; then
    echo "ERROR: expected coverage tools were not produced in ${BUILD_DIR_ABS}." >&2
    exit 1
  fi
fi

if ! resolve_llvm_binary llvm-cxxfilt >/dev/null 2>&1; then
  echo "NOTE: llvm-cxxfilt was not found in the build output; packaging coverage tools without it." >&2
fi

for bin in "${PACKAGE_BINS[@]}"; do
  if [[ ! -x "${bin}" ]]; then
    echo "ERROR: expected tool at ${bin}, but it was not produced." >&2
    exit 1
  fi
done

DEST_DIR="${OUT_DIR}/${FERROCENE_SHA}/${HOST_TRIPLE}"
mkdir -p "${DEST_DIR}"
cp "${PACKAGE_BINS[@]}" "${DEST_DIR}/"

PACKAGE_NAMES=()
for bin in "${PACKAGE_BINS[@]}"; do
  PACKAGE_NAMES+=("$(basename "${bin}")")
done

pushd "${DEST_DIR}" >/dev/null
sha256sum "${PACKAGE_NAMES[@]}" > SHA256SUMS
popd >/dev/null

ARCHIVE_NAME="coverage-tools-${FERROCENE_SHA}-${HOST_TRIPLE}.tar.gz"
ARCHIVE_PATH="${OUT_DIR}/${ARCHIVE_NAME}"
tar -C "${OUT_DIR}" -czf "${ARCHIVE_PATH}" "${FERROCENE_SHA}/${HOST_TRIPLE}"
sha256sum "${ARCHIVE_PATH}" > "${ARCHIVE_PATH}.sha256"

cat <<EOF

Built coverage tools for ${FERROCENE_SHA} (${HOST_TRIPLE}) at ${DEST_DIR}:
$(for tool_name in "${PACKAGE_NAMES[@]}"; do printf '  - %s/%s\n' "${DEST_DIR}" "${tool_name}"; done)
Checksums stored in ${DEST_DIR}/SHA256SUMS
Archive written to ${ARCHIVE_PATH}
Archive SHA256 stored in ${ARCHIVE_PATH}.sha256
EOF

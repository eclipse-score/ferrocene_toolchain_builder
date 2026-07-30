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
# Package the Ferrocene rust-src input set as a standalone tarball suitable for
# Miri and other tools that need std sources without bundling them into every
# target-specific toolchain archive.
#
# Example:
#   ./scripts/build_rust_src.sh --sha <commit>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/ferrocene_source.sh"

REPO_URL=${FERROCENE_REPO_URL:-"https://github.com/ferrocene/ferrocene.git"}
SRC_DIR=${FERROCENE_SRC_DIR:-".cache/ferrocene-src"}
OUT_DIR=${FERROCENE_OUT_DIR:-"out/ferrocene"}
FERROCENE_SHA="${FERROCENE_SHA:-}"
GIT_DEPTH="${FERROCENE_GIT_DEPTH:-1}"

usage() {
  cat <<'EOF'
Package Ferrocene's rust-src tree as a standalone tar.gz archive.

Required:
  --sha <commit>          Commit or tag to check out (FERROCENE_SHA)

Optional:
  --repo-url <url>        Git repo to clone (default: https://github.com/ferrocene/ferrocene.git)
  --src-dir <path>        Cache directory for the git checkout (default: .cache/ferrocene-src)
  --out-dir <path>        Output directory for artifacts (default: out/ferrocene)
  --git-depth <n>         Git clone/fetch depth (default: 1). Use 0 for full history.
  --full                  Alias for --git-depth 0

Environment overrides:
  FERROCENE_REPO_URL, FERROCENE_SRC_DIR, FERROCENE_OUT_DIR, FERROCENE_SHA, FERROCENE_GIT_DEPTH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) FERROCENE_SHA="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
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

for cmd in git tar sha256sum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

mkdir -p "${SRC_DIR}" "${OUT_DIR}"
prepare_ferrocene_checkout "${REPO_URL}" "${SRC_DIR}" "${FERROCENE_SHA}" "${GIT_DEPTH}"

ARCHIVE_NAME="rust-src-${FERROCENE_SHA}.tar.gz"
ARCHIVE_PATH="${OUT_DIR}/${ARCHIVE_NAME}"
SHA_PATH="${ARCHIVE_PATH}.sha256"

# Match Ferrocene's rust-src dist component contents, but emit a Bazel-friendly
# source tree instead of the generic installer wrapper.
tar -C "${SRC_DIR}" \
  --exclude='library/backtrace/crates' \
  --exclude='library/stdarch/Cargo.toml' \
  --exclude='library/stdarch/crates/stdarch-verify' \
  --exclude='library/stdarch/crates/intrinsic-test' \
  -czf "${ARCHIVE_PATH}" \
  library \
  src/llvm-project/compiler-rt \
  src/llvm-project/libunwind \
  ferrocene/library/libc \
  ferrocene/library/backtrace-rs

sha256sum "${ARCHIVE_PATH}" | tee "${SHA_PATH}"

cat <<EOF

Built archive: ${ARCHIVE_PATH}
SHA256 file  : ${SHA_PATH}

This archive unpacks to a source tree root containing:
  - library/
  - src/llvm-project/compiler-rt/
  - src/llvm-project/libunwind/
  - ferrocene/library/libc/
  - ferrocene/library/backtrace-rs/

For Miri, point MIRI_LIB_SRC at <extract-root>/library.
EOF

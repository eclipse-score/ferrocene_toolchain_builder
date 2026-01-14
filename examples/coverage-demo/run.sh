#!/usr/bin/env bash
set -euo pipefail

# Configuration with sensible defaults; override via env.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/../.." && pwd)"

RUSTC="${RUSTC:-${REPO_ROOT}/build/x86_64-unknown-linux-gnu/stage2/bin/rustc}"
SYMBOL_REPORT="${SYMBOL_REPORT:-${REPO_ROOT}/out/ferrocene/tools/779fbed05ae9e9fe2a04137929d99cc9b3d516fd/x86_64-unknown-linux-gnu/symbol-report}"
BLANKET="${BLANKET:-${REPO_ROOT}/out/ferrocene/tools/779fbed05ae9e9fe2a04137929d99cc9b3d516fd/x86_64-unknown-linux-gnu/blanket}"
FERROCENE_SRC="${FERROCENE_SRC:-${REPO_ROOT}/.cache/ferrocene-src}"
SYSROOT="${SYSROOT:-${REPO_ROOT}/build/x86_64-unknown-linux-gnu/stage2}"
TARGET="${TARGET:-x86_64-unknown-linux-gnu}"
# Shared libs needed by symbol-report (rustc_private). Prefer stage1 libs if present.
RUSTC_LIB_SEARCH=(
  "${REPO_ROOT}/build/x86_64-unknown-linux-gnu/stage2/lib"
  "${REPO_ROOT}/build/x86_64-unknown-linux-gnu/stage1/lib"
  "${REPO_ROOT}/build/x86_64-unknown-linux-gnu/stage0-sysroot/lib"
)
LD_PATH_JOIN=$(IFS=:; echo "${RUSTC_LIB_SEARCH[*]}")
export LD_LIBRARY_PATH="${LD_PATH_JOIN}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
OUT_DIR="${PROJECT_ROOT}/coverage-out"
BIN_DIR="${OUT_DIR}/bin"
PROFRAW_DIR="${OUT_DIR}/profraw"
REPORT_DIR="${OUT_DIR}/blanket"
SYMBOL_REPORT_JSON="${OUT_DIR}/symbol-report.json"
PROFILER_LIB_DIR="${SYSROOT}/lib/rustlib/${TARGET}/lib"
TMPDIR="${TMPDIR:-/tmp/ferrocene-coverage}"

mkdir -p "${BIN_DIR}" "${PROFRAW_DIR}" "${REPORT_DIR}" "${TMPDIR}"
export TMPDIR

for tool in "${RUSTC}" "${SYMBOL_REPORT}" "${BLANKET}"; do
  if [[ ! -x "${tool}" ]]; then
    echo "Missing tool: ${tool} (check your paths)" >&2
    exit 1
  fi
done

echo "Using:"
echo "  RUSTC         = ${RUSTC}"
echo "  SYMBOL_REPORT = ${SYMBOL_REPORT}"
echo "  BLANKET       = ${BLANKET}"
echo "  FERROCENE_SRC = ${FERROCENE_SRC}"
echo "  SYSROOT       = ${SYSROOT}"
echo "  TARGET        = ${TARGET}"
echo "  PROFILER_LIB_DIR = ${PROFILER_LIB_DIR}"

if ! compgen -G "${PROFILER_LIB_DIR}/libprofiler_builtins"*.rlib >/dev/null; then
  echo "profiler_builtins missing in ${PROFILER_LIB_DIR} (coverage runtime not built)." >&2
  echo "Rebuild your Ferrocene toolchain with profiler enabled or point SYSROOT to one that has it." >&2
  exit 1
fi

# Remap paths so blanket sees relative sources, matching Ferrocene's setup.
REMAP="--remap-path-prefix=${PROJECT_ROOT}/=."
COMMON_FLAGS=(
  -C instrument-coverage
  -C link-dead-code
  -C codegen-units=1
  -C debuginfo=2
  -L "dependency=${PROFILER_LIB_DIR}"
  "${REMAP}"
)

TEST_BIN="${BIN_DIR}/demo-tests"
echo "Building instrumented test binary..."
"${RUSTC}" \
  --test "${PROJECT_ROOT}/src/lib.rs" \
  --target "${TARGET}" \
  --sysroot "${SYSROOT}" \
  -o "${TEST_BIN}" \
  "${COMMON_FLAGS[@]}"

echo "Running tests to collect .profraw files..."
LLVM_PROFILE_FILE="${PROFRAW_DIR}/demo-%m.profraw" "${TEST_BIN}"

shopt -s nullglob
PROFRAW_FILES=("${PROFRAW_DIR}"/*.profraw)
shopt -u nullglob
if [[ ${#PROFRAW_FILES[@]} -eq 0 ]]; then
  echo "No .profraw files found in ${PROFRAW_DIR}" >&2
  exit 1
fi

echo "Generating symbol-report.json..."
SYMBOL_REPORT_OUT="${SYMBOL_REPORT_JSON}" \
  "${SYMBOL_REPORT}" \
  --crate-name coverage_demo \
  --edition 2021 \
  --crate-type lib \
  "${PROJECT_ROOT}/src/lib.rs" \
  --target "${TARGET}" \
  --sysroot "${SYSROOT}" \
  -o /dev/null \
  "${REMAP}"

python3 - <<'PY' "${SYMBOL_REPORT_JSON}" "${PROJECT_ROOT}"
import json, sys, pathlib
path = pathlib.Path(sys.argv[2]).resolve()
with open(sys.argv[1]) as f:
    data = json.load(f)
for sym in data.get("symbols", []):
    fname = pathlib.Path(sym["filename"])
    try:
        rel = fname.relative_to(path)
    except ValueError:
        rel = fname
    sym["filename"] = rel.as_posix()
with open(sys.argv[1], "w") as f:
    json.dump(data, f)
PY

echo "Rendering blanket HTML report..."
"${BLANKET}" show \
  $(printf -- '--instr-profile=%s ' "${PROFRAW_FILES[@]}") \
  --object "${TEST_BIN}" \
  --report "${SYMBOL_REPORT_JSON}" \
  --ferrocene-src "${PROJECT_ROOT}" \
  --path-equivalence ".,${PROJECT_ROOT}" \
  --html-out "${REPORT_DIR}/index.html"

echo
echo "Coverage artifacts:"
echo "  Raw profiles : ${PROFRAW_DIR}"
echo "  Symbol report: ${SYMBOL_REPORT_JSON}"
echo "  HTML report  : ${REPORT_DIR}/index.html"

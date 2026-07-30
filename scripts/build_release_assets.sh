#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/build_release_assets.sh --sha <commit> [options]

Build the full Ferrocene release payload from one shared source checkout and
one shared x.py build tree:
  - main toolchain archives
  - subset archives
  - coverage-tools archives
  - standalone rust-src
  - prebuilt Miri sysroots

Options:
  --sha <commit>         Commit or tag to build
  --src-dir <path>       Release checkout root (default: .cache/releases/<sha>/src)
  --build-dir <path>     Shared x.py build root (default: .cache/releases/<sha>/build)
  --out-dir <path>       Release output root (default: out/releases/<sha>)
  --cargo-home <path>    Cargo home to reuse for Miri sysroot builds
  --offline              Pass --offline to build_miri_sysroots.sh
  --skip-qnx             Skip QNX toolchain and QNX Miri sysroot artifacts
  --skip-subset          Skip Ferrocene subset toolchains
  --skip-miri-sysroots   Skip prebuilt Miri sysroots
  -h, --help             Show this help text

Environment:
  FERROCENE_BOOTSTRAP_TOML defaults to ./config.profiler.toml
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

assert_profiler_runtime_in_archive() {
  local archive_path="$1"
  # Avoid grep exiting early on a pipefed tar listing; with pipefail enabled
  # that can surface as a false negative when tar receives SIGPIPE.
  local archive_listing
  archive_listing="$(tar -tf "${archive_path}")"
  if ! grep -Eq 'libprofiler_builtins-[^/]+\.rlib$' <<<"${archive_listing}"; then
    die "archive is missing libprofiler_builtins: ${archive_path}"
  fi
}

sha=""
src_dir=""
build_dir=""
out_dir=""
cargo_home=""
offline=0
skip_qnx=0
skip_subset=0
skip_miri_sysroots=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)
      sha="${2:-}"
      shift 2
      ;;
    --src-dir)
      src_dir="${2:-}"
      shift 2
      ;;
    --build-dir)
      build_dir="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    --cargo-home)
      cargo_home="${2:-}"
      shift 2
      ;;
    --offline)
      offline=1
      shift
      ;;
    --skip-qnx)
      skip_qnx=1
      shift
      ;;
    --skip-subset)
      skip_subset=1
      shift
      ;;
    --skip-miri-sysroots)
      skip_miri_sysroots=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${sha}" ]] || die "--sha is required"

if [[ -z "${src_dir}" ]]; then
  src_dir=".cache/releases/${sha}/src"
fi
if [[ -z "${build_dir}" ]]; then
  build_dir=".cache/releases/${sha}/build"
fi
if [[ -z "${out_dir}" ]]; then
  out_dir="out/releases/${sha}"
fi

bootstrap_toml="${FERROCENE_BOOTSTRAP_TOML:-./config.profiler.toml}"
tools_out_dir="${out_dir}/tools"
sysroots_dir="${out_dir}/miri-sysroots"

mkdir -p "${out_dir}" "${tools_out_dir}"

export FERROCENE_BOOTSTRAP_TOML="${bootstrap_toml}"
export FERROCENE_SRC_DIR="${src_dir}"
export FERROCENE_BUILD_DIR="${build_dir}"
export FERROCENE_OUT_DIR="${out_dir}"
export FERROCENE_TOOLS_OUT_DIR="${tools_out_dir}"

declare -a targets=(
  x86_64-unknown-linux-gnu
  aarch64-unknown-linux-gnu
)
declare -a main_targets=(
  x86_64-unknown-linux-gnu
  aarch64-unknown-linux-gnu
)
declare -a miri_targets=(
  x86_64-unknown-linux-gnu
  aarch64-unknown-linux-gnu
)

if [[ "${skip_subset}" -eq 0 ]]; then
  targets+=(
    x86_64-unknown-ferrocene.subset
    aarch64-unknown-ferrocene.subset
  )
fi

if [[ "${skip_qnx}" -eq 0 ]]; then
  targets+=(
    x86_64-pc-nto-qnx800
    aarch64-unknown-nto-qnx800
  )
  main_targets+=(
    x86_64-pc-nto-qnx800
    aarch64-unknown-nto-qnx800
  )
  miri_targets+=(
    x86_64-pc-nto-qnx800
    aarch64-unknown-nto-qnx800
  )
fi

for target in "${targets[@]}"; do
  echo "==> building toolchain archive for ${target}"
  ./scripts/build_ferrocene.sh \
    --sha "${sha}" \
    --target "${target}" \
    --exec x86_64-unknown-linux-gnu \
    --src-dir "${src_dir}" \
    --out-dir "${out_dir}" \
    --build-dir "${build_dir}" \
    --bootstrap "${bootstrap_toml}"
done

for target in "${main_targets[@]}"; do
  assert_profiler_runtime_in_archive "${out_dir}/ferrocene-${sha}-${target}.tar.gz"
done

echo "==> packaging rust-src"
./scripts/build_rust_src.sh \
  --sha "${sha}" \
  --src-dir "${src_dir}" \
  --out-dir "${out_dir}"

echo "==> building coverage tools for x86_64-unknown-linux-gnu"
./scripts/build_coverage_tools.sh \
  --sha "${sha}" \
  --host x86_64-unknown-linux-gnu \
  --src-dir "${src_dir}" \
  --out-dir "${tools_out_dir}" \
  --build-dir "${build_dir}" \
  --bootstrap "${bootstrap_toml}" \
  --stage 2 \
  --toolchain-archive "${out_dir}/ferrocene-${sha}-x86_64-unknown-linux-gnu.tar.gz"

echo "==> building coverage tools for aarch64-unknown-linux-gnu"
./scripts/build_coverage_tools.sh \
  --sha "${sha}" \
  --host aarch64-unknown-linux-gnu \
  --src-dir "${src_dir}" \
  --out-dir "${tools_out_dir}" \
  --build-dir "${build_dir}" \
  --bootstrap "${bootstrap_toml}" \
  --stage 2 \
  --toolchain-archive "${out_dir}/ferrocene-${sha}-aarch64-unknown-linux-gnu.tar.gz"

if [[ "${skip_miri_sysroots}" -eq 0 ]]; then
  echo "==> building prebuilt Miri sysroots"
  miri_args=(
    --sha "${sha}"
    --host-toolchain "${out_dir}/ferrocene-${sha}-x86_64-unknown-linux-gnu.tar.gz"
    --rust-src "${out_dir}/rust-src-${sha}.tar.gz"
    --out-dir "${sysroots_dir}"
  )
  if [[ -n "${cargo_home}" ]]; then
    miri_args+=(--cargo-home "${cargo_home}")
  fi
  if [[ "${offline}" -eq 1 ]]; then
    miri_args+=(--offline)
  fi
  for target in "${miri_targets[@]}"; do
    miri_args+=(--target "${target}")
  done

  ./scripts/build_miri_sysroots.sh "${miri_args[@]}"

  ./scripts/package_miri_sysroots.sh \
    --sha "${sha}" \
    --sysroots-dir "${sysroots_dir}" \
    --out-dir "${out_dir}"
fi

cat <<EOF

Release artifacts for ${sha} are under:
  ${out_dir}

Expected release files include:
  - ferrocene-${sha}-<target>.tar.gz(.sha256)
  - rust-src-${sha}.tar.gz(.sha256)
  - ${tools_out_dir}/coverage-tools-${sha}-<host>.tar.gz(.sha256)
  - miri-sysroot-${sha}-<target>.tar.gz(.sha256)
EOF

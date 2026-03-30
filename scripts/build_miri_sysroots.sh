#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/build_miri_sysroots.sh \
    --sha <commit> \
    [--host-toolchain /path/to/ferrocene-x86_64-unknown-linux-gnu.tar.gz] \
    [--rust-src /path/to/rust-src.tar.gz] \
    [--out-dir /path/to/output] \
    [--cargo-home /path/to/cargo-home] \
    [--target <triple>]... \
    [--offline]

Builds one prebuilt Miri sysroot per target by running `cargo miri setup`
against the Ferrocene host toolchain and standalone rust-src artifact.

Defaults:
  --host-toolchain out/ferrocene-ubuntu24-prof/ferrocene-<sha>-x86_64-unknown-linux-gnu.tar.gz
  --rust-src      out/ferrocene/rust-src-<sha>.tar.gz
  --out-dir       out/ferrocene-ubuntu24-prof/miri-sysroots
  --cargo-home    $CARGO_HOME or $HOME/.cargo
  --target        x86_64-unknown-linux-gnu
  --target        aarch64-unknown-linux-gnu
  --target        x86_64-pc-nto-qnx800
  --target        aarch64-unknown-nto-qnx800

Notes:
  - This script reuses the existing Cargo registry cache from `--cargo-home`
    (or `$CARGO_HOME` / `$HOME/.cargo`) so local sysroot generation can work
    offline once crates are cached.
  - This script builds sysroots only for the targets you request.
  - The existing x.py build cache is not reused directly; `cargo miri setup`
    builds a separate Miri sysroot from `rust-src`.
  - `*.ferrocene.subset` targets are not included by default because the std
    sysroot build currently fails for them.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

realpath_safe() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
}

resolve_toolchain_root() {
  local arg="$1"
  local extract_dir="$2"
  if [[ -d "$arg" ]]; then
    arg="$(realpath_safe "$arg")"
    [[ -x "$arg/bin/cargo" ]] || die "toolchain directory is missing bin/cargo: $arg"
    [[ -x "$arg/bin/miri" ]] || die "toolchain directory is missing bin/miri: $arg"
    printf '%s\n' "$arg"
    return
  fi

  [[ -f "$arg" ]] || die "toolchain path does not exist: $arg"
  mkdir -p "$extract_dir"
  tar -xzf "$arg" -C "$extract_dir"

  local root
  root="$(find "$extract_dir" -mindepth 1 -maxdepth 2 -type f -path '*/bin/cargo' -printf '%h\n' | sed 's#/bin$##' | head -n 1)"
  [[ -n "$root" ]] || die "could not find extracted toolchain root under $extract_dir"
  printf '%s\n' "$root"
}

resolve_rust_src_dir() {
  local arg="$1"
  local extract_dir="$2"
  if [[ -d "$arg" ]]; then
    arg="$(realpath_safe "$arg")"
    if [[ -d "$arg/library" ]]; then
      printf '%s\n' "$arg/library"
      return
    fi
    if [[ "$(basename "$arg")" == "library" ]]; then
      printf '%s\n' "$arg"
      return
    fi
    die "rust-src directory must contain library/ or be the library directory: $arg"
  fi

  [[ -f "$arg" ]] || die "rust-src path does not exist: $arg"
  mkdir -p "$extract_dir"
  tar -xzf "$arg" -C "$extract_dir"

  if [[ -d "$extract_dir/library" ]]; then
    printf '%s\n' "$extract_dir/library"
    return
  fi

  local library_dir
  library_dir="$(find "$extract_dir" -type d -name library | head -n 1)"
  [[ -n "$library_dir" ]] || die "could not find extracted rust-src library directory under $extract_dir"
  printf '%s\n' "$library_dir"
}

sha=""
host_toolchain=""
rust_src=""
out_dir=""
cargo_home=""
offline=0
declare -a targets=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)
      sha="${2:-}"
      shift 2
      ;;
    --host-toolchain)
      host_toolchain="${2:-}"
      shift 2
      ;;
    --rust-src)
      rust_src="${2:-}"
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
    --target)
      targets+=("${2:-}")
      shift 2
      ;;
    --offline)
      offline=1
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

[[ -n "$sha" ]] || die "--sha is required"

if [[ -z "$host_toolchain" ]]; then
  host_toolchain="out/ferrocene-ubuntu24-prof/ferrocene-${sha}-x86_64-unknown-linux-gnu.tar.gz"
fi
if [[ -z "$rust_src" ]]; then
  rust_src="out/ferrocene/rust-src-${sha}.tar.gz"
fi
if [[ -z "$out_dir" ]]; then
  out_dir="out/ferrocene-ubuntu24-prof/miri-sysroots"
fi
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(
    x86_64-unknown-linux-gnu
    aarch64-unknown-linux-gnu
    x86_64-pc-nto-qnx800
    aarch64-unknown-nto-qnx800
  )
fi

mkdir -p "$out_dir"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/miri-sysroots.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

toolchain_root="$(resolve_toolchain_root "$host_toolchain" "$tmp_root/toolchain")"
rust_src_dir="$(resolve_rust_src_dir "$rust_src" "$tmp_root/rust-src")"

orig_home="${HOME:-$PWD}"
if [[ -z "$cargo_home" ]]; then
  cargo_home="${CARGO_HOME:-$orig_home/.cargo}"
fi
common_target_dir="$tmp_root/cargo-target"
mkdir -p "$cargo_home" "$common_target_dir"

export PATH="$toolchain_root/bin:/bin:/usr/bin:/usr/local/bin"
export LD_LIBRARY_PATH="$toolchain_root/lib:$toolchain_root/lib/rustlib/x86_64-unknown-linux-gnu/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CARGO="$toolchain_root/bin/cargo"
export RUSTC="$toolchain_root/bin/rustc"
export MIRI="$toolchain_root/bin/miri"
export MIRI_HOST_SYSROOT="$toolchain_root"
export MIRI_LIB_SRC="$rust_src_dir"
export HOME="$orig_home"
export CARGO_HOME="$(realpath_safe "$cargo_home")"
export CARGO_TARGET_DIR="$common_target_dir"
if [[ "$offline" -eq 1 ]]; then
  export CARGO_NET_OFFLINE=true
fi

for target in "${targets[@]}"; do
  sysroot_dir="$(realpath_safe "$out_dir")/$target"
  rm -rf "$sysroot_dir"
  mkdir -p "$sysroot_dir"

  echo "==> building Miri sysroot for $target"
  export MIRI_SYSROOT="$sysroot_dir"
  "$toolchain_root/bin/cargo-miri" miri setup --target "$target"

  cat > "$sysroot_dir/BUILD-INFO.txt" <<INFO
sha=$sha
host_toolchain=$toolchain_root
target=$target
rust_src=$rust_src_dir
INFO

done

echo
for target in "${targets[@]}"; do
  echo "Built: $(realpath_safe "$out_dir")/$target"
done

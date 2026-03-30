#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/package_miri_sysroots.sh \
    --sha <commit> \
    [--sysroots-dir /path/to/miri-sysroots] \
    [--out-dir /path/to/output] \
    [--target <triple>]...

Packages successful prebuilt Miri sysroots into one tar.gz per target and
emits matching .sha256 files.

Defaults:
  --sysroots-dir out/ferrocene-ubuntu24-prof/miri-sysroots
  --out-dir      out/ferrocene-ubuntu24-prof
  --target       all targets in --sysroots-dir that contain BUILD-INFO.txt

Archive names:
  miri-sysroot-<sha>-<target>.tar.gz
  miri-sysroot-<sha>-<target>.tar.gz.sha256
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

sha=""
sysroots_dir=""
out_dir=""
declare -a targets=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)
      sha="${2:-}"
      shift 2
      ;;
    --sysroots-dir)
      sysroots_dir="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    --target)
      targets+=("${2:-}")
      shift 2
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

if [[ -z "$sysroots_dir" ]]; then
  sysroots_dir="out/ferrocene-ubuntu24-prof/miri-sysroots"
fi
if [[ -z "$out_dir" ]]; then
  out_dir="out/ferrocene-ubuntu24-prof"
fi

[[ -d "$sysroots_dir" ]] || die "sysroots dir does not exist: $sysroots_dir"
mkdir -p "$out_dir"

if [[ ${#targets[@]} -eq 0 ]]; then
  while IFS= read -r path; do
    targets+=("$(basename "$(dirname "$path")")")
  done < <(find "$sysroots_dir" -mindepth 2 -maxdepth 2 -type f -name BUILD-INFO.txt | sort)
fi

[[ ${#targets[@]} -gt 0 ]] || die "no successful sysroots found under $sysroots_dir"

for target in "${targets[@]}"; do
  sysroot_path="$sysroots_dir/$target"
  [[ -f "$sysroot_path/BUILD-INFO.txt" ]] || die "missing BUILD-INFO.txt for target $target at $sysroot_path"

  archive_path="$out_dir/miri-sysroot-${sha}-${target}.tar.gz"
  sha_path="${archive_path}.sha256"

  tar -C "$sysroots_dir" -czf "$archive_path" "$target"
  sha256sum "$archive_path" > "$sha_path"

  echo "Built: $archive_path"
  echo "SHA256: $sha_path"
done

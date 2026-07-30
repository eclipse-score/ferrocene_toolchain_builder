#!/usr/bin/env bash

prepare_ferrocene_checkout() {
  local repo_url="$1"
  local src_dir="$2"
  local ferrocene_sha="$3"
  local git_depth="$4"

  mkdir -p "${src_dir}"

  if [[ ! -d "${src_dir}/.git" ]]; then
    if [[ "${git_depth}" -gt 0 ]]; then
      git clone --no-checkout --depth "${git_depth}" "${repo_url}" "${src_dir}"
    else
      git clone "${repo_url}" "${src_dir}"
    fi
  else
    git -C "${src_dir}" remote set-url origin "${repo_url}"
  fi

  if git -C "${src_dir}" rev-parse --verify "${ferrocene_sha}^{commit}" >/dev/null 2>&1; then
    echo "Found ${ferrocene_sha} locally; skipping fetch."
  else
    if [[ "${git_depth}" -gt 0 ]]; then
      git -C "${src_dir}" fetch --depth "${git_depth}" origin "${ferrocene_sha}"
    else
      git -C "${src_dir}" fetch --all
    fi
  fi

  git -C "${src_dir}" checkout --detach "${ferrocene_sha}"
  apply_local_ferrocene_patches "${src_dir}"
}

apply_local_ferrocene_patches() {
  local src_dir="$1"
  local script_dir
  local patch_dir
  local patch_path

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  patch_dir="${script_dir}/../patches"

  if [[ ! -d "${patch_dir}" ]]; then
    return 0
  fi

  shopt -s nullglob
  for patch_path in "${patch_dir}"/*.patch; do
    if git -C "${src_dir}" apply --reverse --check "${patch_path}" >/dev/null 2>&1; then
      echo "Patch already applied in ${src_dir}: $(basename "${patch_path}")"
      continue
    fi

    git -C "${src_dir}" apply --check "${patch_path}"
    git -C "${src_dir}" apply "${patch_path}"
    echo "Applied patch in ${src_dir}: $(basename "${patch_path}")"
  done
  shopt -u nullglob
}

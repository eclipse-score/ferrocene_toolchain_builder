#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/run_direct_miri_test.sh \
    --workspace /path/to/cargo-workspace \
    --package rust_kvs \
    --toolchain /path/to/ferrocene-toolchain.tar.gz \
    --rust-src /path/to/rust-src.tar.gz \
    [--target x86_64-unknown-linux-gnu] \
    [--cargo-test-arg ARG]... \
    [--miri-flag FLAG]... \
    [--harness-arg ARG]... \
    [--patch-crate URL crate_name=/path/to/crate]...

This script does three things:
  1. creates a Miri sysroot from the packaged Ferrocene toolchain
  2. rebuilds the target-side dependency closure against that sysroot
  3. runs the crate's test harness via the direct `miri` driver

Notes:
  - Host build scripts and proc-macros stay on the normal toolchain sysroot.
  - Target-side crates are rebuilt against the Miri sysroot with
    `-Zalways-encode-mir`.
  - `--cargo-test-arg --lib` is usually the right choice for a library crate.
  - By default the final Miri run uses:
      - `-Zmiri-disable-isolation`
      - `--test-threads=1`
  - `--patch-crate` appends a Cargo `[patch."URL"]` section to the copied
    workspace root. Repeat it for multiple crates from the same git repo.

Examples:
  scripts/run_direct_miri_test.sh \
    --workspace /home/dcalavrezo/sources/persistency \
    --package rust_kvs \
    --toolchain /home/dcalavrezo/sources/ferrocene_builder/out/ferrocene-ubuntu24-prof/ferrocene-779fbed05ae9e9fe2a04137929d99cc9b3d516fd-x86_64-unknown-linux-gnu.tar.gz \
    --rust-src /home/dcalavrezo/sources/ferrocene_builder/out/ferrocene/rust-src-779fbed05ae9e9fe2a04137929d99cc9b3d516fd.tar.gz \
    --cargo-test-arg --lib \
    --patch-crate https://github.com/eclipse-score/baselibs_rust.git score_log=/home/dcalavrezo/sources/baselibs_rust/src/log/score_log \
    --patch-crate https://github.com/eclipse-score/baselibs_rust.git stdout_logger=/home/dcalavrezo/sources/baselibs_rust/src/log/stdout_logger \
    --harness-arg --exact \
    --harness-arg kvs_value::kvs_value_tests::test_i32_from_ok
EOF
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

workspace=""
package=""
toolchain_arg=""
rust_src_arg=""
target="x86_64-unknown-linux-gnu"
declare -a cargo_test_args=()
declare -a miri_flags=("-Zmiri-disable-isolation")
declare -a harness_args=("--test-threads=1")
declare -a patch_specs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --package)
      package="${2:-}"
      shift 2
      ;;
    --toolchain)
      toolchain_arg="${2:-}"
      shift 2
      ;;
    --rust-src)
      rust_src_arg="${2:-}"
      shift 2
      ;;
    --target)
      target="${2:-}"
      shift 2
      ;;
    --cargo-test-arg)
      cargo_test_args+=("${2:-}")
      shift 2
      ;;
    --miri-flag)
      miri_flags+=("${2:-}")
      shift 2
      ;;
    --harness-arg)
      harness_args+=("${2:-}")
      shift 2
      ;;
    --patch-crate)
      patch_specs+=("${2:-}|${3:-}")
      shift 3
      ;;
    --no-default-miri-flags)
      miri_flags=()
      shift
      ;;
    --no-default-harness-args)
      harness_args=()
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        harness_args+=("$1")
        shift
      done
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$workspace" ]] || die "--workspace is required"
[[ -n "$package" ]] || die "--package is required"
[[ -n "$toolchain_arg" ]] || die "--toolchain is required"
[[ -n "$rust_src_arg" ]] || die "--rust-src is required"

workspace="$(realpath_safe "$workspace")"
[[ -d "$workspace" ]] || die "workspace does not exist: $workspace"
[[ -f "$workspace/Cargo.toml" ]] || die "workspace root is missing Cargo.toml: $workspace"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/direct-miri.XXXXXX")"
toolchain_root=""
rust_src_dir=""

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

toolchain_root="$(resolve_toolchain_root "$toolchain_arg" "$tmp_root/toolchain")"
rust_src_dir="$(resolve_rust_src_dir "$rust_src_arg" "$tmp_root/rust-src")"

workspace_copy="$tmp_root/workspace"
rsync -a --delete --exclude .git --exclude target "$workspace/" "$workspace_copy/"

if [[ ${#patch_specs[@]} -gt 0 ]]; then
  python3 - "$workspace_copy/Cargo.toml" "${patch_specs[@]}" <<'PY'
import os
import sys

manifest = sys.argv[1]
entries = sys.argv[2:]
by_url = {}

for entry in entries:
    url, spec = entry.split("|", 1)
    crate, path = spec.split("=", 1)
    by_url.setdefault(url, []).append((crate, os.path.realpath(path)))

with open(manifest, "a", encoding="utf-8") as fh:
    for url, items in by_url.items():
        fh.write(f'\n[patch."{url}"]\n')
        for crate, path in items:
            fh.write(f'{crate} = {{ path = "{path}" }}\n')
PY
fi

sysroot_home="$tmp_root/sysroot-home"
sysroot_cargo_home="$tmp_root/sysroot-cargo-home"
sysroot_target_dir="$tmp_root/sysroot-target"
miri_sysroot="$tmp_root/miri-sysroot"
mkdir -p "$sysroot_home" "$sysroot_cargo_home" "$sysroot_target_dir"

export PATH="$toolchain_root/bin:/bin:/usr/bin:/usr/local/bin"
export LD_LIBRARY_PATH="$toolchain_root/lib:$toolchain_root/lib/rustlib/$target/lib"
export CARGO="$toolchain_root/bin/cargo"
export MIRI="$toolchain_root/bin/miri"
export MIRI_HOST_SYSROOT="$toolchain_root"
export MIRI_LIB_SRC="$rust_src_dir"
export HOME="$sysroot_home"
export CARGO_HOME="$sysroot_cargo_home"
export CARGO_TARGET_DIR="$sysroot_target_dir"
export MIRI_SYSROOT="$miri_sysroot"

"$toolchain_root/bin/cargo" miri setup -v >/dev/null

wrapper="$tmp_root/selective-sysroot-rustc.sh"
cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

real_rustc="$1"
shift

out_dir=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--out-dir" ]]; then
    out_dir="$arg"
    break
  fi
  case "$arg" in
    --out-dir=*)
      out_dir="${arg#--out-dir=}"
      break
      ;;
  esac
  prev="$arg"
done

if [[ -n "${SELECTIVE_MIRI_TARGET_DIR:-}" && -n "$out_dir" && "$out_dir" == "${SELECTIVE_MIRI_TARGET_DIR}"/* ]]; then
  exec "$real_rustc" "$@" "--sysroot=${SELECTIVE_MIRI_SYSROOT:?}" -Zalways-encode-mir
else
  exec "$real_rustc" "$@"
fi
EOF
chmod +x "$wrapper"

build_home="$tmp_root/build-home"
build_target_dir="$tmp_root/build-target"
build_log="$tmp_root/build.log"
mkdir -p "$build_home" "$build_target_dir"

export HOME="/home/dcalavrezo"
export CARGO_HOME="/home/dcalavrezo/.cargo"
export CARGO_TARGET_DIR="$build_target_dir"
export RUSTC="$toolchain_root/bin/rustc"
export RUSTC_WRAPPER="$wrapper"
export SELECTIVE_MIRI_TARGET_DIR="$build_target_dir/$target"
export SELECTIVE_MIRI_SYSROOT="$miri_sysroot"

set +e
"$toolchain_root/bin/cargo" test \
  --manifest-path "$workspace_copy/Cargo.toml" \
  -p "$package" \
  --no-run \
  --target "$target" \
  -vv \
  "${cargo_test_args[@]}" \
  >"$build_log" 2>&1
cargo_status=$?
set -e

export HOME="$build_home"
mkdir -p "$HOME"

command_json="$(python3 - "$build_log" "$package" "$target" <<'PY'
import json
import shlex
import sys

log_path, package, target = sys.argv[1:]
matches = []

with open(log_path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if " Running `" not in line and not line.lstrip().startswith("Running `"):
            continue
        start = line.find("`")
        end = line.rfind("`")
        if start == -1 or end <= start:
            continue
        cmd = line[start + 1:end]
        if f"CARGO_CRATE_NAME={package}" not in cmd:
            continue
        if " --test " not in cmd:
            continue
        if f" --target {target}" not in cmd and f"--target={target}" not in cmd:
            continue
        matches.append(cmd)

if not matches:
    raise SystemExit(1)

tokens = shlex.split(matches[-1])
wrapper_idx = None
for i, token in enumerate(tokens):
    if token.endswith("selective-sysroot-rustc.sh"):
        wrapper_idx = i
        break

if wrapper_idx is None or wrapper_idx + 1 >= len(tokens):
    raise SystemExit(2)

env = {}
for token in tokens[:wrapper_idx]:
    if "=" not in token:
        continue
    key, value = token.split("=", 1)
    env[key] = value

rustc_args = tokens[wrapper_idx + 2:]

kept = []
i = 0
while i < len(rustc_args):
    arg = rustc_args[i]
    if arg in {"--out-dir", "--emit", "-o"}:
      i += 2
      continue
    if arg in {"--error-format"}:
      i += 2
      continue
    if arg.startswith("--out-dir=") or arg.startswith("--emit=") or arg.startswith("--error-format="):
      i += 1
      continue
    if arg == "--json" or arg.startswith("--json="):
      i += 2 if arg == "--json" else 1
      continue
    if arg == "-C" and i + 1 < len(rustc_args):
      value = rustc_args[i + 1]
      if value.startswith("incremental=") or value.startswith("metadata=") or value.startswith("extra-filename="):
        i += 2
        continue
    if arg.startswith("-Cincremental=") or arg.startswith("-Cmetadata=") or arg.startswith("-Cextra-filename="):
      i += 1
      continue
    if arg == "--sysroot" or arg.startswith("--sysroot="):
      i += 2 if arg == "--sysroot" else 1
      continue
    kept.append(arg)
    i += 1

print(json.dumps({"env": env, "args": kept}))
PY
)" || die "failed to find the final rustc --test invocation in $build_log"

final_command="$tmp_root/direct-miri-command.sh"
python3 - "$command_json" "$toolchain_root" "$miri_sysroot" "$build_target_dir" "$workspace_copy" \
  "$(printf '%s\n' "${miri_flags[@]}")" \
  "$(printf '%s\n' "${harness_args[@]}")" \
  "$final_command" <<'PY'
import json
import os
import sys

payload = json.loads(sys.argv[1])
toolchain_root = sys.argv[2]
miri_sysroot = sys.argv[3]
build_target_dir = sys.argv[4]
workspace_copy = sys.argv[5]
miri_flags = [item for item in sys.argv[6].splitlines() if item]
harness_args = [item for item in sys.argv[7].splitlines() if item]
output_path = sys.argv[8]

env = payload["env"]
args = payload["args"]

env_keys = [
    "CARGO_CRATE_NAME",
    "CARGO_MANIFEST_DIR",
    "CARGO_MANIFEST_PATH",
    "CARGO_PKG_AUTHORS",
    "CARGO_PKG_DESCRIPTION",
    "CARGO_PKG_HOMEPAGE",
    "CARGO_PKG_LICENSE",
    "CARGO_PKG_LICENSE_FILE",
    "CARGO_PKG_NAME",
    "CARGO_PKG_README",
    "CARGO_PKG_REPOSITORY",
    "CARGO_PKG_RUST_VERSION",
    "CARGO_PKG_VERSION",
    "CARGO_PKG_VERSION_MAJOR",
    "CARGO_PKG_VERSION_MINOR",
    "CARGO_PKG_VERSION_PATCH",
    "CARGO_PKG_VERSION_PRE",
    "CARGO_PRIMARY_PACKAGE",
    "CARGO_SBOM_PATH",
    "REPOSITORY_NAME",
]

with open(output_path, "w", encoding="utf-8") as fh:
    fh.write("#!/usr/bin/env bash\n")
    fh.write("set -euo pipefail\n")
    fh.write("cd " + json.dumps(workspace_copy) + "\n")
    fh.write("export PATH=" + json.dumps(f"{toolchain_root}/bin:/bin:/usr/bin:/usr/local/bin") + "\n")
    fh.write("export LD_LIBRARY_PATH=" + json.dumps(f"{toolchain_root}/lib:{toolchain_root}/lib/rustlib/x86_64-unknown-linux-gnu/lib") + "\n")
    for key in env_keys:
        if key in env:
            fh.write(f"export {key}=" + json.dumps(env[key]) + "\n")
    fh.write("exec " + json.dumps(f"{toolchain_root}/bin/miri"))
    for flag in miri_flags:
        fh.write(" " + json.dumps(flag))
    for arg in args:
        fh.write(" " + json.dumps(arg))
    fh.write(" " + json.dumps(f"--sysroot={miri_sysroot}"))
    if harness_args:
        fh.write(" --")
        for arg in harness_args:
            fh.write(" " + json.dumps(arg))
    fh.write("\n")

os.chmod(output_path, 0o755)
PY

echo "Prepared temp workspace under: $workspace_copy"
echo "Prepared Miri sysroot under:   $miri_sysroot"
echo "Build log written to:          $build_log"
echo "Reusable direct Miri command:  $final_command"

if [[ $cargo_status -ne 0 ]]; then
  echo "NOTE: cargo test --no-run exited with $cargo_status; this is expected when the top-level test harness links against the Miri sysroot." >&2
fi

"$final_command"

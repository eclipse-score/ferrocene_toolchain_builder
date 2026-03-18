# score_ferrocene_builder

This repository builds the [ferrocene](https://github.com/ferrocene/ferrocene) compiler from a specific commit and packages the resulting install tree as a tarball (suitable for use as a pinned toolchain archive in other build systems).

## Prerequisites
- `git`, `python3`, and [`uv`](https://github.com/astral-sh/uv) on `PATH` (Ferrocene bootstrap requires it).
- A toolchain capable of building Ferrocene/Rust (LLVM + common C/C++ build deps).
- Network access to `https://github.com/ferrocene/ferrocene.git` (or a mirror you provide).
- If building QNX targets: a working QNX SDP + license and `source /path/to/qnxsdp-env.sh`.
- If building `aarch64-unknown-linux-gnu`: `aarch64-linux-gnu-gcc` (Debian/Ubuntu: `gcc-aarch64-linux-gnu g++-aarch64-linux-gnu`).

## Build and Package Ferrocene
```bash
./scripts/build_ferrocene.sh --sha <commit> \
  --target x86_64-unknown-linux-gnu \
  --exec x86_64-unknown-linux-gnu
```

Outputs are written to `out/ferrocene/ferrocene-<sha>-<target>.tar.gz` with a matching `.sha256` file. Host/exec and target triples can be customized, as can the repo URL via environment or flags (see `--help`).

The script auto-generates `<src>/bootstrap.toml` (override with `--bootstrap` or `FERROCENE_BOOTSTRAP_TOML`) with:
- `change-id = "ignore"`
- `profile = "dist"`
- `[llvm] download-ci-llvm = false`
- `[gcc] download-ci-gcc = false`
- `[rust] download-rustc = false`

This avoids Ferrocene’s CI S3 downloads (which require AWS credentials/CLI). If you prefer CI artifacts, remove or adjust those settings and ensure `aws` is available and configured.

By default the core toolchain packages plus `miri` are built/installed (dist: `rustc rust-std cargo rustfmt clippy miri`; install: `rustc library/std cargo rustfmt clippy miri`) to skip doc builds that can fail on missing mdbook preprocessors or path issues. Override with `--dist-packages "<space-separated list>"` / `FERROCENE_DIST_PACKAGES` and `--install-packages "<space-separated list>"` / `FERROCENE_INSTALL_PACKAGES`.

Git checkout uses a shallow clone by default (`--git-depth 1` / `FERROCENE_GIT_DEPTH=1`). Set `--full` or `--git-depth 0` if you need full history.

Install step note: the script sets `DESTDIR=out/ferrocene/install` when running `x.py install` so no privileged paths are touched; the installed tree under that DESTDIR is what gets tarred.

## Build environment and coverage
- Toolchains are rebuilt on Ferrocene’s Ubuntu 20.04 CI image (baseline glibc); see `ferrocene/ci/docker-images/ubuntu-20/Dockerfile` in the upstream Ferrocene repo.
- Profiling is enabled via `config.profiler.toml` to include `libprofiler_builtins` in the sysroot.
- QNX targets are currently built without profiling due to compiler-rt profiler runtime issues; use `config.toml` for QNX until that is fixed.
- Coverage helpers (`symbol-report`, `blanket`) are built via `scripts/build_coverage_tools.sh`; a runnable demo is in `examples/coverage-demo/`.
- Note: `blanket` is a bootstrap tool and is only built in stage1; when using `--stage 2` to match `symbol-report` with the stage2 toolchain, the script will fall back to the stage1 `blanket`.

### Build commands (per-target archives)
Build Linux + Ferrocene subset targets with profiling enabled (produces one tarball per target under `out/ferrocene-ubuntu20-prof/`):
```bash
docker run --rm -it \
  -e SHA="779fbed05ae9e9fe2a04137929d99cc9b3d516fd" \
  -v "/home/dcalavrezo/sources/ferrocene_builder:/work" -w /work \
  ferrocene-ubuntu20 bash -lc '
    set -euo pipefail
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends pkg-config

    export FERROCENE_BOOTSTRAP_TOML=./config.profiler.toml
    export FERROCENE_SRC_DIR=/work/.cache/ferrocene-src-ubuntu20-prof
    export FERROCENE_OUT_DIR=/work/out/ferrocene-ubuntu20-prof

    for target in \
      aarch64-unknown-linux-gnu \
      x86_64-unknown-linux-gnu \
      aarch64-unknown-ferrocene.subset \
      x86_64-unknown-ferrocene.subset
    do
      ./scripts/build_ferrocene.sh --sha "$SHA" --target "$target" --exec x86_64-unknown-linux-gnu
    done

    # Host tools only need to be built once
    ./scripts/build_coverage_tools.sh --sha "$SHA" --host x86_64-unknown-linux-gnu --build-dir /work/.cache/ferrocene-src-ubuntu20-prof/build
  '
```

That will emit four separate archives under `out/ferrocene-ubuntu20-prof/`, each named `ferrocene-<sha>-<target>.tar.gz`.

### Ubuntu 24 variant
Ferrocene also ships `ferrocene/ci/docker-images/ubuntu-24/Dockerfile`. Unlike the Ubuntu 20 image, the upstream Ubuntu 24 image does not install the AArch64 GNU cross toolchain, so Linux + subset builds that include `aarch64-*` targets need a few extra packages in the container.

Build the local image from the cached Ferrocene checkout:
```bash
docker build --tag ferrocene-ubuntu24 \
  --file .cache/ferrocene-src-ubuntu20-prof/ferrocene/ci/docker-images/ubuntu-24/Dockerfile \
  .cache/ferrocene-src-ubuntu20-prof
```

Then run the Linux + Ferrocene subset build with a separate Ubuntu 24 cache/output tree:
```bash
docker run --rm -it \
  -e SHA="779fbed05ae9e9fe2a04137929d99cc9b3d516fd" \
  -v "/home/dcalavrezo/sources/ferrocene_builder:/work" -w /work \
  ferrocene-ubuntu24 bash -lc '
    set -euo pipefail
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      pkg-config \
      gcc-aarch64-linux-gnu \
      g++-aarch64-linux-gnu \
      binutils-aarch64-linux-gnu \
      libc6-dev-arm64-cross

    export FERROCENE_BOOTSTRAP_TOML=./config.profiler.toml
    export FERROCENE_SRC_DIR=/work/.cache/ferrocene-src-ubuntu24-prof
    export FERROCENE_OUT_DIR=/work/out/ferrocene-ubuntu24-prof

    for target in \
      aarch64-unknown-linux-gnu \
      x86_64-unknown-linux-gnu \
      aarch64-unknown-ferrocene.subset \
      x86_64-unknown-ferrocene.subset
    do
      ./scripts/build_ferrocene.sh --sha "$SHA" --target "$target" --exec x86_64-unknown-linux-gnu
    done
  '
```

If you only need x86_64 outputs, drop the `aarch64-*` targets and the extra AArch64 cross packages. Coverage tools and `rust-src` can be rebuilt the same way as above, just switching to `ferrocene-ubuntu24` and the `ubuntu24` cache/output directories. For QNX, reuse the QNX recipe below with `ferrocene-ubuntu24`, `FERROCENE_SRC_DIR=/work/.cache/ferrocene-src-ubuntu24-qnx`, `FERROCENE_OUT_DIR=/work/out/ferrocene-ubuntu24-qnx`, and `pkg-config`; the Ubuntu 24 image already includes `libssl-dev`.

If you want `symbol-report` to match the stage2 toolchain, build the coverage tools at stage2 (the script will reuse the stage1 `blanket`):
```bash
docker run --rm -it \
  -e SHA="779fbed05ae9e9fe2a04137929d99cc9b3d516fd" \
  -v "/home/dcalavrezo/sources/ferrocene_builder:/work" -w /work \
  ferrocene-ubuntu20 bash -lc '
    set -euo pipefail
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends pkg-config

    export FERROCENE_BOOTSTRAP_TOML=./config.profiler.toml
    export FERROCENE_SRC_DIR=/work/.cache/ferrocene-src-ubuntu20-prof
    export FERROCENE_OUT_DIR=/work/out/ferrocene-ubuntu20-prof

    for target in \
      aarch64-unknown-linux-gnu \
      x86_64-unknown-linux-gnu \
      aarch64-unknown-ferrocene.subset \
      x86_64-unknown-ferrocene.subset
    do
      ./scripts/build_ferrocene.sh --sha "$SHA" --target "$target" --exec x86_64-unknown-linux-gnu
    done

    # Host tools only need to be built once
    ./scripts/build_coverage_tools.sh --sha "$SHA" --host x86_64-unknown-linux-gnu \
      --build-dir /work/.cache/ferrocene-src-ubuntu20-prof/build --stage 2
  '
```

Build QNX targets without profiling (per-target archives under `out/ferrocene-ubuntu20-qnx/`):
```bash
mkdir -p .qnx-config
export QNX_SDP="$HOME/qnx800"
export QNX_LICENSE="$HOME/.qnx/license/licenses"

docker run --rm -it \
  -e SHA="779fbed05ae9e9fe2a04137929d99cc9b3d516fd" \
  -v "$PWD:/work" -w /work \
  -v "$QNX_SDP:/opt/qnx:ro" \
  -v "$QNX_LICENSE:/opt/qnx-license/licenses:ro" \
  -v "$PWD/.qnx-config:/qnx-config" \
  ferrocene-ubuntu20 bash -lc '
    set -euo pipefail
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends pkg-config libssl-dev

    export QNX_HOST=/opt/qnx/host/linux/x86_64
    export QNX_TARGET=/opt/qnx/target/qnx
    export QNX_CONFIGURATION_EXCLUSIVE=/qnx-config
    export QNX_SHARED_LICENSE_FILE=/opt/qnx-license/licenses
    export PATH="$QNX_HOST/usr/bin:$PATH"

    export FERROCENE_BOOTSTRAP_TOML=./config.toml
    export FERROCENE_SRC_DIR=/work/.cache/ferrocene-src-ubuntu20-qnx
    export FERROCENE_OUT_DIR=/work/out/ferrocene-ubuntu20-qnx

    for target in aarch64-unknown-nto-qnx800 x86_64-pc-nto-qnx800; do
      ./scripts/build_ferrocene.sh --sha "$SHA" --target "$target" --exec x86_64-unknown-linux-gnu
    done
  '
```

When you’re ready to build QNX without profiling (same image), do the same pattern but with QNX env and `config.toml`:
```bash
mkdir -p .qnx-config
export QNX_SDP="$HOME/qnx800"
export QNX_LICENSE="$HOME/.qnx/license/licenses"

docker run --rm -it \
  -e SHA="779fbed05ae9e9fe2a04137929d99cc9b3d516fd" \
  -v "$PWD:/work" -w /work \
  -v "$QNX_SDP:/opt/qnx:ro" \
  -v "$QNX_LICENSE:/opt/qnx-license/licenses:ro" \
  -v "$PWD/.qnx-config:/qnx-config" \
  ferrocene-ubuntu20 bash -lc '
    set -euo pipefail
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends pkg-config libssl-dev

    export QNX_HOST=/opt/qnx/host/linux/x86_64
    export QNX_TARGET=/opt/qnx/target/qnx
    export QNX_CONFIGURATION_EXCLUSIVE=/qnx-config
    export QNX_SHARED_LICENSE_FILE=/opt/qnx-license/licenses
    export PATH="$QNX_HOST/usr/bin:$PATH"

    export FERROCENE_BOOTSTRAP_TOML=./config.toml
    export FERROCENE_SRC_DIR=/work/.cache/ferrocene-src-ubuntu20-qnx
    export FERROCENE_OUT_DIR=/work/out/ferrocene-ubuntu20-qnx

    for target in aarch64-unknown-nto-qnx800 x86_64-pc-nto-qnx800; do
      ./scripts/build_ferrocene.sh --sha "$SHA" --target "$target" --exec x86_64-unknown-linux-gnu
    done
  '
```

### Standalone `rust-src` for Miri / Bazel
`miri` and `cargo-miri` are packaged into the host toolchain archives, but `cargo miri setup` also needs the Rust library sources. Those sources are target-independent, so publish them once as a separate asset instead of copying them into every target archive.

To build a standalone `rust-src-<sha>.tar.gz` while reusing the existing Linux profiling checkout cache:
```bash
FERROCENE_SRC_DIR=./.cache/ferrocene-src-ubuntu20-prof \
FERROCENE_OUT_DIR=./out/ferrocene \
  ./scripts/build_rust_src.sh --sha 779fbed05ae9e9fe2a04137929d99cc9b3d516fd
```

That emits:
- `out/ferrocene/rust-src-<sha>.tar.gz`
- `out/ferrocene/rust-src-<sha>.tar.gz.sha256`

The archive unpacks to a source tree root containing:
- `library/`
- `src/llvm-project/libunwind/`
- `ferrocene/library/libc/`
- `ferrocene/library/backtrace-rs/`

For Bazel, consume the host toolchain archive and the standalone `rust-src` archive together. In the Miri action:
- expose both archives as inputs
- set `MIRI_LIB_SRC` to the extracted `rust-src` `library` directory
- set `MIRI_SYSROOT` to a writable scratch directory

Example environment for a Bazel action:
```bash
export PATH="${TOOLCHAIN_ROOT}/bin:$PATH"
export LD_LIBRARY_PATH="${TOOLCHAIN_ROOT}/lib"
export MIRI_LIB_SRC="${RUST_SRC_ROOT}/library"
export MIRI_SYSROOT="${TMPDIR}/miri-sysroot"

cargo miri setup --target x86_64-unknown-linux-gnu
cargo miri test --target x86_64-unknown-linux-gnu
```

`cargo-miri` validates that `MIRI_LIB_SRC` ends in `library`, so point it at the extracted `library/` directory, not the archive root.

## Multi-target (Linux + QNX) build
When passing a comma-separated target list, the script builds a single install tree containing the host tools and all requested target stdlibs, then emits one archive:
- `out/ferrocene/ferrocene-<sha>-<exec>-multi-<hash>.tar.gz`
- `out/ferrocene/ferrocene-<sha>-<exec>-multi-<hash>.targets.txt` (records the exact target list)

For QNX targets, make sure your environment is set up first:
```bash
source /path/to/qnxsdp-env.sh
```

Then run the build with `config.toml` (generic bootstrap settings). `scripts/build_ferrocene.sh` will
auto-configure QNX builds by exporting per-target `CC_*`, `CFLAGS_*` (the `-V...` selector), and `AR_*`
so `qcc` is invoked in the correct architecture mode:
```bash
SHA=779fbed05ae9e9fe2a04137929d99cc9b3d516fd
TARGETS="x86_64-unknown-linux-gnu,aarch64-unknown-linux-gnu,x86_64-pc-nto-qnx800,aarch64-unknown-nto-qnx800,x86_64-unknown-ferrocene.subset"

## Multi-target (Linux + QNX) build
When passing a comma-separated target list, the script builds a single install tree containing the host tools and all requested target stdlibs, then emits one archive:
- `out/ferrocene/ferrocene-<sha>-<exec>-multi-<hash>.tar.gz`
- `out/ferrocene/ferrocene-<sha>-<exec>-multi-<hash>.targets.txt` (records the exact target list)

For QNX targets, make sure your environment is set up first:
```bash
source /path/to/qnxsdp-env.sh
```

Then run the build with `config.toml` (generic bootstrap settings). `scripts/build_ferrocene.sh` will
auto-configure QNX builds by exporting per-target `CC_*`, `CFLAGS_*` (the `-V...` selector), and `AR_*`
so `qcc` is invoked in the correct architecture mode:
```bash
SHA=779fbed05ae9e9fe2a04137929d99cc9b3d516fd
TARGETS="x86_64-unknown-linux-gnu,aarch64-unknown-linux-gnu,x86_64-pc-nto-qnx800,aarch64-unknown-nto-qnx800,x86_64-unknown-ferrocene.subset"

FERROCENE_BOOTSTRAP_TOML=./config.toml \
  ./scripts/build_ferrocene.sh \
    --sha "$SHA" \
    --target "$TARGETS" \
    --exec x86_64-unknown-linux-gnu \
    --jobs "$(nproc)"
```

## QNX SDP Download Without Bazel
If you need QNX in CI without Bazel:
- Option A: use the Python downloader (handles cookies/redirects):
  ```bash
  ./scripts/fetch_qnx_sdp.py https://www.qnx.com/download/download/79858/installation.tgz /tmp/installation.tgz
  tar -C /opt -xzf /tmp/installation.tgz  # adjust path
  ```
- Option B: get the cookie headers and use curl (if redirects loop, prefer Option A):
  ```bash
  python3 scripts/qnx_credentials_helper.py <<<'{"uri":"https://www.qnx.com/download/download/79858/installation.tgz"}' > /tmp/qnx-headers.json
  curl -L --fail -o /tmp/installation.tgz \
    -H "Cookie: $(jq -r '.headers.Cookie[0]' /tmp/qnx-headers.json)" \
    https://www.qnx.com/download/download/79858/installation.tgz
  tar -C /opt -xzf /tmp/installation.tgz  # adjust path
  ```
- Set the license and env:
  ```bash
  mkdir -p /opt/score_qnx/license
  echo "$SCORE_QNX_LICENSE" | base64 --decode > /opt/score_qnx/license/licenses
  export QNX_HOST=/opt/installation/host/linux/x86_64
  export QNX_TARGET=/opt/installation/target/qnx
  export QNX_CONFIGURATION_EXCLUSIVE=/var/tmp/.qnx
  export QNX_SHARED_LICENSE_FILE=/opt/score_qnx/license/licenses
  export PATH="$QNX_HOST/usr/bin:$PATH"
  ```
- Provide a `config.toml` with all desired targets (Linux + QNX + subsets) and run `scripts/build_ferrocene.sh` with `FERROCENE_BOOTSTRAP_TOML=./config.toml`. The script will use the existing config file without overwriting it.

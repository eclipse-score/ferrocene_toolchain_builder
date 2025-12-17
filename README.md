# Ferrocene Bazel Toolchain Builder

This repository builds the [ferrocene](https://github.com/ferrocene/ferrocene) compiler from a specific commit and wraps the resulting binaries as an archive so consumer repositories can register a `rules_rust` toolchain without forking the upstream sources.

## Prerequisites
- git, python3, [uv](https://github.com/astral-sh/uv) on PATH (Ferrocene bootstrap requires it) and a toolchain capable of building Ferrocene/Rust (LLVM, C/C++ build deps, etc.)
- Network access to `https://github.com/ferrocene/ferrocene.git` (or a mirror you provide).

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

By default only the core toolchain packages are built/installed (dist: `rustc rust-std cargo rustfmt clippy`; install: `rustc library/std cargo rustfmt clippy`) to skip doc builds that can fail on missing mdbook preprocessors or path issues. Override with `--dist-packages "<space-separated list>"` / `FERROCENE_DIST_PACKAGES` and `--install-packages "<space-separated list>"` / `FERROCENE_INSTALL_PACKAGES`.

Install step note: the script sets `DESTDIR=out/ferrocene/install` when running `x.py install` so no privileged paths are touched; the installed tree under that DESTDIR is what gets tarred.


## What the Module Produces
The `ferrocene_toolchain` extension wraps the archive into a repository that exposes:
- Binaries: `:rustc`, `:cargo`, `:rustdoc`, `:clippy_driver`, `:rustfmt`
- Standard library: `:rust_std-<target>`
- Host libs for rustc: `:rustc_lib`


No fork of the Ferrocene sources is required; only the commit SHA and the resulting archive URL are pinned in the consuming repository.

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

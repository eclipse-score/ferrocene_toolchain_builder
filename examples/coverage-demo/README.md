# Coverage demo with Ferrocene tools

This example shows how to:
1. build and run a tiny test binary with coverage instrumentation,
2. collect the raw coverage (`.profraw`) files,
3. produce a `symbol-report.json` with the `symbol-report` tool, and
4. generate an HTML report with `blanket`.

The demo uses host coverage (default `x86_64-unknown-linux-gnu`), but you can set `TARGET` to `x86_64-ferrocene-linux-gnu` if you have that stdlib available in your Ferrocene sysroot.

## Prerequisites
- A Ferrocene toolchain with `rustc` for your target (e.g. from `scripts/build_ferrocene.sh`).
- The toolchain must include the coverage runtime (`libprofiler_builtins`) in its sysroot. If the
  demo exits saying it is missing, rebuild Ferrocene with profiler enabled or point `SYSROOT`
  to one that has it.
- The coverage tools built from this repo: `symbol-report` and `blanket` (see `scripts/build_coverage_tools.sh`).
- A `cargo` you can point at your `rustc` (system cargo is fine).

## Run
```bash
# From repo root:
cd examples/coverage-demo

# Point to the Ferrocene bits you built earlier (defaults in parentheses). The
# defaults assume you built with profiler enabled using config.profiler.toml.
export RUSTC=${RUSTC:-"$(pwd)/../../build/x86_64-unknown-linux-gnu/stage2/bin/rustc"}
export SYMBOL_REPORT=${SYMBOL_REPORT:-"$(pwd)/../../out/ferrocene/tools/779fbed05ae9e9fe2a04137929d99cc9b3d516fd/x86_64-unknown-linux-gnu/symbol-report"}
export BLANKET=${BLANKET:-"$(pwd)/../../out/ferrocene/tools/779fbed05ae9e9fe2a04137929d99cc9b3d516fd/x86_64-unknown-linux-gnu/blanket"}
export FERROCENE_SRC=${FERROCENE_SRC:-"$(pwd)/../../.cache/ferrocene-src"}
# Change if you have a different toolchain layout:
export SYSROOT=${SYSROOT:-"$(pwd)/../../build/x86_64-unknown-linux-gnu/stage2"}
# Use the Ferrocene coverage target if available:
export TARGET=${TARGET:-x86_64-unknown-linux-gnu}

# Run the full demo
./run.sh
```

Outputs land under `examples/coverage-demo/coverage-out/`:
- `profraw/` contains the raw coverage files from the test run.
- `symbol-report.json` contains the symbol spans for this crate.
- `blanket/index.html` is the rendered coverage report.

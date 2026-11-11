---
type: Project
title: agentbuild
description: A Swift CLI for owned Notika, ABDiff, and Gunship development, leased commands, durable raw logs, and native outcome evidence.
tags: [swift, cli, builds, agentlease]
---

# agentbuild

`agentbuild` 0.3 is a standalone Swift CLI and Notika's integrated development
controller. Notika's public Make targets dispatch to its closed 54-route native
catalog: macOS and leased iPad Simulator builds/tests, focused batches,
result/coverage consumers, fixed performance workloads, and semantic replay.
Generation, exact-product macOS launch, DocC, direct Rust tests, preflight, and
today-only cache/session maintenance are Swift-owned workflows. The former
Python controller remains a test behavior reference without a live fallback.

ABDiff has a separate native adapter for Tuist generation, macOS and iPad builds
and tests, and supervised application launch. It shares compilation admission
and native supervision with Notika while retaining its own project profiles and
artifacts. See [ABDiff workflows](Docs/abdiff-workflows.md).

Gunship has an Unreal adapter for editor and game compilation, headless
automation, cooking and packaging, and packaged gameplay validation. Only
Unreal Build Tool compilation holds the shared compilation gate. See
[Gunship workflows](Docs/gunship-workflows.md).

The core preserves literal arguments, explicit resource ownership, per-stream
and combined raw logs, actual native outcomes, and source/result evidence boundaries.
Each project adapter has its own SwiftPM target and tests under `Adapters/`;
they link with the shared core into one executable. See
[Adapter modules](Docs/adapter-modules.md) for the source layout and dependency rules.
See the [project foundations](Docs/project-foundations.md) for ownership,
process retirement, raw-log custody, and source/result evidence boundaries.

## Why AgentBuild?

When several agents develop on one Mac, their builds can regenerate the same
Xcode project, write to the same DerivedData directory, or compete for compilation
resources. Each run also needs enough evidence to show what executed and whether
its tests passed.

AgentLease provides atomic resource ownership. AgentBuild adds project knowledge:
which resources a workflow needs, which native commands to run, and when ownership
can end. Its managed project routes provide:

- **Coordinated builds.** Generated projects and compatible caches stay protected
  while in use. The account-wide `host:compile` gate coordinates compilation
  across participating repositories. Test routes release that gate before test
  execution, allowing another project to compile while tests run.
- **Reusable build state.** Compatible DerivedData survives source changes so
  Xcode can reuse incremental build outputs.
- **Inspectable results.** Raw logs, native exit status, result bundles, and
  executed-test counts accompany source and toolchain observations. Source drift
  and reporting failures remain separate from actual native outcomes.
- **Shared workflow code.** Notika, ABDiff, and Gunship adapters reuse ownership, process
  supervision, and log capture while retaining their own commands and artifacts.

Keeping these rules in a separately tested and installed Swift CLI lets projects
share one implementation instead of duplicating orchestration scripts. The
practical benefit is dependable automation and less wasted work; build speed
benefits come from cache reuse and avoiding competing compilation.

## Use

```sh
agentbuild --help
agentbuild --version
agentbuild doctor
agentbuild doctor --json
agentbuild run --resource example:fixture -- /usr/bin/printf '%s\n' 'hello'
agentbuild notika plan --repository /absolute/path/to/Notika --route build-macos --json
agentbuild notika generate --repository /absolute/path/to/Notika
agentbuild notika build --repository /absolute/path/to/Notika --route build-macos
agentbuild notika build --repository /absolute/path/to/Notika --route test-unit-file --file SomeTests
agentbuild notika build --repository /absolute/path/to/Notika --route test-ui-file --platform ipad-simulator --file SomeUITests --method testName --device 'iPad Air 13-inch (M4)'
agentbuild notika run --repository /absolute/path/to/Notika
agentbuild notika run-rust-test svg --repository /absolute/path/to/Notika
agentbuild notika run-preflight --repository /absolute/path/to/Notika
agentbuild notika run-docs archive --repository /absolute/path/to/Notika
agentbuild notika run-docs preview --repository /absolute/path/to/Notika --port 8000
agentbuild notika cleanup --repository /absolute/path/to/Notika --json
agentbuild abdiff plan --repository /absolute/path/to/ABDiff --route build-macos --json
agentbuild abdiff generate --repository /absolute/path/to/ABDiff
agentbuild abdiff build --repository /absolute/path/to/ABDiff --route build-macos
agentbuild abdiff build --repository /absolute/path/to/ABDiff --route test-unit-file --file SomeTests
agentbuild gunship test --repository /absolute/path/to/Gunship --engine /absolute/path/to/UE_5.8 --filter Gunship.Zombies
agentbuild gunship package --repository /absolute/path/to/Gunship --engine /absolute/path/to/UE_5.8 --archive /absolute/archive
```

Doctor requires successful version probes for `swift`, `xcodebuild`, and
`agentlease`. It also reports whether `tuist`, `simlease`, `simslim`, `make`, and
`git` are available on `PATH`. It exits `0` when the required probes succeed
and `1` otherwise; optional missing tools do not fail the check.

`run` requires an absolute executable and at least one `--resource` or
`--shared-resource`. Arguments remain literal; specify a shell explicitly when
needed. Output goes to `stdout.log`, `stderr.log`, and `combined.log` below
`Artifacts/AgentBuild/<run-id>/`, alongside an atomic `manifest.json`.
Use `--artifacts-root`, `--working-directory`, and `--lease-home` for isolated
workflows, and `--json` for a machine-readable final report.

The CLI preserves child exit codes and reports child signals as `128 + signal`.
Cancellation waits for direct-child reaping; surviving inheriting descendants
retain their locks. See the [execution contract](Docs/execution.md) for failure
codes and lifecycle limits.

`notika plan` observes source and toolchain inputs, derives the compatible cache
and exact Xcode phases, and prints the requested resources. It acquires no leases,
creates no session or cache, and executes no project build. Its report explicitly
marks planning as unowned and its observations as sequential.

`notika build` invokes every admitted native route directly. It holds the session
writer, generated graph, compatible cache, and account compilation resources
in that order. It saves separate and combined raw logs and native termination;
source drift and publication errors remain separate diagnostics. Test routes
release compilation before runtime and retain actual result counts. UI and
Simulator workflows acquire or adopt one outer SimLease boundary; functional
Simulator checks apply SimSlim only to its exported device. See
[Notika workflows](Docs/notika-workflows.md) and
[fixed performance evidence](Docs/notika-performance.md).

`notika generate` prepares the existing bridge artifacts and runs the pinned
Tuist wrapper under exclusive graph ownership. It moves existing generated
project/workspace folders to Trash before regeneration and records each native
outcome in a generation-specific session report. `--cached` selects the existing
cached-dependency generation setting.

`notika run` builds and launches the exact macOS product inside one live session.
Its running receipt identifies the launched process; the supervisor remains
alive until the application exits. `notika run-rust-test svg|liteparse` owns
the pinned license check and Cargo workload below a compatible Rust test cache.

`notika run-preflight` runs or reuses the exact-source development gate. Broad
`test`, `test-unit`, and `build-and-test` routes run that gate automatically;
focused routes preserve their narrow workload. Independent semantic helpers
and contract tests may use Python; they do not own the native controller.

Managed routes perform best-effort executed maintenance using the current local
day cutoff before admitting new work. Busy, invalid, or uncertain entries stay
protected; maintenance diagnostics do not replace a native outcome.
`notika cleanup` previews that retention policy by default. `--execute` moves
admitted, inactive older folders to the Trash. Busy or uncertain entries stay
in place and appear in the report. See [daily cleanup](Docs/notika-cleanup.md).

`notika run-docs archive|rendered|preview` runs one fixed DocC build and retains
its archive in the session. Rendered and preview modes snapshot the renderer
and produce a private static site; `--renderer-root` selects a stable owned
renderer tree. Preview binds only `127.0.0.1`, prints its ready URL, and keeps
the supervisor alive until interruption. Graph/cache ownership spans the full
pipeline; compilation ownership covers only docbuild. Docbuild, rendering,
preview, and maintenance outcomes remain separately reported.

The package uses Swift tools 6.4, Swift 6 language mode, and macOS 27 or later.
ArgumentParser 1.8.2 and Subprocess 1.0.0 are exact dependencies; AgentLeaseCore
is pinned to a reviewed Git revision.

## Development

```sh
make build
make release
make test
make test TEST_FILTER=ABDiff
make install
```

`SWIFT_JOBS` defaults to `sysctl -n hw.logicalcpu`, using all logical cores
(12 on the validation Mac), as requested. `make build SWIFT_JOBS=1` reduces
compiler parallelism. Bootstrap compilation acquires the exclusive AgentLease
resource `host:compile` in the effective account's registry. The default registry
is `~/.agentlease`, independent of an inherited `HOME` or checkout-local
`AGENTLEASE_HOME`. An explicitly set `AGENTLEASE_COMPILE_HOME` must be absolute
and nonempty, and all participating repositories must use the same override.
Test execution starts after its build has released compilation ownership.
The test route explicitly disables parallel test cases: fault fixtures replace
process-global descriptors, and overlapping fixtures can temporarily inherit
each other's locks. Individual concurrency tests still exercise competing
tasks and native children inside their own case.

## Installation

`make install` copies the release executable to `~/Developer/tools/agentbuild`.
Add `~/Developer/tools` to `PATH` to use the command alongside `agentlease`,
`simlease`, and `simslim`. Set `BIN_DIR` to an absolute directory to choose
another destination. Installation atomically replaces the copied executable;
it does not create a symlink or depend on the source checkout's `.build` tree.

The copied executable matches the built release and the tool doctor passes.
The [workflow validation record](Docs/notika-workflows.md#validation-record)
records the tested workflows, native outcomes, and evidence limits. Source,
build products, and the installed executable have independent lifecycles.

See the [documentation index](Docs/index.md) and [design contract](Docs/design.md)
for ownership, evidence, and project-adapter boundaries. Implemented route
coverage is distinct from a claim that every native workflow has been executed
in a particular validation batch.

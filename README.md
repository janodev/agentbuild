---
type: Project
title: agentbuild
description: A Swift CLI for leased command execution, durable raw logs, and native outcome evidence.
tags: [swift, cli, builds, agentlease]
---

# agentbuild

`agentbuild` is a standalone Swift CLI. It checks the local toolchain and runs
explicitly leased commands through Swift Subprocess, saving raw output and
native outcomes. Project-specific graph, cache, build, test, and launch routes
remain future work; it does not yet replace Notika's development driver.

```sh
agentbuild --help
agentbuild --version
agentbuild doctor
agentbuild doctor --json
agentbuild run --resource example:fixture -- /usr/bin/printf '%s\n' 'hello'
```

Doctor requires successful version probes for `swift`, `xcodebuild`, and
`agentlease`. It also reports whether `tuist`, `simlease`, `simslim`, `make`, and
`git` are available on `PATH`. It exits `0` when the required probes succeed
and `1` otherwise; optional missing tools do not fail the check.

`run` requires an absolute executable and at least one `--resource` or
`--shared-resource`. Arguments remain literal; specify a shell explicitly when
needed. Output goes to separate `stdout.log` and `stderr.log` files below
`Artifacts/AgentBuild/<run-id>/`, alongside an atomic `manifest.json`.
Use `--artifacts-root`, `--working-directory`, and `--lease-home` for isolated
workflows, and `--json` for a machine-readable final report.

The CLI preserves child exit codes and reports child signals as `128 + signal`.
Cancellation waits for direct-child reaping; surviving inheriting descendants
retain their locks. See the [execution contract](Docs/execution.md) for failure
codes and lifecycle limits.

The package uses Swift tools 6.4, Swift 6 language mode, and macOS 27 or later.
ArgumentParser 1.8.2 and Subprocess 1.0.0 are exact dependencies; AgentLeaseCore
is pinned to a reviewed Git revision.

## Development

```sh
make build
make release
make test
make install
```

`SWIFT_JOBS` defaults to `2`; for example, `make build SWIFT_JOBS=1` reduces
compiler parallelism. Bootstrap compilation acquires the exclusive AgentLease
resource `host:compile` in the effective account's registry. The default registry
is `~/.agentlease`, independent of an inherited `HOME` or checkout-local
`AGENTLEASE_HOME`. An explicitly set `AGENTLEASE_COMPILE_HOME` must be absolute
and nonempty, and all participating repositories must use the same override.
Test execution starts after its build has released compilation ownership.

## Installation

The default installation is
`~/.local/opt/agentbuild/bin/agentbuild`, with a command symlink at
`~/.local/bin/agentbuild`. Add `~/.local/bin` to `PATH` to use that command.
Installation copies a release binary; it does not point into the source
checkout's `.build` directory.

This per-user `opt` layout keeps the installed tool separate from source and
build products. The source checkout can remain at
`~/Developer/code/janodev/agentbuild`. Existing flat executable installations
such as `~/Developer/tools/agentlease` also work; `opt` is an installation
convention, not a requirement for other tools.

See the [documentation index](Docs/index.md) and [design contract](Docs/design.md)
for the boundary between this foundation and future managed execution.

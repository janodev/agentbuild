---
type: Project
title: agentbuild
description: A Swift command-line foundation for coordinated agent build workflows.
tags: [swift, cli, builds, agentlease]
---

# agentbuild

`agentbuild` is a standalone Swift CLI foundation. It currently provides
`--help`, `--version`, and `doctor [--json]`. Doctor runs diagnostic tool probes
through Swift Subprocess. Managed project builds are future work; the CLI does
not yet replace Notika's development driver.

```sh
agentbuild --help
agentbuild --version
agentbuild doctor
agentbuild doctor --json
```

Doctor requires successful version probes for `swift`, `xcodebuild`, and
`agentlease`. It also reports whether `tuist`, `simlease`, `simslim`, `make`, and
`git` are available on `PATH`. It exits `0` when the required probes succeed
and `1` otherwise; optional missing tools do not fail the check.

The package uses Swift tools 6.2, Swift 6 language mode, and macOS 27 or later.
Dependencies are pinned to ArgumentParser 1.8.2 and Subprocess 1.0.0.

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

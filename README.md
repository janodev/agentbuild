# AgentBuild

AgentBuild is a Swift command-line foundation for coordinated build workflows.
It runs explicitly leased commands, preserves native results and raw logs, and
routes project workflows to independently installed adapter executables.

Project policy belongs to each project's adapter. This repository publishes
`AgentBuildCore`, `AgentBuildCLISupport`, and the generic `agentbuild` executable.
It contains no project adapters. Adapter package directories must have an identity
different from `agentbuild`; for example, use `Tools/ExampleBuild`.

```text
agentbuild run / doctor              → shared execution and diagnostics
agentbuild example <arguments>       → agentbuild-example <arguments>
private project / Tools/ExampleBuild → its adapter, tests, and workflow docs
```

## Use

```sh
agentbuild --help
agentbuild --version
agentbuild doctor --json
agentbuild run --resource example:fixture -- /usr/bin/printf '%s\n' 'hello'
agentbuild example --help
```

`run` requires an absolute executable and at least one exclusive `--resource`
or `--shared-resource`. Arguments remain literal; invoke a shell explicitly
when needed. It saves `stdout.log`, `stderr.log`, `combined.log`, and an atomic
`manifest.json` under `Artifacts/AgentBuild/<run-id>/`. Use `--artifacts-root`,
`--working-directory`, and `--lease-home` for isolated workflows and `--json`
for a machine-readable final report. It preserves native exit codes and reports
native signals as `128 + signal`. See the [execution contract](Docs/execution.md).

`doctor` probes `swift`, `xcodebuild`, and `agentlease`, and reports optional
tool availability. Readiness establishes tool availability, not project build
or test success.

Install `agentbuild-example` beside the resolved `agentbuild` executable to
provide `agentbuild example`. An absolute
`AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE` override selects a different executable.
The router drops the adapter name and replaces its process with that executable,
keeping the remaining arguments, environment, standard streams, and inherited
descriptors. It acquires no leases and performs no build. Adapters are not
searched for on `PATH`. See [building an adapter](Docs/building-an-adapter.md)
for the complete routing and package contract.

Adapters can share one source mirror and DerivedData directory across compatible
worktrees using the [warm build slot API](Docs/warm-build-slots.md).

## Development

The package requires Swift tools 6.4, Swift 6 language mode, and macOS 27 or
later. ArgumentParser 1.8.2 and Subprocess 1.0.0 are exact dependencies;
AgentLeaseCore is pinned to a reviewed Git revision.

```sh
make build
make release
make test
make test TEST_FILTER=ManagedCLITests
make install
```

`SWIFT_JOBS` defaults to all logical CPU cores. Compilation acquires the
account-wide AgentLease `host:compile` resource. Tests execute after compilation
ownership ends. The shared registry defaults to the effective account's
`~/.agentlease`, independently of inherited `HOME` and checkout-local
`AGENTLEASE_HOME`. An explicit `AGENTLEASE_COMPILE_HOME` must be absolute and
nonempty, and every participating repository must use the same value.

`make install` atomically copies the release executable to
`~/Developer/tools/agentbuild`. Set `BIN_DIR` to an absolute directory to choose
another destination. Installation does not point into `.build`. Install each
adapter independently as another copied executable in that directory, or set
its explicit absolute override.

See the [documentation index](Docs/index.md), [design contract](Docs/design.md),
and [adapter authoring guide](Docs/building-an-adapter.md).

## Companion tools

- [AgentLease](https://github.com/janodev/agentlease) coordinates shared resources.
- [SimLease](https://github.com/janodev/simlease) manages disposable simulators and macOS UI automation.
- [SimSlim](https://github.com/janodev/simslim) reduces Simulator background work.

These tools work independently. Adapters use them when their workflow requires
resource or device coordination.

## License

MIT — see [LICENSE](LICENSE).

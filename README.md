# AgentBuild

Running multiple coding agents—or several Git worktrees—on one Mac breaks normal
Xcode and Swift workflows fast. Every new worktree triggers a cold build and its
own multi-gigabyte `DerivedData`. Concurrent compilers thrash the CPU. Killing a
stuck agent leaves orphaned build processes behind. And agents routinely declare
victory when `xcodebuild` exits `0` after running zero tests.

AgentBuild is a macOS Swift CLI and library suite (`agentbuild`,
`AgentBuildCore`, and `AgentBuildCLISupport`) built to make parallel,
single-machine Apple development fast, predictable, and honest—while keeping
project-specific build policy in lightweight private adapters.

## Why AgentBuild?

- **Incremental Xcode builds across Git worktrees with APFS clones.**
  Xcode ties `DerivedData` to absolute source paths, so separate worktrees
  normally cannot share a warm build cache. `WarmBuildSlot` lets compatible
  worktrees take turns building inside one stable `src/` mirror paired with one
  persistent `DerivedData/` directory. Byte-identical files keep their existing
  inode and timestamp so Xcode skips recompiling them; new and changed files use
  APFS copy-on-write clones for near-instant syncs and minimal extra disk space,
  with monotonic timestamps so same-size edits are never missed.
- **Full-speed compiles without CPU thrashing—and tests that don't block builds.**
  All participating repositories share one account-wide `host:compile` kernel
  lock via AgentLease, letting each build use every logical CPU core at full
  speed instead of fighting concurrent compilers. `XcodeExecutionPlan` splits a
  logical `xcodebuild test` into `build-for-testing` (holds `host:compile`) and
  `test-without-building` (releases `host:compile` immediately), so another agent
  can compile while your simulator or UI tests run.
- **Truthful, agent-proof build and test evidence.**
  Every supervised run captures raw `stdout.log`, `stderr.log`, `combined.log`,
  and an atomic `manifest.json` while preserving exact native exit codes and
  signals (`128 + signal`). For Xcode workflows, `AgentBuildCore` also parses
  real `.xcresult` counts (`ExecutedTests`) so zero-test runs never pass
  silently, and snapshots Git and file hashes (`RepositorySourceSnapshot`) to
  report source drift separately from native build outcomes.
- **Crash-safe supervision and clean teardown on macOS.**
  Kernel-backed `flock` leases are inherited across child descriptors, so locks
  survive coordinator crashes while work is still running and release
  automatically when processes exit—never relying on stale lock files or
  timeouts. `SIGINT`, `SIGTERM`, and `SIGHUP` immediately tear down the
  workload's Darwin process group instead of leaving zombie compilers behind.
- **Safe artifact and cache retention.**
  Built-in calendar-day retention rules (`LocalCalendarRetention`) and safe
  Trash helpers let adapters prune old caches and sessions without deleting
  active or busy runs.
- **Shared systems plumbing, private project policy.**
  This repository holds generic execution, supervision, caching, and evidence
  primitives—no project names or private rules. Each repository keeps its own
  small Swift adapter (`agentbuild-<project>`) that links `AgentBuildCore` and
  `AgentBuildCLISupport` and installs beside `agentbuild`.

## Companion tools

Run multiple coding agents on one Mac with less resource contention, lighter
simulators, and less disk clutter. Competing builds and desktop UI tests take
turns while independent work continues in parallel.

This project is part of a set of tools:

- **AgentBuild** (this repo) — coordinates builds and tests, shares warm build slots across worktrees, splits compile/test phases, and records native evidence.
- [AgentLease](https://github.com/janodev/agentlease) — coordinates access to shared resources with crash-safe kernel locks (`host:compile`, caches, artifacts).
- [SimLease](https://github.com/janodev/simlease) — provides disposable iOS simulators, cleans them up afterward, and queues exclusive macOS UI automation.
- [SimSlim](https://github.com/janodev/simslim) — disables unneeded Simulator background services so more simulators fit in memory.

AgentLease, SimLease, and SimSlim work independently. Project adapters built on
AgentBuild combine them whenever a workflow needs shared locks, disposable
simulators, or slimmed devices.

## How it fits together

```text
Worktree A ──┐                                  ┌── src/ (APFS-cloned mirror)
Worktree B ──┼─▶ WarmBuildSlot (exclusive lock) ┼── DerivedData/ (reused cache)
Worktree C ──┘                                  └── host:compile held only during build
```

At the command line, `agentbuild` provides built-in generic commands and acts as
a zero-overhead POSIX `exec` router to independently installed project adapters:

```text
agentbuild doctor                    → check local toolchain readiness
agentbuild run --resource ... -- ... → run a leased command and save raw logs + manifest
agentbuild example <args>            → exec agentbuild-example <args> (installed sibling)
```

Routing drops the adapter name and replaces the `agentbuild` process directly,
keeping literal arguments, environment, standard streams, inherited lock
descriptors, and native signal semantics. It never searches `PATH`, builds
missing packages, or acquires leases on the adapter's behalf.

## Requirements & install

Requires **macOS 27 or later**, **Swift 6.4** (Swift 6 language mode), and
[AgentLease](https://github.com/janodev/agentlease) installed for coordinated
builds.

```sh
git clone https://github.com/janodev/agentbuild.git
cd agentbuild
make install
```

`make install` compiles a release binary under the account-wide `host:compile`
lease and atomically copies it to `~/Developer/tools/agentbuild` (set `BIN_DIR`
to an absolute path to install elsewhere; it never symlinks into `.build`). Add
`~/Developer/tools` to `PATH`.

## Quick start

Check local tool availability (`swift`, `xcodebuild`, `agentlease`, and optional
tools):

```sh
agentbuild doctor
agentbuild doctor --json
```

Run any command under explicit exclusive (`--resource`) or shared
(`--shared-resource`) kernel leases, capturing raw logs and an atomic manifest
under `Artifacts/AgentBuild/<run-id>/`:

```sh
agentbuild run \
  --resource example:fixture \
  --json \
  -- /usr/bin/printf '%s\n' 'hello'
```

Arguments after `--` remain literal with no implicit shell expansion; invoke a
shell explicitly when needed. Use `--working-directory`, `--artifacts-root`,
`--lease-home`, and `--wait-seconds` to customize execution.

### Building a project adapter

To give a repository managed workflows (such as `agentbuild example build` or
`agentbuild example test`), create a small private Swift package in that
repository—for example `Tools/ExampleBuild` (the package directory's final
component must differ from `agentbuild`, ignoring case)—depending on pinned
revisions of `AgentBuildCore` and `AgentBuildCLISupport`:

1. Register your project commands alongside `NativeWorkerCommand` from
   `AgentBuildCLISupport`.
2. Use `WarmBuildSlot` to sync worktrees into a shared APFS-cloned mirror and
   persistent `DerivedData`, `XcodeExecutionPlan` / `XcodePhaseRunner` to split
   compilation from test runtime, and `ExecutedTests` /
   `RepositorySourceSnapshot` to record truthful results.
3. Copy the compiled `agentbuild-example` release executable beside `agentbuild`
   (or point `AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE` to an explicit absolute
   path).

See [Building an adapter](Docs/building-an-adapter.md) and
[Warm build slots](Docs/warm-build-slots.md) for complete Swift examples.

## Development

```sh
make build
make release
make test
make test TEST_FILTER=ManagedCLITests
```

`SWIFT_JOBS` defaults to all logical CPU cores. Compilation acquires the
account-wide AgentLease `host:compile` resource and releases it before test
execution begins. The shared registry defaults to the effective account's
`~/.agentlease` (or an explicit shared `AGENTLEASE_COMPILE_HOME`).

To exercise `WarmBuildSlot` against four real macOS Xcode builds—verifying that
switching worktrees with identical inputs skips Swift compilation while
same-size edits trigger the expected rebuild—run:

```sh
AGENTBUILD_TEST_XCODE_SLOT=1 make test TEST_FILTER=WarmBuildSlotTests
```

## Documentation

| Guide | Covers |
| --- | --- |
| [Docs/index.md](Docs/index.md) | Full documentation index |
| [Docs/warm-build-slots.md](Docs/warm-build-slots.md) | Sharing `DerivedData` and APFS-cloned source mirrors across worktrees |
| [Docs/building-an-adapter.md](Docs/building-an-adapter.md) | Minimal adapter package, routing rules, lifecycle phases, and installation |
| [Docs/execution.md](Docs/execution.md) | Owned execution contract, cancellation, exit codes, and raw evidence |
| [Docs/design.md](Docs/design.md) | Architecture, POSIX `exec` handoff, and diagnostics limits |
| [Docs/adapter-modules.md](Docs/adapter-modules.md) | Public library boundaries vs. private project ownership |

## License

MIT — see [LICENSE](LICENSE).

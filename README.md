# AgentBuild

AgentBuild is a macOS Swift CLI and library for coordinating builds and tests when multiple coding
agents share one Mac.

When running multiple agents on a single computer:

- CPU contention from multiple compilers degrades overall performance.
- Each compilation uses multiple GB of intermediate products.
- Non-shareable resources interfere with each other (UI automation, same simulator, computer use, etc.).
- High memory and disk use.

How AgentBuild helps:

- Compiler serialization to prevent overhead.
- Multiple worktree compilation to a single folder.
- Reserve resources for exclusive use.
- Reclaims disk usage.
- Technology agnostic. Compiles projects in any language (Swift, Unreal, Rust, etc.)
- iOS simulators use less memory by launching without background services (via SimSlim).

## Companion tools

- **AgentBuild** (this repo): coordinates builds and tests, shares warm build slots across worktrees, and records native logs and results.
- [AgentLease](https://github.com/janodev/agentlease): coordinates shared resources with kernel locks (`host:compile`, caches, artifacts).
- [SimLease](https://github.com/janodev/simlease): creates disposable iOS simulators, cleans them up afterward, and queues macOS UI automation.
- [SimSlim](https://github.com/janodev/simslim): disables unneeded Simulator background services to reduce memory use.
- **git-seed-worktree** creates a new Git worktree that can share tracked file data with an existing checkout on APFS. [Installation instructions](https://github.com/janodev/git-seed-worktree#use)

AgentLease, SimLease, and SimSlim work independently. Project adapters built on
AgentBuild combine them when needed.

## How multiple worktrees compile in a single folder

Worktrees usually have small differences, so compiling serially to a single folder is cheaper and faster.

This feature is based on *APFS clones*. An APFS clone is an independent file that initially shares disk blocks with the
original. When either file is edited, only the changed blocks allocate new
storage. 

```text
Worktree A ──┐                                  ┌── src/ (APFS-cloned mirror)
Worktree B ──┼─▶ WarmBuildSlot (exclusive lock) ┼── DerivedData/ (reused cache)
Worktree C ──┘                                  └── host:compile held during compile
```

Suppose worktrees A and B each have their own edits. When either builds,
`WarmBuildSlot` takes an exclusive lock on a reusable build slot (`src/` plus a
sibling `DerivedData/`) and syncs `src/` to match that worktree:

1. Files removed from the worktree are removed from `src/`.
2. Files whose bytes and permissions already match are left untouched.
3. New or changed files are APFS-cloned into `src/` and stamped with a newer
   modification time to hint that compilation is required.

Because Xcode uses all available CPU cores while compiling, taking turns on one
slot avoids CPU contention while letting both worktrees reuse the same warm
`DerivedData` and saving GB of disk space. If you want one worktree
running tests while another compiles, an adapter can use multiple numbered
slots, each with its own `DerivedData`, while compilation still serializes on
`host:compile`.

See [Docs/warm-build-slots.md](Docs/warm-build-slots.md) for the API and
adapter example.

## Architecture

`agentbuild` provides built-in generic commands (`doctor`, `run`) and routes
project commands to independently installed sibling executables via POSIX
`exec`:

```text
agentbuild doctor                    → check local toolchain availability
agentbuild run --resource ... -- ... → run a leased command and save raw logs + manifest
agentbuild example <args>            → exec agentbuild-example <args>
```

Routing drops the adapter name and replaces the `agentbuild` process directly,
keeping literal arguments, environment, standard streams, inherited file
descriptors, and native signals. It does not search `PATH`, build missing
packages, or acquire leases for the adapter. Project policy, tests, fixtures,
and workflow docs stay in each project's own repository.

## Requirements and install

Requires macOS 27 or later, Swift 6.4 (Swift 6 language mode), and
[AgentLease](https://github.com/janodev/agentlease).

```sh
git clone https://github.com/janodev/agentbuild.git
cd agentbuild
make install
```

`make install` builds a release binary under the account-wide `host:compile`
lease and atomically copies it to `~/Developer/tools/agentbuild` (set `BIN_DIR`
to an absolute directory to install elsewhere; it never symlinks into `.build`).
Add `~/Developer/tools` to `PATH`.

## Quick start

If you already have a worktree, run AgentBuild from that checkout. To create a
new worktree on APFS, you can install the optional `git-seed-worktree` companion
on your `PATH`. Run this from the root of a finished checkout of the repository.

```sh
git seed-worktree -b feature/login ../login HEAD --seed . --clone-tracked
cd ../login
```

Check local tool availability (`swift`, `xcodebuild`, `agentlease`, and optional
tools):

```sh
agentbuild doctor
agentbuild doctor --json
```

Run any command under explicit exclusive (`--resource`) or shared
(`--shared-resource`) leases, saving logs and `manifest.json` under
`Artifacts/AgentBuild/<run-id>/`:

```sh
agentbuild run \
  --resource example:fixture \
  --json \
  -- /usr/bin/printf '%s\n' 'hello'
```

Arguments after `--` remain literal with no implicit shell expansion; invoke a
shell explicitly when needed. Use `--working-directory`, `--artifacts-root`,
`--lease-home`, and `--wait-seconds` to configure execution.

### Building a project adapter

To add project workflows (such as `agentbuild example build` or
`agentbuild example test`), create a private Swift package in that repository,
for example `Tools/ExampleBuild` (the final directory component must differ from
`agentbuild`, ignoring case), depending on pinned revisions of `AgentBuildCore`
and `AgentBuildCLISupport`:

1. Register your project commands and `NativeWorkerCommand` from
   `AgentBuildCLISupport`.
2. Use `WarmBuildSlot`, `XcodeExecutionPlan` / `XcodePhaseRunner`,
   `ExecutedTests`, and `RepositorySourceSnapshot` as needed.
3. Copy the compiled `agentbuild-example` release executable beside `agentbuild`
   (or set `AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE` to an absolute path).

See [Docs/building-an-adapter.md](Docs/building-an-adapter.md) for a minimal
package and checklist.

## Development

```sh
make build
make release
make test
make test TEST_FILTER=ManagedCLITests
```

`SWIFT_JOBS` defaults to all logical CPU cores. Compilation acquires the
account-wide AgentLease `host:compile` resource and releases it before tests
start. The shared registry defaults to the effective account's `~/.agentlease`
(or an explicit shared `AGENTLEASE_COMPILE_HOME`).

To test `WarmBuildSlot` against four real macOS Xcode builds (verifying that
switching worktrees with identical inputs skips Swift compilation and that
same-size edits trigger a rebuild):

```sh
AGENTBUILD_TEST_XCODE_SLOT=1 make test TEST_FILTER=WarmBuildSlotTests
```

## Documentation

| Guide | Covers |
| --- | --- |
| [Docs/index.md](Docs/index.md) | Documentation index |
| [Docs/warm-build-slots.md](Docs/warm-build-slots.md) | Reusing a warm build directory and `DerivedData` across worktrees |
| [Docs/building-an-adapter.md](Docs/building-an-adapter.md) | Minimal adapter package, routing rules, lifecycle phases, and installation |
| [Docs/execution.md](Docs/execution.md) | Owned execution contract, cancellation, exit codes, and raw evidence |
| [Docs/design.md](Docs/design.md) | Architecture, POSIX `exec` handoff, and diagnostics limits |
| [Docs/adapter-modules.md](Docs/adapter-modules.md) | Public library boundaries and private project ownership |

## License

MIT. See [LICENSE](LICENSE).

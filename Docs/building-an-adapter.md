---
okf_version: "0.1"
type: Guide
title: Building an AgentBuild adapter
description: Create, test, and install a private project adapter using AgentBuild's public Swift libraries.
tags: [development, adapters, swiftpm, agentlease, testing]
---

# Start in the owning project

An adapter is an independently built executable named `agentbuild-<name>`.
Keep its Swift package, project routes, fixtures, tests, and workflow docs in the
owning project's private repository, conventionally `Tools/ExampleBuild`. The
public AgentBuild repository contains reusable mechanisms, not project policy.
Adding an adapter requires no change to the public executable or package graph.

Before implementing commands, read the project's architecture, build, test, and
resource-coordination instructions. Inventory its existing wrappers, toolchain
pins, cache identities, native phases, artifacts, and exit behavior. Define
which behavior must remain compatible. Do not substitute fixture success for
real native validation when migrating an existing controller.

For an Xcode adapter, choose between per-worktree DerivedData and a shared
`AgentBuildCore.WarmBuildSlot`. A shared slot can save disk and cold builds when
agents frequently create worktrees with similar inputs. The adapter chooses
which inputs to mirror and which builds can share a cache. See the
[integration example](warm-build-slots.md).

To make this option discoverable in the consuming repository, its root or
adapter-package `AGENTS.md` can include this line:

> When changing Xcode build caching, consider `AgentBuildCore.WarmBuildSlot`
> for sharing DerivedData across compatible worktrees. Check the adapter's
> AgentBuild revision in `Package.resolved` before using the API.
> [Warm build slot example](https://github.com/janodev/agentbuild/blob/a7a6b4dbc8be3b45eacc270eec644dd4220bd839/Docs/warm-build-slots.md)

# Create the Swift package

Use Swift tools 6.4, Swift 6 language mode, and macOS 27 or later. Depend on
`AgentBuildCore` and `AgentBuildCLISupport` using a reviewed full Git revision,
not a floating branch. Resolve and commit the adapter's own `Package.resolved`.
The public package's release and your adapter's release are independent.

The final directory component of the adapter package must differ from the
public dependency identity `agentbuild`, ignoring case. Use a project-specific
directory such as `Tools/ExampleBuild`, rather than `Tools/AgentBuild`.
SwiftPM derives package identity from its location; setting a different
`Package(name:)` does not resolve a root/dependency identity collision.

The following minimal package prints a read-only plan and registers the native
worker protocol. Replace `REVIEWED_AGENTBUILD_COMMIT` with a full commit that
exports both products before resolving. The sources need no project tools or
leases to run their plan.

```text
Tools/ExampleBuild/
├── Package.swift
├── Package.resolved
├── Sources/ExampleAgentBuild/ExampleAgentBuild.swift
├── Tests/
└── Docs/
```

`Package.swift`:

```swift
// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "ExampleAgentBuild",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "agentbuild-example", targets: ["ExampleAgentBuild"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/janodev/agentbuild.git",
            revision: "REVIEWED_AGENTBUILD_COMMIT"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
    ],
    targets: [
        .executableTarget(
            name: "ExampleAgentBuild",
            dependencies: [
                .product(name: "AgentBuildCore", package: "agentbuild"),
                .product(name: "AgentBuildCLISupport", package: "agentbuild"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

`Sources/ExampleAgentBuild/ExampleAgentBuild.swift`:

```swift
import AgentBuildCLISupport
import AgentBuildCore
import ArgumentParser

@main
struct ExampleAgentBuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentbuild-example",
        abstract: "Run this project's managed development workflows.",
        subcommands: [Plan.self, NativeWorkerCommand.self]
    )
}

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Describe the example workload without executing it."
    )

    mutating func run() throws {
        print("Unowned plan: no native workload configured.")
    }
}
```

The imported public `NativeWorkerCommand` wraps `NativeWorkerEntry` from
`AgentBuildCore`; register it even though it is hidden from help. Native
supervision reexecutes the current adapter executable with `_native-worker`
and descriptor arguments. Omitting that command breaks worker startup. The
worker grants no project route authority by itself. Keep nonce and descriptor
protocol handling in the shared implementation rather than reconstructing it
in a project command.

For an existing adapter command, copy its command configuration into the new
root and change `commandName` to `agentbuild-example`. Preserve its subcommands,
options, and help behavior, then add `NativeWorkerCommand`. Register any private
self-reexecution helpers in that same root. Give only the executable target an
`@main` entry point. If tests need to import project commands, put them in a
private library target with a thin executable root.

# Understand routing

These invocations must reach the same adapter command:

```sh
agentbuild example plan
/absolute/tools/agentbuild-example plan
```

Names match `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`; built-in names `doctor`,
`run`, `help`, and `_native-worker` are reserved. The router validates the name,
resolves its own executable, and checks
`AGENTBUILD_ADAPTER_<UPPERNAME>_EXECUTABLE`, uppercasing the name and replacing
hyphens with underscores. For example, `example-tools` uses
`AGENTBUILD_ADAPTER_EXAMPLE_TOOLS_EXECUTABLE`. When set, that variable must name
an absolute executable. Otherwise it selects `agentbuild-<name>` in the resolved
router executable's directory. It never searches `PATH` for an adapter,
compiles a missing package, or reads project configuration to discover one.
An invalid explicit override is an error, not permission to fall back. The
target must be an executable regular file, must not itself be a symlink, and
must not identify the same device/inode as the router. Invalid names, overrides,
or self-delegation exit `64`; a missing adapter exits `127`; an unrunnable target
exits `126`; an unexpected routing failure exits `70`.

The leading adapter selector is removed. Every remaining argument, including
`--`, spaces, wildcard characters, and shell metacharacters, remains literal.
A POSIX `exec` handoff replaces the router with the adapter. The environment,
working directory, standard streams, inherited file descriptors, exit status,
and signal behavior follow the process replacement. The router does not become
an additional supervisor and does not acquire leases.

Use the resolved current executable for adapter self-reexecution; do not infer
it from `argv[0]` or a `PATH` lookup. This keeps native helpers on the exact
installed adapter revision and preserves inherited ownership descriptors.

# Define planning and execution separately

Implement a read-only planner before admitting native work. Its output should
identify the exact executable, literal arguments, working directory, toolchain
identity, resources, compatible cache inputs, and expected evidence. Planning
must not acquire leases, create sessions or caches, run maintenance, generate
projects, compile, or launch. Mark source/toolchain observations as sequential
and unowned. Execution must revalidate the inputs it actually owns and uses.

Keep routes typed and project-specific. Explicitly define each phase's authority:
what it reads, mutates, builds, launches, retains, and reports. Share generic
mechanisms through the two public libraries; do not import another project's
adapter to reuse its resource names, schemas, or workflow assumptions.

A typical native workflow has these ownership intervals:

| Phase | Required ownership |
| --- | --- |
| Session admission | Exclusive writer for the session and its evidence |
| Graph generation | Exclusive generated-graph ownership |
| Native compilation | Appropriate graph/cache ownership, then exclusive `host:compile` |
| Test execution | Retained graph/cache/result ownership; compilation ownership released |
| Device or UI interaction | One outer device/desktop boundary through required teardown |
| Final publication | Retained evidence ownership through native retirement and publication |

Acquire resources only when needed and release them promptly after their
protected operation and cleanup finish. Do not hold a desktop lease while
coding, waiting for input, or running unrelated checks. Never remove another
process's active lock or infer inactivity from metadata age. Use owner and
kernel-lock evidence.

All participating projects must use the same account-wide `host:compile`
registry. The shared default is the effective account's home plus `.agentlease`,
not inherited `HOME` or checkout-local `AGENTLEASE_HOME`. An explicit
`AGENTLEASE_COMPILE_HOME` must be absolute and nonempty and must have the same
value across every participating repository. Fail acquisition rather than
silently compiling without coordination. Avoid nesting another compilation
owner around a managed route that already owns the gate.

Separate build-for-testing and test-without-building when the native tool
supports them. Release `host:compile` before test runtime, launch, or user
interaction; keep graph, cache, and result custody for their actual remaining
use. Generation needs graph ownership but does not automatically need a
compilation lease. Classify phases that really compile, including auxiliary
language or documentation builds, rather than assuming only the main build
uses compilation resources.

# Preserve native evidence

Retain exact native invocation information, combined raw stdout/stderr logs,
separate streams when supported, and native result artifacts such as `.xcresult`
bundles. Keep the actual native exit or signal authoritative. Reports should
separately identify observed native termination, cancellation, source drift,
executed-test counts, log/result publication failures, and ancillary maintenance
outcomes.

A successful formatter, completed coordinator, or generated result directory
cannot prove that tests passed. Parse actual executed counts and distinguish
zero executed tests from a passing run. Preserve native failures even when
reporting also fails. A hash change during validation is a source observation,
not an automatic native failure or a reason to rerun all tests.

Define cache compatibility and retention within the private adapter. Protect
unknown, busy, incomplete, or invalid evidence. If cleanup moves entries to
Trash, report that action accurately; it does not establish reclaimed disk
space. The shared generic execution layer has no automatic project retention
policy.

# Test the contract

Keep public-mechanism tests in AgentBuild and project-policy tests in the
adapter. Adapter fixtures should exercise literal argument forwarding,
working directories and environment, exact command configuration, helper
self-reexecution, cache identities, ownership ordering, and result publication.
Include native failures and signals, waiting and cancellation, direct-child
reaping, inherited-descriptor lifetime, and evidence failures where the adapter
adds behavior. Read the [execution contract](execution.md) before asserting
stronger descendant cleanup guarantees than the shared layer provides.

Verify test phases release compilation ownership before execution. Check real
executed-test counts, zero-test handling, failed native tests, and cancellation
during both waiting and running work. Verify device/UI routes use one outer
coordination boundary and finish teardown before releasing it.

Then run a representative real native workflow in the private project. Preserve
raw logs and result bundles and record the native exit status, executed counts,
source observations, tested adapter revision, installed executable identity,
and limitations. Synthetic fixtures and public library tests do not establish
that this real workflow succeeded.

Build the adapter through its project's managed compilation route, or establish
one compilation boundary around its Swift build before it has a managed route.
Do not bypass the shared host gate with routine direct `swift build`. Build
tests under that boundary, release it, then execute tests with `--skip-build`.

# Install and verify independently

Build a release adapter under the compilation gate. Atomically replace a copied
regular executable named `agentbuild-example` beside the installed, resolved
`agentbuild` executable. Copy through a temporary file in the destination
directory, set executable permissions, and rename it into place. Do not install
a symlink into a checkout's `.build` directory. Verify the copied bytes against
the release product. The public package's installer installs only `agentbuild`;
each private package owns adapter installation.

For a reviewed alternate location, use an explicit absolute override:

```sh
AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE=/absolute/reviewed/agentbuild-example \
    agentbuild example --help
```

Check direct adapter help, routed help, a mutation-free plan, and the actual
managed native workload. Confirm that invocation from a different working
directory still resolves the intended sibling or override and that no stale
binary is selected through `PATH`. Do not add automatic package builds to the
router or project wrappers as a missing-adapter fallback.

Record install and validation evidence in the private project's documentation.
Keep project wrappers compatible with `agentbuild example ...` where useful.
Publish shared library changes and update the adapter's reviewed revision pin
as separate release steps; linking a public library does not publish the private
adapter sources.

# Migration and history

When moving an existing adapter, copy its source, tests, fixtures, and workflow
docs into its private project before removing them from the public tree. Update
resource paths, package-relative fixtures, root command configuration, helper
registration, dependencies, and installers. Retain the established wrapper
arguments and native evidence semantics, then validate the independently built
and installed adapter.

Removing files from the current public tree does not remove previous commits,
release assets, forks, or other historical copies. History cleanup is a separate,
explicitly authorized operation. Do not rewrite history as an implicit part of
adapter extraction.

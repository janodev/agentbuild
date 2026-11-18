---
okf_version: "0.1"
type: Architecture
title: Adapter package boundaries
description: Defines public shared-library ownership and independently installed project adapters.
tags: [architecture, swiftpm, adapters, testing]
---

# Package ownership

The public package builds `agentbuild` and publishes two reusable libraries.
Project adapters are independent Swift packages in their own private project
repositories, using project-specific directories such as `Tools/ExampleBuild`.
The final directory component must differ from dependency identity `agentbuild`,
ignoring case; changing `Package(name:)` alone does not prevent a SwiftPM identity
collision.

| Component | Ownership |
| --- | --- |
| `AgentBuildCore` | Generic compilation admission, native supervision and worker protocols, evidence, repository observations, result parsing, and phase splitting |
| `AgentBuildCLISupport` | Signal relay, current-executable resolution, and the descriptor-only native worker command |
| `agentbuild` | Generic `run`, `doctor`, hidden `_native-worker`, and external-adapter routing |
| `agentbuild-example` | Its project's commands, planning, resource and cache policy, reports, fixtures, tests, and workflow documentation |

Shared modules must not import project adapters or contain project-specific
routes, toolchain policy, resource namespaces, or retention rules. An adapter
must not depend on another adapter. Public library API should express reusable
concepts; exporting a symbol is a compatibility commitment, not a reason to
publish all implementation details.

# Library sharing and executable delegation

Adapters link `AgentBuildCore` and `AgentBuildCLISupport` through a reviewed,
pinned SwiftPM dependency. This is library sharing at build time. Each adapter
has its own executable, dependency resolution, tests, release, and installation
lifecycle. It need not rebuild the generic executable when its project policy
changes.

`agentbuild example ...` replaces the router process with the installed
`agentbuild-example ...` executable. This is executable delegation at runtime,
not dynamic Swift module loading. The public executable does not link or
register project command types. Adding an adapter requires no public source
change or public project-name allowlist.

An adapter root command uses its executable name (`agentbuild-example`), adopts
its project's command configuration, and registers `NativeWorkerCommand` from
`AgentBuildCLISupport`. Native supervision reexecutes the adapter's own resolved
executable; that executable must recognize `_native-worker`. Any additional
private helper must also be registered by its owning adapter root.

Only executable targets have `@main`. A private adapter may keep its commands
in a separate private library target when its tests need to import them.
Neither its library nor its executable is a public AgentBuild product.

# Tests and documentation

Use `make build` and `make test` for this public package. The tests build under
`host:compile` and execute after its release. Public tests cover shared APIs,
generic command behavior, and routing against synthetic adapter executables.
Project fixtures and integration tests stay with the private adapter.

A fixture proving process or controller behavior does not establish that a real
project build, test run, deployment, or UI workflow passed. Each adapter records
native validation and limitations in its own workflow documentation. Keep real
native status and executed-test counts separate from source observations and
report formatting.

See [building an adapter](building-an-adapter.md) for the package skeleton,
routing rules, resource lifecycle, and installation checklist. Deleting migrated
project files from this repository changes the current tree; it does not remove
previously committed content from Git history. History cleanup requires a
separate decision and operation.

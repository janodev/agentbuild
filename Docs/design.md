---
okf_version: "0.1"
type: Architecture
title: agentbuild design contract
description: Public execution, independent adapter routing, ownership, and evidence boundaries.
tags: [architecture, subprocess, agentlease, testing]
---

# Public foundation

`agentbuild` provides generic owned execution, tool diagnostics, and delegation
to independently installed project adapters. `AgentBuildCore` and
`AgentBuildCLISupport` are reusable SwiftPM products. Private projects own their
adapter packages, project policy, tests, fixtures, and workflow documentation;
see [package boundaries](adapter-modules.md).

The package targets macOS 27 or later with Swift tools 6.4 and Swift 6 language
mode. ArgumentParser 1.8.2 and Subprocess 1.0.0 are exact dependencies;
AgentLeaseCore uses a reviewed Git revision.

# Command routing

The built-in surface is `doctor`, explicitly leased `run`, and the hidden
`_native-worker` protocol entry. An external adapter name selects
`agentbuild-<name>`. Resolution first considers the explicit absolute
`AGENTBUILD_ADAPTER_<UPPERNAME>_EXECUTABLE` override, then a sibling of the
current executable resolved through dyld and `realpath`. It does not search
`PATH`, build missing adapters, load plugins, or acquire resource leases.

Names match `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`; built-in names are reserved.
The router validates the name before deriving paths and environment keys,
uppercasing it and replacing hyphens with underscores for the override. Targets
must be executable regular files, not symlinks or the router itself. It drops the leading adapter selector and performs a POSIX `exec`
handoff with the remaining literal arguments. Environment, standard streams,
signals, and inheritable file descriptors retain their normal process semantics.
The adapter becomes the process observed by the invoking shell or supervisor.
An explicit invalid override fails rather than silently selecting another tool.

Root help describes the generic surface. Adapter help is owned by the adapter:
`agentbuild example --help` delegates just like any other adapter invocation.
Project wrappers can retain the `agentbuild <name> ...` interface without
publishing project policy in the shared executable.

# Compilation and installation

Repository Make routes compile under exclusive AgentLease `host:compile`, using
all logical CPU cores by default. Tests build under that gate and execute after
its release. The shared registry defaults to the effective account's home plus
`.agentlease`; inherited `HOME` and checkout `AGENTLEASE_HOME` do not select it.
An explicit `AGENTLEASE_COMPILE_HOME` must be absolute and nonempty, and all
participating repositories must use the same registry. Acquisition failure
must not fall back to an uncoordinated build or another registry.

Installation atomically replaces a copied release executable. It does not
create a command symlink into `.build`. The generic executable and every
adapter install independently. Compatible pinned library revisions govern each
adapter build; sibling executable placement governs runtime discovery. Source,
build products, and installed binaries have independent lifecycles.

# Execution and project admission

Generic `run` uses AgentLeaseCore for acquisition, child environment,
spawn/session configuration, descriptor inheritance, and registry records. It
preserves literal arguments, working directory, raw outputs, and observed
native termination. See the [execution contract](execution.md) for cancellation,
crash, publication, and descendant limits.

The generic layer does not infer project resources, cache compatibility, source
provenance, native route policy, or result custody. Each adapter derives those
facts explicitly. Passing a project command to generic `run` does not create a
managed project workflow. Do not wrap an adapter's already-managed route in
another resource owner unless that adapter explicitly supports adoption.

A project planner observes inputs and describes exact phases and resources
without acquiring leases, creating sessions or caches, doing maintenance,
building, or launching. Observations must identify their unowned and sequential
nature; they are not proof that future execution will use identical inputs.

Execution establishes writer, generated-graph, and compatible-cache ownership
before compilation admission, retaining each for its actual use. Logical test
routes separate build-for-testing from test-without-building so `host:compile`
ends before test execution. Device and UI workflows use one outer device or
desktop coordination boundary spanning their required preparation and teardown.
Adapters define cache/session retention and never infer an inactive lock from
metadata age.

Native termination, executed-test counts, source drift, cancellation, evidence
publication, and ancillary maintenance outcomes remain separate observations.
Raw logs and native result bundles accompany reports; formatting success cannot
replace native success. Tests must establish executed counts and inspect real
native outcomes. Source changes during validation require assessment of the
concrete affected checks, not automatic blanket retesting.

# Diagnostics and evidence limits

Doctor probes required `swift --version`, `xcodebuild -version`, and
`agentlease --version` sequentially in isolated sessions. Each probe has a
ten-second timeout and a 16 KiB limit per output stream. Optional tool presence
is reported without running the tools. It exits `0` only when required probes
succeed, and `1` otherwise. Readiness establishes these probes, not ownership
or a successful project workflow.

Source implementation, fixture coverage, and successful real native execution
are distinct evidence. Shared documentation defines contracts; each private
adapter records its own native validation and known limitations.

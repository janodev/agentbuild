---
type: Architecture
title: agentbuild design contract
description: Current capabilities and the requirements for adding managed build execution.
tags: [architecture, subprocess, agentlease, testing]
---

# Current foundation

`agentbuild` separates a Swift core from its ArgumentParser CLI. It targets
macOS 27 or later with Swift tools 6.4 and Swift 6 language mode.
ArgumentParser 1.8.2 and Subprocess 1.0.0 are exact dependencies; AgentLeaseCore
uses a reviewed Git revision.

The public surface is `--help`, `--version`, `doctor [--json]`, and `run`.
Doctor probes
`swift --version`, `xcodebuild -version`, and `agentlease --version` sequentially
in isolated Subprocess sessions. Each probe has a ten-second timeout and a
16 KiB limit per output stream. It reports optional `tuist`, `simlease`,
`simslim`, `make`, and `git` presence without running them.

Doctor exits `0` only when all three required probes succeed, and `1` otherwise.
JSON output has `schemaVersion: 1`, `toolVersion: 0.2.0`, `stage: bootstrap`,
`ready`, and a `tools` array. Each tool records its name, requirement, resolved
path, status, version, and diagnostic detail. Readiness means these required
probes succeeded. It does not establish project graph, cache, device, build
invocation, or result-bundle ownership. No managed project build route is
implemented yet.

# Compilation and installation

The repository's Make routes build this tool under the exclusive AgentLease
`host:compile` resource, with `SWIFT_JOBS=2` by default. This bootstrap gate
coordinates compilation with other participating repositories. It does not
implement Notika's graph, cache, invocation, or result-custody contracts.
Tests are built under the gate and executed after it is released.

The shared registry defaults to the effective account's home plus
`.agentlease`; inherited `HOME` and checkout `AGENTLEASE_HOME` do not select it.
An explicit `AGENTLEASE_COMPILE_HOME` must be absolute and nonempty. There is
no fallback to a different registry when acquisition fails.

Installation copies a release executable to
`~/.local/opt/agentbuild/bin/agentbuild` and links it from `~/.local/bin`.
Source, `.build`, and installed binary have independent lifecycles. Existing
tools installed as flat executables under `~/Developer/tools` remain usable.

# Owned execution layer

The generic `run` command now reuses AgentLeaseCore for acquisition, child
environment, spawn/session configuration, descriptor inheritance, and registry
records. It preserves literal arguments, working directory, raw output files,
and native exit/signal evidence. Its cancellation and crash fixtures cover
waiting, partial acquisition, direct-child reaping, ignoring descendants,
coordinator death, and publication failures. The
[execution contract](execution.md) specifies these boundaries.

This layer does not infer project resources, compile admission phases, cache
compatibility, or source/result provenance. Do not wrap Notika's managed Python
routes in `agentbuild run`: those routes already acquire their own resources.

Next add one explicit project build route. Port the core invariants and focused
tests needed by that route before exposing it. Acquire graph and compatible
cache ownership before compilation admission, preserve native exit status and
raw evidence, and release compilation ownership before test execution or UI
interaction. A thin forwarding command cannot claim these guarantees.

Notika's existing Python driver remains the reference implementation. Port
bounded components as they become necessary instead of copying its entire
driver into this package. Notika's current today-only retention policy remains
owned by Notika; this foundation does not alter its caches, artifacts, or
retention decisions.

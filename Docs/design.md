---
type: Architecture
title: agentbuild design contract
description: Integrated Swift execution, ownership, outcome, and evidence boundaries for generic commands and project development.
tags: [architecture, subprocess, agentlease, testing]
---

# Integrated controller

`agentbuild` separates a Swift core from its ArgumentParser CLI. It targets
macOS 27 or later with Swift tools 6.4 and Swift 6 language mode.
ArgumentParser 1.8.2 and Subprocess 1.0.0 are exact dependencies; AgentLeaseCore
uses a reviewed Git revision.

The generic command surface is `doctor` and explicitly leased `run`.
The Notika adapter provides read-only planning, generation, the complete closed
54-route native build/test catalog, exact-product macOS interactive launch,
pinned Rust tests, DocC archive/rendering/preview, explicit development
preflight, and cache/session cleanup.
Notika's public Make and `Scripts/notika-dev` compatibility commands enter these
Swift routes. The former Python controller remains a behavior reference for
contract tests, never a runtime fallback or private native Make authority.

Planning observes inputs and prints exact native phases; it does not acquire
leases, create sessions, run automatic maintenance, build, or launch.
Doctor probes
`swift --version`, `xcodebuild -version`, and `agentlease --version` sequentially
in isolated Subprocess sessions. Each probe has a ten-second timeout and a
16 KiB limit per output stream. It reports optional `tuist`, `simlease`,
`simslim`, `make`, and `git` presence without running them.

The separate [ABDiff adapter](abdiff-workflows.md) uses the shared compilation,
native supervision, and raw-capture primitives with explicit ABDiff schemes,
test configurations, and artifact identities. Its Make entry points forward
literal arguments to `agentbuild abdiff`; they do not enter Notika's route or
cache contracts. ABDiff's Simulator workflows use stock SimLease simulators;
physical iPad build/install workflows require an exact hardware UDID and own
that device through deployment without a Simulator or desktop lease.

Doctor exits `0` only when all three required probes succeed, and `1` otherwise.
JSON output has `schemaVersion: 1`, `toolVersion: 0.3.0`, `stage: bootstrap`,
`ready`, and a `tools` array. Each tool records its name, requirement, resolved
path, status, version, and diagnostic detail. Readiness means these required
probes succeeded. It does not establish project graph, cache, device, build
invocation, or result-bundle ownership. Managed project routes establish
project capabilities separately; doctor readiness does not establish them.

# Compilation and installation

The repository's Make routes build this tool under the exclusive AgentLease
`host:compile` resource, using all logical CPU cores by default. This bootstrap gate
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

# Execution and project admission

The generic `run` command now reuses AgentLeaseCore for acquisition, child
environment, spawn/session configuration, descriptor inheritance, and registry
records. It preserves literal arguments, working directory, raw output files,
and native exit/signal evidence. Its cancellation and crash fixtures cover
waiting, partial acquisition, direct-child reaping, ignoring descendants,
coordinator death, and publication failures. The
[execution contract](execution.md) specifies these boundaries.

The generic layer does not infer project resources or source/result provenance.
Notika's adapter explicitly derives those facts using the
[project contracts](project-foundations.md). Other repositories need their own
validated adapters; passing a project command to generic `run` does not adopt
Notika's policy. Do not wrap managed Notika routes in another `agentbuild run`
or `agentlease run` because they already acquire their resources.

Notika execution owns its session writer, graph, cache policy, and compatible
cache before compilation. Logical tests split into build-for-testing and
test-without-building; compilation admission ends before runtime. Exact native
invocations use a one-use ledger and a separate supervised helper. Raw logs,
process retirement, result trees, consumers, and final publication remain under
retained ownership. Native termination, executed counts, source drift,
cancellation, and publication failures are separate observations.

UI and Simulator workflows acquire or adopt one outer SimLease boundary before
project admission. Interactive macOS launch attests the exact newly built
product and keeps the supervisor alive for the app's lifetime. Required UI-test
user scripts and local package product hiding run within owned execution.

The two performance routes use fixed workloads and Swift attachment
interpretation; generic route success does not establish a current performance
measurement. Pinned Rust license/test pipelines own a separate cache namespace.
The DocC adapter runs one fixed docbuild against the ordinary Debug/macOS cache
and copies its admitted archive into the session. Rendered/preview modes
snapshot the renderer and produce a private static site. The loopback preview
reports readiness and retains writer/graph/cache ownership until its native
child retires; only docbuild enters compilation admission. Native DocC and
ancillary rendering/preview outcomes remain separate.

# Preflight and maintenance

Broad test routes run the exact-source/toolchain development preflight and can
reuse its admitted successful receipt. Public `notika run-preflight` uses the
same closed helper/Rust catalog without recursive Make or the former Python
preflight coordinator. Python remains valid inside independent contract tests
and semantic helpers. Native compilation stays within the account gate.

Managed workflows perform executed today-only maintenance before session
admission. Inactive, validated entries used or completed before the current
local day may move to Trash; busy, incomplete, unknown, or invalid evidence is
protected. Explicit `notika cleanup` previews by default and `--execute` performs
the admitted moves. Maintenance reports are ancillary to native outcomes and
never describe Trash bytes as freed disk space. AgentLease registry retention
is a separate lifecycle domain.

Source implementation, fixture coverage, and successful real native execution
are distinct evidence. These documents describe contracts; task-specific
validation records establish which workflows were exercised.

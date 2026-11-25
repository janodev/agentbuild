---
okf_version: "0.1"
type: Documentation Index
title: agentbuild documentation
description: Public execution, adapter routing, shared-library ownership, and authoring references.
tags: [development, build, documentation]
---

# agentbuild documentation

- [Project overview](../README.md) — Generic CLI, libraries, development, and installation.
- [Design contract](design.md) — Public package responsibilities and process handoff.
- [Adapter modules](adapter-modules.md) — Independent package and shared-library boundaries.
- [Building an adapter](building-an-adapter.md) — Minimal Swift package, command registration, installation, and verification.
- [Warm build slots](warm-build-slots.md) — Reuse source paths and DerivedData across worktrees.
- [Owned execution](execution.md) — Locks, subprocesses, cancellation, raw logs, and native outcomes.

Each project's adapter, tests, fixtures, and workflow documentation live in that
project's private package, such as `Tools/ExampleBuild`. They are not distributed
with this public package.

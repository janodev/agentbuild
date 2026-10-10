---
okf_version: "0.1"
type: Documentation Index
title: agentbuild documentation
description: Links development, execution, project-adapter, and retention references for agentbuild.
tags: [development, build, documentation]
---

# agentbuild documentation

- [Project overview](../README.md) - A Swift command-line foundation for coordinated agent build workflows.
- [Design contract](design.md) - Current capabilities and the requirements for adding managed build execution.
- [Owned execution](execution.md) - Lock, subprocess, cancellation, raw-log, and outcome contracts for generic commands.
- [Project foundations](project-foundations.md) - Typed Notika routes, compatible cache identities, compilation phases, and local-day retention policy.
- [Notika workflows](notika-workflows.md) - Swift Make dispatch, generation, native tests, launch, Rust, and documentation routes.
- [Notika daily cleanup](notika-cleanup.md) - Today-only inactive cache/session collection with exclusive ownership and exact-folder Trash moves.
- [Notika performance evidence](notika-performance.md) - Native report validation, attachment identity, and reproduced text/canvas measurements.

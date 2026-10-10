---
type: Agent Instructions
title: agentbuild development instructions
description: Scope, compilation coordination, and validation requirements for the Swift CLI.
tags: [development, agents, testing]
---

# Development

- Start with `Docs/index.md` and `Docs/design.md`.
- Preserve source changes made by the user or another agent.
- Target macOS 27 or later, use Swift 6 language mode, and sort imports alphabetically.
- Use `make build`, `make release`, `make test`, and `make install`. Compilation
  acquires the account-wide AgentLease `host:compile` resource. Keep the default
  two compiler jobs unless a task requires a different setting.
- Use Apple Testing for Swift tests. Do not run SwiftFormat or SwiftLint.
- The current CLI provides diagnostics and generic owned command execution.
  Read `Docs/execution.md` before lifecycle changes. Expose managed build routes only after
  their ownership, cancellation, artifact, and outcome contracts are implemented
  and tested. Notika's Python driver is the reference for those contracts.
- Install a copied release binary under the per-user opt directory. Never point
  the command symlink into `.build`.
- Use OKF metadata for documentation, following the existing documents.

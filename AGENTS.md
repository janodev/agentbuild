---
type: Agent Instructions
title: agentbuild development instructions
description: Public shared-library, routing, compilation, and validation boundaries.
tags: [development, agents, testing]
---

# Development

- Start with `Docs/index.md`, `Docs/design.md`, and `Docs/adapter-modules.md`.
- Preserve source changes made by the user or another agent.
- Target macOS 27 or later, use Swift tools 6.4 and Swift 6 language mode,
  and sort imports alphabetically.
- Use `make build`, `make release`, `make test`, and `make install`. Compilation
  acquires the account-wide AgentLease `host:compile` resource. Keep the default
  all logical CPU cores unless the user requests a different setting. Test
  execution must start after compilation ownership ends.
- Use Apple Testing for Swift tests. Do not run SwiftFormat or SwiftLint.
- This public package owns generic execution, adapter routing, and reusable
  libraries. Project adapters, their tests, fixtures, project names, and workflow
  documentation belong in a project-specific private package, such as
  `Tools/ExampleBuild`. Its final directory component must differ from the public
  dependency identity `agentbuild`, ignoring case.
  Do not add project adapters or project-specific policy to this repository.
- Read `Docs/building-an-adapter.md` when extending the public adapter API.
  Shared code must not import an adapter. Expose deliberately reusable API;
  keep implementation details private or package-scoped.
- Read `Docs/execution.md` before lifecycle changes. Keep native outcomes,
  raw evidence, executed-test counts, source drift, cancellation, and publication
  failures separate. Router handoff must preserve literal arguments, environment,
  standard streams, inherited descriptors, and native process semantics without
  acquiring leases, building adapters, or searching `PATH`.
- Install a copied release binary at `~/Developer/tools/agentbuild`. Never point
  an installed command into `.build`. Adapter installation is independent.
- Use OKF metadata for documentation, following the existing documents.
  Keep README.md free of frontmatter.
- Removing files from the current tree does not remove them from Git history.
  History rewriting is a separate, explicitly authorized operation.

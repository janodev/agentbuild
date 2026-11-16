# Development

- Start with `Docs/index.md` and `Docs/design.md`.
- Preserve source changes made by the user or another agent.
- Target macOS 27 or later, use Swift 6 language mode, and sort imports alphabetically.
- Use `make build`, `make release`, `make test`, and `make install`. Compilation
  acquires the account-wide AgentLease `host:compile` resource. Keep the default
  all logical CPU cores unless the user requests a different setting.
- Use Apple Testing for Swift tests. Do not run SwiftFormat or SwiftLint.
- The CLI provides generic owned execution and the Notika, ABDiff, and Gunship adapters.
  Each adapter owns a separate target and tests under `Adapters/<project>`.
  Read `Docs/adapter-modules.md` before changing target ownership. Adapters must
  not depend on one another; shared layers must not import adapter modules.
  Read `Docs/execution.md`, `Docs/notika-workflows.md`, and the relevant contract
  before lifecycle changes. Keep native outcomes, raw evidence, source drift,
  and publication failures separate. The former Python driver is a test behavior
  reference, not a routine execution fallback.
- For ABDiff integration, read `Docs/abdiff-workflows.md`; keep its routes and
  artifacts separate from Notika's historical cache and evidence schemas.
- Install a copied release binary at `~/Developer/tools/agentbuild`. Never point
  the installed command into `.build`.
- Keep documentation in plain Markdown without YAML frontmatter.

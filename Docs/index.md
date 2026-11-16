# agentbuild documentation

- [Project overview](../README.md) - A Swift command-line foundation for coordinated agent build workflows.
- [Design contract](design.md) - Current capabilities and the requirements for adding managed build execution.
- [Adapter modules](adapter-modules.md) - Separate project targets, shared APIs, per-adapter tests, and one linked executable.
- [Owned execution](execution.md) - Lock, subprocess, cancellation, raw-log, and outcome contracts for generic commands.
- [Project foundations](project-foundations.md) - Typed Notika routes, compatible cache identities, compilation phases, and local-day retention policy.
- [Notika workflows](notika-workflows.md) - Swift Make dispatch, generation, native tests, launch, Rust, and documentation routes.
- [ABDiff workflows](abdiff-workflows.md) - ABDiff's native build/test adapter, generation, cache ownership, and supervised launch.
- [Gunship workflows](gunship-workflows.md) - Gunship's Unreal build, automation, packaging, and packaged-validation adapter, including known ownership and compilation limitations.
- [Notika daily cleanup](notika-cleanup.md) - Today-only inactive cache/session collection with exclusive ownership and exact-folder Trash moves.
- [Notika performance evidence](notika-performance.md) - Native report validation, attachment identity, and reproduced text/canvas measurements.

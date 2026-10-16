---
type: Development Reference
title: ABDiff development workflows
description: Describes the ABDiff adapter, literal Make dispatch, compilation ownership, and native evidence.
tags: [abdiff, xcode, testing, agentlease, workflows]
---

# Commands

```sh
agentbuild abdiff plan --repository /absolute/path/to/ABDiff --route build --json
agentbuild abdiff generate --repository /absolute/path/to/ABDiff
agentbuild abdiff build --repository /absolute/path/to/ABDiff --route build-macos
agentbuild abdiff build --repository /absolute/path/to/ABDiff --route build-ios
agentbuild abdiff build --repository /absolute/path/to/ABDiff --route test-unit-file --file ApplePropertyListInspectionTests
agentbuild abdiff build --repository /absolute/path/to/ABDiff --route test-ui-file --file AppleInspectionUITests --method testIPAPackagesShowApplicationVersionsAndEmbeddedPrivacy
agentbuild abdiff build --repository /absolute/path/to/ABDiff --route test-unit-file --platform ipad-simulator --file IPadHexDiffViewportTests
agentbuild abdiff run --repository /absolute/path/to/ABDiff
```

`plan` observes the selected project and prints native arguments without acquiring
leases, creating cache/session directories, building, or operating a device.
Planning observations are sequential and confer no execution ownership.

ABDiff's `Scripts/abdiff-dev` forwards literal arguments to the copied release
installed at `~/.local/opt/agentbuild/bin/agentbuild`. An explicit absolute
`AGENTBUILD_EXECUTABLE` can select a reviewed candidate for validation. The wrapper
does not compile a missing tool or select an arbitrary executable from PATH.
Its root-owned Make overlay routes routine native work through this adapter and
leaves the pinned `mk` submodule unchanged.

# Project profiles

The macOS app uses the `ABDiff` scheme. The iPad app uses `ABDiffIPad`, with
`ABDiffIPadTests` and `ABDiffIPadUITests` as separate test targets. The iPad scheme
has no test plan. Ordinary builds use Debug; test routes default to DebugUITests,
which enables the macOS UI-test logging configuration. Release remains an
explicit selection. Focused selectors and file/method names travel as independent
arguments, without shell evaluation.

When the repository includes `Tests/ABDiffTextCoreTests`, broad macOS unit and
unit-coverage routes also select that independent kernel target. Focused selectors
may name `ABDiffTextCoreTests/Suite/method()` explicitly. `test-transport` runs
`SemanticControlTransportTests` in the macOS `ABDiffMergetoolTests` scheme under
a desktop lease because its tests launch the real application and CLI.

macOS native routes allow Xcode to refresh the development provisioning profiles
required by the app and its Help downloader extension using the configured Xcode
account. Simulator builds do not require this provisioning step.

The adapter invokes Xcode directly. A test request becomes build-for-testing and
then test-without-building against the same cache and selected tests. Compilation
holds the account-wide `host:compile` gate; runtime executes after releasing it.
A failed build skips runtime. Native exit/signal observations, cancellation,
source drift, and evidence failures retain separate meanings.

# Ownership and device boundaries

Native work owns its session writer, generated graph, cache namespace, and
selected cache before entering compilation admission. Generation owns the graph
exclusively. ABDiff has its own project and artifact namespace; adding the adapter
does not alter Notika's historical identities or result schemas.

macOS build and unit-test routes do not reserve the desktop. UI tests and supervised
app launch enter or adopt one outer SimLease boundary. iPad tests and interactive
launch use the exact simulator ID exported by that boundary. Build-only iPad work
can compile for a generic Simulator destination without booting a device.
ABDiff does not apply SimSlim.

`run` supervises the exact product produced by its build. For a user's ordinary
manual macOS launch, build first, read the successful report's `productPath`, and
open that exact app without reserving the desktop.

# Evidence and installation

Each admitted run retains its own manifest and raw native phase logs. `--json`
provides the final structured report, including the exact product path when one
is available. Callers must check the exit status before consuming a product;
directory age or an older DerivedData bundle does not identify a successful run.
Result bundles from tests belong to their runtime invocation.

Source-drift observations cover ABDiff's Git state, untracked regular files, and
selected generated graph and dependency-lock files. They do not snapshot the
contents of sibling local packages or already-dirty submodule worktrees. A stable
worktree observation does not establish that every dependency remained unchanged.

ABDiff currently retains sessions and compatible caches until explicit manual
maintenance. It does not apply Notika's automatic daily collection. Retire a
session or cache only when inactive and while holding the corresponding exclusive
ABDiff namespace leases; age alone does not establish inactivity.

Install an updated controller with `make install` in the agentbuild checkout.
This builds the release under compilation ownership and copies it to the per-user
opt directory. The command symlink never points into `.build`.

ABDiff's README and agent instructions document its Make shortcuts. Distribution,
notarization, and dependency provisioning are explicit ancillary workflows;
adopting native build coordination does not publish an application.

# Validation record

Validated on 16 October 2026 with Xcode 27.0 and Swift 6.4:

- All 525 AgentBuild tests passed, including the ABDiff planner/CLI contracts and
  the shared capture-integrity regression tests. All nine ABDiff wrapper tests
  passed, including Make's `build-and-test` configuration selection.
- Managed Tuist dependency resolution and workspace generation succeeded
  (`96E5DBF8-9856-4CC0-9996-0160B66A704E`).
- macOS Debug and generic iPad Simulator Debug builds succeeded
  (`F1D9DBBD-416B-4468-9BCB-F677213D62F8` and
  `D015B775-0EAA-478D-862C-B45062D347BD`).
- A parameterized macOS unit-test method passed
  (`875AEBEC-AFB2-4CDD-840A-48E21B98CA87`). The installed release then passed
  one macOS UI test, four iPad unit tests, and one iPad UI test
  (`50555298-98A3-49FE-8905-435F2587A337`,
  `BA71E944-5320-4C17-B79D-61D38234AEA8`, and
  `80840F21-352F-413A-B35C-C2B2A4D2A805`). Private simulators were deleted.

Those build/test sessions retained complete phase captures, reported no source
or tool drift, and had no orchestration or publication failures. Generation
reported its expected graph changes. The native checks are focused route
validation, not a run of ABDiff's entire test suite.

The initial adoption release matched `.build/release/agentbuild`; its SHA-256 was
`f6b276f6293b6092cf6bf936351f56b2320d7d02841635e70f412277e60a98d4`.

The subsequent `assets` merge integration passed all 528 controller tests.
Native validation covered 1,507 macOS unit tests (one opt-in test skipped),
16 iPad unit tests, the three control-transport tests, and the selected parser,
text-merge, hex viewport, footer, localization, and PDF UI tests. The transport
receipt is `CEE9BF93-C84A-4CF2-A677-BF951361097D`; it selects the intended
`SemanticControlTransportTests` suite explicitly.

---
type: Development Reference
title: Gunship development workflows
description: Describes the Gunship Unreal adapter, its compilation boundary, desktop lease, and native evidence.
tags: [gunship, unreal, testing, agentlease, workflows]
---

# Commands

```sh
agentbuild gunship plan --repository /absolute/path/to/Gunship --engine /absolute/path/to/UE_5.8 --action package --archive /absolute/archive
agentbuild gunship build --repository /absolute/path/to/Gunship --engine /absolute/path/to/UE_5.8
agentbuild gunship build --repository /absolute/path/to/Gunship --engine /absolute/path/to/UE_5.8 --target Gunship --configuration Shipping
agentbuild gunship test --repository /absolute/path/to/Gunship --engine /absolute/path/to/UE_5.8 --filter Gunship.Zombies+Gunship.Sensor
agentbuild gunship package --repository /absolute/path/to/Gunship --engine /absolute/path/to/UE_5.8 \
  --map /Game/Gunship/Maps/L_Defense_Blockout --archive /absolute/archive
agentbuild gunship validate --repository /absolute/path/to/Gunship --scenario zombies --archive /absolute/archive
```

`--engine` defaults to `GUNSHIP_UNREAL_ENGINE`. Validation runs an existing
archive and does not need an engine. Gunship's `Scripts/gunship-dev` supplies
its repository and default engine, then forwards literal arguments to the
installed release at `~/Developer/tools/agentbuild` (or an absolute
`AGENTBUILD_EXECUTABLE`). Both `--archive path` and `--archive=path` accept
relative paths through the wrapper and preserve literal arguments.

`plan` resolves the repository, engine, and archive and prints each native
phase without acquiring leases, creating a session, or running Unreal tools.

# Routes and phases

The adapter runs Gunship's own scripts with `/bin/zsh -f`, so the Unreal
workarounds they contain (the deferred Xcode bundle step, loose cooking before
IoStore) keep a single source. Each script receives explicit `GUNSHIP_*`
values; the caller's other `GUNSHIP_*` variables are not inherited.

| Route | Phases (`*` holds `host:compile`) |
| --- | --- |
| `build` | `build_macos.sh <target>`* |
| `test` | `build_macos.sh GunshipEditor`*, `test_macos.sh` |
| `package` | `build_macos.sh GunshipEditor`*, `build_macos.sh Gunship`*, `package_macos.sh` with `GUNSHIP_SKIP_BUILD=1` |
| `validate` | `validate_<scenario>_macos.sh` (`slice` runs `validate_macos.sh`) |

The Unreal Build Tool build phases hold the account-wide `host:compile` gate,
including the build wrapper's bundle finalization.
Cooking, staging, headless automation, and packaged gameplay run after its
release. This boundary does not prevent AutomationTool script compilation; see
[Known limitations](#known-limitations). A failed phase skips the rest.

The editor target builds Development only. `--configuration Shipping` applies to
the game target and to packaging, whose product becomes
`Mac/Gunship-Mac-Shipping.app`. Test filters are automation paths joined by `+`;
the default is `Gunship`. Package maps are `/Game` package paths joined by `+`.
Validation accepts one map. The `slice` harness uses `L_Apron` and rejects
explicit map overrides.
Scenarios are lowercase script stems; values reach the scripts as literal
environment data, never as shell text.

# Ownership

Every route holds `gunship:sessions:<repository>` shared. Build, test, and
package hold `gunship:workspace:<repository>` exclusively: Binaries,
Intermediate, cooked content, and the editor's derived data form one build
tree. Package and validate also hold `gunship:archive:<archive>` exclusively.
The archive path is resolved through existing symlinks, so two spellings of one
directory share a lease. Dangling symlinks are rejected until their destinations
exist; ordinary missing output directories remain valid. An archive cannot contain
the repository.

Package and validate refuse an archive whose executable is running, such as a
game someone is playing, before waiting for leases, after admission, and immediately
before the package or validation phase. This catches a game opened during the
preceding compilation. Manual launches do not acquire these cooperative leases,
so the check cannot prevent a launch after the last check. Choose a new archive
directory when an existing build may be opened during packaging.

Validation needs the desktop. Outside a SimLease session the command
re-executes itself under `simlease macos-ui` with `caffeinate -dimsu`; inside
one it requires `SIMLEASE_MACOS_UI=1` and the `macos-ui` host resource.
Gunship's validation scripts see that boundary and do not lease again. Other
routes never reserve the desktop.

Each native phase starts an isolated process session and retains its leases until
the leader has exited and no live workers remain in that session. Unreal workers
that start their own process group remain within this session. Cancellation escalates only
the pinned leader's group; workers in other groups must exit before ownership can
be released. A stalled worker can therefore keep the run waiting. A descendant
that creates a new session is outside this retirement guarantee. Phase reports
record `retirementScope: session`.

# Known limitations

- **Manual launches can race the archive check.** Finder and other unmanaged
  launchers do not acquire the archive lease. A game can start after the final
  idle check while packaging replaces that archive. Use a unique archive
  directory for each package and keep builds that may be opened at separate
  paths. Stronger coordination requires every launcher to participate in the
  same lease protocol; the current adapter does not provide such a launcher.
- **Workers can escape by creating another process session.** Changing only
  the process group is covered, but calling `setsid` or an equivalent operation
  leaves the supervised session. A worker that also closes inherited lease
  descriptors can survive after ownership is released. The adapter does not
  discover or terminate these escaped workers. Covering them requires additional
  lifecycle control for the engine or tool that launches them.
- **A stuck worker can keep cancellation waiting.** Cancellation escalates
  signals only to the pinned original process group. Other groups within the
  session must exit before leases can be released, so cancellation has no fixed
  completion deadline. `--wait-seconds` limits lease acquisition, not worker
  retirement or cancellation. A stalled worker or crash reporter may require
  manual recovery of that specific process. The adapter does not release ownership on
  a timeout or kill processes by name. Automatic termination of those workers
  would require a safe process-identity and ownership mechanism.
- **Source-engine packaging can compile UAT outside the gate.**
  `GUNSHIP_SKIP_BUILD=1` skips the wrapper's target builds, and UAT's `-skipbuild`
  skips the game build. Neither disables AutomationTool or script-module
  compilation. Source engines can rebuild AutomationTool and stale script
  modules during the package phase outside `host:compile`. Installed engines
  suppress engine module compilation, but this is not a guarantee against project script-module
  compilation. If all compilation must hold `host:compile`, the workflow needs
  a separate gated UAT/script preparation phase followed by packaging with that
  compilation disabled. The adapter does not currently implement this split.

These are limits of the current ownership and compilation boundaries. Passing
controller tests does not establish that a particular Unreal workflow is free
of them. The [native verification record](#native-unreal-verification) establishes
the routes and configuration actually exercised; the limitations above remain.

# Evidence

Each run owns `Artifacts/AgentSessions/<run-id>` inside the repository, which
Gunship's Git ignore rules must exclude; planning rejects a repository that does
not. The session holds raw stdout, stderr, and combined logs for every phase,
`in-progress.json`, and the terminal `manifest.json`.

- `test` exports Unreal's report to `Automation/` in the session. The manifest
  records succeeded, warning, failed, and not-run counts and the failed test
  paths, including when the native run failed. Success also requires a
  nonempty run with no failures and nothing left unrun.
- `package` records the product path and the SHA-256 of its executable.
- `validate` writes scenario evidence to `Evidence/` in the session and records
  every `Saved/Validation/*/report.json` it finds, with its checks and failed
  check names. Success also requires at least one report and all reports
  passing. The archive executable is hashed before and after the run.

Source observations hash Git state and every untracked, unignored file before
and after the run. Gunship keeps most of its project untracked, so this covers
`Source`, `Config`, `Content`, and `Scripts` contents. Any change makes the
outcome inconclusive (status 70); there is no allowance list. Tool observations
cover the engine's `Build.version`, the selected developer directory, and
`xcodebuild -version`.

Native exit or signal, cancellation, source or tool drift, evidence failures,
and publication failures keep separate meanings, as in the
[execution contract](execution.md). A received CLI cancellation signal is frozen
before terminal publication and recorded as `cancellationSignal`; the manifest,
JSON, human output, and process exit use `128 + signal`. The observed native
termination remains separate. Library task cancellation without a CLI signal
uses status 130 when no native failure was observed.
Sessions are retained until manual
retirement while holding the corresponding Gunship namespace leases.

# Validation of review fixes

On 7 November 2026, `make test` passed all 592 tests in 59 suites, including
session retirement on native exit, cancellation, owner EOF, and helper death.
The six Gunship wrapper tests also passed. Both archive argument forms produced
identical read-only plans against the real project without creating an archive
or session. These are controller and fixture checks. The subsequent real Unreal
runs are recorded below.

# Native Unreal verification

On 7 November 2026, the candidate Debug controller ran all four routes against
Gunship on an Apple M5 Pro, macOS 27.2 (26B123), Unreal Engine 5.8.3
(58210709), and Xcode 27.2 (27B52), using the Mac 27.2 SDK. Targets were arm64
Development. Commands entered through `Scripts/gunship-dev` with
`AGENTBUILD_EXECUTABLE` selecting the checkout's `.build/debug/agentbuild`.
The controller was not installed. Its SHA-256 was
`d751efa6723e42a07831383b0c049ffd230399639a5819bd729ab2f80cb30aee`.

Reports below are local retained evidence in the sibling Gunship checkout.

| Route | Session manifest | Observed result |
| --- | --- | --- |
| `build` | [5AE89FD7-9543-42EE-ABE4-C720FEBBA0BA](../../Gunship/Artifacts/AgentSessions/5AE89FD7-9543-42EE-ABE4-C720FEBBA0BA/manifest.json) | Editor build passed; incremental, up to date, zero actions. |
| `test --filter Gunship.Zombies+Gunship.Sensor` | [80A4CCD8-E8A5-408E-A35A-F9976B669559](../../Gunship/Artifacts/AgentSessions/80A4CCD8-E8A5-408E-A35A-F9976B669559/manifest.json) | All 10 expected tests passed; warnings, failed, not-run, and in-process counts were zero. |
| `package --map /Game/Gunship/Maps/L_Defense_Blockout` | [209D1F3A-E4CE-404E-AEF1-057ACE8B4D7F](../../Gunship/Artifacts/AgentSessions/209D1F3A-E4CE-404E-AEF1-057ACE8B4D7F/manifest.json) | Both target phases passed; game build completed 93 actions, followed by successful cooking, staging, archiving, and signature verification. |
| `validate --scenario zombies` | [4BA308BE-20C1-4449-BC8A-3C10C59179D8](../../Gunship/Artifacts/AgentSessions/4BA308BE-20C1-4449-BC8A-3C10C59179D8/manifest.json) | Completed 34 passing checks and 12 decoded 1920x1080 screenshots, including color and IR frames. |

All four terminal reports recorded status `succeeded`, exit zero, complete raw
captures, no source or tool drift, and no orchestration or publication failures.
Independent inspection matched the raw stream sizes and hashes, automation and
scenario reports, and all 12 retained PNGs to their recorded evidence.

The new package is
`Gunship/Saved/Packaged/AgentBuild-20261107T134306Z/Mac/Gunship.app`.
Its executable SHA-256 was
`66bc7a6e47eee567faa0838037dc34a2486dd29f68b8757e87ca52b4018cf3aa`,
matching both validation observations. The
[scenario report](../../Gunship/Artifacts/AgentSessions/4BA308BE-20C1-4449-BC8A-3C10C59179D8/Evidence/20261107T134720Z-88152/Saved/Validation/Zombies/report.json)
records `GunshipZombieTest` on `L_Defense_Blockout`, completion, hardware-input
isolation, all checks passing, and all expected screenshots present.

Lease observations recorded `host:compile` held during the game build and free
during headless automation, UAT cooking/staging, and packaged gameplay. Archive
ownership remained held during validation. UAT's later Xcode Stage/Package
commands performed bundle copying, plist processing, and signing; their logs
contained no C++ or Swift compile/link actions. Validation entered one SimLease
macOS UI boundary (`FA612A8A`), and the desktop lock was independently checked
free after exit. Archive, workspace, and compilation resources were also free;
no verification game, editor commandlet, or native helper remained running.

The observation bundle is retained at
`Gunship/Saved/AgentBuildVerification/20261107T134306Z/`, including route JSON,
candidate identity, lease observations, the SimLease transcript, and
`summary.json`. These runs establish the supported installed-engine Development
path; they do not verify Shipping, source-engine packaging, every validation
scenario, or a broad run of all Gunship tests. The zombies run used its opt-in
review harness with health, spawn, and schedule overrides recorded in the report.

The crowd frame window observed 589 samples with 36-40 zombies: 20.39 ms mean,
23.38 ms p95, and 49.05 fps. The report explicitly records
`meets_60fps_target: false` and labels this window as not a controlled benchmark.
The functional pass does not establish the 60 fps target. The runtime also
retained a pre-existing warning that `MI_PolygonMilitary_01_A` lacks
`InstancedStaticMeshes` usage and falls back to the default material. This
verification does not establish pristine scene materials.

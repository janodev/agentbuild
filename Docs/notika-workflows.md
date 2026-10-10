---
type: Development Reference
title: Notika development workflows
description: Describes Swift-controlled Make routes, native execution, result evidence, and supervised interactive sessions.
tags: [notika, xcode, testing, agentlease, workflows]
status: implemented
---

# Commands

```sh
agentbuild notika generate --repository /absolute/path/to/Notika
agentbuild notika build --repository /absolute/path/to/Notika --route build-macos
agentbuild notika build --repository /absolute/path/to/Notika --route test-unit-file --file SomeTests
agentbuild notika build --repository /absolute/path/to/Notika --route test-unit-focused --only-testing 'SomeTests/someMethod()'
agentbuild notika build --repository /absolute/path/to/Notika --route build-ios
agentbuild notika run --repository /absolute/path/to/Notika
agentbuild notika run-rust-test svg --repository /absolute/path/to/Notika
agentbuild notika run-preflight --repository /absolute/path/to/Notika
agentbuild notika run-docs archive --repository /absolute/path/to/Notika
```

These commands use the Swift project adapter. They run admitted native phases
directly. `build` aliases the ordinary macOS build;
`test-xcode-file` aliases `test-unit-file`. Repeat `--only-testing` to select a
batch of Swift Testing suites or methods. Selectors are literal argument data.

Notika's root Make routes dispatch through `Scripts/notika-dev`, a literal-argv
Bash entry point for the installed Swift executable. The root-owned Make overlay
contains the closed build/test route inventory; it leaves the pinned `mk`
submodule unchanged. Routine generation, build, test, launch, Rust, and artifact
maintenance use this controller. Python implementations remain reference tests
and independent helper contracts.

`AGENTBUILD_EXECUTABLE` can select an absolute reviewed executable while testing
a new release. Normally the wrapper uses
`~/.local/opt/agentbuild/bin/agentbuild`. It never bootstraps a tool build or
falls back to the old controller when that binary is absent.

Use Notika's Make shortcuts for routine work:

```sh
make generate
make build-macos
make test-unit-file FILE=NotebookTemplateMetadataTests
make run-macos
make maintain-artifacts
```

The Swift build adapter covers the closed 54-route catalog and aliases,
including broad/focused tests, visual tests, coverage exports, and the two fixed
performance workloads. Planning is read-only and does not prove execution.
Broad test routes first run or reuse the exact-source development preflight;
focused tests avoid that broad prerequisite.

# Ownership and evidence

Generation holds the shared session-writer resource and exclusive graph
resource. It runs the two fixed preparation scripts, moves the checked prior
project/workspace entries to Trash, and invokes `Scripts/tuist generate --no-open`
under account compilation admission. `--cached` sets `USE_CACHED_DEPENDENCIES=1`
for Tuist. Generation retains separate raw phase logs and a closed lifecycle
report; it does not claim an Xcode build or graph-freshness receipt.
After preparation, all prior graph entries are checked before the first Trash
operation, then each is checked again immediately before its move. The exact
owned `xcshareddata/swiftpm/configuration` directory supports Xcode's permissive
permissions; that exception does not admit links or relax other paths.

Generation exposed a moved upstream PhononCoreML `1.1.1` tag. Notika's local
Phonon package pins its already recorded revision
`464ae57460fed61d4feb6f2a7424b5be1213accb`, which the regenerated
`.package.resolved` retains exactly.

The adapter holds a shared session-writer resource, shared generated graph,
shared cache-policy resource, and exclusive compatible cache. It validates
workspace and cache bindings before native execution. Compilation acquires
the account-wide `host:compile` gate last and releases it before test runtime
or result inspection. A borrowed directory descriptor binds the native
working directory; a copied pathname does not replace that capability.

A logical test has separate `build-for-testing` and `test-without-building`
phases. A failed build skips runtime. The result bundle belongs to this
session and exact runtime invocation. Apple's first summary read can create
SQLite indexes at the result root. A supervised preparation phase permits only
those fixed index additions while watching the original payload. After it
finishes, the driver seals the complete result tree and reuses that captured
summary. Later result consumers must leave the sealed evidence unchanged.
Passing unit results require actual, nonempty passing counts with no failed
tests. A parameterized Swift Testing method can execute several cases.

Each native phase retains stdout, stderr, and a combined raw log. The combined
log preserves the order in which capture reads the two pipes; separate pipes
cannot establish a total order of the child's writes. Capture budgets the
original output once, up to 64 MiB, and the combined file mirrors its retained
bytes. All three files require pinned custody, matching sizes and digests, EOF,
and publication revalidation. Overflow or any log failure makes capture
incomplete while the pipes continue draining through worker retirement.

Historical retention readers can admit an older closed record with only the
two original streams. They record combined evidence as unavailable. Current
publication and result consumers require the combined file.

Raw logs, actual native termination, executed counts,
source/tool observations, cancellation, and publication errors appear in the
session report. Native failure takes precedence over later evidence errors.
Native success with missing, empty, changed, or unreadable evidence is
inconclusive rather than a passing test run. Source drift is reported separately
from the observed native outcome.

# Interactive and device ownership

UI and iPad simulator routes enter one outer SimLease supervisor before project
ownership. An inherited valid boundary is honored without nesting. Simulator
commands target only its exported `SIMULATOR_ID`; functional workflows run
SimSlim first. Performance workflows retain system services.

`notika run` builds and starts the exact admitted macOS product. It publishes
the actual process identity and application raw-log paths when the app is
running, then remains alive until the app exits. The outer macOS UI lease,
session writer, graph, and cache stay owned throughout that lifetime. A running
receipt is a launch observation; it is not a terminal successful session.

Rust families run their fixed license check and Cargo commands under shared
graph, Rust policy/cache, and account compilation ownership. Their reports use a
separate strict namespace and retain actual raw output and termination.

`notika run-preflight` exposes the same exact-source reusable development gate
without a fabricated Xcode request or a recursive Make invocation.

`notika run-docs archive|rendered|preview` builds DocC under compilation
admission, then snapshots the archive into its session. Rendered output uses the
configured renderer tree and Swift's bounded copy/overlay operations. Preview
serves that retained site on loopback while writer, graph, and cache ownership
remain live. A failed renderer or preview never turns a successful docbuild into
a successful documentation workflow; both outcomes remain in its report.
Preview readiness follows whole-site verification, bounded by 250,000 entries,
2 GiB, and 64 levels. Cancellation or helper retirement ends the readiness wait.

Generic `agentbuild run` must not wrap these managed Notika routes: they already
own their resources. Imported result paths, copied JSON receipts, source
observations, and environment markers do not confer live lease authority.

# Validation record

On 10 October 2026, the full Swift controller suite passed 494 tests in 49
suites in 126.604 seconds in
[batch 43](../Untracked/Validation/project-foundations-tests-43.log).
Actual Notika sessions also established the following results. Reports are
initially published under Notika's `Artifacts/AgentSessions/`.

| Session | Workflow and result |
| --- | --- |
| `22A680D0-C64C-472F-A5D2-D3FD83E310A4` | macOS build: native exit 0, succeeded session |
| `2E618D82-23B3-45DD-BF88-E50F933724FE` | Focused `NotebookTemplateMetadataTests`: native exit 0, 9/9 passed, no failures, result publication admitted |
| `30FA337E-860A-41FF-ADA6-A4E5B27A2435` | Generation: native exit 0, complete admitted generation report |
| `F44D28C2-BCCA-4E64-88DD-A48F482B4DCC` | macOS launch: native build exit 0; user confirmed the Documents window; user-requested close completed with app and workflow exit 0 |
| `C8036C09-DAE0-4E78-A156-0F2932D34A35` | SVG Rust tests: native exit 0, 46/46 passed |
| `1DE6E295-A2C2-4870-9A8A-F1AED47E594A` | LiteParse Rust tests: native exit 0, 6/6 passed |
| `1A3A73EF-C846-495B-BF69-02565BDDBBA9` | Regeneration after merging BugFixing's MDVault update: all five native phases exited 0; publication admitted |

The updated release installation passed with version `0.3.0` at
`~/.local/opt/agentbuild/bin/agentbuild`; its command link and tool doctor passed.
The installed regular executable has mode `0755` and matches the built release
SHA-256 `946f73461a4cbb6aec5bdc611a270023c0bdf3af7faf04750e4325f7dd99afc7`.
The Make compilation default now uses `hw.logicalcpu` (12 on this Mac), matching
the user's all-core preference.

The iPad creation check, `0DF2A751-257A-47BD-889A-3BA3C744013C`, passed with
native exit 0, one executed/passing test, admitted results, and no source or
toolchain drift. It retained the selected paper-guide spacing after notebook
creation. SimLease deleted its private iPad Air simulator after completion.

DocC session `A6AB7234-B282-4F90-B45E-3DB6117A9CFE` completed its native build
and transform with exit 0. The actual preview served HTTP 200 for HTML and a
3.76 MB data response identifying Notika. Controlled server cancellation returned
130; the final manifest and stdout, stderr, and combined captures were complete.
Closing identities were unavailable after cancellation, so this run does not
prove absence of source or toolchain drift.

The final integrated preflight passed on 11 October 2026 in session
`FF01BA0F-884F-4404-813B-FEFB260E66E7`: 19 logical checks and 21 native phases,
all with exit 0, complete stdout/stderr/combined capture, and admitted final
publication. Python reference/helper suites reported 1,016 passing tests and
three skips; Rust reported six LiteParse and 46 SVG tests passing, with no
failures or ignored tests. The 428-test controller reference suite passed in
411.372 seconds.

An immediate invocation, `0503D0AE-B5FA-4E17-8D3C-C0C488FB7263`, reused the
same passing receipt with zero native phases. Both invocations completed with
exit 0 and no orchestration or publication errors. They tested Notika commit
`d01f2e1b0` with installed controller source commit `df81b35`; later changes to
this validation record are documentation-only. The receipt key was
`bf271f4ecdc933a833abcccd449ce590abc3bda9c1566127fa7ec80bfb061c4f`.

The installed release includes combined raw capture, historical terminal
admission, and cancellable preview readiness. Native execution was validated
for the listed workflows.
Session evidence remains subject to the documented daily retention policy.

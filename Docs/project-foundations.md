---
type: Implementation Contract
title: Project workflow foundations
description: Defines the integrated Notika controller's request, identity, compilation, lifecycle, publication, and retention boundaries.
tags: [notika, agentlease, xcode, cache, retention, testing]
---

# Adoption boundary

The 0.3 Notika adapter adopts these components for all 54 closed native routes,
generation, exact-product macOS launch, DocC archive/rendering/preview, direct
SVG/LiteParse tests, development preflight, and today-only cache/session
maintenance. Notika's public Make routes
and compatibility wrapper dispatch to the installed Swift executable. Native
execution does not call private Make authority or fall back to the former Python
controller, which remains a behavior reference for contract tests.

`notika plan` prints source/tool observations, requested resources, and physical
phases without acquiring ownership, creating files, or running maintenance.
Execution consumes admitted plans beneath live ownership; plans alone do not
establish a native outcome.

Notika-specific route and compatibility vocabulary is an explicit adapter.
Other projects need their own validated profiles. Generic command execution
does not infer these project facts or automatically acquire compilation admission.

# Requests and identities

`NotikaActionRequest` validates the current closed route catalog, platforms,
file/method selection, native Swift Testing signatures, ordered selectors,
interactive mode, and documentation mode. CLI convenience construction applies
the existing platform/device defaults. Raw request construction preserves the
original request validation. Make selector transport uses canonical `%20` and
`%60` escapes; it never evaluates a selector as shell code.

`NotikaXcodeInvocationPlan` derives the exact ordered logical invocations for
all current Make routes and aliases, including fixed selectors, performance
settings, and coverage. Raw focused UI and interactive requests use their
reference effective routes. DocC has a separate pipeline. These immutable plans
preserve literal UTF-8 paths and arguments; their equality does not normalize
Unicode. The native executor can consume them directly, without asking private
Make recipes to reconstruct them.

`CacheCompatibilityIdentity` validates the complete Notika compatibility
material before hashing it. Source HEAD, diffs, and untracked file observations
are separate from this material. Exact execution retains the generated graph
and selected scheme. Current storage omits project, generated graph, dependency lock, gitlink, and
submodule fingerprints and
normalizes ordinary Debug app/UI scheme pairs, provided no purpose is present.
Xcode handles incremental invalidation when project or dependency inputs change.
Performance schemes, configurations, flags, toolchains, and
worktrees retain their separate identities.

Xcode usage metadata versions 1, 2, and 3 retain their historical cache keys.
Version 4 uses stable worktree/toolchain/build-profile storage keys. Exact
execution identities still retain every project and dependency fingerprint.
Adopting version 4 selects a new directory once; older caches remain readable
under their original schemas and are not relocated automatically. Accepting
a historical key still requires the exact admitted execution digest.
Resource names retain Notika's existing graph, policy, and cache prefixes so
historical retained evidence binds the same kernel-lock namespace. Independent
reference fixtures may exercise those contracts without becoming live routes.

`CanonicalJSONDigest` matches the Python identity encoding: sorted scalar keys,
compact separators, unescaped Unicode, and integer-only numbers. Strings keep
their original UTF-8 spelling; differently composed Unicode is not substituted.
Member arrays can represent distinct Unicode spellings that Swift dictionary
keys would otherwise merge. Duplicate raw keys and excessive nesting are
rejected. This encoder is not a strict evidence-file reader; bounded reads,
duplicate-key parsing, and descriptor admission remain separate responsibilities.

`NotikaRepositoryIdentity` observes Git HEAD, raw status/diffs, untracked inputs,
submodule worktrees, authored/generated graph inputs, and dependency locks.
Toolchain probes retain the pinned Tuist wrapper and resolved tool binary hashes.
`RepositoryCommandCapture` returns complete raw bytes or fails on overflow,
timeout, or cancellation; it never hashes a truncated prefix. Defaults are
64 MiB stdout, 64 KiB stderr, and 30 seconds per command. File hashing streams
through a regular, nofollow descriptor. Source snapshots are sequential
observations, not an atomic freeze or custody proof. Source drift remains
independent of native build/test outcomes.

# Compilation phases

`NotikaProjectAdmission` acquires a shared generated graph, shared cache policy,
then exclusive compatible cache. Generation acquires an exclusive graph alone.
Each layer uses the established resource name and kernel lock. A positive
wait budget covers the complete acquisition/publication sequence; zero permits
one immediate attempt per layer. Cancellation and errors unwind earlier layers
in reverse order. Shared app/UI profiles own the same current cache, while an
explicit historical key must still be admitted by the exact execution profile.

Project ownership is borrowed inside its async scope. The caller must own its
session writer first, validate physical cache bindings, and await workload
retirement before returning. This component does not publish run records, prove
filesystem custody, or supervise a killed coordinator itself.

`HostCompilationAdmission` selects the effective account's home plus
`.agentlease`, ignoring `HOME` and checkout-local `AGENTLEASE_HOME`.
`AGENTLEASE_COMPILE_HOME` must be a nonempty absolute path; an invalid override
does not fall back. AgentLease performs safe registry admission and acquires
exclusive `host:compile` ownership. The returned capability is borrowed only
inside its async scope. Scope exit closes references without `LOCK_UN`, and
an escaped capability cannot obtain descriptors after release.

The project owner must acquire graph and compatible cache custody first and
await complete child teardown inside the compilation scope. Inherited
descriptors preserve admission while a surviving child retains them.
Contention diagnostics and metadata write issues are available to the owner.
This scope does not publish a project run record or artifact manifest itself.

`XcodeExecutionPlan` parses the managed route option vocabulary and derives
physical phases from one already-authorized argument array. Unknown option
arity fails before execution; keyword-valued schemes and settings retain their
literal values. A logical `test` becomes `build-for-testing`, then
`test-without-building`. Only runtime receives the result-bundle path.
Each phase preserves the original selectors, destination, cache, and settings.
Plans are descriptions, not invocation authority or execution evidence.

`XcodePhaseRunner` executes these phases sequentially beneath the caller's
project ownership. It releases compilation admission before runtime and stops
on the first observed native nonzero exit or signal. The operation must reap
its direct child before returning. Driver errors remain thrown errors rather
than synthetic native termination; the project journal must retain the
observed outcomes and any failure independently.

`NativeInvocationLedger` admits one exact physical phase at a time, in logical
invocation and phase order. Its opaque claims belong to one actor and are
consumed once. Changed arguments, skipped/repeated phases, concurrent claims,
and foreign claims fail. Completion records observed native termination,
cancellation, and ancillary failure separately. Native failure takes precedence;
an unobserved child never gains a synthetic native result. This is in-process
admission state, not filesystem or subprocess custody.

# Strict artifact parsing

`RetainedArtifactDirectory` pins each nofollow ancestor. `RetainedArtifactFile`
reads a bounded regular file through its retained descriptor, checks owner,
permissions, link count, nanosecond metadata, and name bindings before and
after reading. Paths alone are not admitted evidence. Closed schemas use
`StrictJSONDocument`; a successful parse alone does not establish custody.

`StrictJSONDocument` retains the original bytes and digest while parsing within
byte, depth, and value-node limits. Duplicate decoded UTF-8 keys, invalid UTF-8,
malformed escapes, trailing content, and nonfinite floating-point values fail.
Object members and schema lookup preserve distinct Unicode spellings. Integer
tokens retain their full spelling until a schema performs a checked conversion.
Lone surrogate escapes are rejected because Swift strings require Unicode
scalars. This parser does not establish descriptor custody or admit a manifest;
schema bindings and pinned file observations remain the caller's responsibility.

# Native execution and raw output

`DarwinWorkloadSupervisor` uses checked Darwin spawn attributes and an explicit
descriptor whitelist. The native workload gets its own process group. The
worker pins its leader until descendants stop, escalates cancellation, and
reaps the leader before returning. Closing borrowed lock references never
performs `LOCK_UN`.

`NativePhaseSupervisor` launches a separate helper with a sole owner-pipe
writer in the coordinator. Owner EOF makes the helper retire unfinished work.
A nonce and request digest bind its bounded receipts. Missing receipts cannot
invent native success; retained lock references remain quarantined until
independent process-group quiescence is established. An unknown native PID
requires manual recovery rather than releasing ownership on a guessed timeout.

`NativeLogCapture` drains stdout and stderr separately into private raw files.
The combined default limit is 64 MiB. Overflow and write failures request
retirement and continue draining; a retained prefix remains incomplete.
Complete logs retain mutation watches and descriptor/name/digest checks through
publication. `CapturedNativePhaseRunner` waits for both native retirement and
pipe EOF, then returns a capsule that keeps these checks alive.
Shared session-root watches allow new sibling phase folders and publication
files. Private capture directories and sealed result trees still reject link
or content changes; expected sibling creation is not evidence tampering.

`NotikaOwnedNativeExecutor` consumes the exact invocation ledger under live
project ownership, acquires compilation admission only for compile phases,
and strips inherited private authority from its child environment. Its
operation must return only after helper retirement and raw draining. Actual
native termination, cancellation, missing results, and driver failures remain
separate observations.

# Cache and generation custody

`NotikaCacheUsageRecord` validates versions 1–4 against their respective cache
keys, exact profile, repository, directory inode/device, owner and lifecycle.
Its timestamps use checked Gregorian integer arithmetic before daily policy.
The inode must always match. A volume receives its device number when it
mounts, so a restart can renumber it: a stored device number may differ only
when the record was last written before the current kernel boot
(`DirectoryIdentityBoot`). Rust usage records and session-retention bindings
apply the same rule.
`NotikaCacheCustody` requires live graph/policy/cache ownership and pins the
fixed same-user cache ancestry. Atomic usage updates preserve a valid cache's
original creation timestamp; invalid existing metadata is not overwritten.
This publisher does not collect caches.

`NotikaGenerationCoordinator` holds the exclusive graph through artifact
preparation, retirement of the two fixed generated graph entries, pinned Tuist
generation, workspace validation, and final source observation. Preparation
must pass before an old graph is retired. Generation does not acquire
`host:compile`; its exclusive graph ownership still prevents concurrent use or
regeneration of the same checkout.
The caller supplies supervised command and Trash operations; no freshness stamp
is inferred from the presence of a workspace.

# Session publication

`NotikaBuildSession` acquires the shared session-writer lease before any project
lease and creates a private UUID directory. It publishes separate immutable
in-progress and terminal reports using a closed Swift schema. Read-only
descriptors, both hardlink names, and mutation watches retain the sealed bytes.
The terminal report binds request, source/tool observations, compatibility,
physical phases, observed native results, and retained raw capsules.
Production publication also binds each complete capsule's actual executable,
literal arguments and working directory to its admitted Xcode phase. Reports
retain the actual command and an environment digest. Package fixtures can use
an internal substitute executor; their reports explicitly label that command
admission as a trusted package fixture and do not establish native Xcode execution.

Source or tool drift after native exit zero yields an inconclusive driver
status while retaining native zero. A native failure keeps its actual code.
If complete raw evidence mutates, diagnostic fallback marks it unadmitted and
cannot produce success. Session publication must finish and revalidate before
the shared writer lease is released. This is the native build/test schema.
Interactive, generation, Rust, documentation, and preflight workflows
publish their own closed lifecycle reports; each binds its actual command,
source observations, raw capture, and native outcome rather than borrowing the
meaning of a different workflow's schema.

Result-producing routes bind the runtime invocation to a retained `.xcresult`
tree and complete native summary. Coverage and summary consumers run against
retained directory descriptors and publish admitted report artifacts. Fixed
Text and Canvas performance routes validate exported attachment identity and
interpretation independently before publication. An attachment or report error
can prevent evidence success without changing an observed native exit/count.
Interactive launch publishes an exact-product running receipt, retains live
project ownership while the app runs, and publishes terminal evidence only
after supervised retirement.

# Documentation pipeline

`notika run-docs archive|rendered|preview` owns one fixed DocC build against the
ordinary Debug/macOS cache and copies the admitted archive into its private
session. Rendered and preview modes snapshot a stable renderer tree, transform
the archive, and overlay a private static site. Preview binds only `127.0.0.1`
and publishes its readiness URL and site commitment. The session writer,
generated graph, and compatible cache remain owned through preview retirement;
only docbuild acquires `host:compile`. Native DocC, ancillary rendering/preview,
publication, drift, and maintenance evidence retain their distinct outcomes.

# Development preflight

Broad `test`, `test-unit`, and `build-and-test` routes run the exact-source/toolchain
development gate before native Xcode execution; fixed semantic replay and
focused routes retain their narrow work. Public `notika run-preflight` uses the
same closed catalog. Swift owns gate admission, source/tool identities, receipt
reuse, helper capture, and the pinned Rust subworkloads. Independent semantic
helpers and Python contract tests remain ordinary supervised steps; neither
recursive Make nor the former Python preflight coordinator owns this workflow.

An admitted reusable success must match source, toolchain, and complete command
identity. Native helper failures preserve their actual outcomes. Source changes
during the gate cannot produce an exact-source passing receipt.

# Today-only retention

`LocalCalendarRetention` captures one evaluation instant and injected local
time zone. Day boundaries use Gregorian calendar intervals, including 23-hour,
25-hour, and historical skipped-midnight days. They do not add 86,400 seconds.

A validated idle Xcode cache is eligible only when its last use precedes
today's start. Exact-midnight use survives. Future cache timestamps are invalid.
A finalized prior-day session expires at today's start unless its original
expiry was earlier or a valid keep overrides the daily policy. Incomplete,
busy, and invalid evidence cannot become eligible. Invalid keeps block fallback;
valid keeps retain their separate, at-most-30-elapsed-day extension contract.

Xcode, Rust, and session collectors apply the current local-day policy in their
separate fixed namespaces. AgentLease registry retention remains a separate
domain. The calendar model determines eligibility only; collectors validate
schemas and bindings, retain live exclusive leases, revalidate pinned inodes,
and supervise exact-claim Trash custody before any move. Moving to Trash is
never reported as freed disk space.

Managed build, generation, Rust, documentation, and standalone preflight sessions
execute best-effort maintenance before writer/project admission; interactive
launch uses its managed build path.
Today's entries remain protected. Busy, incomplete, malformed, or unknown
evidence stays in place and is reported separately from the native outcome.
Explicit cleanup previews by default; execution can select all namespaces or
the requested `caches`, `sessions`, or `rust-caches` scope.

# Validation

Static Python oracle vectors establish canonical bytes, hashes, historical
cache projections, and request shapes without Python at Swift runtime.
Fixtures exercise real host contention, cancellation, child reaping, and
release before runtime. Calendar cases include UTC/local date disagreement,
cutoff equality, DST, explicit expiry, and keep limits. These checks establish
component contracts. Implemented route coverage is not a claim that every
workflow has passed a real native run; task-specific validation records retain
actual routes, inputs, executed counts, outcomes, and remaining limitations.

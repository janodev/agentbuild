# Commands

```sh
agentbuild notika cleanup --repository /absolute/path/to/Notika --json
agentbuild notika cleanup --repository /absolute/path/to/Notika --execute --json
agentbuild notika cleanup --repository /absolute/path/to/Notika --scope caches --execute --json
```

The first command previews eligible folders. The second moves eligible folders
to Trash. Both select the checkout's `.agentlease` registry by default, with
`AGENTLEASE_HOME` or `--lease-home` as an explicit override. The account-wide
compilation registry remains separate. `--scope` selects `all` (default),
`caches`, `sessions`, or `rust-caches`; unselected namespaces are not inspected.
Build, generation, Rust, and other managed producers run executed maintenance
before acquiring their own writer scope. A cleanup diagnostic remains separate
from the actual native outcome.

# Ownership and eligibility

Xcode collection acquires the exact cache-policy resource exclusively with
zero wait, then each compatible cache resource exclusively with zero wait.
Native producers hold the policy shared and their cache exclusive, including
inherited child references. Busy ownership is reported and skipped.

Only the fixed `DerivedData/AgentCaches` namespace is inspected. Metadata
versions 1–3 must bind the actual owned directory and their admitted profile.
The last use must precede the start of the current local calendar day. Today's,
future, malformed, unrecognized, linked, or unbound entries remain protected.
Only eligible caches are walked for allocated-size evidence.

Rust collection independently acquires the producer's Rust-cache policy and
per-cache resources. It inspects the fixed `DerivedData/RustTestCaches`
namespace and admits only the known SVG/LiteParse metadata schema. The same
local-day cutoff applies; a different compatible identity alone does not make
a cache eligible. Unknown records and active Rust producers stay protected.

Session collection acquires three exclusive leases with zero wait, in order:
the exact session-writer namespace, the Xcode cache policy, and the Rust cache
policy. A busy lease protects the whole session namespace before any scan.
Coordinator writers hold the session resource shared through native work and
final publication. Legacy Python children can inherit cache-policy descriptors
without a session-writer descriptor; requiring both policies protects their
artifacts after the original coordinator exits. All three leases remain held
through scanning, revalidation and moving, and their descriptors are inherited
by the awaited Trash helper. Only admitted entries under
`Artifacts/AgentSessions` can expire. For finalized sessions, prior-day
completion uses today's start as its effective expiry unless the original
expiry was earlier or a valid manifest-bound keep overrides it. An invalid keep
blocks cleanup.

The Swift build, generation, Rust, preflight, and documentation sealed-report
schemas admit terminal and genuine in-progress evidence through explicit
readers. Exact legacy `development-session.json` authority, bound
`notika.abandoned-development-session` terminal manifests, and ordinary legacy
Python terminal manifests are also recognized. Legacy owner checks use exact
process birth identity; live or unobservable owners remain protected. Unknown
families and malformed or future lifecycle evidence remain protected.

Directory bindings in cache usage records and session evidence always require
the recorded inode. A recorded device number from an earlier kernel boot is
admitted when it differs, because remounting at restart renumbers the volume;
a device mismatch within the current boot remains invalid.

Legacy Python publication can leave a second, sealed hard link named
`.<filename>.<PID>.<32-lowercase-hex>.stage`, where the filename is
`manifest.json` or `development-session.json`, inside the same session.
Retention accepts that layout only when there are
exactly two links and the known private sibling has the same complete file
fingerprint as the public record. Both names are revalidated before claiming
or moving the session. External or unrecognized links stay protected. This
retention admission does not make the record reusable build/result evidence.

Admitted unfinished sessions use the later of their recorded start and the
latest nested artifact modification as their last activity. A log written
today preserves a session started yesterday. The nofollow inventory is bounded
to 10,000 entries, 256 directories and depth 32; unsafe, future, changed or
over-limit inventories block cleanup. Original unfinished evidence moves
intact, with its native outcome reported as unknown. Retention never invents a
successful terminal report or establishes replay-grade native/result provenance.

# Trash and reporting

Collectors pin nofollow ancestry and exact evidence descriptors, then revalidate
eligibility under live ownership. Before moving, they exclusively rename the
exact source into a private claim namespace. The Trash helper receives the claim
as literal argument data and retains the borrowed lock and custody descriptors.
Failure restores only the claimed inode and never overwrites a replacement.
Uncertain pending claims block later collection for inspection.

The JSON report distinguishes preview, moved, busy, invalid, revalidation
failure and Trash failure. Allocated cache bytes moved to Trash are not freed
disk space. Cleanup does not empty the system Trash or retire AgentLease
registry records. Registry maintenance remains a separate lifecycle domain.

The CLI returns 3 for an incomplete scan, malformed/unmanaged/busy evidence,
protected incomplete sessions, or failed/revalidation-skipped moves, and 130 after
structured cancellation. Valid retained entries can coexist with a complete
scan. Xcode, session, and Rust collectors run sequentially, with no nested
collector calls. Only the session collector holds the two related cache-policy
safety leases together with its session-writer lease.

# Validation boundary

Filesystem fixtures exercise real producer locks, schemas and local-day
cutoffs, descriptor/path mutations, bounded traversal, exact claim restoration,
and malformed keeps.

The opt-in
`NotikaCacheRetentionCollectorTests.systemTrashMovesOnlyThePriorDayCacheInAnIsolatedGitRepository`
check uses `AGENTBUILD_TEST_SYSTEM_TRASH=1` and the default system Trash operator.
It passed on 2026-10-10: one test, process exit 0. In an isolated temporary Git
repository, it moved one prior-day cache to the actual volume Trash and verified
the exact directory inode, usage bytes and unique marker. The current-day cache
kept its original inode and bytes. The local evidence is
[system-trash-operational-1.log](../Untracked/Validation/system-trash-operational-1.log).
The created Trash fixture remains for inspection; moving it does not establish
that disk space was freed.

Notika's `make maintain-artifacts` dispatches to the Swift collector. Cleanup
uses live kernel locks; neither an old registry filename nor a retained report
means the folder is currently leased.

On 2026-10-11, the full Swift suite passed 498 tests in 49 suites in
237.527 seconds. Four regression tests cover 14 parameterized cases for legacy
publication links: ordinary terminal, authority-only and abandoned records;
external, unrecognized or third links; malformed staging names; and removed or
replaced aliases during revalidation. The raw log is
`Untracked/Validation/session-hardlink-fix-tests.log`.

The installed release passed doctor and matched its copied build with SHA-256
`abd635a8e70dea29437166ceedb3c8c24478430acd4dfef6db40114807ac3cce`.
Executing session cleanup moved all 21 affected prior-day records to Trash,
reducing `Artifacts/AgentSessions` from 1.7 GB to 4.4 MB. The two current-day
records and one older authority with a mismatched filesystem device remained
unchanged; `Artifacts/AgentSessionTrashClaims` was empty afterward. The executed
report is `Untracked/Validation/session-hardlink-cleanup-executed.json`. Exit 3
reports the protected mismatched authority, not a failed Trash operation.

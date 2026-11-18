---
okf_version: "0.1"
type: Contract
title: Owned command execution
description: Defines generic command ownership, cancellation, log persistence, and truthful outcome boundaries.
tags: [agentlease, subprocess, execution, evidence, testing]
---

# Invocation

```sh
agentbuild run --resource example:work --json -- /usr/bin/printf '%s\n' 'literal value'
```

`--resource` requests exclusive ownership; repeatable `--shared-resource`
permits shared ownership. AgentLease validates and sorts the complete set.
The executable and all configured paths must be absolute. Arguments contain
no implicit shell expansion, including later `--` arguments. Stdin is closed
through `/dev/null`; this route is noninteractive.

`--working-directory` defaults to the current directory. `--artifacts-root`
defaults to its `Artifacts/AgentBuild` subdirectory. `--lease-home` selects an
explicit registry; otherwise AgentLease honors `AGENTLEASE_HOME` or uses the
effective account's home plus `.agentlease`. This generic registry selection
is distinct from the repository Makefile's account-wide compilation gate.
An inherited nonempty `AGENTLEASE_HELD_RESOURCES` rejects nested execution;
this version cannot adopt already-owned project resources.

# Ownership and cancellation

AgentLeaseCore supplies persistent kernel locks, registry admission, sorted
acquisition, metadata, run records, and inherited descriptor manifests. An
acquisition claim protects publication until the resource set is acquired.
`--wait-seconds` includes registry admission and acquisition/publication time;
zero allows an immediate attempt, while an expired positive budget never
becomes a new immediate attempt. Cancellation during waiting releases partial
ownership without starting a command.

The subprocess is spawned in a new session using AgentLease's tested Darwin
spawn attributes. Selected close-on-exec lock descriptors are inherited only
by the intended child; the coordinator's flags remain unchanged. Do not use
Subprocess 1.0's `createSession` prefork path for this operation.

SIGINT, SIGTERM, and SIGHUP cancel structured execution. Cancellation sends
SIGKILL to the live command's process group immediately, and waits for the
direct child to be reaped before publishing and closing the coordinator's
references. This is intentional: Subprocess 1.0 can abandon later graceful
escalation when a leader exits before its ignoring descendants.

An escaped descendant, an already-exited leader's background process, or a
child surviving coordinator SIGKILL can outlive the coordinator. Inherited
lock descriptors remain authoritative until those processes close them.
Closing the coordinator's reference never sends `LOCK_UN`. These are
cooperative locks: a process that deliberately closes inherited descriptors
or changes sessions falls outside automatic group cleanup. This layer does
not promise immediate termination of every descendant after coordinator death.

# Evidence and outcomes

Each UUID session owns a private 0700 directory, 0600 raw stdout/stderr files,
and a 0600 atomically published `manifest.json`. Pinned nofollow directory and
file descriptors own evidence; filesystem paths are diagnostic. Existing
artifact roots must belong to the current user and forbid group/world writes.
Every ancestor is opened without following symbolic links. Supply a canonical
absolute artifact root; paths through macOS aliases such as `/var` or `/tmp`
must use their resolved `/private` spelling.
Log descriptors remain close-on-exec in the coordinator and are borrowed by
the spawn API. No output-size limit or in-memory collection changes the result.

The manifest records schema 1, tool version, run ID, state, command path and
argument commitment, directory, resources/modes, PIDs, timestamps, cancellation
signal, optional observed native termination/failure, and raw-log paths/byte
counts. Full arguments and environment are not persisted. AgentLease's schema
2 run record uses the same run ID. Metadata write failures are recorded as
diagnostics; kernel ownership remains authoritative.

`completed` means the direct child's result was observed, including nonzero
exits. Byte counts describe the coordinator's final observation. A surviving
descendant may still hold or append to the log files; this version does not
seal output or prove result custody for project builds. Child write failures
are visible to the child; file redirection alone cannot prove the child checked
every write. The coordinator checks log flushes and manifest publication.

| Condition | CLI status | Native termination evidence |
| --- | --- | --- |
| Observed child exit | Exact child code | Exit and code |
| Observed child signal | 128 + signal | Signal and number |
| CLI SIGINT/SIGTERM/SIGHUP | 128 + received signal | Omitted if teardown did not return it |
| Library task cancellation | 130 | Omitted if unobserved |
| Acquisition timeout | 75 | Omitted; no child |
| Missing executable | 127 | Omitted; launch failure |
| Unrunnable executable | 126 | Omitted; launch failure |
| Missing working directory | 70 | Omitted; setup failure |
| Other driver failure | 70 | Omitted unless previously observed |
| Final evidence publication failure | Native failure code, or 70 after native success | Preserved in the returned diagnostic report |

Publication failures cannot invent child success or erase a native failure.
A post-spawn callback error follows teardown and finalizes this run, even if
the callback carries a publication error associated with another report.
After coordinator SIGKILL, a manifest may remain `running`; inspect kernel
ownership rather than treating that diagnostic state as an active lease.

# Validation and remaining work

`ManagedCommandRunnerTests` covers literal arguments, working directory,
large binary logs, native exits/signals, launch failure, wait/cancellation,
partial release, reaping, ignoring descendants, callback/final-publication
failures, completed descendants, and coordinator death. `ManagedCLITests`
covers signal relay, JSON/status agreement, waiting, and passthrough arguments.
`SessionArtifactsTests` covers permissions, descriptor lifetime, nofollow
paths, and publication failures. AgentLease's logging/spawn tests verify the
shared underlying implementation.

The next project route must own the generated graph and compatible cache
before acquiring `host:compile`, release compilation admission before tests
or UI work, and retain authoritative native status and project provenance.
This layer does not implement a project adapter's cache retention or prune its sessions.
Generic raw logs currently have no automatic retirement; project/session
retention must be defined before routine production adoption.

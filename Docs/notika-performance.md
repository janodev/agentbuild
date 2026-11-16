---
type: Reference
title: Notika performance evidence
description: Fixed native performance acceptance and retained attachment interpretation in the Swift controller.
tags: [notika, performance, evidence, development]
---

# Notika performance evidence

The two performance routes preserve the existing fixed workloads. Native Xcode
status and executed-test counts remain authoritative; attachment export and
interpretation are ancillary operations whose failure prevents successful
evidence publication without changing an observed native exit status.

`NotikaPerformanceReservation` creates a private session evidence directory
before Xcode. Canvas also reserves the original `report.json` inode and supplies
its device/inode identity to the UI test. The unsandboxed controller writes the
exported matrix through that retained descriptor after testing.
The reservation also supplies the fixed benchmark opt-in and identity variables;
their `TEST_RUNNER_` counterparts carry the same values into Xcode's test runner.
These variables come from the admitted reservation rather than inherited flags.

Attachment export runs only against the admitted, retained result-directory
descriptor. Its exact command, actual working-directory identity, process
retirement, complete raw capture, and result receipt remain retained through
final publication. The evidence tree admits only declared files, bounds total
bytes and entries, refuses symbolic/hard links, seals files read-only, and keeps
descriptor and mutation-watch custody until session sealing.

The native Text route requires exactly two passing, non-skipped tests and exactly
two raw attachments with the fixed scenario/test identifiers. Its version-2 raw
reports must bind the source hash, revision, Release configuration, disabled
diagnostics, and profile ordinal zero. Swift independently validates the complete
70-input/two-pass measurement, incremental dependency counters, nested stage
accounting, and both completion/history checks before deriving summaries.

Canvas requires one passing, non-skipped matrix test. Swift checks exactly 24
samples in the four-fixture, three-repetition counterbalanced A/B order, finite
durations, fixed workload, monitor conservation, source/session/configuration
bindings, and the original reserved report inode. The published report must be
byte-identical to the exported matrix attachment. Eight summary rows are derived
from retained raw bytes.

Neither route runs a Python driver, runner, or analyzer. Summaries are reproduced
again from the sealed evidence tree before admission. The integer-only session
snapshot records artifact hashes, the Swift interpretation contract version,
toolchain identity, actual ancillary export outcome, and outer lease session.
Floating measurement values remain in the retained raw/summary JSON files.

The independent Text oracles are documented in
[the test evidence provenance](../Tests/Evidence/NotikaPerformance/README.md).
They validate interpretation compatibility and do not claim a current native
performance measurement.

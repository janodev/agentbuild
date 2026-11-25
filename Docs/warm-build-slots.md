---
okf_version: "0.1"
type: Guide
title: Reusing a warm build directory across worktrees
description: Adapter integration for a leased source mirror and persistent DerivedData.
tags: [adapters, xcode, apfs, agentlease]
---

# Reusing a warm build directory across worktrees

Use `WarmBuildSlot` in a private adapter when several worktrees
can build at the same source path. Each key gets a `src/` mirror and a sibling
`DerivedData/`. The next invocation syncs its selected worktree into that same
mirror. Byte-identical regular files with matching permissions keep their inode
and timestamp. A changed regular file receives a timestamp later than the
previous entry at that path. When a coarse volume needs another clock tick,
sync can wait up to one second before handing off the slot. A preexisting
timestamp far in the future can keep replacements ahead of the clock and
cause extra rebuilds until wall time catches up. New and changed regular
files use APFS clones where supported, with an ordinary copy on unsupported
filesystems or across volumes. The prepared slot reports counts of cloned, copied and unchanged regular files.
A build can edit its mirrored regular files independently of the worktree.

Create a dedicated 0700 pool directory in an adapter-owned location outside the
worktrees. Use canonical absolute paths with real directory components. The
worktree root must belong to the effective user and forbid group and other writes. Supply
a key derived from the canonical Git common directory and the adapter's cache
compatibility inputs, such as its schema, toolchain, configuration and SDK.
Linked worktrees can then share a key across revisions and uncommitted edits.
Include a slot number if your adapter offers multiple independent slots. Each
additional slot has its own DerivedData and can overlap another slot's test
runtime. Compilation still takes the account-wide `host:compile` lease.
Constructing the slot reads the pool identity and exposes the planned paths and
exclusive lease resource. Creation and synchronization happen in `withPreparedSlot`.

## Adapter example

This build-only function takes the private adapter's admitted paths, executable
identities, scheme, child environment and retained resource descriptors. Supply
canonical project-relative input paths. For example, pass
`["App.xcworkspace", "App.xcodeproj"]` as `inputDirectories` to admit both
bundles and their contents. Supply selected individual files in `inputFiles`.
For a submodule, select the required files or explicitly admit its whole tree.
The session evidence directory lives outside the pool.
`consume` lets the adapter revalidate evidence, record
the native outcome and export a product before another caller can reuse the slot.

```swift
import AgentBuildCore
import Foundation

func buildInSlot(
    worktree: String, pool: String, compatibilityKey: String, inputFiles: [String], inputDirectories: [String],
    workspace: String, scheme: String, xcodebuild: String, adapterExecutable: String,
    coordinatorEnvironment: [String: String], childEnvironment: [String: String], sessionLogs: String, retainedLocks: [Int32],
    consume: @Sendable (CapturedNativePhase, PreparedBuildSlot) async throws -> Void
) async throws {
    // Include ancestors so the mirror can descend to each selected input.
    var selected = Set<Data>()
    for file in inputFiles + inputDirectories {
        var prefix = ""
        for component in file.split(separator: "/") {
            prefix += (prefix.isEmpty ? "" : "/") + component
            selected.insert(Data(prefix.utf8))
        }
    }
    let paths = selected
    let directoryPrefixes = inputDirectories.map { Array(($0 + "/").utf8) }
    let location = try WarmBuildSlot(poolDirectory: pool, key: compatibilityKey)
    try await location.withPreparedSlot(
        worktree: worktree, environment: coordinatorEnvironment,
        including: { path in
            paths.contains(Data(path.utf8)) || directoryPrefixes.contains { path.utf8.starts(with: $0) }
        }
    ) { slot in
        let command = try DarwinWorkloadCommand(
            executable: xcodebuild,
            arguments: ["-workspace", workspace, "-scheme", scheme,
                        "-derivedDataPath", slot.derivedDataDirectory, "build"],
            workingDirectory: slot.sourceDirectory, environment: childEnvironment
        )
        let phase = try await HostCompilationAdmission().withLease(environment: coordinatorEnvironment) { compile in
            try await CapturedNativePhaseRunner().run(
                helperExecutable: adapterExecutable, command: command,
                retainedLockDescriptors: retainedLocks + slot.leaseDescriptors + compile.inheritedDescriptors(),
                nativeWorkingDirectoryDescriptor: slot.sourceDirectoryDescriptor,
                artifactRoot: sessionLogs
            )
        }
        try await consume(phase, slot)
    }
}
```

Use the coordinator's account-wide registry settings for both lease calls.
The child environment controls the tools and settings visible to Xcode.

For test routes, keep both `build-for-testing` and `test-without-building`
inside the slot operation. Use the adapter's existing phase runner to acquire
compilation admission for the first phase. The slot lease and directory
descriptor are borrowed through the end of the operation. Pass the slot lease
descriptors to supervised children and await retirement. Use the same account
registry for every participant accessing a pool. Let `withPreparedSlot` acquire
the slot resource once, before compilation admission. Cleanup must take that
same resource exclusively before removing the slot. Two callers selecting the same
slot wait for exclusive ownership, subject to `waitSeconds`.

## Input and output policy

- The predicate receives each worktree-relative name encountered on disk,
  including directories. Returning false for a directory prunes its subtree.
  For a Git project an adapter can start with NUL-delimited tracked and
  nonignored untracked paths, then add declared ignored inputs and submodule
  contents. The mirror skips Git control entries named `.git`. Routes needing
  Git metadata must supply it explicitly, for example as an admitted revision
  for a build script.
- The slot owns the entire `src/` directory. Every sync removes entries outside
  the selected tree, including files a previous build generated there. Keep
  reusable generated outputs in a separate adapter-owned location, include
  generated inputs in the mirror, or regenerate them under graph ownership.
  Model sibling packages, external symlink targets, and absolute paths in
  project files before adopting the route.
- Mirroring handles regular file bytes and POSIX permission bits, directories
  and UTF-8 symbolic links. The default `.withinSource` policy rebases absolute
  links spelled under the canonical worktree root to relative links in the mirror.
  Before handoff it verifies that every selected link, including chained links,
  resolves beneath `src/`. Dangling links, cycles and escapes fail preparation.
  An adapter that requires literal link targets can pass
  `symlinkPolicy: .preserveLiteral`. This restores the earlier behavior and lets
  build tools read or write the external referent. These checks apply to links
  in the prepared mirror. The adapter controls the build command and other
  paths the command can access. Inputs whose build semantics depend on extended attributes,
  ACLs or source directory metadata need additional adapter handling.
- A successful sync describes a sequential read of a live worktree. The mirror
  checks observed entries for changes while reading. Keep the adapter's source
  observations and revalidation for edits racing admission. The slot's stable
  path is its execution location. Record the originating worktree separately.
- The operation starts after the mirror is ready. A failed or cancelled sync
  may leave partial files in the slot. The next owner reconciles against the
  actual directory under its lease. Recovery restores permissions on read-only
  mirror directories and clears user immutable and append-only flags on owned
  slot copies, including stale temporary clones. Locked files with multiple hard
  links require the owner to resolve them, since all names share the flags.
  Use session-owned paths for raw logs and
  result bundles, and export any products that must survive the next build.
  Keep slot cleanup coordinated with ownership and the adapter's retention
  policy.

## Verify the shared mechanism

Run `AGENTBUILD_TEST_XCODE_SLOT=1 make test TEST_FILTER=WarmBuildSlotTests` to
exercise the mirror and four real macOS Xcode builds. The fixture switches to
a second source tree with identical inputs, makes a same-size edit with the
original source timestamp, then switches back. It
checks that the identical build skips Swift compilation and executes each
built product to verify which source it contains.

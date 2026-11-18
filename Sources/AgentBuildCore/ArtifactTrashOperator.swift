import AgentLeaseCore
import Darwin
import Foundation
import Synchronization

public enum ArtifactTrashError: Error, Equatable, Sendable {
    case retiredSource
    case failed
    case systemCall(String, Int32)
}

/// Trusted operational seam. Collectors first prove eligibility and exclusively
/// claim the exact inode. Implementations revalidate immediately before moving,
/// await their child, and inherit its borrowed lock/custody descriptors.
public protocol ArtifactTrashOperator: Sendable {
    var identifier: String { get }
    func moveToTrash(_ source: ArtifactTrashSource) async throws
}

/// Created by trusted domain collectors after their real ownership and evidence
/// admission. Its retained directory is the private claim, never an untrusted
/// original pathname. Construction does not establish eligibility or ownership.
public final class ArtifactTrashSource: Sendable {
    public var path: String { directory.path }
    public let originalPath: String
    private let directory: RetainedArtifactDirectory
    private let descriptors: [Int32]
    private let revalidation: @Sendable () throws -> Void
    private let live = Mutex(true)

    public init(
        directory: RetainedArtifactDirectory, originalPath: String,
        inheritedDescriptors: [Int32], revalidate: @escaping @Sendable () throws -> Void
    ) {
        self.directory = directory; self.originalPath = originalPath
        descriptors = inheritedDescriptors; revalidation = revalidate
    }

    public func revalidateBeforeMove() throws {
        try live.withLock { state in
            guard state else { throw ArtifactTrashError.retiredSource }
            try validate()
        }
    }

    /// Borrowed only for an awaited child. Do not close or alter these FDs.
    public func inheritedDescriptors() throws -> [Int32] {
        try live.withLock { state in
            guard state else { throw ArtifactTrashError.retiredSource }
            try validate()
            return descriptors
        }
    }

    public func retire() { live.withLock { $0 = false } }

    private func validate() throws {
        try directory.revalidate()
        try revalidation()
        for descriptor in descriptors {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else { throw ArtifactTrashError.systemCall("fstat Trash custody", errno) }
        }
        try directory.revalidate()
    }
}

/// Fixed system interpreter and synchronous Foundation Trash API. The path is
/// passed as an argument, never interpolated JavaScript or shell text. Lock and
/// inode custody survive parent death in the awaited helper; moving to Trash
/// does not prove that disk space has been freed.
public struct SystemArtifactTrashOperator: ArtifactTrashOperator {
    public let identifier = "system-foundation-trash:/usr/bin/osascript"
    public init() {}

    public func moveToTrash(_ source: ArtifactTrashSource) async throws {
        let inherited = try source.inheritedDescriptors()
        let sink = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sink >= 0 else { throw ArtifactTrashError.systemCall("open Trash output sink", errno) }
        defer { _ = Darwin.close(sink) }
        try source.revalidateBeforeMove()
        let script = """
        ObjC.import('Foundation');
        function run(args) {
            var result = Ref(); var error = Ref();
            var url = $.NSURL.fileURLWithPath(args[0]);
            if (!$.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError(url, result, error)) {
                throw new Error('Trash operation failed');
            }
        }
        """
        let parent = String(source.path[..<(source.path.lastIndex(of: "/") ?? source.path.startIndex)])
        let result = try await SupervisedSubprocess.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["/usr/bin/osascript", "-l", "JavaScript", "-e", script, source.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"],
            inheritedDescriptors: inherited, workingDirectory: parent,
            standardOutputDescriptor: sink, standardErrorDescriptor: sink
        )
        guard result.termination == .exited(0) else { throw ArtifactTrashError.failed }
    }
}

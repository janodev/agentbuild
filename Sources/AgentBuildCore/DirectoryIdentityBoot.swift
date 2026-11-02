import Darwin
import Foundation

public enum DirectoryIdentityBootError: Error, Equatable, Sendable {
    case unavailable(Int32)
}

/// The kernel boot observed by this process. A volume receives its device
/// number when it mounts, so a restart can renumber the volume that holds a
/// retained directory while the directory keeps its inode.
public struct DirectoryIdentityBoot: Equatable, Sendable {
    public let bootedAtMicrosecondsSince1970: Int64

    public init(bootedAtMicrosecondsSince1970: Int64) {
        self.bootedAtMicrosecondsSince1970 = bootedAtMicrosecondsSince1970
    }

    public static func current() throws -> Self {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard Darwin.sysctl(&name, UInt32(name.count), &boot, &size, nil, 0) == 0 else {
            throw DirectoryIdentityBootError.unavailable(errno)
        }
        guard size == MemoryLayout<timeval>.size, boot.tv_sec > 0 else {
            throw DirectoryIdentityBootError.unavailable(EINVAL)
        }
        return Self(bootedAtMicrosecondsSince1970: Int64(boot.tv_sec) * 1_000_000 + Int64(boot.tv_usec))
    }

    /// Whether a directory identity stored at `recordedAt` still names the
    /// observed directory. The inode must always match. The device number must
    /// match too unless the record predates this boot: a device number from an
    /// earlier boot no longer names a volume. Callers still pin the observed
    /// directory to its expected parent volume and path.
    public func admits(
        storedDeviceID: UInt64,
        storedInode: UInt64,
        recordedAtMicrosecondsSince1970 recordedAt: Int64,
        observedDeviceID: UInt64,
        observedInode: UInt64
    ) -> Bool {
        guard storedInode == observedInode else { return false }
        return storedDeviceID == observedDeviceID || recordedAt < bootedAtMicrosecondsSince1970
    }

    public func admits(
        storedDeviceID: UInt64,
        storedInode: UInt64,
        recordedAt: Date,
        observedDeviceID: UInt64,
        observedInode: UInt64
    ) -> Bool {
        let scaled = (recordedAt.timeIntervalSince1970 * 1_000_000).rounded(.down)
        guard scaled.isFinite, scaled >= Double(Int64.min), scaled < Double(Int64.max) else { return false }
        return admits(
            storedDeviceID: storedDeviceID, storedInode: storedInode,
            recordedAtMicrosecondsSince1970: Int64(scaled),
            observedDeviceID: observedDeviceID, observedInode: observedInode
        )
    }
}

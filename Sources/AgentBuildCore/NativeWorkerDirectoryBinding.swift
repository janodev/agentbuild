import Darwin

/// Immutable observation of the directory actually admitted by the parent.
/// This value carries no descriptor and cannot grant working-directory custody.
public struct NativeWorkingDirectoryIdentity: Codable, Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let owner: UInt32
    public let mode: UInt16
}

/// A directory capability is bound to the private request; it conveys no lock
/// or route authority and is consumed only by the native spawn's fchdir action.
struct NativeWorkerDirectoryBinding: Codable, Equatable, Sendable {
    let descriptor: Int32
    let device: Int64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt16

    var identity: NativeWorkingDirectoryIdentity {
        NativeWorkingDirectoryIdentity(device: device, inode: inode, owner: owner, mode: mode)
    }

    init(descriptor: Int32, path: String) throws {
        let status = try Self.checkedStatus(descriptor: descriptor, path: path)
        self.descriptor = descriptor
        device = Int64(status.st_dev)
        inode = UInt64(status.st_ino)
        owner = UInt32(status.st_uid)
        mode = UInt16(status.st_mode)
    }

    func validate(path: String) throws {
        let status = try Self.checkedStatus(descriptor: descriptor, path: path)
        guard device == Int64(status.st_dev), inode == UInt64(status.st_ino),
              owner == UInt32(status.st_uid), mode == UInt16(status.st_mode) else {
            throw NativeWorkerProtocol.protocolFailure("working directory capability identity mismatch")
        }
    }

    private static func checkedStatus(descriptor: Int32, path: String) throws -> stat {
        var status = stat()
        var entry = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor >= 3, fstat(descriptor, &status) == 0,
              lstat(path, &entry) == 0, flags >= 0, flags & O_ACCMODE == O_RDONLY,
              status.st_mode & S_IFMT == S_IFDIR, entry.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(), status.st_mode & 0o7022 == 0,
              status.st_dev == entry.st_dev, status.st_ino == entry.st_ino,
              status.st_uid == entry.st_uid, status.st_mode == entry.st_mode else {
            throw NativeWorkerProtocol.protocolFailure("invalid pinned working directory capability")
        }
        return status
    }
}

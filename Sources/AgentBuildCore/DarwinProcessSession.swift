import Darwin

/// A conservative session census. Unlike ancestry polling, session membership
/// survives both process-group changes and reparenting. A child that explicitly
/// creates another session remains outside this boundary.
enum DarwinProcessSession {
    static func liveMembers(of session: Int32) -> [Int32]? {
        guard session > 0 else { return nil }
        guard let records = snapshot(filter: KERN_PROC_ALL, value: 0) else { return nil }
        var members: [Int32] = []
        for record in records {
            let pid = record.kp_proc.p_pid
            guard pid > 0 else { continue }
            // Darwin getsid returns ESRCH for zombies. Their descriptors are
            // already closed and they cannot fork or write, so they do not
            // prevent quiescence. The caller pins its exited native leader
            // separately until this live-member census is empty.
            guard record.kp_proc.p_stat != Int8(SZOMB) else { continue }
            let birth = record.kp_proc.p_un.__p_starttime
            guard matches(pid: pid, birth: birth) else { return nil }
            let observed = getsid(pid)
            // A disappeared or reused process may have forked a new session
            // member after the snapshot. Retry rather than mistaking that
            // incomplete observation for quiescence. Birth identities captured
            // by the kernel snapshot detect reuse before and around getsid.
            guard observed >= 0, matches(pid: pid, birth: birth) else { return nil }
            if observed == session { members.append(pid) }
        }
        return members.sorted()
    }

    /// Only used to classify EPERM after signalling the still-pinned original
    /// group. An unknown census must never conceal a real permission failure.
    static func groupHasLiveMembers(_ group: Int32) -> Bool? {
        guard group > 0, let records = snapshot(filter: KERN_PROC_PGRP, value: group) else { return nil }
        return records.contains { $0.kp_proc.p_pid > 0 && $0.kp_proc.p_stat != Int8(SZOMB) }
    }

    private static func snapshot(filter: Int32, value: Int32) -> [kinfo_proc]? {
        var query: [Int32] = [CTL_KERN, KERN_PROC, filter, value]
        var required = 0
        guard sysctl(&query, UInt32(query.count), nil, &required, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        guard required >= 0, required <= 16 * 1_024 * 1_024 - 32 * stride else { return nil }
        let capacity = max(required + 32 * stride, 64 * stride)
        var records = [kinfo_proc](repeating: kinfo_proc(), count: capacity / stride)
        var bytes = records.count * stride
        let result = records.withUnsafeMutableBytes {
            sysctl(&query, UInt32(query.count), $0.baseAddress, &bytes, nil, 0)
        }
        guard result == 0, bytes >= 0, bytes <= records.count * stride,
              bytes % stride == 0 else { return nil }
        return Array(records.prefix(bytes / stride))
    }

    private static func matches(pid: Int32, birth: timeval) -> Bool {
        // sysctl allows process birth observations for other accounts, whereas
        // PROC_PIDTBSDINFO can deny them. Never turn that denial into a missing
        // session member or a permanent wait on ordinary system processes.
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var record = kinfo_proc()
        var bytes = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&query, UInt32(query.count), &record, &bytes, nil, 0) == 0,
              bytes == MemoryLayout<kinfo_proc>.stride, record.kp_proc.p_pid == pid else { return false }
        let observed = record.kp_proc.p_un.__p_starttime
        return observed.tv_sec == birth.tv_sec && observed.tv_usec == birth.tv_usec
    }
}

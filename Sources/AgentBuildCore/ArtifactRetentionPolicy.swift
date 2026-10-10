import Foundation

/// These domains have separate collectors and must not share an age policy.
public enum ArtifactRetentionPolicy: String, Codable, Sendable {
    case todayOnlyCaches
    case todayOnlySessions
    case rustCacheAgeAndQuota
    case agentLeaseRegistry
}

/// Filesystem validation and ownership acquisition happen before policy evaluation.
public enum ArtifactRetentionAdmission: Sendable {
    case complete
    case incomplete
    case busy
    case invalid
}

public enum ArtifactRetentionEligibility: Equatable, Sendable {
    case eligible
    case retained
    case incomplete
    case busy
    case invalid
}

/// A collector validates a keep's schema, ownership, binding, and issue time.
/// This policy additionally checks its expiry against the original manifest.
public enum SessionRetentionKeep: Sendable {
    case absent
    case validated(expiresAt: Date)
    case invalid
}

public enum SessionRetentionSource: Equatable, Sendable {
    case manifest
    case todayOnly
    case keep
}

public struct SessionRetentionEvaluation: Equatable, Sendable {
    public let eligibility: ArtifactRetentionEligibility
    public let effectiveExpiresAt: Date?
    public let source: SessionRetentionSource?
}

public enum ArtifactRetentionPolicyError: Error, Equatable, Sendable {
    case invalidEvaluationTime
    case unrepresentableLocalDay
}

/// One captured evaluation instant and its local calendar boundaries.
/// Decisions are not deletion authority: collectors still revalidate evidence
/// and retain exclusive ownership across any filesystem mutation.
public struct LocalCalendarRetention: Equatable, Sendable {
    public let evaluatedAt: Date
    public let localDayStart: Date
    public let nextLocalMidnight: Date
    public let timeZone: TimeZone

    public init(evaluatedAt: Date, timeZone: TimeZone = .current) throws {
        guard evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ArtifactRetentionPolicyError.invalidEvaluationTime
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // A DST change at midnight can start a day at 01:00. Its following
        // boundary is still midnight, so adding a day to that 01:00 is wrong.
        guard let day = calendar.dateInterval(of: .day, for: evaluatedAt),
              day.start.timeIntervalSinceReferenceDate.isFinite,
              day.end.timeIntervalSinceReferenceDate.isFinite,
              day.start <= evaluatedAt, evaluatedAt < day.end else {
            throw ArtifactRetentionPolicyError.unrepresentableLocalDay
        }
        self.evaluatedAt = evaluatedAt
        localDayStart = day.start
        nextLocalMidnight = day.end
        self.timeZone = timeZone
    }

    /// Current keys, warmest-family caches, and quota do not override this cutoff.
    public func cacheEligibility(
        lastUsedAt: Date?,
        admission: ArtifactRetentionAdmission = .complete
    ) -> ArtifactRetentionEligibility {
        if let blocked = blockedEligibility(admission) { return blocked }
        guard let lastUsedAt else { return .incomplete }
        guard lastUsedAt.timeIntervalSinceReferenceDate.isFinite,
              lastUsedAt <= evaluatedAt else { return .invalid }
        return lastUsedAt < localDayStart ? .eligible : .retained
    }

    /// Missing finalized lifecycle evidence remains incomplete. Valid keeps
    /// override daily pruning, including when their own expiry has arrived.
    public func sessionEligibility(
        completedAt: Date?,
        manifestExpiresAt: Date?,
        keep: SessionRetentionKeep = .absent,
        admission: ArtifactRetentionAdmission = .complete
    ) -> SessionRetentionEvaluation {
        if let blocked = blockedEligibility(admission) { return blockedSession(blocked) }
        guard let completedAt, let manifestExpiresAt else {
            return blockedSession(.incomplete)
        }
        guard completedAt.timeIntervalSinceReferenceDate.isFinite,
              manifestExpiresAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt <= manifestExpiresAt else { return blockedSession(.invalid) }

        let expiry: Date
        let source: SessionRetentionSource
        switch keep {
        case .invalid:
            return blockedSession(.invalid)
        case .validated(let expiresAt):
            // The existing keep contract uses an elapsed 30-day extension,
            // unlike the local-calendar day used by automatic retention.
            let extensionSeconds = expiresAt.timeIntervalSince(manifestExpiresAt)
            guard expiresAt.timeIntervalSinceReferenceDate.isFinite,
                  extensionSeconds > 0, extensionSeconds <= 30 * 24 * 60 * 60 else {
                return blockedSession(.invalid)
            }
            expiry = expiresAt
            source = .keep
        case .absent:
            if completedAt < localDayStart, localDayStart < manifestExpiresAt {
                expiry = localDayStart
                source = .todayOnly
            } else {
                expiry = manifestExpiresAt
                source = .manifest
            }
        }
        return SessionRetentionEvaluation(
            eligibility: expiry <= evaluatedAt ? .eligible : .retained,
            effectiveExpiresAt: expiry,
            source: source
        )
    }

    private func blockedEligibility(
        _ admission: ArtifactRetentionAdmission
    ) -> ArtifactRetentionEligibility? {
        switch admission {
        case .complete: nil
        case .incomplete: .incomplete
        case .busy: .busy
        case .invalid: .invalid
        }
    }

    private func blockedSession(
        _ eligibility: ArtifactRetentionEligibility
    ) -> SessionRetentionEvaluation {
        SessionRetentionEvaluation(eligibility: eligibility, effectiveExpiresAt: nil, source: nil)
    }
}

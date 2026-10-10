@testable import AgentBuildCore
import Foundation
import Testing

@Test(arguments: [
    ("Europe/Madrid", "2026-10-09T23:30:00Z", "2026-10-09T22:00:00Z", "2026-10-10T22:00:00Z"),
    ("Asia/Kathmandu", "2026-10-09T20:00:00Z", "2026-10-09T18:15:00Z", "2026-10-10T18:15:00Z"),
    ("America/Los_Angeles", "2026-10-10T01:00:00Z", "2026-10-09T07:00:00Z", "2026-10-10T07:00:00Z"),
])
func retentionUsesLocalCalendarDay(
    zone: String, instant: String, start: String, next: String
) throws {
    let retention = try retentionContext(instant, zone: zone)
    #expect(retention.localDayStart == retentionDate(start))
    #expect(retention.nextLocalMidnight == retentionDate(next))
}

@Test(arguments: [
    ("Europe/Madrid", "2026-03-29T12:00:00Z", "2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z", 23),
    ("Europe/Madrid", "2026-10-25T12:00:00Z", "2026-10-24T22:00:00Z", "2026-10-25T23:00:00Z", 25),
    ("America/Sao_Paulo", "2018-11-04T12:00:00Z", "2018-11-04T03:00:00Z", "2018-11-05T02:00:00Z", 23),
])
func retentionMidnightsRespectDaylightSavingTransitions(
    zone: String, instant: String, start: String, next: String, hours: Int
) throws {
    let retention = try retentionContext(instant, zone: zone)
    #expect(retention.localDayStart == retentionDate(start))
    #expect(retention.nextLocalMidnight == retentionDate(next))
    #expect(retention.nextLocalMidnight.timeIntervalSince(retention.localDayStart) == Double(hours * 60 * 60))
}

@Test(arguments: [
    ("2026-10-09T21:59:59Z", ArtifactRetentionEligibility.eligible),
    ("2026-10-09T22:00:00Z", .retained),
    ("2026-10-09T22:00:01Z", .retained),
    ("2026-10-10T10:00:00Z", .retained),
    ("2026-10-10T10:00:01Z", .invalid),
])
func cacheRetentionRequiresUseStrictlyBeforeLocalMidnight(
    usedAt: String, expected: ArtifactRetentionEligibility
) throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    #expect(retention.cacheEligibility(lastUsedAt: retentionDate(usedAt)) == expected)
}

@Test(arguments: [
    (ArtifactRetentionAdmission.incomplete, ArtifactRetentionEligibility.incomplete),
    (.busy, .busy),
    (.invalid, .invalid),
])
func incompleteBusyOrInvalidAdmissionCannotBecomeEligible(
    admission: ArtifactRetentionAdmission, expected: ArtifactRetentionEligibility
) throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    let yesterday = retentionDate("2026-10-09T10:00:00Z")
    #expect(retention.cacheEligibility(lastUsedAt: yesterday, admission: admission) == expected)
    let session = retention.sessionEligibility(
        completedAt: yesterday,
        manifestExpiresAt: retentionDate("2026-10-17T10:00:00Z"),
        admission: admission
    )
    #expect(session.eligibility == expected)
    #expect(session.effectiveExpiresAt == nil)
    #expect(session.source == nil)
}

@Test func missingFinalizedEvidenceDoesNotAuthorizeRetentionCleanup() throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    #expect(retention.cacheEligibility(lastUsedAt: nil) == .incomplete)
    #expect(retention.sessionEligibility(completedAt: nil, manifestExpiresAt: nil).eligibility == .incomplete)
    #expect(retention.sessionEligibility(
        completedAt: retentionDate("2026-10-09T10:00:00Z"), manifestExpiresAt: nil
    ).eligibility == .incomplete)
}

@Test func priorDaySessionCompletionOverridesLaterManifestExpiry() throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    let originalExpiry = retentionDate("2026-10-17T10:00:00Z")
    let session = retention.sessionEligibility(
        completedAt: retentionDate("2026-10-09T21:59:59Z"),
        manifestExpiresAt: originalExpiry
    )
    #expect(session.eligibility == .eligible)
    #expect(session.effectiveExpiresAt == retentionDate("2026-10-09T22:00:00Z"))
    #expect(session.source == .todayOnly)
}

@Test(arguments: [
    "2026-10-09T22:00:00Z",
    "2026-10-10T10:00:00Z",
    "2026-10-11T10:00:00Z",
])
func completionAtMidnightTodayOrInFutureDoesNotTriggerDailyExpiry(completedAt: String) throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    let expiry = retentionDate("2026-10-17T10:00:00Z")
    let session = retention.sessionEligibility(completedAt: retentionDate(completedAt), manifestExpiresAt: expiry)
    #expect(session.eligibility == .retained)
    #expect(session.effectiveExpiresAt == expiry)
    #expect(session.source == .manifest)
}

@Test(arguments: ["2026-10-10T09:59:59Z", "2026-10-10T10:00:00Z"])
func explicitManifestExpiryStillAppliesToCurrentDaySessions(expiresAt: String) throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    let session = retention.sessionEligibility(
        completedAt: retentionDate("2026-10-09T22:00:00Z"),
        manifestExpiresAt: retentionDate(expiresAt)
    )
    #expect(session.eligibility == .eligible)
    #expect(session.source == .manifest)
}

@Test(arguments: [
    ("2026-10-09T10:00:00Z", ArtifactRetentionEligibility.eligible),
    ("2026-10-10T10:00:00Z", .eligible),
    ("2026-10-11T10:00:00Z", .retained),
])
func validKeepOverridesDailyPolicyUntilItsOwnExpiry(
    expiresAt: String, expected: ArtifactRetentionEligibility
) throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    let expiry = retentionDate(expiresAt)
    let session = retention.sessionEligibility(
        completedAt: retentionDate("2026-10-07T10:00:00Z"),
        manifestExpiresAt: retentionDate("2026-10-08T10:00:00Z"),
        keep: .validated(expiresAt: expiry)
    )
    #expect(session.eligibility == expected)
    #expect(session.effectiveExpiresAt == expiry)
    #expect(session.source == .keep)
}

@Test func invalidKeepDoesNotFallBackToDailyOrManifestExpiry() throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    let session = retention.sessionEligibility(
        completedAt: retentionDate("2026-10-07T10:00:00Z"),
        manifestExpiresAt: retentionDate("2026-10-08T10:00:00Z"),
        keep: .invalid
    )
    #expect(session.eligibility == .invalid)
    #expect(session.effectiveExpiresAt == nil)
    #expect(session.source == nil)
}

@Test(arguments: [
    (0.0, ArtifactRetentionEligibility.invalid),
    (-1.0, ArtifactRetentionEligibility.invalid),
    (2_592_000.0, ArtifactRetentionEligibility.retained),
    (2_592_001.0, ArtifactRetentionEligibility.invalid),
] as [(Double, ArtifactRetentionEligibility)])
func keepMustExtendOriginalExpiryWithinThirtyElapsedDays(
    extensionSeconds: Double, expected: ArtifactRetentionEligibility
) throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    let originalExpiry = retentionDate("2026-10-17T10:00:00Z")
    let session = retention.sessionEligibility(
        completedAt: retentionDate("2026-10-09T10:00:00Z"),
        manifestExpiresAt: originalExpiry,
        keep: .validated(expiresAt: originalExpiry.addingTimeInterval(extensionSeconds))
    )
    #expect(session.eligibility == expected)
}

@Test func sessionLifecycleMustEndBeforeManifestExpiry() throws {
    let retention = try retentionContext("2026-10-10T10:00:00Z")
    #expect(retention.sessionEligibility(
        completedAt: retentionDate("2026-10-09T10:00:01Z"),
        manifestExpiresAt: retentionDate("2026-10-09T10:00:00Z")
    ).eligibility == .invalid)
}

@Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
func nonfiniteEvaluationTimesAreRejected(value: Double) {
    #expect(throws: ArtifactRetentionPolicyError.invalidEvaluationTime) {
        try LocalCalendarRetention(evaluatedAt: Date(timeIntervalSinceReferenceDate: value))
    }
}

private func retentionContext(
    _ instant: String, zone: String = "Europe/Madrid"
) throws -> LocalCalendarRetention {
    let timeZone = try #require(TimeZone(identifier: zone))
    return try LocalCalendarRetention(evaluatedAt: retentionDate(instant), timeZone: timeZone)
}

private func retentionDate(_ value: String) -> Date {
    // Every test instant uses an explicit UTC offset; fixture failures must not
    // silently substitute a current date and move the expected calendar day.
    ISO8601DateFormatter().date(from: value)!
}

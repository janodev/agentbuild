import Foundation

public enum NotikaArtifactCleanupScope: String, Codable, CaseIterable, Sendable {
    case all
    case caches
    case sessions
    case rustCaches = "rust-caches"
}

/// Explicit narrow cleanup keeps compatibility aliases from silently widening
/// an authorized mutation to another artifact namespace.
public struct NotikaScopedArtifactCleanupReport: Encodable, Sendable {
    public let namespace = "agentbuild.notika-cleanup"
    public let schemaVersion = 1
    public let toolVersion = AgentBuild.version
    public let scope: NotikaArtifactCleanupScope
    public let caches: NotikaCacheRetentionReport?
    public let sessions: NotikaSessionRetentionReport?
    public let rustCaches: NotikaRustCacheRetentionReport?

    public var attentionCount: Int {
        (caches?.entries.filter {
            [.invalid, .unmanaged, .busy].contains($0.classification)
                || [.skippedRevalidation, .trashFailed].contains($0.action)
        }.count ?? 0) + (sessions?.entries.filter {
            [.invalid, .incomplete].contains($0.classification)
                || [.skippedRevalidation, .trashFailed].contains($0.action)
        }.count ?? 0) + (rustCaches?.entries.filter {
            [.invalid, .unmanaged, .busy].contains($0.classification)
                || [.skippedRevalidation, .trashFailed].contains($0.action)
        }.count ?? 0)
    }

    public var complete: Bool {
        (caches?.scanComplete ?? true) && (sessions?.scanComplete ?? true)
            && (rustCaches?.scanComplete ?? true) && attentionCount == 0
    }
}

public struct NotikaArtifactMaintenanceReport: Encodable, Sendable {
    public let namespace = "agentbuild.notika-cleanup"
    public let schemaVersion = 1
    public let toolVersion = AgentBuild.version
    public let caches: NotikaCacheRetentionReport
    public let sessions: NotikaSessionRetentionReport
    public let rustCaches: NotikaRustCacheRetentionReport

    public var attentionCount: Int {
        caches.entries.filter {
            [.invalid, .unmanaged, .busy].contains($0.classification)
                || [.skippedRevalidation, .trashFailed].contains($0.action)
        }.count + sessions.entries.filter {
            [.invalid, .incomplete].contains($0.classification)
                || [.skippedRevalidation, .trashFailed].contains($0.action)
        }.count + rustCaches.entries.filter {
            [.invalid, .unmanaged, .busy].contains($0.classification)
                || [.skippedRevalidation, .trashFailed].contains($0.action)
        }.count
    }

    public var complete: Bool {
        caches.scanComplete && sessions.scanComplete && rustCaches.scanComplete
            && attentionCount == 0
    }
}

/// Run before acquiring a workflow's session-writer lease. Each domain uses
/// immediate exclusive admission and releases it before the next domain.
/// A protected entry is a maintenance diagnostic, never a native build result.
public struct NotikaArtifactMaintenance: Sendable {
    private let caches: NotikaCacheRetentionCollector
    private let sessions: NotikaSessionRetentionCollector
    private let rustCaches: NotikaRustCacheRetentionCollector

    public init(canonicalRepository: String, registryRoot: String,
                evaluatedAt: Date = Date(), timeZone: TimeZone = .current,
                trashOperator: any ArtifactTrashOperator = SystemArtifactTrashOperator()) throws {
        caches = try NotikaCacheRetentionCollector(
            canonicalRepository: canonicalRepository, registryRoot: registryRoot,
            evaluatedAt: evaluatedAt, timeZone: timeZone, trashOperator: trashOperator
        )
        sessions = try NotikaSessionRetentionCollector(
            canonicalRepository: canonicalRepository, registryRoot: registryRoot,
            evaluatedAt: evaluatedAt, timeZone: timeZone, trashOperator: trashOperator
        )
        rustCaches = try NotikaRustCacheRetentionCollector(
            canonicalRepository: canonicalRepository, registryRoot: registryRoot,
            evaluatedAt: evaluatedAt, timeZone: timeZone, trashOperator: trashOperator
        )
    }

    public func run(execute: Bool = false) async throws -> NotikaArtifactMaintenanceReport {
        let cacheReport = try await caches.run(execute: execute)
        let sessionReport = try await sessions.run(execute: execute)
        let rustReport = try await rustCaches.run(execute: execute)
        return NotikaArtifactMaintenanceReport(caches: cacheReport, sessions: sessionReport, rustCaches: rustReport)
    }

    public func run(scope: NotikaArtifactCleanupScope, execute: Bool = false) async throws -> NotikaScopedArtifactCleanupReport {
        let cacheReport = scope == .all || scope == .caches ? try await caches.run(execute: execute) : nil
        let sessionReport = scope == .all || scope == .sessions ? try await sessions.run(execute: execute) : nil
        let rustReport = scope == .all || scope == .rustCaches ? try await rustCaches.run(execute: execute) : nil
        return NotikaScopedArtifactCleanupReport(scope: scope, caches: cacheReport,
            sessions: sessionReport, rustCaches: rustReport)
    }
}

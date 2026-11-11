import AgentBuildCore

/// ABDiff's generated graph inputs and public error vocabulary wrap the shared snapshot.
struct ABDiffSourceSnapshot: Sendable {
    let raw: [String: String]
    let comparison: [String: String]
    let allowedFileHashes: [String: String]

    /// Generated graph and lock files ABDiff observes alongside Git state.
    static let abdiffProjectFiles = [
        "ABDiff.xcodeproj/project.pbxproj", "ABDiff.xcworkspace/contents.xcworkspacedata", "Project.swift",
        "Tuist/Package.resolved", ".package.resolved",
    ]

    static func validatedAllowedPaths(_ paths: [String]) throws -> [String] {
        do { return try RepositorySourceSnapshot.validatedAllowedPaths(paths) }
        catch let error as RepositorySourceSnapshotError { throw projectError(error) }
    }

    static func capture(repository: String, allowedPaths: [String], environment: [String: String],
                        projectFiles: [String] = abdiffProjectFiles) async throws -> Self {
        do {
            let snapshot = try await RepositorySourceSnapshot.capture(repository: repository,
                allowedPaths: allowedPaths, environment: environment, projectFiles: projectFiles)
            return Self(raw: snapshot.raw, comparison: snapshot.comparison, allowedFileHashes: snapshot.allowedFileHashes)
        } catch let error as RepositorySourceSnapshotError { throw projectError(error) }
    }

    private static func projectError(_ error: RepositorySourceSnapshotError) -> any Error {
        switch error {
        case .invalidRequest(let detail): ABDiffProjectError.invalidRequest(detail)
        case .changedInput(let path): ABDiffProjectDriverError.changedInput(path)
        case .evidence(let detail): ABDiffProjectDriverError.evidence(detail)
        case .io(let operation, let code): ABDiffProjectDriverError.io(operation, code)
        }
    }
}

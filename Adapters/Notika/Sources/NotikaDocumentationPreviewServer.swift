import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation

/// Native loopback helper used only beneath the supervised DocC controller.
/// It retains a genuine session-writer lease until its socket and requests end;
/// inherited controller leases remain owned by the surrounding native worker.
public enum NotikaDocumentationPreviewServer {
    public static func run(repository: String, sessionDirectory: String, registryRoot: String,
                           port: Int, siteSHA256: String) async throws {
        guard (1_024...65_535).contains(port), documentationSHA(siteSHA256) else {
            throw NotikaDocumentationDriverError.invalidArgument("preview binding")
        }
        let paths = try AgentLeasePaths.open(selectedRoot: registryRoot)
        let runID = UUID().uuidString, pid = getpid(), acquired = RunRecord.timestamp()
        let writer = try await LeaseSet.acquire(ResourceSet(exclusive: [], shared: ["notika:sessions:" + repository]),
            paths: paths, waitSeconds: 0, initialMetadata: { lease in
                LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID,
                    coordinatorPID: pid, childPID: nil, mode: .run, state: .acquired,
                    label: "notika-docc-loopback-preview", bead: nil, acquiredAt: acquired)
            })
        defer { writer.release() }
        let session = try ControllerSessionArtifacts(borrowingSessionPath: sessionDirectory, repository: repository)
        let directory = try RetainedArtifactDirectory(path: sessionDirectory, requiredPermissions: 0o700)
        let progress = try directory.openFile(named: "in-progress.json", policy: ArtifactFilePolicy(minimumBytes: 1, requiredPermissions: 0o400))
        let report = try NotikaDocumentationSessionReport(data: progress.readBounded(), expectedRepository: repository,
            expectedSessionID: URL(fileURLWithPath: sessionDirectory).lastPathComponent)
        guard report.lifecycle == "inProgress", report.mode == .preview, report.payload.previewPort == port,
              report.payload.registryRoot.utf8.elementsEqual(registryRoot.utf8),
              report.payload.directoryIdentity.deviceID == UInt64(session.identity.st_dev),
              report.payload.directoryIdentity.inode == session.identity.st_ino else { throw documentationSchema("previewSession") }
        for name in ["manifest.json", "preview-ready.json"] {
            do {
                _ = try directory.openFile(named: name, policy: ArtifactFilePolicy(minimumBytes: 1, requiredPermissions: 0o400))
                throw documentationSchema("previewAlreadyFinalized")
            } catch RetainedArtifactError.systemCall(_, ENOENT) {}
        }
        let site = try NotikaDocumentationTree(path: sessionDirectory + "/site", privateRoot: true)
        let commitment = try site.commitment(retainingEntries: true)
        guard commitment.sha256 == siteSHA256 else { throw documentationSchema("previewSite") }
        let opened = socket(AF_INET, SOCK_STREAM, 0)
        guard opened >= 0 else { throw documentationIO("open loopback preview socket") }
        let listener = DocumentationDescriptor(opened)
        try previewNonblocking(opened)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(opened, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(opened, 16) == 0 else { throw documentationIO("bind loopback preview socket") }
        let ready = NotikaDocumentationPreviewEvidence(protocolName: "notika.docc-loopback-preview.v1", host: "127.0.0.1",
            port: port, url: documentationPreviewURL(port), processID: getpid(), site: site.path, siteTreeSHA256: siteSHA256)
        try session.publish(sealedData: documentationEncoded(ready), name: "preview-ready.json", validating: {
            try progress.revalidate()
            guard try site.commitment() == commitment else { throw NotikaDocumentationDriverError.artifactChanged }
        })
        print(ready.url)
        while true {
            try Task.checkCancellation()
            try session.revalidate(); try progress.revalidate(); try site.revalidate()
            let accepted = accept(listener.value, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { throw documentationIO("accept preview request") }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            let connection = DocumentationDescriptor(accepted)
            do {
                try previewNonblocking(connection.value)
                try await previewServe(connection.value, site: site)
            } catch is CancellationError { throw CancellationError() }
            catch is PreviewClientError {}
        }
    }
}

private func previewNonblocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
          fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw documentationIO("configure preview socket") }
    var enabled: Int32 = 1
    guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw documentationIO("configure preview socket signal handling")
    }
}

private func previewServe(_ descriptor: Int32, site: NotikaDocumentationTree) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    var header = Data(), buffer = [UInt8](repeating: 0, count: 2_048)
    while header.range(of: Data("\r\n\r\n".utf8)) == nil {
        try Task.checkCancellation()
        guard header.count < 8_192, ContinuousClock.now < deadline else { return }
        let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress!, min($0.count, 8_192 - header.count), 0) }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            try await Task.sleep(for: .milliseconds(10)); continue
        }
        guard count > 0 else { return }
        header.append(contentsOf: buffer.prefix(count))
    }
    guard let request = String(data: header, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
        try await previewResponse(descriptor, code: 400); return
    }
    let fields = request.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[2] == "HTTP/1.1" || fields[2] == "HTTP/1.0" else {
        try await previewResponse(descriptor, code: 400); return
    }
    guard fields[0] == "GET" || fields[0] == "HEAD" else { try await previewResponse(descriptor, code: 405); return }
    let target = String(fields[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard target.hasPrefix("/"), let decoded = String(target).removingPercentEncoding,
          !decoded.utf8.contains(where: { $0 < 32 || $0 == 127 }),
          !decoded.contains("\\") else { try await previewResponse(descriptor, code: 400, headOnly: fields[0] == "HEAD"); return }
    var components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), components.count <= 64 else {
        try await previewResponse(descriptor, code: 404, headOnly: fields[0] == "HEAD"); return
    }
    if components.isEmpty { components = ["index.html"] }
    let file: DocumentationOpenedFile
    var servedName = components.last ?? "index.html"
    do { file = try site.openFile(components: components) }
    catch {
        guard previewMissingFile(error) else { throw error }
        do { file = try site.openFile(components: components + ["index.html"]); servedName = "index.html" }
        catch {
            guard previewMissingFile(error) else { throw error }
            // DocC renderer owns its SPA entry point. Only its closed public
            // documentation/tutorials routes may use that retained fallback.
            guard components.first == "documentation" || components.first == "tutorials" else {
                try await previewResponse(descriptor, code: 404, headOnly: fields[0] == "HEAD"); return
            }
            do { file = try site.openFile(components: ["index.html"]); servedName = "index.html" }
            catch {
                guard previewMissingFile(error) else { throw error }
                try await previewResponse(descriptor, code: 404, headOnly: fields[0] == "HEAD"); return
            }
        }
    }
    try file.revalidate()
    let contentType = previewContentType(servedName)
    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(file.size)\r\nContent-Type: \(contentType)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
    try await previewSend(descriptor, data: Data(response.utf8))
    if fields[0] == "HEAD" { return }
    var offset: Int64 = 0, bytes = [UInt8](repeating: 0, count: 128 * 1_024)
    while offset < file.size {
        try Task.checkCancellation()
        try file.revalidate()
        let count = bytes.withUnsafeMutableBytes { pread(file.descriptor.value, $0.baseAddress!, min($0.count, Int(file.size - offset)), off_t(offset)) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw NotikaDocumentationDriverError.artifactChanged }
        try file.revalidate()
        try await previewSend(descriptor, data: Data(bytes.prefix(count)))
        offset += Int64(count)
    }
    try file.revalidate()
}

private func previewSend(_ descriptor: Int32, data: Data) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    var offset = 0
    while offset < data.count {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw PreviewClientError.timeout }
        let count = data.withUnsafeBytes { send(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            try await Task.sleep(for: .milliseconds(10)); continue
        }
        guard count > 0 else { throw PreviewClientError.disconnected }
        offset += count
    }
}
private enum PreviewClientError: Error { case timeout, disconnected }
private func previewMissingFile(_ error: any Error) -> Bool {
    if case NotikaDocumentationDriverError.artifactIO(_, let code) = error { return code == ENOENT || code == ENOTDIR || code == EISDIR }
    return false
}
private func previewResponse(_ descriptor: Int32, code: Int, headOnly: Bool = false) async throws {
    let title = code == 400 ? "Bad Request" : code == 405 ? "Method Not Allowed" : "Not Found"
    let body = Data((title + "\n").utf8)
    let header = "HTTP/1.1 \(code) \(title)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
    try await previewSend(descriptor, data: Data(header.utf8) + (headOnly ? Data() : body))
}
private func previewContentType(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "js": return "text/javascript; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "json": return "application/json"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "ico": return "image/x-icon"
    case "woff": return "font/woff"
    case "woff2": return "font/woff2"
    case "wasm": return "application/wasm"
    default: return "application/octet-stream"
    }
}

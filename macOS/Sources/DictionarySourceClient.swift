import Foundation

struct IFDictionaryHTTPResponse: Sendable {
    let url: URL
    let status: Int
    let data: Data
    let expectedLength: Int64
}

typealias IFDictionaryTransport = @Sendable (URLRequest, Int) async throws -> IFDictionaryHTTPResponse

/// One ephemeral request per delegate. Bytes are bounded while receiving, including redirects.
private final class IFDictionaryHTTPTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var continuation: CheckedContinuation<IFDictionaryHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    init(limit: Int) { self.limit = limit }

    func run(_ request: URLRequest) async throws -> IFDictionaryHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false; configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, IFDictionarySourceClient.isAllowed(url) else {
            failure = IFDictionaryUpdateError(.download, "redirect-host")
            completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // System TLS trust is allowed; credentials are never supplied to public source endpoints.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              IFDictionarySourceClient.isAllowed(url) else {
            failure = IFDictionaryUpdateError(.download, "non-http-response")
            completionHandler(.cancel); return
        }
        self.response = http
        guard http.expectedContentLength <= Int64(limit) else {
            failure = IFDictionaryUpdateError(.download, "response-too-large")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - buffer.count else {
            failure = IFDictionaryUpdateError(.download, "response-too-large"); dataTask.cancel(); return
        }
        buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = continuation; self.continuation = nil; self.task = nil; self.session = nil; lock.unlock()
        defer { session.invalidateAndCancel() }
        if let failure = failure ?? error { continuation?.resume(throwing: failure); return }
        guard let response, let url = response.url else {
            continuation?.resume(throwing: IFDictionaryUpdateError(.download, "non-http-response")); return
        }
        continuation?.resume(returning: .init(url: url, status: response.statusCode,
                                            data: buffer, expectedLength: response.expectedContentLength))
    }
}

struct IFDictionarySourceClient: Sendable {
    let transport: IFDictionaryTransport
    let logger: IFDictionaryDiagnosticLogger
    init(transport: @escaping IFDictionaryTransport = { request, limit in
        try await IFDictionaryHTTPTask(limit: limit).run(request)
    }, logger: @escaping IFDictionaryDiagnosticLogger = { _ in }) {
        self.transport = transport; self.logger = logger
    }
    static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && ["api.github.com", "raw.githubusercontent.com"].contains(url.host ?? "")
    }
    private func request(_ url: URL, stage: IFDictionaryStage, source: String, limit: Int) async throws -> Data {
        do {
            try Task.checkCancellation()
            guard Self.isAllowed(url) else { throw IFDictionaryUpdateError(stage, "request-host", source: source) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpShouldHandleCookies = false
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("InkFlow-Dictionary", forHTTPHeaderField: "User-Agent")
            let response = try await transport(request, limit)
            guard Self.isAllowed(response.url) else { throw IFDictionaryUpdateError(stage, "redirect-host", source: source) }
            guard response.status == 200 else {
                throw IFDictionaryUpdateError(stage, "http-status", source: source, httpStatus: response.status)
            }
            guard !response.data.isEmpty, response.data.count <= limit,
                  response.expectedLength < 0 || response.expectedLength == response.data.count else {
                throw IFDictionaryUpdateError(stage, "response-size", source: source)
            }
            return response.data
        } catch {
            let value: IFDictionaryUpdateError
            if let known = error as? IFDictionaryUpdateError {
                value = .init(stage, known.code, source: source, httpStatus: known.httpStatus, detail: known.detail)
            } else { value = .wrapping(error, stage: stage, source: source) }
            throw value
        }
    }
    func check(observed: [IFDictionarySourceReceipt]) async throws -> IFDictionaryCheck {
        struct Commit: Decodable { let sha: String; let commit: Body; struct Body: Decodable { let tree: Tree; struct Tree: Decodable { let sha: String } } }
        struct Tree: Decodable { let sha: String; let truncated: Bool; let tree: [Entry]
            struct Entry: Decodable { let path: String; let mode: String; let type: String; let sha: String; let size: Int? }
        }
        do {
            var checked = [String: IFDictionaryCheckedSource]()
            let specs = IFDictionaryCatalog.sources.filter(\.isUpdatable)
            for repository in Array(Set(specs.map(\.repository))).sorted() {
                let selected = specs.filter { $0.repository == repository }
                let spec = selected[0]
                let commitURL = URL(string: "https://api.github.com/repos/\(repository)/commits/\(spec.branch)")!
                let commitBytes = try await request(commitURL, stage: .check, source: repository, limit: 8_388_608)
                let commit: Commit
                do { commit = try JSONDecoder().decode(Commit.self, from: commitBytes) }
                catch { throw IFDictionaryUpdateError(.check, "response-json", source: repository, file: "commit", detail: "Invalid GitHub commit response") }
                guard IFDictionaryHash.isHex(commit.sha, length: 40), IFDictionaryHash.isHex(commit.commit.tree.sha, length: 40) else {
                    throw IFDictionaryUpdateError(.check, "commit-format", source: repository)
                }
                let treeURL = URL(string: "https://api.github.com/repos/\(repository)/git/trees/\(commit.commit.tree.sha)?recursive=1")!
                let treeBytes = try await request(treeURL, stage: .check, source: repository, limit: 16_777_216)
                let tree: Tree
                do { tree = try JSONDecoder().decode(Tree.self, from: treeBytes) }
                catch { throw IFDictionaryUpdateError(.check, "response-json", source: repository, file: "tree", detail: "Invalid GitHub tree response") }
                guard !tree.truncated, tree.sha == commit.commit.tree.sha else {
                    throw IFDictionaryUpdateError(.check, "tree-incomplete", source: repository)
                }
                for source in selected {
                    let entries = tree.tree.filter { $0.path == source.path }
                    guard entries.count == 1, let entry = entries.first, entry.type == "blob", entry.mode == "100644",
                          IFDictionaryHash.isHex(entry.sha, length: 40), let size = entry.size,
                          size > 0, size <= IFDictionaryCatalog.maximumSourceBytes else {
                        throw IFDictionaryUpdateError(.check, "tree-file", source: source.id, file: source.path)
                    }
                    checked[source.id] = .init(id: source.id, commit: commit.sha, blobSHA: entry.sha, byteCount: size)
                }
            }
            let result = specs.compactMap { checked[$0.id] }
            let changed = result.contains { item in
                !observed.contains { $0.id == item.id && $0.blobSHA == item.blobSHA && $0.byteCount == item.byteCount }
            }
            return .init(sources: result, hasUpdate: changed)
        } catch {
            let value = IFDictionaryUpdateError.wrapping(error, stage: .check); logger(value); throw value
        }
    }
    func download(_ check: IFDictionaryCheck,
                  progress: @Sendable (IFDictionaryProgress) -> Void = { _ in }) async throws -> [IFDictionaryInput] {
        do {
            let specs = IFDictionaryCatalog.sources.filter(\.isUpdatable)
            guard check.sources.map(\.id) == specs.map(\.id) else { throw IFDictionaryUpdateError(.download, "source-set") }
            var result = [IFDictionaryInput]()
            for (spec, checked) in zip(specs, check.sources) {
                guard IFDictionaryHash.isHex(checked.commit, length: 40), IFDictionaryHash.isHex(checked.blobSHA, length: 40),
                      checked.byteCount > 0, checked.byteCount <= IFDictionaryCatalog.maximumSourceBytes else {
                    throw IFDictionaryUpdateError(.download, "checked-source", source: spec.id)
                }
                progress(.init(stage: .download, completed: result.count, total: specs.count))
                let bytes = try await request(spec.rawURL(commit: checked.commit), stage: .download, source: spec.id, limit: checked.byteCount)
                let receipt = IFDictionarySourceReceipt(id: spec.id, commit: checked.commit, blobSHA: checked.blobSHA,
                    sha256: IFDictionaryHash.sha256(bytes), byteCount: checked.byteCount, recordCount: 0)
                let input = IFDictionaryInput(receipt: receipt, data: bytes)
                try IFDictionaryGenerator.validate(input)
                result.append(input)
            }
            progress(.init(stage: .download, completed: specs.count, total: specs.count))
            return result
        } catch {
            let value = IFDictionaryUpdateError.wrapping(error, stage: .download); logger(value); throw value
        }
    }
}

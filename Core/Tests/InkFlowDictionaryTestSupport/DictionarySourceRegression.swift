import Foundation
@testable import InkFlowDomain
@testable import InkFlowRime

private func check(_ value: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fatalError(message, file: (file), line: line) }
}
private func asyncFails(_ code: String? = nil, _ body: () async throws -> Void) async {
    do { try await body(); fatalError("Expected failure \(code ?? "")") }
    catch let error as IFDictionaryUpdateError { if let code { check(error.code == code, "Expected \(code), got \(error.technicalDetails)") } }
    catch { check(code == nil, "Unexpected error \(error)") }
}

private let fakeCommit = String(repeating: "a", count: 40)
private let fakeTree = String(repeating: "b", count: 40)

private actor RequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func wait() async {
        calls += 1
        if calls > 1 { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private func network(_ mutation: String = "", changed: Bool = false) -> IFDictionarySourceClient {
    IFDictionarySourceClient(transport: { request, _ in
        let url = request.url!
        check(request.value(forHTTPHeaderField: "Authorization") == nil && !request.httpShouldHandleCookies, "No auth/cookies")
        check(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10", "Pinned API version")
        if mutation == "malformed" { return .init(url: url, status: 200, data: Data("{".utf8), expectedLength: 1) }
        if mutation == "offline" { throw URLError(.notConnectedToInternet) }
        if mutation == "timeout" { throw URLError(.timedOut) }
        if mutation == "403" || mutation == "429" { return .init(url: url, status: Int(mutation)!, data: Data([0]), expectedLength: 1) }
        if mutation == "redirect" { return .init(url: URL(string: "https://evil.example/dict")!, status: 200, data: Data([0]), expectedLength: 1) }
        let data: Data
        if url.path.contains("/commits/") {
            data = try JSONSerialization.data(withJSONObject: ["sha": mutation == "badcommit" ? "../head" : fakeCommit,
                "commit": ["tree": ["sha": fakeTree]]])
        } else if url.path.contains("/git/trees/") {
            let repository = IFDictionaryCatalog.sources.first { url.path.hasPrefix("/repos/\($0.repository)/") }!.repository
            let specs = IFDictionaryCatalog.sources.filter { $0.repository == repository }
            var entries = specs.map { spec -> [String: Any] in
                ["path": spec.path, "mode": mutation == "symlink" ? "120000" : "100644", "type": "blob",
                 "sha": changed && spec.id == "frost-8105" ? String(repeating: "c", count: 40) : spec.pinnedBlobSHA, "size": spec.pinnedByteCount]
            }
            if mutation == "missing" { entries.removeLast() }
            data = try JSONSerialization.data(withJSONObject: ["sha": fakeTree, "truncated": mutation == "truncated", "tree": entries])
        } else { fatalError("Check must never download raw data") }
        return .init(url: url, status: 200, data: data, expectedLength: Int64(data.count))
    })
}

package func verifyDictionarySources(repository: URL) async throws {
    try await DictionarySourceRegression.networkTests(repository)
}

private enum DictionarySourceRegression {
    static func networkTests(_ repository: URL) async throws {
        let baseline = IFDictionaryCatalog.sources.map(\.pinnedReceipt)
        check(try await !network().check(observed: baseline).hasUpdate, "Unrelated commit must not offer update")
        check(try await network(changed: true).check(observed: baseline).hasUpdate, "Selected changed blob offers update")
        for (mutation, code) in [("missing", "tree-file"), ("truncated", "tree-incomplete"), ("symlink", "tree-file"),
                                 ("badcommit", "commit-format"), ("403", "http-status"), ("429", "http-status"),
                                 ("redirect", "redirect-host"), ("offline", "underlying"), ("timeout", "underlying")] {
            await asyncFails(code) { _ = try await network(mutation).check(observed: baseline) }
        }
        do { _ = try await network("malformed").check(observed: baseline); fatalError("Expected malformed response") }
        catch let error as IFDictionaryUpdateError {
            let firstRepository = IFDictionaryCatalog.sources.filter(\.isUpdatable).map(\.repository).sorted().first!
            check(error.code == "response-json" && error.source == firstRepository && error.file == "commit", "Malformed JSON retains endpoint/source context")
        }
        let specs = IFDictionaryCatalog.sources.filter(\.isUpdatable)
        let bytes = try Dictionary(uniqueKeysWithValues: specs.map { spec in
            (spec.id, try Data(contentsOf: repository.appendingPathComponent("build/dictionary-sources/\(spec.id).yaml")))
        })
        let checked = IFDictionaryCheck(sources: specs.map { .init(id: $0.id, commit: $0.pinnedCommit, blobSHA: $0.pinnedBlobSHA, byteCount: $0.pinnedByteCount) }, hasUpdate: true)
        let good = IFDictionarySourceClient(transport: { request, limit in
            let spec = specs.first { $0.rawURL(commit: $0.pinnedCommit) == request.url }!
            let data = bytes[spec.id]!
            check(data.count == limit, "Immutable checked byte limit")
            return .init(url: request.url!, status: 200, data: data, expectedLength: Int64(data.count))
        })
        let downloaded = try await good.download(checked)
        check(downloaded.count == specs.count && downloaded[0].receipt.sha256 == specs[0].pinnedSHA256, "Verified downloads")
        for corruption in ["truncate", "hash", "length", "oversize"] {
            let bad = IFDictionarySourceClient(transport: { request, _ in
                var data = bytes[specs[0].id]!
                if corruption == "truncate" { data.removeLast() }
                if corruption == "hash" { data[0] ^= 1 }
                if corruption == "oversize" { data.append(0) }
                return .init(url: request.url!, status: 200, data: data,
                    expectedLength: corruption == "length" ? Int64(data.count + 1) : Int64(data.count))
            })
            await asyncFails { _ = try await bad.download(checked) }
        }
        check(!IFDictionarySourceClient.isAllowed(URL(string: "http://api.github.com/")!), "HTTPS only")
        check(!IFDictionarySourceClient.isAllowed(URL(string: "https://user@api.github.com/")!), "No credential URL")
        let cancelled = Task { try await good.download(checked) }; cancelled.cancel()
        await asyncFails { _ = try await cancelled.value }
        for download in [false, true] {
            let cancelledClient = IFDictionarySourceClient(transport: { _, _ in throw CancellationError() })
            do {
                if download { _ = try await cancelledClient.download(checked) }
                else { _ = try await cancelledClient.check(observed: baseline) }
                check(false, "Cancelled transport cannot succeed")
            } catch is CancellationError {} catch { check(false, "Source client preserves cancellation: \(error)") }

            let gate = RequestGate()
            let transport = download ? good.transport : network().transport
            let lateClient = IFDictionarySourceClient(transport: { request, limit in
                await gate.wait()
                return try await transport(request, limit)
            })
            let late = Task {
                if download { _ = try await lateClient.download(checked) }
                else { _ = try await lateClient.check(observed: baseline) }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await gate.calls == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            check(await gate.calls == 1, "Request entered before cancellation")
            late.cancel(); await gate.open()
            do { try await late.value; check(false, "A late response cannot resume cancelled source work") }
            catch is CancellationError {} catch { check(false, "Late response preserves cancellation: \(error)") }
            check(await gate.calls == 1, "Cancellation prevents the next network request")
        }
        print("PASS client: immutable no/change/unrelated checks; missing/tree/mode/status/redirect/offline/timeout/length/hash/cancellation")
    }
}

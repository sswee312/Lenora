import Foundation
import Testing
@testable import Lenora

struct RemoteMediaDownloaderTests {
    private func fetch(status: Int, body: Data = Data("PNG".utf8), headers: [String: String] = ["Content-Type": "image/png"],
                       finalURL: URL? = nil) -> RemoteMediaDownloader.Fetch {
        { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try body.write(to: file)
            let response = HTTPURLResponse(url: finalURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (file, response)
        }
    }

    private let source = URL(string: "https://res.cloudinary.com/demo/image/upload/x.png")!
    private let backend = LenoraBackendConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "secret-token")

    private func authorization(for url: String, backend: LenoraBackendConfiguration?) -> String? {
        RemoteMediaDownloader(maxBytes: 100, timeout: 5, backend: backend)
            .request(for: URL(string: url)!).value(forHTTPHeaderField: "Authorization")
    }

    @Test(arguments: [
        ("http://127.0.0.1:8787/v1/results/0f1e2d3c4b5a69788796a5b4c3d2e1f0", true),
        ("http://127.0.0.1:8788/v1/results/0f1e2d3c4b5a69788796a5b4c3d2e1f0", false),
        ("http://localhost:8787/v1/results/0f1e2d3c4b5a69788796a5b4c3d2e1f0", false),
        ("https://127.0.0.1:8787/v1/results/0f1e2d3c4b5a69788796a5b4c3d2e1f0", false),
        ("https://res.cloudinary.com/demo/image/upload/x.png", false),
    ])
    func sendsTheBackendTokenOnlyToTheBackendOrigin(url: String, sendsToken: Bool) {
        #expect(authorization(for: url, backend: backend) == (sendsToken ? "Bearer secret-token" : nil))
    }

    @Test(arguments: [
        ("https://API.example.com/v1", "https://api.example.com:443/v1/results/a", true),
        ("http://Example.test:80", "http://example.test/v1/results/a", true),
        ("https://api.example.com", "http://api.example.com/v1/results/a", false),
        ("https://api.example.com", "https://api.example.com:8443/v1/results/a", false),
        ("https://api.example.com", "https://api.example.com.evil.example/v1/results/a", false),
        ("https://api.example.com", "file:///v1/results/a", false),
    ])
    func sameOriginNormalizesDefaultPortsAndCase(base: String, url: String, same: Bool) {
        #expect(LenoraBackendConfiguration(baseURL: URL(string: base)!, token: nil).isSameOrigin(URL(string: url)!) == same)
    }

    @Test func noTokenWithoutABackendToken() {
        let url = "http://127.0.0.1:8787/v1/results/0f1e2d3c4b5a69788796a5b4c3d2e1f0"
        #expect(authorization(for: url, backend: LenoraBackendConfiguration(baseURL: backend.baseURL, token: nil)) == nil)
        #expect(authorization(for: url, backend: nil) == nil)
    }

    @Test func downloadFetchesWithTheBackendToken() async throws {
        let sent = Box<String?>(nil)
        let base = fetch(status: 200)
        let recording: RemoteMediaDownloader.Fetch = { request in
            sent.value = request.value(forHTTPHeaderField: "Authorization")
            return try await base(request)
        }
        let file = try await RemoteMediaDownloader(maxBytes: 100, timeout: 5, backend: backend, fetch: recording)
            .download(URL(string: "http://127.0.0.1:8787/v1/results/0f1e2d3c4b5a69788796a5b4c3d2e1f0")!)
        try? FileManager.default.removeItem(at: file)
        #expect(sent.value == "Bearer secret-token")
    }

    @Test func returnsValidatedFile() async throws {
        let file = try await RemoteMediaDownloader(maxBytes: 100, timeout: 5, fetch: fetch(status: 200)).download(source)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == Data("PNG".utf8))
    }

    @Test(arguments: [404, 500, 302])
    func rejectsNonSuccessStatus(status: Int) async {
        await #expect(throws: RemoteDownloadError.badStatus(status)) {
            try await RemoteMediaDownloader(maxBytes: 100, timeout: 5, fetch: fetch(status: status)).download(source)
        }
    }

    @Test func rejectsOversizedBody() async {
        await #expect(throws: RemoteDownloadError.tooLarge(3)) {
            try await RemoteMediaDownloader(maxBytes: 2, timeout: 5, fetch: fetch(status: 200)).download(source)
        }
    }

    @Test func rejectsHTMLErrorPages() async {
        let html = fetch(status: 200, body: Data("<html>".utf8), headers: ["Content-Type": "text/html; charset=utf-8"])
        await #expect(throws: RemoteDownloadError.unexpectedContentType("text/html; charset=utf-8")) {
            try await RemoteMediaDownloader(maxBytes: 100, timeout: 5, fetch: html).download(source)
        }
    }

    @Test func rejectsRedirectToInsecureURL() async {
        let redirected = fetch(status: 200, finalURL: URL(string: "http://evil.example/x.png")!)
        await #expect(throws: RemoteDownloadError.disallowedURL("http://evil.example/x.png")) {
            try await RemoteMediaDownloader(maxBytes: 100, timeout: 5, fetch: redirected).download(source)
        }
    }

    @Test(arguments: [
        ("https://a.example/x", true), ("http://127.0.0.1:8787/x", true), ("http://localhost/x", true),
        ("http://a.example/x", false), ("file:///etc/passwd", false), ("ftp://a.example/x", false),
    ])
    func allowsOnlyHTTPSOrLoopback(url: String, allowed: Bool) {
        #expect(RemoteMediaDownloader.isAllowed(URL(string: url)!) == allowed)
    }

    @Test func rejectedDownloadsLeaveNoTempFile() async throws {
        let created = Box<URL?>(nil)
        let tracking: RemoteMediaDownloader.Fetch = { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("x".utf8).write(to: file)
            created.value = file
            return (file, HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        _ = try? await RemoteMediaDownloader(maxBytes: 100, timeout: 5, fetch: tracking).download(source)
        #expect(!FileManager.default.fileExists(atPath: try #require(created.value).path))
    }

    @Test func rejectsRedirectToLoopbackEvenThoughLoopbackIsAllowedInitially() async {
        let redirected = fetch(status: 200, finalURL: URL(string: "http://127.0.0.1:8787/x.png")!)
        await #expect(throws: RemoteDownloadError.disallowedURL("http://127.0.0.1:8787/x.png")) {
            try await RemoteMediaDownloader(maxBytes: 100, timeout: 5, fetch: redirected).download(source)
        }
    }

    @Test func loopbackInitialURLWithoutRedirectIsAccepted() async throws {
        let local = URL(string: "http://127.0.0.1:8787/x.png")!
        let file = try await RemoteMediaDownloader(maxBytes: 100, timeout: 5, fetch: fetch(status: 200)).download(local)
        try? FileManager.default.removeItem(at: file)
    }

    @Test(arguments: [
        ("https://cdn.example/x", true), ("http://127.0.0.1:8787/x", false), ("http://localhost/x", false),
        ("http://a.example/x", false), ("file:///etc/passwd", false),
    ])
    func redirectsMustStayHTTPS(url: String, allowed: Bool) {
        #expect(RemoteMediaDownloader.isAllowedRedirect(URL(string: url)!) == allowed)
    }

    private func redirect(to target: String, authorization: String? = nil, using delegate: ImportDownloadDelegate) -> URLRequest?? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: source)
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let outcome = Box<URLRequest??>(nil)
        var request = URLRequest(url: URL(string: target)!)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
            outcome.value = .some($0)
        }
        return outcome.value ?? nil
    }

    @Test func delegateRefusesRedirectToLoopbackAndRecordsIt() {
        let delegate = ImportDownloadDelegate(maxBytes: 100)
        let decision = redirect(to: "http://127.0.0.1:8787/x", using: delegate)
        #expect(decision == .some(nil))
        #expect(delegate.refusedRedirect?.absoluteString == "http://127.0.0.1:8787/x")
    }

    @Test func delegateFollowsHTTPSRedirect() {
        let delegate = ImportDownloadDelegate(maxBytes: 100)
        let decision = redirect(to: "https://cdn.example/x.png", using: delegate)
        #expect(decision??.url?.absoluteString == "https://cdn.example/x.png")
        #expect(delegate.refusedRedirect == nil)
    }

    @Test func redirectsNeverCarryTheBackendToken() {
        let decision = redirect(to: "https://cdn.example/x.png", authorization: "Bearer secret-token",
                                using: ImportDownloadDelegate(maxBytes: 100))
        #expect(decision??.url?.absoluteString == "https://cdn.example/x.png")
        #expect(decision??.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

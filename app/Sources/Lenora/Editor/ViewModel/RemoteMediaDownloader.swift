import Foundation

enum RemoteDownloadError: Error, Equatable, LocalizedError {
    case disallowedURL(String)
    case badStatus(Int)
    case tooLarge(Int64)
    case unexpectedContentType(String)
    case unreadableMedia

    var errorDescription: String? {
        switch self {
        case .disallowedURL(let url): "Refused to download from \(url)."
        case .badStatus(let status): "The download failed (HTTP \(status))."
        case .tooLarge: "The downloaded file is larger than the import limit."
        case .unexpectedContentType(let type): "The server returned \(type) instead of media."
        case .unreadableMedia: "The downloaded file could not be read as media."
        }
    }
}

struct RemoteMediaDownloader: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse)
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    let maxBytes: Int64
    let timeout: TimeInterval
    let backend: LenoraBackendConfiguration?
    private let fetch: Fetch

    init(maxBytes: Int64, timeout: TimeInterval, backend: LenoraBackendConfiguration? = nil, fetch: Fetch? = nil) {
        self.maxBytes = maxBytes
        self.timeout = timeout
        self.backend = backend
        self.fetch = fetch ?? { request in
            let delegate = ImportDownloadDelegate(maxBytes: maxBytes)
            let (file, response) = try await URLSession.shared.download(for: request, delegate: delegate)
            if let refused = delegate.refusedRedirect {
                try? FileManager.default.removeItem(at: file)
                throw RemoteDownloadError.disallowedURL(refused.absoluteString)
            }
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (file, http)
        }
    }

    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": url.host(percentEncoded: false).map { loopbackHosts.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) } ?? false
        default: false
        }
    }

    static func isAllowedRedirect(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let backend, let token = backend.token, backend.isSameOrigin(url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    @concurrent
    func download(_ url: URL) async throws -> URL {
        guard Self.isAllowed(url) else { throw RemoteDownloadError.disallowedURL(url.absoluteString) }
        let (file, response) = try await fetch(request(for: url))
        do {
            if let final = response.url, !(final == url ? Self.isAllowed(final) : Self.isAllowedRedirect(final)) {
                throw RemoteDownloadError.disallowedURL(final.absoluteString)
            }
            guard (200..<300).contains(response.statusCode) else { throw RemoteDownloadError.badStatus(response.statusCode) }
            if let type = response.value(forHTTPHeaderField: "Content-Type"), type.lowercased().hasPrefix("text/html") {
                throw RemoteDownloadError.unexpectedContentType(type)
            }
            let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size <= maxBytes else { throw RemoteDownloadError.tooLarge(size) }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}

final class ImportDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maxBytes: Int64
    private let lock = NSLock()
    private var refused: URL?

    init(maxBytes: Int64) { self.maxBytes = maxBytes }

    var refusedRedirect: URL? { lock.withLock { refused } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, RemoteMediaDownloader.isAllowedRedirect(target) else {
            lock.withLock { refused = request.url }
            completionHandler(nil)
            return
        }
        // The backend token is for the backend's own origin; a redirect never carries it.
        var redirected = request
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > maxBytes {
            downloadTask.cancel()
            return
        }
        if totalBytesWritten > maxBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // No-op: the async download(for:delegate:) API copies the temp file for us.
    }
}

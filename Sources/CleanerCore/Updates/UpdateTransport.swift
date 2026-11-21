// The only network code of the updater.
//
// Two requests exist: a small GET (the release description and the checksum file) and a download to a file.
// Both are HTTPS only, use the system's default trust evaluation (no custom challenge handling), carry no
// cookies, credentials or identifiers, and send a generic User-Agent. Redirects are followed only to the hosts
// in `UpdateHostPolicy`, at most five of them. Sizes are capped while the bytes arrive, not afterwards.
import Foundation

public protocol UpdateTransport: Sendable {
    /// A small document in memory (at most `maxBytes`).
    func fetch(_ url: URL, role: UpdateHostRole, maxBytes: Int, accept: String) async throws -> Data
    /// A file: written to `file` (which must not exist yet), at most `maxBytes`, exactly `expectedBytes` long.
    /// `progress` gets the number of bytes received so far.
    func download(_ url: URL, to file: URL, expectedBytes: Int64, maxBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

public final class LiveUpdateTransport: UpdateTransport, @unchecked Sendable {
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let downloadTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 15, downloadTimeout: TimeInterval = 600) {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCredentialStorage = nil
        c.waitsForConnectivity = false
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        c.timeoutIntervalForRequest = requestTimeout
        c.httpAdditionalHeaders = ["User-Agent": "MacCleaner-Updater"]
        session = URLSession(configuration: c)
        self.requestTimeout = requestTimeout
        self.downloadTimeout = downloadTimeout
    }

    /// Refuses redirects that leave GitHub, and stops redirect chains.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private var count = 0
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            count += 1
            guard count <= 5, let url = request.url, UpdateHostPolicy.isAllowedRedirect(url) else {
                completionHandler(nil)   // the 3xx answer is returned and treated as a failure
                return
            }
            var next = request
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(next)
        }
    }

    private func request(_ url: URL, accept: String, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "GET"
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return r
    }

    private func check(_ response: URLResponse, role: UpdateHostRole?) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse("not an HTTP answer") }
        if let final = http.url, !UpdateHostPolicy.isAllowedRedirect(final) {
            throw UpdateError.badResponse("answer came from an unexpected host")
        }
        switch http.statusCode {
        case 200: return http
        case 404: throw UpdateError.noRelease
        case 429: throw UpdateError.rateLimited
        case 403:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.value(forHTTPHeaderField: "retry-after") != nil {
                throw UpdateError.rateLimited
            }
            throw UpdateError.badResponse("HTTP 403")
        default: throw UpdateError.badResponse("HTTP \(http.statusCode)")
        }
    }

    private func wrap(_ error: Error) -> Error {
        if error is UpdateError || error is CancellationError { return error }
        if let e = error as? URLError {
            if e.code == .cancelled { return CancellationError() }
            return UpdateError.offline(e.localizedDescription)
        }
        return UpdateError.offline(error.localizedDescription)
    }

    public func fetch(_ url: URL, role: UpdateHostRole, maxBytes: Int, accept: String) async throws -> Data {
        guard UpdateHostPolicy.isAllowedStart(url, role: role) else { throw UpdateError.badResponse("address not allowed") }
        do {
            let (bytes, response) = try await session.bytes(for: request(url, accept: accept, timeout: requestTimeout), delegate: RedirectGuard())
            let http = try check(response, role: role)
            if http.expectedContentLength > Int64(maxBytes) { throw UpdateError.tooLarge("\(http.expectedContentLength) bytes") }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw UpdateError.tooLarge("more than \(maxBytes) bytes") }
            }
            return data
        } catch { throw wrap(error) }
    }

    public func download(_ url: URL, to file: URL, expectedBytes: Int64, maxBytes: Int64,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard UpdateHostPolicy.isAllowedStart(url, role: .download) else { throw UpdateError.badResponse("address not allowed") }
        guard expectedBytes > 0, expectedBytes <= maxBytes else { throw UpdateError.tooLarge("\(expectedBytes) bytes") }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw UpdateError.installFailed("cannot create the download file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            let (bytes, response) = try await session.bytes(for: request(url, accept: "application/octet-stream", timeout: requestTimeout),
                                                            delegate: RedirectGuard())
            let http = try check(response, role: nil)
            if http.expectedContentLength > maxBytes { throw UpdateError.tooLarge("\(http.expectedContentLength) bytes") }
            if http.expectedContentLength >= 0, http.expectedContentLength != expectedBytes {
                throw UpdateError.sizeMismatch(expected: expectedBytes, actual: http.expectedContentLength)
            }
            var total: Int64 = 0
            var chunk = [UInt8]()
            chunk.reserveCapacity(1 << 16)
            let deadline = Date().addingTimeInterval(downloadTimeout)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 1 << 16 {
                    total += Int64(chunk.count)
                    if total > maxBytes || total > expectedBytes { throw UpdateError.tooLarge("more than \(expectedBytes) bytes") }
                    try handle.write(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    progress(total)
                    try Task.checkCancellation()
                    if Date() > deadline { throw UpdateError.offline("the download took too long") }
                }
            }
            total += Int64(chunk.count)
            if total > maxBytes { throw UpdateError.tooLarge("more than \(maxBytes) bytes") }
            if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
            try handle.synchronize()
            guard total == expectedBytes else { throw UpdateError.sizeMismatch(expected: expectedBytes, actual: total) }
            progress(total)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw wrap(error)
        }
    }
}

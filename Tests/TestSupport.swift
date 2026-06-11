import Foundation
@testable import MeetingShield

enum TestDates {
    static let now = Date(timeIntervalSince1970: 1_779_443_200)
    static let start = now.addingTimeInterval(10 * 60)
}

enum TestTempDirectory {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MeetingShieldTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    var valueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    func save(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func retrieve(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func delete(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

/// URLProtocol stub serving canned responses keyed by a request matcher.
/// Tests register handlers with unique URL components (calendar IDs etc.) so
/// parallel test execution cannot collide.
final class StubURLProtocol: URLProtocol {
    struct StubResponse {
        var statusCode: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [(matcher: @Sendable (URLRequest) -> Bool, response: StubResponse)] = []
    nonisolated(unsafe) private static var unmatchedRequests: [URLRequest] = []

    static func register(matcher: @escaping @Sendable (URLRequest) -> Bool, response: StubResponse) {
        lock.lock()
        defer { lock.unlock() }
        handlers.append((matcher, response))
    }

    static func registerJSON(matcher: @escaping @Sendable (URLRequest) -> Bool, json: String, statusCode: Int = 200) {
        register(matcher: matcher, response: StubResponse(statusCode: statusCode, body: Data(json.utf8)))
    }

    static var unmatched: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return unmatchedRequests
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response: StubResponse? = Self.lock.withLock {
            if let match = Self.handlers.first(where: { $0.matcher(request) }) {
                return match.response
            }
            Self.unmatchedRequests.append(request)
            return nil
        }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    var queryValues: [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                          uniquingKeysWith: { _, new in new })
    }
}

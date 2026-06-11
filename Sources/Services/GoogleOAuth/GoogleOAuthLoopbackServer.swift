import Darwin
import Foundation

private final class SingleResumeContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        let continuation = takeContinuation()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        let continuation = takeContinuation()
        continuation?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    let redirectURI: String

    private let socketFD: Int32
    private let port: UInt16
    private let path: String
    private let lock = NSLock()
    private var closed = false

    init(path: String = "/oauth2redirect") throws {
        self.path = path.hasPrefix("/") ? path : "/\(path)"

        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            AppLog.oauth.error("loopbackSocketFailed step=socket")
            throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
        }
        self.socketFD = socketFD

        var reuse: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketFD)
            AppLog.oauth.error("loopbackSocketFailed step=setsockopt")
            throw GoogleOAuthError.loopbackServerFailed(reason)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketFD)
            AppLog.oauth.error("loopbackSocketFailed step=bind")
            throw GoogleOAuthError.loopbackServerFailed(reason)
        }

        guard Darwin.listen(socketFD, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketFD)
            AppLog.oauth.error("loopbackSocketFailed step=listen")
            throw GoogleOAuthError.loopbackServerFailed(reason)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(socketFD, socketAddress, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketFD)
            AppLog.oauth.error("loopbackSocketFailed step=getsockname")
            throw GoogleOAuthError.loopbackServerFailed(reason)
        }

        port = UInt16(bigEndian: boundAddress.sin_port)
        redirectURI = "http://127.0.0.1:\(port)\(self.path)"
        AppLog.oauth.info("loopbackListenerStarted host=127.0.0.1 path=\(self.path, privacy: .public)")
    }

    deinit {
        closeListeningSocket()
    }

    func waitForCallback(timeout: TimeInterval = 180) async throws -> URL {
        AppLog.oauth.info("loopbackWaitForCallback timeoutSeconds=\(Int(timeout), privacy: .public)")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let gate = SingleResumeContinuation(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try self.acceptCallbackLoop()
                    self.closeListeningSocket()
                    gate.resume(returning: url)
                } catch {
                    self.closeListeningSocket()
                    gate.resume(throwing: error)
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                self.closeListeningSocket()
                AppLog.oauth.error("loopbackCallbackTimedOut")
                gate.resume(throwing: GoogleOAuthError.callbackTimedOut)
            }
        }
    }

    /// Accepts connections until a request for the expected callback path
    /// arrives. Browsers open speculative connections that send no data and
    /// request /favicon.ico; consuming the first connection and closing the
    /// listener (the previous behavior) made sign-in flaky.
    private func acceptCallbackLoop() throws -> URL {
        var attempts = 0
        while attempts < 32 {
            attempts += 1
            do {
                if let url = try acceptOneConnection() {
                    return url
                }
                AppLog.oauth.debug("loopbackIgnoredNoiseConnection attempt=\(attempts, privacy: .public)")
            } catch let error as GoogleOAuthError {
                // Listener socket failures are fatal; per-connection issues are not.
                if case .loopbackServerFailed = error, isListenerClosed() {
                    throw error
                }
                AppLog.oauth.debug("loopbackConnectionError attempt=\(attempts, privacy: .public)")
            }
        }
        throw GoogleOAuthError.loopbackServerFailed("No valid callback after \(attempts) connections.")
    }

    /// Returns the callback URL, or nil for noise connections (empty payload,
    /// wrong path) that were answered and should not end the wait.
    private func acceptOneConnection() throws -> URL? {
        var clientAddress = sockaddr_in()
        var clientAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.accept(socketFD, socketAddress, &clientAddressLength)
            }
        }
        guard clientFD >= 0 else {
            throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(clientFD) }

        // Per-connection read deadline so an idle speculative connection
        // cannot stall the accept loop until the overall timeout.
        var readTimeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        let request: String
        do {
            request = try readHTTPRequest(from: clientFD)
        } catch {
            return nil
        }
        guard let firstLine = request.components(separatedBy: "\r\n").first, !firstLine.isEmpty else {
            AppLog.oauth.debug("loopbackEmptyConnection")
            return nil
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            try? sendResponse(to: clientFD, status: "400 Bad Request", body: "Meeting Shield could not read this Google sign-in callback.")
            AppLog.oauth.debug("loopbackCallbackMalformed reason=requestLine")
            return nil
        }

        let target = String(parts[1])
        guard let callbackURL = URL(string: "http://127.0.0.1:\(port)\(target)"),
              URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.path == path else {
            try? sendResponse(to: clientFD, status: "404 Not Found", body: "This sign-in callback does not belong to Meeting Shield.")
            AppLog.oauth.debug("loopbackUnexpectedPathIgnored")
            return nil
        }

        AppLog.oauth.info("loopbackCallbackReceived path=\(self.path, privacy: .public)")
        try sendResponse(
            to: clientFD,
            status: "200 OK",
            body: "Google Calendar is connected. You can close this browser tab and return to Meeting Shield."
        )
        return callbackURL
    }

    private func isListenerClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func readHTTPRequest(from clientFD: Int32) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < 16_384 {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(clientFD, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if count < 0 {
                throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func sendResponse(to clientFD: Int32, status: String, body: String) throws {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Meeting Shield</title></head><body><p>\(body)</p></body></html>
        """
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        let bytes = [UInt8](response.utf8)
        let sent = bytes.withUnsafeBytes { rawBuffer in
            Darwin.send(clientFD, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        if sent < 0 {
            throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
        }
    }

    private func closeListeningSocket() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(socketFD, SHUT_RDWR)
        Darwin.close(socketFD)
    }
}

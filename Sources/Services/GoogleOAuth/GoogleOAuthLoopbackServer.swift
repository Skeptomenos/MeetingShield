import Darwin
import Foundation

private final class SingleResumeContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var workerActive = false

    var isCompleted: Bool {
        lock.withLock { result != nil }
    }

    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        workerActive = true
        lock.unlock()
        return true
    }

    func interrupt(with result: Result<T, Error>, close: () -> Void) {
        lock.withLock {
            guard self.result == nil else { return }
            self.result = result
            if !workerActive { close() }
        }
    }

    func finishWorker(with result: Result<T, Error>, close: () -> Void) {
        lock.lock()
        if self.result == nil { self.result = result }
        close()
        workerActive = false
        let finalResult = self.result ?? result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: finalResult)
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
        do {
            try Self.makeNonblocking(socketFD)
        } catch {
            Darwin.close(socketFD)
            throw error
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
        AppLog.oauth.info("loopbackListenerStarted host=127.0.0.1")
    }

    deinit {
        closeListeningSocket()
    }

    func waitForCallback(timeout: TimeInterval = 180) async throws -> URL {
        AppLog.oauth.info("loopbackWaitForCallback timeoutSeconds=\(Int(timeout), privacy: .public)")
        let gate = SingleResumeContinuation<URL>()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard gate.install(continuation) else { return }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Result {
                            try self.acceptCallbackLoop(deadline: deadline, isCompleted: { gate.isCompleted })
                        }
                        gate.finishWorker(with: result) { self.closeListeningSocket() }
                    }
                }
            } onCancel: {
                gate.interrupt(with: .failure(CancellationError())) { self.closeListeningSocket() }
            }
        } catch {
            if error as? GoogleOAuthError == .callbackTimedOut {
                AppLog.oauth.error("loopbackCallbackTimedOut")
            }
            throw error
        }
    }

    private static func makeNonblocking(_ socket: Int32) throws {
        let flags = fcntl(socket, F_GETFL, 0)
        var noSignal: Int32 = 1
        guard flags >= 0,
              fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0,
              setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
        }
    }

    private func checkWait(deadline: ContinuousClock.Instant, isCompleted: () -> Bool) throws {
        if isCompleted() { throw CancellationError() }
        if ContinuousClock.now >= deadline { throw GoogleOAuthError.callbackTimedOut }
    }

    private func waitForReadiness(
        socket: Int32,
        events: Int16,
        deadline: ContinuousClock.Instant,
        idleDeadline: ContinuousClock.Instant? = nil,
        isCompleted: () -> Bool
    ) throws {
        while true {
            try checkWait(deadline: deadline, isCompleted: isCompleted)
            let now = ContinuousClock.now
            if let idleDeadline, now >= idleDeadline {
                throw GoogleOAuthError.loopbackServerFailed("Local callback connection was idle.")
            }
            let remaining = now.duration(to: min(deadline, idleDeadline ?? deadline)).components
            let milliseconds = Double(remaining.seconds) * 1000 + Double(remaining.attoseconds) / 1e15
            var descriptor = pollfd(fd: socket, events: events, revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(max(1, min(100, milliseconds.rounded(.up)))))
            let pollError = errno
            try checkWait(deadline: deadline, isCompleted: isCompleted)
            if ready > 0 { return }
            if ready < 0, pollError != EINTR {
                throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(pollError)))
            }
        }
    }

    private func acceptCallbackLoop(deadline: ContinuousClock.Instant, isCompleted: () -> Bool) throws -> URL {
        var attempts = 0
        while attempts < 32 {
            try waitForReadiness(socket: socketFD, events: Int16(POLLIN), deadline: deadline, isCompleted: isCompleted)
            do {
                if let url = try acceptOneConnection(deadline: deadline, isCompleted: isCompleted) {
                    return url
                }
                attempts += 1
                AppLog.oauth.debug("loopbackIgnoredNoiseConnection attempt=\(attempts, privacy: .public)")
            } catch let error as GoogleOAuthError {
                if error == .callbackTimedOut { throw error }
                attempts += 1
                AppLog.oauth.debug("loopbackConnectionError attempt=\(attempts, privacy: .public)")
            }
        }
        throw GoogleOAuthError.loopbackServerFailed("No valid callback after \(attempts) connections.")
    }

    private func acceptOneConnection(deadline: ContinuousClock.Instant, isCompleted: () -> Bool) throws -> URL? {
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
        try Self.makeNonblocking(clientFD)

        let request = try readHTTPRequest(from: clientFD, deadline: deadline, isCompleted: isCompleted)
        guard let firstLine = request.components(separatedBy: "\r\n").first, !firstLine.isEmpty else {
            AppLog.oauth.debug("loopbackEmptyConnection")
            return nil
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            try? sendResponse(to: clientFD, status: "400 Bad Request", body: "Meeting Shield could not read this Google sign-in callback.", deadline: deadline, isCompleted: isCompleted)
            AppLog.oauth.debug("loopbackCallbackMalformed reason=requestLine")
            return nil
        }

        let target = String(parts[1])
        guard let callbackURL = URL(string: "http://127.0.0.1:\(port)\(target)"),
              URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.path == path else {
            try? sendResponse(to: clientFD, status: "404 Not Found", body: "This sign-in callback does not belong to Meeting Shield.", deadline: deadline, isCompleted: isCompleted)
            AppLog.oauth.debug("loopbackUnexpectedPathIgnored")
            return nil
        }

        AppLog.oauth.info("loopbackCallbackReceived")
        try sendResponse(
            to: clientFD,
            status: "200 OK",
            body: "Google Calendar is connected. You can close this browser tab and return to Meeting Shield.",
            deadline: deadline, isCompleted: isCompleted
        )
        return callbackURL
    }

    private func readHTTPRequest(
        from clientFD: Int32, deadline: ContinuousClock.Instant, isCompleted: () -> Bool
    ) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var idleDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while data.count < 16_384 {
            try waitForReadiness(
                socket: clientFD, events: Int16(POLLIN), deadline: deadline,
                idleDeadline: idleDeadline, isCompleted: isCompleted
            )
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(clientFD, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw GoogleOAuthError.loopbackServerFailed(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            idleDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            data.append(contentsOf: buffer.prefix(count))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func sendResponse(
        to clientFD: Int32, status: String, body: String,
        deadline: ContinuousClock.Instant, isCompleted: () -> Bool
    ) throws {
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
        var offset = 0
        var idleDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while offset < bytes.count {
            try waitForReadiness(
                socket: clientFD, events: Int16(POLLOUT), deadline: deadline,
                idleDeadline: idleDeadline, isCompleted: isCompleted
            )
            let sent = bytes.withUnsafeBytes { rawBuffer in
                Darwin.send(clientFD, rawBuffer.baseAddress?.advanced(by: offset), rawBuffer.count - offset, 0)
            }
            if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            guard sent > 0 else {
                throw GoogleOAuthError.loopbackServerFailed("Local callback response failed.")
            }
            offset += sent
            idleDeadline = ContinuousClock.now.advanced(by: .seconds(2))
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

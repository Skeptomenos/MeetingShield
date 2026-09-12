import Darwin
import Foundation
import Testing
@testable import MeetingShield

@Suite("Google OAuth real local listener cancellation")
struct GoogleOAuthLoopbackCancellationTests {
    @Test("An already cancelled callback wait throws cancellation and closes its listener")
    func cancellationBeforeWaitClosesListener() async throws {
        let server = try GoogleOAuthLoopbackServer(path: "/cancel-before-wait")
        let probe = try LocalSocketProbe(redirectURI: server.redirectURI)
        let waitTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            return try await server.waitForCallback(timeout: 0.2)
        }

        let result = await waitTask.result

        expectCancellation(result)
        #expect(try await probe.connectionFailure() == ECONNREFUSED)
    }

    @Test("Cancelling an active callback wait throws cancellation and closes its listener")
    func cancellationAfterNoiseResponseClosesListener() async throws {
        let server = try GoogleOAuthLoopbackServer(path: "/cancel-active-wait")
        let probe = try LocalSocketProbe(redirectURI: server.redirectURI)
        let waitTask = Task { try await server.waitForCallback(timeout: 1) }
        let noiseResponse = try await response(
            from: probe,
            target: "/unrelated-local-probe",
            waiting: waitTask
        )
        #expect(noiseResponse.hasPrefix("HTTP/1.1 404 Not Found\r\n"))

        waitTask.cancel()
        let result = await waitTask.result

        expectCancellation(result)
        #expect(try await probe.connectionFailure() == ECONNREFUSED)
    }

    @Test("An uncancelled listener captures a synthetic local callback after noise")
    func syntheticCallbackSucceedsAfterNoise() async throws {
        let server = try GoogleOAuthLoopbackServer(path: "/successful-local-callback")
        let probe = try LocalSocketProbe(redirectURI: server.redirectURI)
        let waitTask = Task { try await server.waitForCallback(timeout: 1) }
        let noiseResponse = try await response(
            from: probe,
            target: "/unrelated-local-probe",
            waiting: waitTask
        )
        #expect(noiseResponse.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        let callbackResponse = try await response(
            from: probe,
            target: "/successful-local-callback?code=synthetic-local-code&state=synthetic-local-state",
            waiting: waitTask
        )
        let callback = try await waitTask.value

        #expect(callbackResponse.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(callback.absoluteString == "\(server.redirectURI)?code=synthetic-local-code&state=synthetic-local-state")
        #expect(try await probe.connectionFailure() == ECONNREFUSED)
    }

    @Test("An uncancelled callback wait reports timeout and closes its listener")
    func ordinaryTimeoutClosesListener() async throws {
        let server = try GoogleOAuthLoopbackServer(path: "/uncancelled-local-timeout")
        let probe = try LocalSocketProbe(redirectURI: server.redirectURI)
        let waitTask = Task { try await server.waitForCallback(timeout: 0.2) }

        let result = await waitTask.result

        switch result {
        case .success:
            Issue.record("The listener accepted a callback without a local request.")
        case let .failure(error):
            #expect(error as? GoogleOAuthError == .callbackTimedOut)
        }
        #expect(try await probe.connectionFailure() == ECONNREFUSED)
    }

    @Test("Cancellation closes a peer with an unfinished HTTP request in less than one second")
    func cancellationInterruptsPartialRequest() async throws {
        try await exercisePartialRequest(cancel: true)
    }

    @Test("Timeout closes a peer with an unfinished HTTP request in less than two seconds")
    func timeoutInterruptsPartialRequest() async throws {
        try await exercisePartialRequest(cancel: false)
    }

    private func exercisePartialRequest(cancel: Bool) async throws {
        let server = try GoogleOAuthLoopbackServer(path: "/partial-local-callback")
        let probe = try LocalSocketProbe(redirectURI: server.redirectURI)
        let waitStarted = ContinuousClock.now
        let waitTask = Task { try await server.waitForCallback(timeout: cancel ? 5 : 1) }
        defer { waitTask.cancel() }
        let partial = try await probe.partialRequest()
        let fallback = Task.detached {
            do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
            partial.close()
        }
        defer {
            fallback.cancel()
            partial.close()
        }
        try #require(await partial.hasNoResponse())
        let measurementStart = cancel ? ContinuousClock.now : waitStarted

        if cancel { waitTask.cancel() }
        let result = await waitTask.result
        let peerClosed = await partial.peerClosed()
        let elapsed = measurementStart.duration(to: ContinuousClock.now)

        if cancel {
            expectCancellation(result)
        } else {
            switch result {
            case .success:
                Issue.record("An unfinished HTTP request was accepted as a callback.")
            case let .failure(error):
                #expect(error as? GoogleOAuthError == .callbackTimedOut)
            }
        }
        #expect(elapsed < (cancel ? .seconds(1) : .seconds(2)))
        #expect(peerClosed)
        #expect(try await probe.connectionFailure() == ECONNREFUSED)
    }

    private func expectCancellation(_ result: Result<URL, any Error>) {
        switch result {
        case .success:
            Issue.record("A cancelled local callback wait returned a callback.")
        case let .failure(error):
            #expect(error is CancellationError)
        }
    }

    private func response(
        from probe: LocalSocketProbe,
        target: String,
        waiting waitTask: Task<URL, any Error>
    ) async throws -> String {
        do {
            return try await probe.response(for: target)
        } catch {
            waitTask.cancel()
            _ = await waitTask.result
            throw error
        }
    }

    private struct LocalSocketProbe: Sendable {
        let port: UInt16

        init(redirectURI: String) throws {
            let url = try #require(URLComponents(string: redirectURI))
            try #require(url.scheme == "http")
            try #require(url.host == "127.0.0.1")
            let portValue = try #require(url.port)
            port = try #require(UInt16(exactly: portValue))
            try #require(port > 0)
        }

        func response(for target: String) async throws -> String {
            try await Task.detached {
                let socket = try makeSocket()
                defer { Darwin.close(socket) }
                guard connect(socket) == 0 else { throw socketError() }
                let request = Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)
                let sent = request.withUnsafeBytes { bytes in
                    Darwin.send(socket, bytes.baseAddress, bytes.count, 0)
                }
                guard sent == request.count else { throw socketError() }
                var response = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while response.count < 16_384 {
                    let count = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.recv(socket, bytes.baseAddress, bytes.count, 0)
                    }
                    guard count >= 0 else { throw socketError() }
                    if count == 0 { return String(decoding: response, as: UTF8.self) }
                    response.append(contentsOf: buffer.prefix(count))
                }
                throw POSIXError(.EMSGSIZE)
            }.value
        }

        func connectionFailure() async throws -> Int32? {
            try await Task.detached {
                let socket = try makeSocket()
                defer { Darwin.close(socket) }
                return connect(socket) == 0 ? nil : errno
            }.value
        }

        func partialRequest() async throws -> PartialRequestSocket {
            try await Task.detached {
                let socket = try makeSocket()
                do {
                    guard connect(socket) == 0 else { throw socketError() }
                    let request = Data("GET /partial-local-callback?code=synthetic-partial HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Unfinished: held".utf8)
                    let sent = request.withUnsafeBytes { bytes in
                        Darwin.send(socket, bytes.baseAddress, bytes.count, 0)
                    }
                    guard sent == request.count else { throw socketError() }
                    return PartialRequestSocket(socket: socket)
                } catch {
                    Darwin.close(socket)
                    throw error
                }
            }.value
        }

        private func makeSocket() throws -> Int32 {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { throw socketError() }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            var noSignal: Int32 = 1
            guard setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                let error = socketError()
                Darwin.close(socket)
                throw error
            }
            return socket
        }

        private func connect(_ socket: Int32) -> Int32 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(socket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        private func socketError() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private final class PartialRequestSocket: @unchecked Sendable {
        private let socket: Int32
        private let lock = NSLock()
        private var closed = false

        init(socket: Int32) {
            self.socket = socket
        }

        func hasNoResponse() async -> Bool {
            await Task.detached {
                self.lock.withLock {
                    guard !self.closed else { return false }
                    var descriptor = pollfd(fd: self.socket, events: Int16(POLLIN), revents: 0)
                    return Darwin.poll(&descriptor, 1, 50) == 0
                }
            }.value
        }

        func peerClosed() async -> Bool {
            await Task.detached {
                self.lock.withLock {
                    guard !self.closed else { return false }
                    var byte: UInt8 = 0
                    let count = Darwin.recv(self.socket, &byte, 1, MSG_PEEK)
                    return count == 0 || (count < 0 && errno == ECONNRESET)
                }
            }.value
        }

        func close() {
            lock.withLock {
                guard !closed else { return }
                closed = true
                Darwin.shutdown(socket, SHUT_RDWR)
                Darwin.close(socket)
            }
        }
    }
}

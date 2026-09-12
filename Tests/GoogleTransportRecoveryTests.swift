import Darwin
import Foundation
import Testing
@testable import MeetingShield

@Suite("Google transport time bounds")
struct GoogleTransportRecoveryTests {
    @Test("The default Google session bounds inactivity and each complete HTTP transfer")
    func defaultGoogleSessionBoundsEachTransfer() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = InMemoryKeychain()
        let client = defaultClient(directory: directory, keychain: keychain)
        let configuration = client.session.configuration

        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(configuration.timeoutIntervalForResource == 60)
        #expect(keychain.valueCount == 0)
    }

    @Test("Foundation distinguishes an idle connection from a progressing transfer", arguments: TransportCase.allCases)
    func loopbackTransportHonorsSeparateDeadlines(scenario: TransportCase) async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = InMemoryKeychain()
        let client = defaultClient(directory: directory, keychain: keychain)
        let configuration = client.session.configuration
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = scenario == .drippingResourceTimeout ? 1.25 : 5
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.protocolClasses = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let server = try LoopbackHTTPServer(scenario: scenario)
        defer { server.stop() }
        server.start()
        var request = URLRequest(url: server.url)
        request.timeoutInterval = configuration.timeoutIntervalForRequest
        let started = ContinuousClock.now
        var received: Data?
        var status: Int?
        var error: Error?

        do {
            let response = try await session.data(for: request)
            received = response.0
            status = (response.1 as? HTTPURLResponse)?.statusCode
        } catch let failure {
            error = failure
        }

        let elapsed = started.duration(to: ContinuousClock.now)
        server.stop()
        await server.waitUntilClosed()
        let observation = server.observation
        #expect(observation.closed)
        #expect(observation.accepted == 1)
        #expect(observation.receivedExpectedRequest)
        #expect(observation.failure == nil)
        #expect(keychain.valueCount == 0)
        switch scenario {
        case .silentInactivityTimeout:
            #expect((error as? URLError)?.code == .timedOut)
            #expect(received == nil)
            #expect(observation.sentChunks == 0)
            #expect(elapsed >= .milliseconds(200))
            #expect(elapsed < .seconds(4))
        case .finiteDripSurvivesInactivityLimit:
            #expect(error == nil)
            #expect(status == 200)
            #expect(received == Data(repeating: 120, count: 20))
            #expect(observation.sentChunks == 20)
            #expect(elapsed > .seconds(1))
            #expect(elapsed < .seconds(5))
        case .drippingResourceTimeout:
            #expect((error as? URLError)?.code == .timedOut)
            #expect(received == nil)
            #expect(observation.sentChunks >= 5)
            #expect(elapsed >= .milliseconds(800))
            #expect(elapsed < .seconds(4))
        }
    }

    private func defaultClient(directory: URL, keychain: InMemoryKeychain) -> GoogleOAuthClient {
        GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "synthetic-transport-\(UUID().uuidString)"),
            keychain: keychain,
            diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
        )
    }

    enum TransportCase: CaseIterable, Equatable, Sendable {
        case silentInactivityTimeout
        case finiteDripSurvivesInactivityLimit
        case drippingResourceTimeout
    }

    private final class LoopbackHTTPServer: @unchecked Sendable {
        struct Observation: Sendable {
            var accepted = 0
            var receivedExpectedRequest = false
            var sentChunks = 0
            var closed = false
            var failure: String?
        }

        private enum SetupFailure: Error {
            case posix(Int32)
            case invalidAddress
        }

        let url: URL
        private let listener: Int32
        private let target: String
        private let scenario: TransportCase
        private let lock = NSLock()
        private var stopRequested = false
        private var servingTask: Task<Void, Never>?
        private var state = Observation()

        var observation: Observation { lock.withLock { state } }

        init(scenario: TransportCase) throws {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw SetupFailure.posix(errno) }
            var configured = false
            defer { if !configured { Darwin.close(descriptor) } }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(descriptor, 1) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw SetupFailure.posix(errno)
            }
            var boundAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { throw SetupFailure.posix(errno) }
            let target = "/owned-transport-\(UUID().uuidString)"
            let port = UInt16(bigEndian: boundAddress.sin_port)
            guard port != 0, let url = URL(string: "http://127.0.0.1:\(port)\(target)") else {
                throw SetupFailure.invalidAddress
            }
            self.url = url
            self.listener = descriptor
            self.target = target
            self.scenario = scenario
            configured = true
        }

        func start() {
            lock.withLock {
                guard servingTask == nil else { return }
                servingTask = Task.detached(priority: .userInitiated) { self.serve() }
            }
        }

        func stop() {
            lock.withLock { stopRequested = true }
        }

        func waitUntilClosed() async {
            let task = lock.withLock { servingTask }
            await task?.value
        }

        private func shouldContinue(until deadline: ContinuousClock.Instant) -> Bool {
            ContinuousClock.now < deadline && lock.withLock { !stopRequested }
        }

        private func serve() {
            defer {
                Darwin.close(listener)
                lock.withLock { state.closed = true }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            guard let connection = acceptConnection(until: deadline) else { return }
            defer { Darwin.close(connection) }
            guard readExpectedRequest(connection, until: deadline) else { return }
            if scenario == .silentInactivityTimeout {
                while shouldContinue(until: deadline) {
                    if peerClosed(connection) { return }
                }
                return
            }
            let bodyLength = scenario == .finiteDripSurvivesInactivityLimit ? 20 : 1_000_000
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(bodyLength)\r\nConnection: close\r\n\r\n"
            guard send(Data(header.utf8), to: connection, until: deadline) else { return }
            var sent = 0
            var nextChunk = ContinuousClock.now
            while shouldContinue(until: deadline) {
                if ContinuousClock.now >= nextChunk {
                    guard send(Data([120]), to: connection, until: deadline) else { return }
                    sent += 1
                    lock.withLock { state.sentChunks = sent }
                    if sent == bodyLength { return }
                    nextChunk = ContinuousClock.now.advanced(by: .milliseconds(100))
                }
                if peerClosed(connection) { return }
            }
        }

        private func acceptConnection(until deadline: ContinuousClock.Instant) -> Int32? {
            while shouldContinue(until: deadline) {
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    recordFailure("listener_poll")
                    return nil
                }
                guard ready > 0 else { continue }
                let connection = Darwin.accept(listener, nil, nil)
                guard connection >= 0 else {
                    if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    recordFailure("accept")
                    return nil
                }
                var noSignal: Int32 = 1
                guard fcntl(connection, F_SETFL, O_NONBLOCK) == 0,
                      setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    Darwin.close(connection)
                    recordFailure("connection_setup")
                    return nil
                }
                lock.withLock { state.accepted += 1 }
                return connection
            }
            return nil
        }

        private func readExpectedRequest(_ connection: Int32, until deadline: ContinuousClock.Instant) -> Bool {
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 2_048)
            while shouldContinue(until: deadline) {
                var descriptor = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&descriptor, 1, 50) > 0 else { continue }
                let count = buffer.withUnsafeMutableBytes { Darwin.recv(connection, $0.baseAddress, $0.count, 0) }
                guard count > 0 else {
                    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
                    return false
                }
                request.append(contentsOf: buffer.prefix(count))
                guard request.count <= 16_384 else {
                    recordFailure("oversized_request")
                    return false
                }
                guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else { continue }
                let matches = text.hasPrefix("GET \(target) HTTP/1.1\r\n")
                lock.withLock { state.receivedExpectedRequest = matches }
                if !matches { recordFailure("unexpected_request") }
                return matches
            }
            return false
        }

        private func send(_ bytes: Data, to connection: Int32, until deadline: ContinuousClock.Instant) -> Bool {
            bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return false }
                var offset = 0
                while offset < buffer.count && shouldContinue(until: deadline) {
                    let sent = Darwin.send(connection, base.advanced(by: offset), buffer.count - offset, 0)
                    if sent > 0 {
                        offset += sent
                    } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        var descriptor = pollfd(fd: connection, events: Int16(POLLOUT), revents: 0)
                        _ = Darwin.poll(&descriptor, 1, 50)
                    } else {
                        return false
                    }
                }
                return offset == buffer.count
            }
        }

        private func peerClosed(_ connection: Int32) -> Bool {
            var descriptor = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 50) > 0 else { return false }
            var byte: UInt8 = 0
            let count = Darwin.recv(connection, &byte, 1, MSG_PEEK)
            return count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
        }

        private func recordFailure(_ value: String) {
            lock.withLock { state.failure = value }
        }
    }
}

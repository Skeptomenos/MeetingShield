import Foundation
import Testing
@testable import MeetingShield

@Suite("Google OAuth synchronous mutation contention")
struct GoogleOAuthConcurrencyTests {
    @Test("Separate clients serialize mutations in one credential namespace", arguments: Mutation.allCases)
    func sharedNamespacePreservesBothMutations(mutation: Mutation) async throws {
        try await exercise(mutation: mutation, sharedNamespace: true)
    }

    @Test("The contention probe detects stale writes without a shared namespace")
    func independentNamespaceControlLosesTheLaterAddition() async throws {
        try await exercise(mutation: .add, sharedNamespace: false)
    }

    private func exercise(mutation: Mutation, sharedNamespace: Bool) async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContendedStore()
        defer { store.releaseFirstRead() }
        let namespace = "MeetingShieldOAuthContention.\(UUID().uuidString)"
        let firstStore = IsolatedKeychain(store: store, namespace: namespace)
        let secondStore = IsolatedKeychain(store: store, namespace: sharedNamespace ? namespace : namespace + ".control")
        let recorder = DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
        let configuration = GoogleOAuthConfiguration(clientID: "synthetic-contention")
        let firstClient = GoogleOAuthClient(configuration: configuration, keychain: firstStore, diagnostics: recorder)
        let secondClient = GoogleOAuthClient(configuration: configuration, keychain: secondStore, diagnostics: recorder)
        let original = token("original")
        let firstAddition = token("first")
        let secondAddition = token("second")
        try firstClient.saveToken(original)
        store.arm()

        let first = Task {
            try await onThread {
                switch mutation {
                case .add: try firstClient.saveToken(firstAddition)
                case .remove: try firstClient.removeToken(accountID: "original@example.invalid")
                case .clear: try firstClient.clearToken()
                }
            }
        }
        let firstReadEntered = try await onThread { store.waitForFirstRead() }
        #expect(firstReadEntered)
        let second = Task {
            try await onThread { try secondClient.saveToken(secondAddition) }
        }
        let secondAttempted = try await onThread { store.waitForSecondMutationAttempt() }
        #expect(secondAttempted)
        let concurrentRead = try await onThread { store.waitForConcurrentRead() }
        #expect(concurrentRead == !sharedNamespace)
        if concurrentRead { try await second.value }
        store.releaseFirstRead()
        try await first.value
        try await second.value

        #expect(!store.firstReadTimedOut)
        let inventory = firstClient.tokenInventory()
        #expect(inventory.isComplete)
        let expected: Set<String>
        if sharedNamespace {
            expected = mutation == .add
                ? ["original@example.invalid", "first@example.invalid", "second@example.invalid"]
                : ["second@example.invalid"]
        } else {
            expected = ["original@example.invalid", "first@example.invalid"]
        }
        #expect(Set(inventory.tokens.compactMap(\.accountID)) == expected)
        #expect(secondClient.tokenInventory().tokens == inventory.tokens)
        #expect(inventory.tokens.contains(firstAddition) == (mutation == .add))
        #expect(inventory.tokens.contains(secondAddition) == sharedNamespace)
        #expect(inventory.tokens.contains(original) == (mutation == .add))
    }

    private func token(_ name: String) -> GoogleOAuthToken {
        GoogleOAuthToken(
            accessToken: "synthetic-\(name)", refreshToken: "synthetic-refresh-\(name)",
            expiresAt: .distantFuture, scope: AppIdentity.googleScopes.joined(separator: " "), tokenType: "Bearer",
            accountID: "\(name)@example.invalid", accountDisplayName: "Synthetic \(name)"
        )
    }

    private func onThread<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                continuation.resume(with: Result(catching: body))
            }.start()
        }
    }

    enum Mutation: CaseIterable, Sendable {
        case add, remove, clear
    }

    private final class IsolatedKeychain: KeychainStoring, Sendable {
        let store: ContendedStore
        let identity: KeychainService

        init(store: ContendedStore, namespace: String) {
            self.store = store
            identity = KeychainService(service: namespace)
        }

        var oauthMutationState: GoogleOAuthMutationState {
            store.recordMutationAttempt()
            return identity.oauthMutationState
        }

        func save(_ value: String, forKey key: String) throws { store.save(value, forKey: key) }
        func read(forKey key: String) throws -> String? { store.read(forKey: key) }
        func retrieve(forKey key: String) -> String? { store.read(forKey: key) }
        func delete(forKey key: String) throws { store.delete(forKey: key) }
    }

    private final class ContendedStore: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [String: String] = [:]
        private var armed = false
        private var attempts = 0
        private var reads = 0
        private var released = false
        private var readTimedOut = false

        var firstReadTimedOut: Bool { condition.withLock { readTimedOut } }

        func arm() {
            condition.withLock {
                armed = true
                attempts = 0
                reads = 0
                released = false
                readTimedOut = false
            }
        }

        func recordMutationAttempt() {
            condition.withLock {
                guard armed else { return }
                attempts += 1
                condition.broadcast()
            }
        }

        func save(_ value: String, forKey key: String) {
            condition.withLock { values[key] = value }
        }

        func read(forKey key: String) -> String? {
            condition.lock()
            defer { condition.unlock() }
            let captured = values[key]
            guard armed, key == "google.oauth.tokens" else { return captured }
            reads += 1
            condition.broadcast()
            if reads == 1 {
                let deadline = Date().addingTimeInterval(3)
                while !released {
                    if !condition.wait(until: deadline) {
                        readTimedOut = true
                        break
                    }
                }
            }
            return captured
        }

        func delete(forKey key: String) {
            condition.withLock { _ = values.removeValue(forKey: key) }
        }

        func releaseFirstRead() {
            condition.withLock {
                released = true
                armed = false
                condition.broadcast()
            }
        }

        func waitForFirstRead() -> Bool { wait(until: { reads > 0 }, timeout: 2) }
        func waitForSecondMutationAttempt() -> Bool { wait(until: { attempts > 1 }, timeout: 2) }
        func waitForConcurrentRead() -> Bool { wait(until: { reads > 1 }, timeout: 0.3) }

        private func wait(until predicate: () -> Bool, timeout: TimeInterval) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate() {
                if !condition.wait(until: deadline) { return predicate() }
            }
            return true
        }
    }
}

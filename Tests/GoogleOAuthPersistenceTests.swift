import Foundation
import Testing
@testable import MeetingShield

@Suite("Google OAuth persistence failure recovery")
struct GoogleOAuthPersistenceTests {
    @Test("Missing first-run credentials are healthy and Retry performs no writes")
    func missingFirstRunStaysReadOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let inventory = fixture.first.tokenInventory()
        fixture.second.retryPersistence()

        #expect(inventory.isComplete)
        #expect(inventory.tokens.isEmpty)
        #expect(inventory.knownAccountIDs.isEmpty)
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
        #expect(fixture.keychain.snapshot.isEmpty)
        #expect(fixture.keychain.saveAttempts.isEmpty)
        #expect(fixture.keychain.deleteAttempts.isEmpty)
    }

    @Test("Read repair clears only the read warning and preserves credential bytes", arguments: ReadDamage.allCases)
    func readRepairPreservesOtherFailures(damage: ReadDamage) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.token(Fixture.accountA)
        let unsaved = fixture.token(Fixture.accountB)
        let collection = try Fixture.collection([original])
        fixture.keychain.seed(collection, forKey: Fixture.collectionKey)
        fixture.keychain.denySaves([Fixture.collectionKey])
        #expect(throws: KeychainError.self) { try fixture.first.saveToken(unsaved) }
        fixture.keychain.denySaves([])
        switch damage {
        case .corrupt:
            fixture.keychain.seed("{\"tokens\":", forKey: Fixture.collectionKey)
        case .denied:
            fixture.keychain.denyReads([Fixture.collectionKey])
        }
        let damaged = fixture.keychain.snapshot
        let saves = fixture.keychain.saveAttempts
        let deletes = fixture.keychain.deleteAttempts

        let inventory = fixture.first.tokenInventory()
        fixture.second.retryPersistence()

        #expect(!inventory.isComplete)
        #expect(inventory.tokens.isEmpty)
        #expect(fixture.first.persistenceFailures.contains(.read))
        #expect(fixture.first.persistenceFailures.contains(.save(accountID: Fixture.accountB)))
        #expect(fixture.second.persistenceFailures == fixture.first.persistenceFailures)
        #expect(fixture.keychain.snapshot == damaged)
        #expect(fixture.keychain.saveAttempts == saves)
        #expect(fixture.keychain.deleteAttempts == deletes)
        fixture.keychain.seed(collection, forKey: Fixture.collectionKey)
        fixture.keychain.denyReads([])
        let repaired = fixture.keychain.snapshot

        fixture.second.retryPersistence()

        #expect(fixture.first.persistenceFailures == [.save(accountID: Fixture.accountB)])
        #expect(fixture.second.persistenceFailures == [.save(accountID: Fixture.accountB)])
        #expect(fixture.first.tokenInventory().tokens == [original])
        #expect(fixture.keychain.snapshot == repaired)
        #expect(fixture.keychain.saveAttempts == saves)
        #expect(fixture.keychain.deleteAttempts == deletes)
    }

    @Test("A failed save survives healthy reads and another account save until that account is saved", arguments: [false, true])
    func failedSaveRequiresFreshMatchingSave(unassigned: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let accountID = unassigned ? nil : Fixture.accountA
        let original = fixture.token(accountID)
        let updated = fixture.token(accountID, version: "updated")
        let added = fixture.token(Fixture.accountB)
        fixture.keychain.seed(try Fixture.collection([original]), forKey: Fixture.collectionKey)
        let before = fixture.keychain.snapshot
        fixture.keychain.denySaves([Fixture.collectionKey])

        #expect(throws: KeychainError.self) { try fixture.first.saveToken(updated) }

        #expect(fixture.first.persistenceFailures == [.save(accountID: accountID)])
        #expect(fixture.second.persistenceFailures == [.save(accountID: accountID)])
        #expect(fixture.keychain.snapshot == before)
        fixture.keychain.denySaves([])
        let saves = fixture.keychain.saveAttempts
        let deletes = fixture.keychain.deleteAttempts
        #expect(fixture.second.tokenInventory().tokens == [original])

        fixture.first.retryPersistence()

        #expect(fixture.first.persistenceFailures == [.save(accountID: accountID)])
        #expect(fixture.keychain.snapshot == before)
        #expect(fixture.keychain.saveAttempts == saves)
        #expect(fixture.keychain.deleteAttempts == deletes)
        try fixture.second.saveToken(added)
        #expect(fixture.first.persistenceFailures == [.save(accountID: accountID)])
        #expect(fixture.second.tokenInventory().tokens.contains(original))
        #expect(fixture.second.tokenInventory().tokens.contains(added))

        try fixture.first.saveToken(updated)

        let inventory = fixture.second.tokenInventory()
        #expect(inventory.isComplete)
        #expect(inventory.tokens.count == 2)
        #expect(inventory.tokens.contains(updated))
        #expect(inventory.tokens.contains(added))
        #expect(!inventory.tokens.contains(original))
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
    }

    @Test("Retry does not replay a failed destructive action against newer credentials", arguments: DestructiveAction.allCases)
    func failedMutationRequiresFreshExplicitAction(action: DestructiveAction) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.token(Fixture.accountA)
        let second = fixture.token(Fixture.accountB)
        let added = fixture.token(Fixture.accountC)
        fixture.keychain.seed(try Fixture.collection([first, second]), forKey: Fixture.collectionKey)
        let before = fixture.keychain.snapshot
        fixture.keychain.denySaves([Fixture.collectionKey])

        #expect(throws: KeychainError.self) { try action.perform(on: fixture.first) }

        #expect(fixture.first.persistenceFailures == [action.failure])
        #expect(fixture.keychain.snapshot == before)
        #expect(fixture.keychain.deleteAttempts.isEmpty)
        fixture.keychain.denySaves([])
        let saves = fixture.keychain.saveAttempts
        #expect(fixture.second.tokenInventory().isComplete)

        fixture.second.retryPersistence()

        #expect(fixture.first.persistenceFailures == [action.failure])
        #expect(fixture.keychain.snapshot == before)
        #expect(fixture.keychain.saveAttempts == saves)
        #expect(fixture.keychain.deleteAttempts.isEmpty)
        try fixture.second.saveToken(added)
        let afterAddition = fixture.keychain.snapshot
        let afterAdditionSaves = fixture.keychain.saveAttempts
        let afterAdditionDeletes = fixture.keychain.deleteAttempts

        fixture.first.retryPersistence()

        #expect(fixture.first.persistenceFailures == [action.failure])
        #expect(fixture.keychain.snapshot == afterAddition)
        #expect(fixture.keychain.saveAttempts == afterAdditionSaves)
        #expect(fixture.keychain.deleteAttempts == afterAdditionDeletes)

        try action.perform(on: fixture.second)

        let saved = try #require(fixture.keychain.snapshot[Fixture.collectionKey])
        let remaining = try Fixture.decodeCollection(saved)
        let expected = action == .remove ? [second, added] : []
        #expect(Set(remaining.compactMap(\.accountID)) == Set(expected.compactMap(\.accountID)))
        #expect(remaining.count == expected.count)
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
        #expect(!fixture.keychain.deleteAttempts.contains(Fixture.collectionKey))
    }

    @Test("Shared legacy cleanup preserves accounts saved after the failed removal", arguments: NewerSave.allCases)
    func cleanupRetryPreservesNewerCredentials(change: NewerSave) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedLegacyAndCollection()
        fixture.keychain.denyDeletes([Fixture.accountAKey])

        try? fixture.first.removeToken(accountID: Fixture.accountA)

        #expect(fixture.first.persistenceFailures == [.legacyCleanup])
        #expect(fixture.second.persistenceFailures == [.legacyCleanup])
        let afterRemoval = fixture.keychain.snapshot
        let deletionAttempts = fixture.keychain.deleteAttempts
        let inventory = fixture.second.tokenInventory()
        #expect(inventory.isComplete)
        #expect(inventory.tokens.isEmpty)
        #expect(fixture.first.tokenInventory().tokens.isEmpty)
        #expect(fixture.keychain.snapshot == afterRemoval)
        #expect(fixture.keychain.deleteAttempts == deletionAttempts)
        let newer = fixture.token(change == .addAccount ? Fixture.accountB : Fixture.accountA, version: "newer")
        try? fixture.second.saveToken(newer)
        #expect(fixture.first.persistenceFailures == [.legacyCleanup])
        #expect(fixture.second.persistenceFailures == [.legacyCleanup])
        #expect(fixture.first.tokenInventory().tokens == [newer])
        let uncapturedKey = "google.oauth.token.synthetic-uncaptured"
        fixture.keychain.seed("synthetic-untouched-obsolete-key", forKey: uncapturedKey)
        let beforeRetry = fixture.keychain.snapshot
        let collection = try #require(beforeRetry[Fixture.collectionKey])
        let saveAttempts = fixture.keychain.saveAttempts
        let deleteCount = fixture.keychain.deleteAttempts.count
        fixture.keychain.denyDeletes([])

        fixture.first.retryPersistence()

        #expect(fixture.keychain.snapshot[Fixture.collectionKey] == collection)
        #expect(fixture.keychain.snapshot[uncapturedKey] == beforeRetry[uncapturedKey])
        #expect(fixture.keychain.snapshot[Fixture.accountAKey] == nil)
        #expect(fixture.keychain.snapshot[Fixture.indexKey] == nil)
        #expect(fixture.keychain.snapshot[Fixture.legacyKey] == nil)
        #expect(fixture.keychain.saveAttempts == saveAttempts)
        let retriedKeys = Set(fixture.keychain.deleteAttempts.dropFirst(deleteCount))
        let capturedKeys: Set<String> = [Fixture.accountAKey, Fixture.accountBKey, Fixture.indexKey, Fixture.legacyKey]
        #expect(!retriedKeys.isEmpty)
        #expect(retriedKeys.isSubset(of: capturedKeys))
        #expect(!retriedKeys.contains(Fixture.collectionKey))
        #expect(fixture.second.tokenInventory().tokens == [newer])
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
    }

    @Test("Fresh mutation state rediscovers indexed cleanup without changing authoritative credentials", arguments: [false, true])
    func reconstructedStoreRediscoversCleanup(emptyAuthority: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedLegacyAndCollection()
        let obsoleteKeys: Set<String> = [Fixture.accountAKey, Fixture.indexKey, Fixture.legacyKey]
        fixture.keychain.denyDeletes(obsoleteKeys)
        try? fixture.first.removeToken(accountID: Fixture.accountA)
        let added = fixture.token(Fixture.accountB, version: "after-removal")
        if !emptyAuthority {
            try? fixture.second.saveToken(added)
        }
        let persisted = fixture.keychain.snapshot
        let authority = try #require(persisted[Fixture.collectionKey])
        let expectedTokens = emptyAuthority ? [] : [added]
        try #require(try Fixture.decodeCollection(authority) == expectedTokens)
        try #require(obsoleteKeys.isSubset(of: Set(persisted.keys)))
        let reconstructed = FaultKeychain(values: persisted)
        let fresh = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "synthetic-reconstructed-client"),
            keychain: reconstructed,
            diagnostics: DiagnosticsRecorder(directory: fixture.directory.appending(path: "reconstructed"), nativeSink: { _, _ in })
        )
        #expect(reconstructed.oauthMutationState !== fixture.keychain.oauthMutationState)

        let inventory = fresh.tokenInventory()

        #expect(inventory.isComplete)
        #expect(inventory.tokens == expectedTokens)
        #expect(fresh.persistenceFailures == [.legacyCleanup])
        #expect(reconstructed.snapshot == persisted)
        #expect(reconstructed.saveAttempts.isEmpty)
        #expect(reconstructed.deleteAttempts.isEmpty)
        #expect(fresh.tokenInventory().tokens == expectedTokens)
        #expect(reconstructed.deleteAttempts.isEmpty)

        fresh.retryPersistence()

        #expect(reconstructed.snapshot == [Fixture.collectionKey: authority])
        #expect(reconstructed.snapshot[Fixture.collectionKey] == authority)
        #expect(reconstructed.saveAttempts.isEmpty)
        #expect(Set(reconstructed.deleteAttempts) == obsoleteKeys)
        #expect(fresh.persistenceFailures.isEmpty)
        #expect(fresh.tokenInventory().isComplete)
        #expect(fresh.tokenInventory().tokens == expectedTokens)
    }

    @Test("Failed legacy inspection blocks fallback even before obsolete keys have been captured")
    func failedInspectionPreventsLegacyResurrectionAfterAuthorityDisappears() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedLegacyAndCollection()
        let authority = try Fixture.collection([])
        fixture.keychain.seed(authority, forKey: Fixture.collectionKey)
        fixture.keychain.denyReads([Fixture.indexKey])

        let inspected = fixture.first.tokenInventory()

        #expect(inspected.isComplete)
        #expect(inspected.tokens.isEmpty)
        #expect(fixture.first.persistenceFailures.contains(.legacyCleanup))
        #expect(fixture.keychain.saveAttempts.isEmpty)
        #expect(fixture.keychain.deleteAttempts.isEmpty)
        fixture.keychain.seed(nil, forKey: Fixture.collectionKey)
        fixture.keychain.denyReads([])
        let withoutAuthority = fixture.keychain.snapshot

        let unavailable = fixture.second.tokenInventory()
        fixture.first.retryPersistence()
        let afterRetry = fixture.second.tokenInventory()

        #expect(!unavailable.isComplete)
        #expect(unavailable.tokens.isEmpty)
        #expect(!afterRetry.isComplete)
        #expect(afterRetry.tokens.isEmpty)
        #expect(fixture.first.persistenceFailures.contains(.legacyCleanup))
        #expect(fixture.second.persistenceFailures.contains(.legacyCleanup))
        #expect(fixture.keychain.snapshot == withoutAuthority)
        #expect(fixture.keychain.saveAttempts.isEmpty)
        #expect(fixture.keychain.deleteAttempts.isEmpty)
        fixture.keychain.seed(authority, forKey: Fixture.collectionKey)
        let restored = fixture.keychain.snapshot

        let reinspected = fixture.first.tokenInventory()

        #expect(reinspected.isComplete)
        #expect(reinspected.tokens.isEmpty)
        #expect(fixture.first.persistenceFailures.contains(.legacyCleanup))
        #expect(fixture.keychain.snapshot == restored)
        #expect(fixture.keychain.saveAttempts.isEmpty)
        #expect(fixture.keychain.deleteAttempts.isEmpty)

        fixture.second.retryPersistence()

        #expect(fixture.keychain.snapshot == [Fixture.collectionKey: authority])
        #expect(fixture.keychain.saveAttempts.isEmpty)
        #expect(Set(fixture.keychain.deleteAttempts) == [Fixture.accountAKey, Fixture.indexKey, Fixture.legacyKey])
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
        #expect(fixture.first.tokenInventory().isComplete)
        #expect(fixture.first.tokenInventory().tokens.isEmpty)
    }

    @Test("Pending cleanup cannot revive legacy data or delete keys without a readable authoritative collection", arguments: CollectionDamage.allCases)
    func pendingCleanupRequiresAuthoritativeCollection(damage: CollectionDamage) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedLegacyAndCollection()
        fixture.keychain.denyDeletes([Fixture.accountAKey])
        try? fixture.first.removeToken(accountID: Fixture.accountA)
        let authoritative = try #require(fixture.keychain.snapshot[Fixture.collectionKey])
        try #require(try Fixture.decodeCollection(authoritative).isEmpty)
        fixture.keychain.denyDeletes([])
        switch damage {
        case .missing:
            fixture.keychain.seed(nil, forKey: Fixture.collectionKey)
        case .corrupt:
            fixture.keychain.seed("{\"tokens\":", forKey: Fixture.collectionKey)
        case .denied:
            fixture.keychain.denyReads([Fixture.collectionKey])
        }
        let damaged = fixture.keychain.snapshot
        let saves = fixture.keychain.saveAttempts
        let deletes = fixture.keychain.deleteAttempts

        let inventory = fixture.first.tokenInventory()
        fixture.second.retryPersistence()

        #expect(inventory.tokens.isEmpty)
        #expect(fixture.first.persistenceFailures.contains(.legacyCleanup))
        #expect(fixture.second.persistenceFailures.contains(.legacyCleanup))
        #expect(fixture.keychain.snapshot == damaged)
        #expect(fixture.keychain.saveAttempts == saves)
        #expect(fixture.keychain.deleteAttempts == deletes)
        fixture.keychain.seed(authoritative, forKey: Fixture.collectionKey)
        fixture.keychain.denyReads([])

        fixture.second.retryPersistence()

        #expect(fixture.keychain.snapshot == [Fixture.collectionKey: authoritative])
        #expect(fixture.first.tokenInventory().isComplete)
        #expect(fixture.first.tokenInventory().tokens.isEmpty)
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
        #expect(fixture.keychain.saveAttempts == saves)
    }

    @Test("Migration-save failure has its own warning and clears after a real successful migration")
    func failedMigrationRecoversThroughSuccessfulMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let token = fixture.token(Fixture.accountA)
        fixture.keychain.seed(try Fixture.encode(["accountIDs": [Fixture.accountA]]), forKey: Fixture.indexKey)
        fixture.keychain.seed(try Fixture.encode(token), forKey: Fixture.accountAKey)
        let before = fixture.keychain.snapshot
        fixture.keychain.denySaves([Fixture.collectionKey])

        let failed = fixture.first.tokenInventory()

        #expect(!failed.isComplete)
        #expect(failed.tokens == [token])
        #expect(fixture.first.persistenceFailures == [.migration])
        #expect(fixture.second.persistenceFailures == [.migration])
        #expect(fixture.keychain.snapshot == before)
        #expect(fixture.keychain.saveAttempts == [Fixture.collectionKey])
        #expect(fixture.keychain.deleteAttempts.isEmpty)
        fixture.keychain.denySaves([])

        let recovered = fixture.second.tokenInventory()

        #expect(recovered.isComplete)
        #expect(recovered.tokens == [token])
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
        #expect(Set(fixture.keychain.snapshot.keys) == [Fixture.collectionKey])
        let saved = try #require(fixture.keychain.snapshot[Fixture.collectionKey])
        #expect(try Fixture.decodeCollection(saved) == [token])
        #expect(fixture.keychain.saveAttempts == [Fixture.collectionKey, Fixture.collectionKey])
    }

    @Test("Explicit clear retains an empty authoritative collection over later legacy residue")
    func clearRetainsAuthoritativeEmptyBarrier() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedLegacyAndCollection()

        try fixture.first.clearToken()

        let emptyCollection = try #require(fixture.keychain.snapshot[Fixture.collectionKey])
        #expect(try Fixture.decodeCollection(emptyCollection).isEmpty)
        #expect(Set(fixture.keychain.snapshot.keys) == [Fixture.collectionKey])
        #expect(!fixture.keychain.deleteAttempts.contains(Fixture.collectionKey))
        fixture.keychain.seed(try Fixture.encode(fixture.token(Fixture.accountA)), forKey: Fixture.legacyKey)
        let withResidue = fixture.keychain.snapshot
        let saves = fixture.keychain.saveAttempts
        let deletes = fixture.keychain.deleteAttempts

        let inventory = fixture.second.tokenInventory()
        fixture.first.retryPersistence()

        #expect(inventory.isComplete)
        #expect(inventory.tokens.isEmpty)
        #expect(fixture.first.persistenceFailures.isEmpty)
        #expect(fixture.second.persistenceFailures.isEmpty)
        #expect(fixture.keychain.snapshot == withResidue)
        #expect(fixture.keychain.saveAttempts == saves)
        #expect(fixture.keychain.deleteAttempts == deletes)
    }

    enum ReadDamage: CaseIterable, Sendable {
        case corrupt, denied
    }

    enum CollectionDamage: CaseIterable, Sendable {
        case missing, corrupt, denied
    }

    enum NewerSave: CaseIterable, Sendable {
        case addAccount, reconnectAccount
    }

    enum DestructiveAction: CaseIterable, Sendable {
        case remove, clear

        var failure: GoogleOAuthPersistenceFailure {
            switch self {
            case .remove: .remove(accountID: Fixture.accountA)
            case .clear: .clear
            }
        }

        func perform(on client: GoogleOAuthClient) throws {
            switch self {
            case .remove: try client.removeToken(accountID: Fixture.accountA)
            case .clear: try client.clearToken()
            }
        }
    }

    private struct Fixture {
        static let collectionKey = "google.oauth.tokens"
        static let indexKey = "google.oauth.tokens.index"
        static let legacyKey = "google.oauth.token"
        static let accountA = "inventory-a@example.invalid"
        static let accountB = "inventory-b@example.invalid"
        static let accountC = "inventory-c@example.invalid"
        static let accountAKey = "google.oauth.token.3071df969daf4584"
        static let accountBKey = "google.oauth.token.0bd93b40182abff8"
        let directory: URL
        let keychain: FaultKeychain
        let first: GoogleOAuthClient
        let second: GoogleOAuthClient

        init() throws {
            directory = try TestTempDirectory.make()
            keychain = FaultKeychain()
            let configuration = GoogleOAuthConfiguration(clientID: "synthetic-persistence-client")
            let diagnostics = DiagnosticsRecorder(directory: directory, nativeSink: { _, _ in })
            first = GoogleOAuthClient(configuration: configuration, keychain: keychain, diagnostics: diagnostics)
            second = GoogleOAuthClient(configuration: configuration, keychain: keychain, diagnostics: diagnostics)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        func token(_ accountID: String?, version: String = "original") -> GoogleOAuthToken {
            GoogleOAuthToken(
                accessToken: "synthetic-access-\(accountID ?? "unassigned")-\(version)",
                refreshToken: "synthetic-refresh-\(accountID ?? "unassigned")-\(version)",
                expiresAt: .distantFuture, scope: AppIdentity.googleScopes.joined(separator: " "),
                tokenType: "Bearer", accountID: accountID,
                accountDisplayName: accountID.map { _ in "Synthetic account" }
            )
        }

        func seedLegacyAndCollection() throws {
            let token = token(Self.accountA)
            let encoded = try Self.encode(token)
            keychain.seed(try Self.collection([token]), forKey: Self.collectionKey)
            keychain.seed(try Self.encode(["accountIDs": [Self.accountA]]), forKey: Self.indexKey)
            keychain.seed(encoded, forKey: Self.accountAKey)
            keychain.seed(encoded, forKey: Self.legacyKey)
        }

        static func encode<Value: Encodable>(_ value: Value) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }

        static func collection(_ tokens: [GoogleOAuthToken]) throws -> String {
            try encode(["tokens": tokens])
        }

        static func decodeCollection(_ value: String) throws -> [GoogleOAuthToken] {
            let envelope = try JSONDecoder().decode([String: [GoogleOAuthToken]].self, from: Data(value.utf8))
            return try #require(envelope["tokens"])
        }
    }

    private final class FaultKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var deniedReads: Set<String> = []
        private var deniedSaves: Set<String> = []
        private var deniedDeletes: Set<String> = []
        private var reads: [String] = []
        private var saves: [String] = []
        private var deletes: [String] = []

        init(values: [String: String] = [:]) {
            self.values = values
        }

        var snapshot: [String: String] { lock.withLock { values } }
        var readAttempts: [String] { lock.withLock { reads } }
        var saveAttempts: [String] { lock.withLock { saves } }
        var deleteAttempts: [String] { lock.withLock { deletes } }

        func seed(_ value: String?, forKey key: String) {
            lock.withLock { values[key] = value }
        }

        func denyReads(_ keys: Set<String>) {
            lock.withLock { deniedReads = keys }
        }

        func denySaves(_ keys: Set<String>) {
            lock.withLock { deniedSaves = keys }
        }

        func denyDeletes(_ keys: Set<String>) {
            lock.withLock { deniedDeletes = keys }
        }

        func read(forKey key: String) throws -> String? {
            try lock.withLock {
                reads.append(key)
                guard !deniedReads.contains(key) else { throw KeychainError.readFailed(-25308) }
                return values[key]
            }
        }

        func retrieve(forKey key: String) -> String? {
            try? read(forKey: key)
        }

        func save(_ value: String, forKey key: String) throws {
            try lock.withLock {
                saves.append(key)
                guard !deniedSaves.contains(key) else { throw KeychainError.saveFailed(-25308) }
                values[key] = value
            }
        }

        func delete(forKey key: String) throws {
            try lock.withLock {
                deletes.append(key)
                guard !deniedDeletes.contains(key) else { throw KeychainError.deleteFailed(-25308) }
                values.removeValue(forKey: key)
            }
        }
    }
}

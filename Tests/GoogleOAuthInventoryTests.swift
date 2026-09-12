import Foundation
import Testing
@testable import MeetingShield

@Suite("Google OAuth credential inventory preservation")
struct GoogleOAuthInventoryTests {
    private static let collectionKey = "google.oauth.tokens"
    private static let indexKey = "google.oauth.tokens.index"
    private static let legacyKey = "google.oauth.token"
    private static let firstID = "inventory-a@example.invalid"
    private static let secondID = "inventory-b@example.invalid"
    private static let firstKey = "google.oauth.token.3071df969daf4584"
    private static let secondKey = "google.oauth.token.0bd93b40182abff8"

    @Test("A corrupt collection never overwrites or removes recoverable legacy credentials", arguments: ["{", "{\"tokens\":\"invalid-schema\"}"])
    func corruptCollectionPreservesEveryCredentialSource(collection: String) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = [
            Self.collectionKey: collection,
            Self.legacyKey: try encodedToken(accountID: Self.firstID)
        ]
        let keychain = InventoryKeychain(values: original)
        let client = makeClient(keychain: keychain, directory: directory)

        _ = client.storedTokens()
        _ = client.storedTokens()
        let inventory = client.tokenInventory()

        #expect(!inventory.isComplete)
        #expect(inventory.failure?.errorClass == "decoding_error")
        #expect(inventory.tokens.isEmpty)
        #expect(keychain.snapshot == original)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    @Test("An incomplete indexed inventory preserves every migration input", arguments: LegacyDamage.allCases)
    func incompleteLegacyIndexRetainsAllMigrationInputs(damage: LegacyDamage) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = [
            Self.indexKey: try encodedIndex(),
            Self.firstKey: try encodedToken(accountID: Self.firstID)
        ]
        if damage == .corrupt {
            original[Self.secondKey] = "{\"accessToken\":\"synthetic-corrupt-token\"}"
        }
        let keychain = InventoryKeychain(values: original)
        let client = makeClient(keychain: keychain, directory: directory)

        _ = client.storedTokens()
        _ = client.storedTokens()
        let inventory = client.tokenInventory()

        #expect(!inventory.isComplete)
        #expect(inventory.knownAccountIDs == [Self.firstID, Self.secondID])
        #expect(inventory.tokens.compactMap(\.accountID) == [Self.firstID])
        #expect(keychain.snapshot == original)
        #expect(keychain.retrieve(forKey: Self.collectionKey) == nil)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    @Test("A complete indexed inventory migrates both accounts without losing token data")
    func completeLegacyIndexMigratesBothAccounts() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try encodedToken(accountID: Self.firstID)
        let second = try encodedToken(accountID: Self.secondID)
        let keychain = InventoryKeychain(values: [
            Self.indexKey: try encodedIndex(),
            Self.firstKey: first,
            Self.secondKey: second
        ])
        let client = makeClient(keychain: keychain, directory: directory)

        let firstRead = client.storedTokens()
        let secondRead = client.storedTokens()
        let inventory = client.tokenInventory()
        let expectedFirst = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(first.utf8))
        let expectedSecond = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(second.utf8))

        #expect(Set(firstRead.compactMap(\.accountID)) == [Self.firstID, Self.secondID])
        #expect(firstRead == secondRead)
        #expect(inventory.isComplete)
        #expect(inventory.knownAccountIDs == [Self.firstID, Self.secondID])
        #expect(firstRead.contains(expectedFirst))
        #expect(firstRead.contains(expectedSecond))
        #expect(Set(keychain.snapshot.keys) == [Self.collectionKey])
        #expect(keychain.savedKeys == [Self.collectionKey])

        let collection = try #require(keychain.retrieve(forKey: Self.collectionKey))
        let decoded = try JSONSerialization.jsonObject(with: Data(collection.utf8))
        let envelope = try #require(decoded as? [String: Any])
        let records = try #require(envelope["tokens"] as? [[String: Any]])
        #expect(Set(records.compactMap { $0["accountID"] as? String }) == [Self.firstID, Self.secondID])
    }

    @Test("An empty first-run inventory remains disconnected without writing credential records")
    func missingFirstRunIsNormal() async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = InventoryKeychain(values: [:])
        let client = makeClient(keychain: keychain, directory: directory)

        #expect(client.storedTokens().isEmpty)
        #expect(client.storedToken() == nil)
        let inventory = client.tokenInventory()
        #expect(inventory.isComplete)
        #expect(inventory.knownAccountIDs.isEmpty)
        do {
            _ = try await client.validTokens()
            Issue.record("An empty inventory unexpectedly returned valid credentials")
        } catch CalendarProviderError.disconnected {
        } catch {
            Issue.record("An empty inventory returned an unexpected error")
        }

        #expect(keychain.snapshot.isEmpty)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    @Test("A complete empty collection is authoritative over legacy credentials")
    func completeEmptyCollectionDoesNotResurrectLegacyAccount() throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = [
            Self.collectionKey: "{\"tokens\":[]}",
            Self.legacyKey: try encodedToken(accountID: Self.firstID)
        ]
        let keychain = InventoryKeychain(values: original)
        let client = makeClient(keychain: keychain, directory: directory)

        let inventory = client.tokenInventory()

        #expect(inventory.isComplete)
        #expect(inventory.tokens.isEmpty)
        #expect(inventory.knownAccountIDs.isEmpty)
        #expect(client.storedTokens().isEmpty)
        #expect(keychain.snapshot == original)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    @Test("Denied reads remain distinguishable from first-run absence", arguments: ["google.oauth.tokens", "google.oauth.tokens.index", "google.oauth.token.3071df969daf4584"])
    func deniedReadPreservesCredentialsAndReportsFailure(deniedKey: String) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = [
            Self.indexKey: try encodedIndex(),
            Self.firstKey: try encodedToken(accountID: Self.firstID),
            Self.secondKey: try encodedToken(accountID: Self.secondID)
        ]
        let keychain = InventoryKeychain(values: original, deniedKeys: [deniedKey])
        let client = makeClient(keychain: keychain, directory: directory)

        let inventory = client.tokenInventory()

        #expect(!inventory.isComplete)
        #expect(inventory.failure?.errorClass == "keychain_read_failed")
        #expect(LogPrivacy.safeErrorCode("keychain_read_failed") == "keychain_read_failed")
        if deniedKey == Self.firstKey {
            #expect(inventory.knownAccountIDs == [Self.firstID, Self.secondID])
            #expect(inventory.tokens.compactMap(\.accountID) == [Self.secondID])
        } else {
            #expect(inventory.tokens.isEmpty)
        }
        #expect(keychain.snapshot == original)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    @Test("Credential mutations refuse an incomplete inventory", arguments: Mutation.allCases)
    func incompleteInventoryRejectsMutation(mutation: Mutation) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = [
            Self.indexKey: try encodedIndex(),
            Self.firstKey: try encodedToken(accountID: Self.firstID),
            Self.secondKey: "{"
        ]
        let keychain = InventoryKeychain(values: original)
        let client = makeClient(keychain: keychain, directory: directory)
        let encoded = try encodedToken(accountID: Self.firstID)
        var token = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(encoded.utf8))

        do {
            switch mutation {
            case .saveAssigned:
                try client.saveToken(token, accountID: Self.firstID, accountDisplayName: "Replacement")
            case .saveUnassigned:
                token.accountID = nil
                token.accountDisplayName = nil
                try client.saveToken(token)
            case .remove:
                try client.removeToken(accountID: Self.firstID)
            case .clear:
                try client.clearToken()
            }
            Issue.record("Credential mutation accepted an incomplete inventory")
        } catch {
            #expect(LogPrivacy.errorClass(error) == "decoding_error")
        }

        #expect(keychain.snapshot == original)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    @Test("Invalid credential identities preserve sources and unrelated usable accounts", arguments: IdentityDamage.allCases)
    func identityCorruptionPreservesSources(damage: IdentityDamage) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try identityFixture(damage)
        let keychain = InventoryKeychain(values: fixture.original)
        let client = makeClient(keychain: keychain, directory: directory)

        let first = client.tokenInventory()
        let second = client.tokenInventory()
        let restarted = makeClient(keychain: keychain, directory: directory).tokenInventory()

        for inventory in [first, second, restarted] {
            #expect(!inventory.isComplete)
            #expect(inventory.failure != nil)
            #expect(inventory.knownAccountIDs == fixture.knownAccountIDs)
            #expect(inventory.tokens == [fixture.healthyToken])
        }
        #expect(client.storedTokens() == [fixture.healthyToken])
        #expect(keychain.snapshot == fixture.original)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    @Test("Credential identity corruption cannot be overwritten by mutation", arguments: IdentityDamage.allCases, Mutation.allCases)
    func identityCorruptionRejectsMutation(damage: IdentityDamage, mutation: Mutation) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try identityFixture(damage)
        let keychain = InventoryKeychain(values: fixture.original)
        let client = makeClient(keychain: keychain, directory: directory)
        let encoded = try encodedToken(accountID: Self.firstID)
        var token = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(encoded.utf8))

        do {
            switch mutation {
            case .saveAssigned:
                try client.saveToken(token, accountID: Self.firstID, accountDisplayName: "Replacement")
            case .saveUnassigned:
                token.accountID = nil
                token.accountDisplayName = nil
                try client.saveToken(token)
            case .remove:
                try client.removeToken(accountID: Self.firstID)
            case .clear:
                try client.clearToken()
            }
            Issue.record("Credential mutation replaced an inventory with invalid account identity")
        } catch {
            #expect(client.tokenInventory().failure != nil)
        }

        #expect(keychain.snapshot == fixture.original)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    @Test("A valid account token remains usable beside corrupt credential identities", arguments: IdentityDamage.allCases)
    func healthyTokenRemainsUsableWithIdentityCorruption(damage: IdentityDamage) async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try identityFixture(damage)
        let keychain = InventoryKeychain(values: fixture.original)

        await expectHealthyTokenUsable(
            fixture.healthyToken,
            keychain: keychain,
            original: fixture.original,
            directory: directory
        )
    }

    @Test("A valid indexed account remains usable when another account cannot be read", arguments: [false, true])
    func healthyTokenRemainsUsableWithUnreadableSibling(denied: Bool) async throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let healthyBytes = try encodedToken(accountID: Self.secondID)
        let healthy = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(healthyBytes.utf8))
        let original = [
            Self.indexKey: try encodedIndex(),
            Self.firstKey: denied ? try encodedToken(accountID: Self.firstID) : "{",
            Self.secondKey: healthyBytes
        ]
        let keychain = InventoryKeychain(values: original, deniedKeys: denied ? [Self.firstKey] : [])

        await expectHealthyTokenUsable(healthy, keychain: keychain, original: original, directory: directory)
    }

    @Test("A valid collection preserves distinct assigned accounts and one legacy slot", arguments: [false, true])
    func validCollectionPreservesItsMembers(includeLegacy: Bool) throws {
        let directory = try TestTempDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstBytes = try encodedToken(accountID: Self.firstID)
        let secondBytes = try encodedToken(accountID: Self.secondID)
        let first = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(firstBytes.utf8))
        let second = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(secondBytes.utf8))
        var tokens = [first, second]
        if includeLegacy {
            var legacy = first
            legacy.accountID = nil
            legacy.accountDisplayName = nil
            legacy.accessToken = "synthetic-valid-legacy-access"
            legacy.refreshToken = "synthetic-valid-legacy-refresh"
            tokens.append(legacy)
        }
        let original = [
            Self.collectionKey: try encodedCollection(tokens),
            Self.legacyKey: firstBytes
        ]
        let keychain = InventoryKeychain(values: original)
        let client = makeClient(keychain: keychain, directory: directory)

        let inventory = client.tokenInventory()

        #expect(inventory.isComplete)
        #expect(inventory.failure == nil)
        #expect(inventory.knownAccountIDs == [Self.firstID, Self.secondID])
        #expect(inventory.tokens.count == tokens.count)
        for token in tokens {
            #expect(inventory.tokens.contains(token))
        }
        #expect(client.storedTokens() == inventory.tokens)
        #expect(keychain.snapshot == original)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
    }

    private func identityFixture(_ damage: IdentityDamage) throws -> IdentityFixture {
        let firstBytes = try encodedToken(accountID: Self.firstID)
        let secondBytes = try encodedToken(accountID: Self.secondID)
        let first = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(firstBytes.utf8))
        let second = try JSONDecoder().decode(GoogleOAuthToken.self, from: Data(secondBytes.utf8))
        if damage == .legacyIndexMismatch {
            var misplaced = second
            misplaced.accessToken = "synthetic-misfiled-access"
            misplaced.refreshToken = "synthetic-misfiled-refresh"
            return IdentityFixture(
                original: [
                    Self.indexKey: try encodedIndex(),
                    Self.firstKey: String(decoding: try JSONEncoder().encode(misplaced), as: UTF8.self),
                    Self.secondKey: secondBytes
                ],
                knownAccountIDs: [Self.firstID, Self.secondID],
                healthyToken: second
            )
        }

        var invalid = first
        var tokens: [GoogleOAuthToken]
        let knownAccountIDs: Set<String>
        switch damage {
        case .duplicateAssigned:
            invalid.accessToken = "synthetic-conflicting-access"
            invalid.refreshToken = "synthetic-conflicting-refresh"
            tokens = [first, invalid, second]
            knownAccountIDs = [Self.firstID, Self.secondID]
        case .duplicateLegacy:
            invalid.accountID = nil
            invalid.accountDisplayName = nil
            var conflicting = invalid
            conflicting.accessToken = "synthetic-conflicting-legacy-access"
            conflicting.refreshToken = "synthetic-conflicting-legacy-refresh"
            tokens = [invalid, conflicting, second]
            knownAccountIDs = [Self.secondID]
        case .emptyAssignedID:
            invalid.accountID = ""
            tokens = [invalid, second]
            knownAccountIDs = [Self.secondID]
        case .legacyIndexMismatch:
            throw KeychainError.unexpectedData
        }
        return IdentityFixture(
            original: [
                Self.collectionKey: try encodedCollection(tokens),
                Self.legacyKey: firstBytes
            ],
            knownAccountIDs: knownAccountIDs,
            healthyToken: second
        )
    }

    private func encodedCollection(_ tokens: [GoogleOAuthToken]) throws -> String {
        String(decoding: try JSONEncoder().encode(Collection(tokens: tokens)), as: UTF8.self)
    }

    private func expectHealthyTokenUsable(
        _ healthy: GoogleOAuthToken,
        keychain: InventoryKeychain,
        original: [String: String],
        directory: URL
    ) async {
        let marker = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-MeetingShield-Inventory-Test": marker]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = makeClient(keychain: keychain, directory: directory, session: session)

        do {
            let usable = try await client.validToken(healthy)
            #expect(usable == healthy)
            #expect(usable.isUsable)
        } catch {
            Issue.record("An independent account's valid token was blocked by a damaged sibling")
        }

        #expect(keychain.snapshot == original)
        #expect(keychain.savedKeys.isEmpty)
        #expect(keychain.deletedKeys.isEmpty)
        #expect(!StubURLProtocol.unmatched.contains { request in
            request.value(forHTTPHeaderField: "X-MeetingShield-Inventory-Test") == marker
        })
    }

    private func makeClient(keychain: InventoryKeychain, directory: URL, session: URLSession = .shared) -> GoogleOAuthClient {
        GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "inventory-synthetic-client"),
            keychain: keychain,
            session: session,
            diagnostics: DiagnosticsRecorder(directory: directory.appending(path: "diagnostics"), nativeSink: { _, _ in })
        )
    }

    private func encodedIndex() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["accountIDs": [Self.firstID, Self.secondID]])
        return String(decoding: data, as: UTF8.self)
    }

    private func encodedToken(accountID: String) throws -> String {
        let token = GoogleOAuthToken(
            accessToken: "synthetic-access-\(accountID)",
            refreshToken: "synthetic-refresh-\(accountID)",
            expiresAt: .distantFuture,
            scope: AppIdentity.googleScopes.joined(separator: " "),
            tokenType: "Bearer",
            accountID: accountID,
            accountDisplayName: "Synthetic inventory account"
        )
        return String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
    }

    enum LegacyDamage: CaseIterable, Sendable {
        case corrupt
        case missing
    }

    enum Mutation: CaseIterable, Sendable {
        case saveAssigned
        case saveUnassigned
        case remove
        case clear
    }

    enum IdentityDamage: CaseIterable, Sendable {
        case legacyIndexMismatch
        case duplicateAssigned
        case duplicateLegacy
        case emptyAssignedID
    }

    private struct IdentityFixture {
        var original: [String: String]
        var knownAccountIDs: Set<String>
        var healthyToken: GoogleOAuthToken
    }

    private struct Collection: Encodable {
        var tokens: [GoogleOAuthToken]
    }

    private final class InventoryKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private let deniedKeys: Set<String>
        private var values: [String: String]
        private var saves: [String] = []
        private var deletions: [String] = []

        init(values: [String: String], deniedKeys: Set<String> = []) {
            self.values = values
            self.deniedKeys = deniedKeys
        }

        var snapshot: [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        var savedKeys: [String] {
            lock.lock()
            defer { lock.unlock() }
            return saves
        }

        var deletedKeys: [String] {
            lock.lock()
            defer { lock.unlock() }
            return deletions
        }

        func save(_ value: String, forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            saves.append(key)
            values[key] = value
        }

        func retrieve(forKey key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func read(forKey key: String) throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            if deniedKeys.contains(key) { throw KeychainError.readFailed(-25308) }
            return values[key]
        }

        func delete(forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            deletions.append(key)
            values.removeValue(forKey: key)
        }
    }
}

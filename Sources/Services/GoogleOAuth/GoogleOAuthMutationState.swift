import Foundation

final class GoogleOAuthMutationState: @unchecked Sendable {
    struct Revision: Equatable, Sendable {
        var clear: UInt64
        var account: UInt64
    }

    struct Revisions: Sendable {
        var persistenceFailures: Set<GoogleOAuthPersistenceFailure> = []
        var pendingLegacyKeys: Set<String> = []
        var legacyInspectionComplete = false
        private var clear: UInt64 = 0
        private var accounts: [String?: UInt64] = [:]

        func revision(for accountID: String?) -> Revision {
            Revision(clear: clear, account: accounts[accountID, default: 0])
        }

        mutating func invalidate(accountID: String?) {
            accounts[accountID, default: 0] &+= 1
        }

        mutating func invalidateAll() {
            clear &+= 1
            accounts.removeAll()
        }
    }

    private final class StoreEntry {
        weak var owner: AnyObject?
        let state: GoogleOAuthMutationState

        init(owner: AnyObject, state: GoogleOAuthMutationState) {
            self.owner = owner
            self.state = state
        }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var services: [String: GoogleOAuthMutationState] = [:]
    nonisolated(unsafe) private static var stores: [ObjectIdentifier: StoreEntry] = [:]
    private let lock = NSLock()
    private var revisions = Revisions()

    static func shared(service: String) -> GoogleOAuthMutationState {
        registryLock.withLock {
            if let state = services[service] { return state }
            let state = GoogleOAuthMutationState()
            services[service] = state
            return state
        }
    }

    static func shared(store: AnyObject) -> GoogleOAuthMutationState {
        registryLock.withLock {
            stores = stores.filter { $0.value.owner != nil }
            let id = ObjectIdentifier(store)
            if let entry = stores[id], entry.owner === store { return entry.state }
            let state = GoogleOAuthMutationState()
            stores[id] = StoreEntry(owner: store, state: state)
            return state
        }
    }

    func withLock<Value>(_ body: (inout Revisions) throws -> Value) rethrows -> Value {
        try lock.withLock { try body(&revisions) }
    }
}

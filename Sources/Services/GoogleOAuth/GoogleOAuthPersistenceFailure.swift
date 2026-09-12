enum GoogleOAuthPersistenceFailure: Hashable, Sendable {
    case read
    case save(accountID: String?)
    case remove(accountID: String)
    case clear
    case migration
    case legacyCleanup
}

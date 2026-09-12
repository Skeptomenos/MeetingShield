enum PersistenceFailure: String, Error, Equatable, Sendable {
    case invalidData = "invalid_data"
    case readFailed = "read_failed"
    case writeFailed = "write_failed"
}

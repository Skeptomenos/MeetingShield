import Foundation
import Testing
@testable import MeetingShield

@Suite("Material fingerprint privacy")
struct MaterialFingerprintTests {
    private let secretTitle = "Confidential acquisition sync"

    private var event: CalendarEventOccurrence {
        .sample(
            eventID: "fp-privacy",
            title: secretTitle,
            startDate: TestDates.start
        )
    }

    @Test("Fingerprint is a SHA256 hex digest, not reversible encoding")
    func fingerprintIsHashed() {
        let fingerprint = event.materialFingerprint(detectedLinks: []).value

        #expect(fingerprint.count == 64)
        #expect(fingerprint.allSatisfy { $0.isHexDigit })
        // Must not be base64-decodable back to the title (the previous format was).
        if let decoded = Data(base64Encoded: fingerprint).map({ String(decoding: $0, as: UTF8.self) }) {
            #expect(!decoded.contains(secretTitle))
        }
        #expect(!fingerprint.contains(secretTitle))
    }

    @Test("Fingerprint changes on material changes and is stable otherwise")
    func fingerprintIsStableAndSensitive() {
        let base = event.materialFingerprint(detectedLinks: [])
        let again = event.materialFingerprint(detectedLinks: [])
        #expect(base == again)

        var moved = event
        moved.startDate = event.startDate.addingTimeInterval(300)
        #expect(moved.materialFingerprint(detectedLinks: []) != base)

        let link = MeetingLink(
            url: URL(string: "https://meet.google.com/abc-defg-hij")!,
            kind: .googleMeet,
            source: .conferenceMetadata
        )
        #expect(event.materialFingerprint(detectedLinks: [link]) != base)
    }
}

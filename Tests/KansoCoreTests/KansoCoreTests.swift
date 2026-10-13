import Testing
@testable import KansoCore
import Foundation

@Suite("KansoCore Basic Models Suite")
struct KansoCoreTests {
    @Test("TranscriptionResult holds properties correctly")
    func testTranscriptionResult() {
        let now = Date()
        let result = TranscriptionResult(
            text: "Hello world",
            durationSeconds: 1.5,
            engineIdentifier: "test.engine",
            timestamp: now
        )

        #expect(result.text == "Hello world")
        #expect(result.durationSeconds == 1.5)
        #expect(result.engineIdentifier == "test.engine")
        #expect(result.timestamp == now)
    }
}

import Testing
@testable import Lenora

@MainActor
struct ByteCountTextTests {
    @Test func mebibyteLimitsReadAsWholeMegabytes() {
        #expect(MediaEditRefusal.tooLarge(maxBytes: 10_485_760).userMessage.contains("10 MB"))
        #expect(PublishRefusal.tooLarge(byteCount: 209_715_200, maxBytes: 104_857_600).userMessage.contains("100 MB"))
    }
}

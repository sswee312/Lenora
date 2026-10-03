import Foundation
import Testing
@testable import Lenora

struct ByteCountTextTests {
    @Test(arguments: [(Int64(10_485_760), "10 MB"), (104_857_600, "100 MB"), (1_073_741_824, "1 GB")])
    func mebibyteLimitsReadAsWholeUnits(bytes: Int64, text: String) {
        #expect(bytes.byteCountText(locale: Locale(identifier: "en_US_POSIX")) == text)
    }
}

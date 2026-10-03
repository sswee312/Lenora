import Foundation

extension Int64 {
    /// Binary units, so a 10 MiB limit reads "10 MB" rather than "10.5 MB".
    func byteCountText(locale: Locale = .autoupdatingCurrent) -> String {
        formatted(.byteCount(style: .binary).locale(locale))
    }
}

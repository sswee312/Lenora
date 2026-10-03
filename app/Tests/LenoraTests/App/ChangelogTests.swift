import Foundation
import Testing
@testable import Lenora

@Suite("Changelog")
struct ChangelogTests {
    static let shippedFeed = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Lenora/Resources/Changelog/changelog.json")

    private func entry(_ version: String) -> ChangelogEntry {
        ChangelogEntry(version: version, date: nil, sections: [ChangelogSection(heading: nil, items: ["Item"])])
    }

    @Test func shippedFeedHasNoInheritedReleaseNotes() throws {
        let feed = try JSONDecoder().decode(ChangelogFeed.self, from: Data(contentsOf: Self.shippedFeed))
        #expect(feed.entries.isEmpty)
        #expect(ChangelogStore.whatsNew(in: feed, current: "0.1.0", lastSeen: "0.0.9") == nil)
    }

    @Test func upgradeShowsTheCurrentVersionsEntry() {
        let feed = ChangelogFeed(changelogURL: nil, entries: [entry("0.2.0"), entry("0.1.0")])
        #expect(ChangelogStore.whatsNew(in: feed, current: "0.2.0", lastSeen: "0.1.0")?.version == "0.2.0")
    }

    @Test func freshInstallAndSameVersionShowNothing() {
        let feed = ChangelogFeed(changelogURL: nil, entries: [entry("0.2.0")])
        #expect(ChangelogStore.whatsNew(in: feed, current: "0.2.0", lastSeen: nil) == nil)
        #expect(ChangelogStore.whatsNew(in: feed, current: "0.2.0", lastSeen: "") == nil)
        #expect(ChangelogStore.whatsNew(in: feed, current: "0.2.0", lastSeen: "0.2.0") == nil)
    }
}

import Foundation

/// One entry in the bundled catalog.json. `sha` is a content hash of the SKILL.md
/// and is the version anchor: a changed sha means an update is available.
struct SkillCatalogEntry: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let sha: String
    let path: String
}

/// Loads the skill catalog bundled with the app.
@Observable
@MainActor
final class SkillCatalog {
    static let shared = SkillCatalog()

    private(set) var entries: [SkillCatalogEntry] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private var refreshTask: Task<Bool, Never>?

    private init() {}

    func entry(id: String) -> SkillCatalogEntry? { entries.first { $0.id == id } }

    static func bodyURL(path: String) -> URL? { BundledResource.url("Skills/\(path)") }

    @discardableResult
    func refresh() async -> Bool {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await load() }
        refreshTask = task
        let loaded = await task.value
        refreshTask = nil
        return loaded
    }

    private func load() async -> Bool {
        guard let url = BundledResource.url("Skills/catalog.json") else {
            lastError = L10n.string("Bundled skills are missing from this build.")
            Log.agent.error("bundled skills catalog missing")
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try JSONDecoder().decode([SkillCatalogEntry].self, from: try await Self.fetch(url))
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            Log.agent.error("bundled skills catalog unreadable: \(error.localizedDescription)")
            return false
        }
    }

    @concurrent static func fetch(_ url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }
}

import Foundation
import Testing
@testable import Lenora

@Suite("Onboarding store")
@MainActor
struct OnboardingStoreTests {
    @Test func newUserStartsIncomplete() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)

            #expect(!store.isComplete)
        }
    }

    @Test func existingWelcomeCompletionSkipsOnboarding() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: OnboardingStore.completionKey)

            let store = OnboardingStore(defaults: defaults)

            #expect(store.isComplete)
        }
    }

    @Test func completionPersists() throws {
        try withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.complete()

            #expect(store.isComplete)
            #expect(defaults.bool(forKey: OnboardingStore.completionKey))
            #expect(OnboardingStore(defaults: defaults).isComplete)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "OnboardingStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}

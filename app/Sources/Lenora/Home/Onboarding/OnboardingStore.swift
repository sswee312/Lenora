import Foundation
import Observation

@MainActor @Observable
final class OnboardingStore {
    /// Inherited from the pre-survey welcome overlay so existing installs stay onboarded.
    static let completionKey = "hasSeenWelcome"
    static let shared = OnboardingStore()

    private(set) var step = OnboardingStep.welcome
    private(set) var isComplete: Bool
    private(set) var sampleState: OnboardingSampleState = .idle

    private let defaults: UserDefaults
    private var sampleTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isComplete = defaults.bool(forKey: Self.completionKey)
    }

    func advance() {
        move(by: 1)
    }

    func goBack() {
        move(by: -1)
    }

    func complete() {
        defaults.set(true, forKey: Self.completionKey)
        isComplete = true
    }

    func skip() {
        sampleTask?.cancel()
        sampleTask = nil
        sampleState = .idle
        complete()
    }

    /// Owned here rather than by the overlay so onboarding still completes once Home is torn down.
    func openSampleProject() {
        guard sampleTask == nil else { return }
        sampleState = .loading
        sampleTask = Task {
            defer { sampleTask = nil }
            do {
                guard let sample = try await SampleProjectService.shared.fetchSamples().first else {
                    sampleState = .failed
                    return
                }
                try Task.checkCancellation()
                try await AppState.shared.openSample(slug: sample.slug, startTutorial: true)
                try Task.checkCancellation()
                complete()
            } catch is CancellationError {
                sampleState = .idle
            } catch {
                Log.app.error("onboarding sample failed to open: \(error.localizedDescription)")
                sampleState = .failed
            }
        }
    }

    private func move(by offset: Int) {
        guard let destination = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        step = destination
    }
}

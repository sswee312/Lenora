import Foundation

enum OnboardingStep: Int {
    case welcome, account
}

enum OnboardingSampleState: Equatable {
    case idle
    case loading
    case failed
}

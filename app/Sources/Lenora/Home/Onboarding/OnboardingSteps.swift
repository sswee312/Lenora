import AppKit
import SwiftUI

struct OnboardingWelcomeStep: View {
    private static let hero = BundledResource.url("Images/welcome-butterfly.jpg")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            OnboardingTitle(L10n.string("Welcome to Lenora"))
            heroImage
            OnboardingDetail(L10n.string("A video editor built for AI. Generate, and edit all in one place."))
        }
    }

    private var heroImage: some View {
        Group {
            if let hero = Self.hero {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
            } else {
                AppTheme.Background.raisedColor
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppTheme.Onboarding.welcomeHeroHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }
}

private struct OnboardingTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.light))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
    }
}

private struct OnboardingDetail: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.smMd))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

import AppKit
import SwiftUI

struct OnboardingWelcomeStep: View {
    private static let hero = BundledResource.url("Images/welcome-butterfly.jpg")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            OnboardingTitle(L10n.string("Welcome to Lenora Pro"))
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

struct OnboardingAccountStep: View {
    @Bindable var account: AccountService
    let signInFailed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                OnboardingTitle(title)
                OnboardingDetail(detail)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    private var title: String {
        guard account.isSignedIn else {
            return L10n.string("Sign In")
        }
        guard let firstName = account.account?.user.firstName else {
            return L10n.string("Welcome")
        }
        return L10n.string("Welcome, \(firstName)")
    }

    private var detail: String {
        account.isSignedIn
            ? L10n.string("You're ready to start creating.")
            : L10n.string("Sign in to receive 250 free credits for AI chat and generation.")
    }

    private var failure: String? {
        if signInFailed, !account.isSignedIn {
            return L10n.string("Sign-in couldn’t be completed. Try again.")
        }
        return nil
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

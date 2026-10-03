import SwiftUI

struct OnboardingOverlay: View {
    @Bindable var onboarding: OnboardingStore

    var body: some View {
        ZStack {
            AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.strong)
                .ignoresSafeArea()
            card
                .frame(
                    width: AppTheme.Onboarding.cardWidth,
                    height: AppTheme.Onboarding.cardHeight
                )
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            cardContent
            footer
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.vertical, AppTheme.Spacing.lgXl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(
                            AppTheme.Border.primaryColor,
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
        .shadow(AppTheme.Shadow.lg)
    }

    private var cardContent: some View {
        OnboardingWelcomeStep()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(AppTheme.Spacing.xxl)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.string("Get Started"), action: onboarding.complete)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .keyboardShortcut(.defaultAction)
        }
    }
}

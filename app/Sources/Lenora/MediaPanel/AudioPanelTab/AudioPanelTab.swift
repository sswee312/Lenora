import SwiftUI

struct AudioPanelTab: View {
    @State private var musicExpanded = true
    @State private var silenceExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                MusicSection(isExpanded: $musicExpanded)
                SpeechAnalysisSections(silenceExpanded: $silenceExpanded)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
    }
}

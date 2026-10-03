import SwiftUI

struct PendingMediaEdit: Identifiable {
    let id = UUID()
    let asset: MediaAsset
    let action: EditAction
}

struct MediaEditSheet: View {
    let asset: MediaAsset
    let action: EditAction
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var color = Color.blue
    @State private var aspectRatio = ""
    @State private var refusal: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(action.aiEditTitle)
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
            fields
            if let message {
                Text(verbatim: message)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action.aiEditTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.invalidField() != nil || isSubmitting)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.ComponentSize.mediaEditSheetWidth)
        .onAppear { aspectRatio = aspectChoices.first ?? "" }
    }

    private var message: String? {
        if let refusal { return refusal }
        guard !(first.isEmpty && second.isEmpty) else { return nil }
        return request.invalidField()?.reason
    }

    @ViewBuilder private var fields: some View {
        switch action {
        case .generativeFill, .reframe:
            Picker(L10n.string("Aspect Ratio"), selection: $aspectRatio) {
                ForEach(aspectChoices, id: \.self) { Text(verbatim: $0).tag($0) }
            }
        case .replace:
            TextField(L10n.string("Replace"), text: $first)
            TextField(L10n.string("With"), text: $second)
        case .remove:
            TextField(L10n.string("Object to remove"), text: $first)
        case .recolor:
            TextField(L10n.string("Object to recolor"), text: $first)
            ColorPicker(L10n.string("Color"), selection: $color, supportsOpacity: false)
        case .replaceBackground:
            TextField(L10n.string("New background (optional)"), text: $first)
        default:
            EmptyView()
        }
    }

    private var aspectChoices: [String] {
        action == .reframe ? MediaEditRequest.reframeAspectRatios : MediaEditRequest.fillAspectRatios
    }

    private var request: MediaEditRequest {
        switch action {
        case .generativeFill: .edit(.fill(aspectRatio: aspectRatio))
        case .replace: .edit(.replace(from: first, to: second))
        case .remove: .edit(.remove(prompt: first))
        case .recolor: .edit(.recolor(prompt: first, color: String(TextStyle.RGBA(color).hexString.prefix(7))))
        case .replaceBackground: .edit(.backgroundReplace(prompt: first.isEmpty ? nil : first))
        case .restore: .edit(.restore)
        default: .reframe(VideoReframeParams(aspectRatio: aspectRatio))
        }
    }

    private func submit() {
        let request = request
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            switch await EditSubmitter.submitEdit(request, asset: asset, editor: editor) {
            case .started: dismiss()
            case .refused(let reason): refusal = reason.userMessage
            }
        }
    }
}

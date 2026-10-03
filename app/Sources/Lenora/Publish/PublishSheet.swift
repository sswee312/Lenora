import SwiftUI

struct PublishSheet: View {
    enum Target: Identifiable {
        case export(ExportJob)
        case publication(Publication)

        var id: UUID {
            switch self {
            case .export(let job): job.id
            case .publication(let record): record.id
            }
        }
    }

    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    let target: Target
    let limits: PublishLimits
    @State private var includeVertical: Bool
    @State private var aspect: String
    @State private var includeTeaser: Bool
    @State private var teaserSeconds: Int
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    init(target: Target, limits: PublishLimits) {
        self.target = target
        self.limits = limits
        let options: PublishOptions
        if case .publication(let record) = target { options = record.options } else { options = PublishOptions() }
        _includeVertical = State(initialValue: options.vertical != nil)
        _aspect = State(initialValue: options.vertical ?? limits.verticalAspects?.first ?? "")
        _includeTeaser = State(initialValue: options.teaserSeconds != nil)
        _teaserSeconds = State(initialValue: options.teaserSeconds ?? limits.teaserSeconds?.min ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(verbatim: filename)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)

            Text(L10n.string("Always includes a stream, a download link and a poster."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            if let aspects = limits.verticalAspects, !aspects.isEmpty {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Toggle(L10n.string("Vertical cut"), isOn: $includeVertical)
                    Spacer()
                    Picker(String(), selection: $aspect) {
                        ForEach(aspects, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!includeVertical)
                }
            }

            if let range = limits.teaserSeconds {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Toggle(L10n.string("Teaser"), isOn: $includeTeaser)
                    Spacer()
                    Stepper(value: $teaserSeconds, in: range.min...range.max) {
                        Text(L10n.string("\(teaserSeconds) seconds")).monospacedDigit()
                    }
                    .disabled(!includeTeaser)
                }
            }

            Text(L10n.string("Anyone with the link can watch."))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.string("Processing is billed by the backend. The estimate appears once processing starts."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Publish")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.Export.publishSheetWidth)
        .appSheetBackground()
    }

    private var title: String {
        switch target {
        case .export: L10n.string("Publish")
        case .publication: L10n.string("Add Outputs")
        }
    }

    private var filename: String {
        switch target {
        case .export(let job): job.filename
        case .publication(let record): record.exportFilename
        }
    }

    private func submit() {
        let options = PublishOptions(vertical: includeVertical ? aspect : nil, teaserSeconds: includeTeaser ? teaserSeconds : nil)
        let service = editor.publishService
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                switch target {
                case .export(let job):
                    _ = try await service.publish(exportJobId: job.id, options: options, confirmPublic: true)
                case .publication(let record):
                    _ = try service.addOutputs(to: record.id, options: options, confirmPublic: true)
                }
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch let refusal as PublishRefusal {
                errorMessage = refusal.userMessage
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

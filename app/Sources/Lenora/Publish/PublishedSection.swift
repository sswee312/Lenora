import AppKit
import SwiftUI

struct PublishedSection: View {
    @Environment(EditorViewModel.self) private var editor
    let onAddOutputs: (Publication) -> Void
    @State private var pendingUnpublish: Publication?
    @State private var errorMessage: String?
    @State private var unpublishing: Set<UUID> = []

    private static let copyOrder: [PublishRole] = [.download, .stream, .poster, .vertical, .teaser]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            Text(L10n.string("Published"))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.md)
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.zero) {
                    ForEach(editor.publishService.publications.reversed()) { row($0) }
                }
            }
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.bottom, AppTheme.Spacing.sm)
            }
        }
        .frame(maxHeight: AppTheme.Export.publishedMaxHeight)
        .confirmationDialog(
            L10n.string("Unpublish this video?"),
            isPresented: Binding(get: { pendingUnpublish != nil }, set: { if !$0 { pendingUnpublish = nil } }),
            presenting: pendingUnpublish
        ) { record in
            Button(L10n.string("Unpublish"), role: .destructive) { unpublish(record) }
        } message: { _ in
            Text(L10n.string("Every link stops working. This can't be undone."))
        }
    }

    private func row(_ record: Publication) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(verbatim: record.exportFilename)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(statusText(record))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle([.failed, .partial].contains(record.status) ? AppTheme.Status.errorColor : AppTheme.Text.mutedColor)
                    .lineLimit(2)
            }
            Spacer()

            let ready = Self.copyOrder.filter { record.url($0) != nil }
            Menu {
                ForEach(ready, id: \.self) { role in
                    Button(role.copyTitle) { copy(record.url(role)) }
                }
            } label: {
                Image(systemName: "link").frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(ready.isEmpty)
            .help(L10n.string("Copy Link"))
            .accessibilityLabel(L10n.string("Copy Link"))

            if let download = record.url(.download) {
                ExportIconButton("arrow.up.right.square", help: L10n.string("Open")) { NSWorkspace.shared.open(download) }
            }
            if record.canAddOutputs {
                ExportIconButton("plus.rectangle.on.rectangle", help: L10n.string("Add Outputs…")) { onAddOutputs(record) }
            }
            if record.status != .unpublished {
                ExportIconButton("xmark.icloud", help: L10n.string("Unpublish")) { pendingUnpublish = record }
                    .disabled(unpublishing.contains(record.id))
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private func statusText(_ record: Publication) -> String {
        switch record.status {
        case .uploading: L10n.string("Uploading…")
        case .processing:
            record.estimate.map { L10n.string("Processing… Estimated \($0.amount.formatted()) \($0.unit)") } ?? L10n.string("Processing…")
        case .ready: L10n.string("Ready")
        case .partial: L10n.string("Ready, \(record.outputs.count { $0.status == .failed }) failed")
        case .failed: record.message.map { L10n.string("Failed: \($0)") } ?? L10n.string("Failed")
        case .unpublished: L10n.string("Unpublished")
        }
    }

    private func copy(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func unpublish(_ record: Publication) {
        errorMessage = nil
        let service = editor.publishService
        guard unpublishing.insert(record.id).inserted else { return }
        Task {
            defer { unpublishing.remove(record.id) }
            do { _ = try await service.unpublish(record.id) }
            catch is CancellationError {}
            catch let refusal as PublishRefusal { errorMessage = refusal.userMessage }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

@MainActor private extension PublishRole {
    var copyTitle: String {
        switch self {
        case .download: L10n.string("Copy Link")
        case .stream: L10n.string("Copy Stream Link")
        case .poster: L10n.string("Copy Poster Link")
        case .vertical: L10n.string("Copy Vertical Cut Link")
        case .teaser: L10n.string("Copy Teaser Link")
        }
    }
}

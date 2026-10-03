import SwiftUI

extension GenerationView {
    var rewriteTargetKind: String? {
        switch selectedType {
        case .video: "video.generate"
        case .image: "image.generate"
        case .audio: audioModel.category == .tts ? "audio.speech" : nil
        case .upscale: nil
        }
    }

    @ViewBuilder
    var improvePromptButton: some View {
        let rewriter = editor.promptRewriter
        if rewriter.isAvailable, let target = rewriteTargetKind {
            Button {
                rewriter.rewrite(prompt, targetKind: target, current: { prompt }, apply: applyRewrite)
            } label: {
                Group {
                    if rewriter.phase == .rewriting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .hoverHighlight()
            }
            .buttonStyle(.plain)
            .disabled(!rewriter.canRewrite(prompt) || rewriter.phase == .rewriting)
            .help(L10n.string("Improve Prompt"))
            .accessibilityLabel(L10n.string("Improve Prompt"))
        }
    }

    @ViewBuilder
    var promptRewriteError: some View {
        if case .failed(let failure) = editor.promptRewriter.phase {
            Text(failure.userMessage)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.errorColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }

    func applyRewrite(_ rewritten: String) {
        if let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.string == prompt {
            PromptRewriter.replaceText(in: view, with: rewritten)
        } else {
            prompt = rewritten
        }
    }

    func cancelPromptRewrite() { editor.promptRewriter.cancel() }
}

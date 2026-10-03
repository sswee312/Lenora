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
        let responder = promptWindow.window?.firstResponder
        if let view = PromptRewriter.promptTextView(promptFocused: isPromptFocused, firstResponder: responder, sentText: prompt),
           PromptRewriter.replaceText(in: view, with: rewritten) { return }
        prompt = rewritten
    }

    func cancelPromptRewrite() { editor.promptRewriter.cancel() }
}

final class HostWindow {
    weak var window: NSWindow?
}

struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView { Reader(host: host) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        let host: HostWindow
        init(host: HostWindow) { self.host = host; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { host.window = window }
    }
}

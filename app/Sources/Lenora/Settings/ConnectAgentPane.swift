import AppKit
import SwiftUI

struct ConnectAgentPane: View {
    private static let maskedToken = String(repeating: "\u{2022}", count: 24)

    @Bindable private var appState = AppState.shared

    @State private var token: String?
    @State private var tokenFailed = false
    @State private var port = MCPPort.current
    @State private var portDraft = String(MCPPort.current)
    @State private var portInvalid = false
    @State private var confirmingRegenerate = false
    @State private var extensionURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            Text(L10n.string("Agents sign in with this token and port. Treat the token like a password."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            portRow
            tokenRow
            if tokenFailed || appState.mcpService?.startError != nil {
                Text(failureMessage)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                extensionRow
                Divider().overlay(AppTheme.Border.subtleColor)
                snippetRow(.claude, name: "Claude Code") { AgentConnectionSnippets.claudeCode(port: port, token: $0) }
                Divider().overlay(AppTheme.Border.subtleColor)
                snippetRow(.cursor, name: "Cursor") { AgentConnectionSnippets.cursor(port: port, token: $0) }
                Divider().overlay(AppTheme.Border.subtleColor)
                snippetRow(.codex, name: "Codex") { AgentConnectionSnippets.codex(port: port, token: $0) }
            }
        }
        .task {
            await loadToken()
            extensionURL = await Self.locateExtension()
        }
        .confirmationDialog(
            L10n.string("Regenerate token?"),
            isPresented: $confirmingRegenerate,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Regenerate token"), role: .destructive, action: regenerate)
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("Every connected agent will need the new token."))
        }
    }

    private var failureMessage: String {
        if tokenFailed { return L10n.string("The MCP token is unavailable. Check Keychain access, then try again.") }
        return appState.mcpService?.startError ?? ""
    }

    // MARK: - Port and token

    private var portRow: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            label(L10n.string("Port"))
            TextField(String(), text: $portDraft)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit(applyPort)
                .frame(width: AppTheme.Settings.portInputWidth)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(
                            portInvalid ? AppTheme.Status.errorColor : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                )
                .accessibilityLabel(L10n.string("Port"))
            if portInvalid {
                Text(L10n.string("Use a port between 1024 and 65535."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    private var tokenRow: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            label(L10n.string("Token"))
            Text(verbatim: Self.maskedToken)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer(minLength: AppTheme.Spacing.md)
            CopyTextButton(value: token ?? "")
                .disabled(token == nil)
            Button(L10n.string("Regenerate token")) { confirmingRegenerate = true }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(token == nil)
        }
    }

    private func label(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
    }

    private func loadToken() async {
        do {
            token = try await MCPAccessToken.loadOrCreate()
            tokenFailed = false
        } catch {
            Log.mcp.error("mcp token unavailable: \(error.localizedDescription)")
            tokenFailed = true
        }
    }

    private func applyPort() {
        guard let value = Int(portDraft.trimmingCharacters(in: .whitespaces)),
              let valid = UInt16(exactly: value), MCPPort.resolve(value) == valid else {
            portInvalid = true
            return
        }
        portInvalid = false
        portDraft = String(valid)
        guard valid != port else { return }
        UserDefaults.standard.set(Int(valid), forKey: MCPPort.defaultsKey)
        port = valid
        guard let service = appState.mcpService else { return }
        Task { await service.restart() }
    }

    private func regenerate() {
        Task {
            do {
                token = try await MCPAccessToken.regenerate()
                tokenFailed = false
                await appState.mcpService?.restart()
            } catch {
                Log.mcp.error("mcp token regeneration failed: \(error.localizedDescription)")
                tokenFailed = true
            }
        }
    }

    // MARK: - Agents

    private func snippetRow(
        _ agent: SkillExternalAgent,
        name: String,
        snippet: (String) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            agentHeader(agent, name: name)
            HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
                Text(verbatim: snippet(Self.maskedToken))
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyTextButton(value: token.map(snippet) ?? "")
                    .disabled(token == nil)
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.md)
            .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.sm)
        }
        .padding(.vertical, AppTheme.Spacing.mdLg)
    }

    private var extensionRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                agentHeader(.claude, name: "Claude Desktop")
                Spacer(minLength: AppTheme.Spacing.md)
                Button(L10n.string("Install Extension"), action: installExtension)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(extensionURL == nil)
            }
            Text(L10n.string("Paste the token when Claude Desktop asks."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(.bottom, AppTheme.Spacing.mdLg)
    }

    private func agentHeader(_ agent: SkillExternalAgent, name: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ExternalAgentLogo(agent: agent, size: AppTheme.IconSize.lgXl)
            Text(verbatim: name)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
    }

    private func installExtension() {
        guard let extensionURL else { return }
        NSWorkspace.shared.open(extensionURL)
    }

    @concurrent private static func locateExtension() async -> URL? {
        BundledResource.url("lenora.mcpb")
    }
}

private struct CopyTextButton: View {
    private static let feedbackDuration: Duration = .seconds(1.4)

    let value: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(copied ? L10n.string("Copied") : L10n.string("Copy"))
        .accessibilityLabel(L10n.string("Copy"))
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: Self.feedbackDuration)
            copied = false
        }
    }
}

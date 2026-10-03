import SwiftUI

// AI Edit menu for a media asset's context menu.
struct AIEditMenu: View {
    let asset: MediaAsset
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if availableActions.isEmpty && availableAudioTransforms.isEmpty {
            EmptyView()
        } else {
            Menu(L10n.string("AI Edit")) {
                if !enhanceActions.isEmpty {
                    Section(L10n.string("AI Enhance")) {
                        if enhanceActions.contains(.upscale) {
                            Button(L10n.string("Upscale…")) { runUpscale() }
                        }
                        if enhanceActions.contains(.removeBackground) {
                            Button(L10n.string("Remove Background")) { editor.removeBackground(of: asset) }
                        }
                        if enhanceActions.contains(.edit) {
                            Button(L10n.string("Edit…")) { edit() }
                        }
                        if enhanceActions.contains(.rerun) {
                            Button(L10n.string("Rerun")) { rerun() }
                        }
                        if enhanceActions.contains(.lipSync) {
                            Button(L10n.string("Lip Sync…")) { lipSync() }
                        }
                        if enhanceActions.contains(.reframe) {
                            Button(L10n.string("Reframe…")) { reframe() }
                        }
                        if enhanceActions.contains(.createVideo) {
                            Menu(L10n.string("Create Video")) {
                                Button(L10n.string("Set as first frame")) { createVideo(asReference: false) }
                                Button(L10n.string("Set as reference")) { createVideo(asReference: true) }
                            }
                        }
                    }
                }
                if !audioActions.isEmpty || !availableAudioTransforms.isEmpty {
                    Section(L10n.string("AI Audio")) {
                        if audioActions.contains(.rerun) {
                            Button(L10n.string("Rerun")) { rerun() }
                        }
                        ForEach(availableAudioTransforms, id: \.category) { kind in
                            Button(L10n.string(key: kind.menuTitle)) { audioTransform(kind: kind) }
                        }
                        if audioActions.contains(.generateMusic) {
                            Button(L10n.string(key: VideoToAudioEditKind.music.menuTitle)) {
                                videoAudio(kind: .music)
                            }
                        }
                        if audioActions.contains(.generateSFX) {
                            Button(L10n.string(key: VideoToAudioEditKind.sfx.menuTitle)) {
                                videoAudio(kind: .sfx)
                            }
                        }
                    }
                }
            }
        }
    }

    private var availableActions: [EditAction] {
        EditAction.available(for: asset)
    }

    private var enhanceActions: [EditAction] {
        availableActions.filter { $0.group(for: asset.type) == .enhance }
    }

    private var audioActions: [EditAction] {
        availableActions.filter { $0.group(for: asset.type) == .audio }
    }

    private var availableAudioTransforms: [AudioTransformEditKind] {
        AudioTransformEditKind.available(for: asset)
    }

    private func runUpscale() {
        guard let model = UpscaleModelConfig.models(for: asset.type).first else { return }
        let stored = EditSubmitter.upscaleSeed(for: asset, model: model)
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func edit() {
        guard let stored = EditSubmitter.editSeed(for: asset) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func reframe() {
        guard let stored = EditSubmitter.reframeSeed(for: asset) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func lipSync() {
        guard let model = VideoModelConfig.lipSync,
              let stored = EditSubmitter.lipSyncSeed(for: asset, model: model) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func videoAudio(kind: VideoToAudioEditKind) {
        guard let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func audioTransform(kind: AudioTransformEditKind) {
        guard let stored = EditSubmitter.audioTransformSeed(for: asset, kind: kind) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func rerun() {
        if let stored = asset.generationInput {
            editor.seedGenerationPanel(asset: asset, stored: stored)
        }
    }

    private func createVideo(asReference: Bool) {
        guard let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }
}

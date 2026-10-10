// Kizuna for iOS/iPadOS - stream quality settings
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import SwiftUI

struct StreamSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            NightBackground()
            ScrollView {
                VStack(spacing: 20) {
                    presetCard
                    videoCard
                    controlsCard
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(L("settings.stream.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("settings.preset"), systemImage: "speedometer")
            KZGlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach([StreamSettings.Preset.lowLatency, .balanced, .maxQuality]) { preset in
                        presetButton(preset)
                    }
                }
            }
            if model.settings.preset == .custom {
                Text(L("preset.custom"))
                    .font(.footnote)
                    .foregroundStyle(KZColor.textSecondary)
            }
        }
        .kzCard()
    }

    private func presetButton(_ preset: StreamSettings.Preset) -> some View {
        let selected = model.settings.preset == preset
        return Button {
            var updated = model.settings
            updated.apply(preset)
            model.settings = updated
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon(for: preset))
                    .font(.title3)
                Text(preset.title)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .foregroundStyle(selected ? Color.white : KZColor.textSecondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(KZColor.focusGradient)
                        .opacity(0.85)
                }
            }
            .kzGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
    }

    private func icon(for preset: StreamSettings.Preset) -> String {
        switch preset {
        case .lowLatency: return "bolt.fill"
        case .balanced: return "scale.3d"
        case .maxQuality: return "sparkles"
        case .custom: return "slider.horizontal.3"
        }
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            KZSectionHeader(title: L("settings.resolution"), systemImage: "rectangle.on.rectangle")
            Picker(L("settings.resolution"), selection: binding(\.resolution)) {
                Text("720p").tag(720)
                Text("1080p").tag(1080)
            }
            .pickerStyle(.segmented)

            Text(L("settings.fps"))
                .font(.subheadline.weight(.semibold))
            Picker(L("settings.fps"), selection: binding(\.fps)) {
                Text("30").tag(30)
                Text("60").tag(60)
            }
            .pickerStyle(.segmented)

            Text(L("settings.codec"))
                .font(.subheadline.weight(.semibold))
            Picker(L("settings.codec"), selection: binding(\.hevc)) {
                Text("HEVC").tag(true)
                Text("H.264").tag(false)
            }
            .pickerStyle(.segmented)
            Text(L("settings.codec.note"))
                .font(.caption)
                .foregroundStyle(KZColor.textSecondary)

            Text(L("settings.bitrate", Int(model.settings.bitrateMbps)))
                .font(.subheadline.weight(.semibold))
            Slider(value: binding(\.bitrateMbps), in: 5...50, step: 1) {
                Text(L("settings.bitrate", Int(model.settings.bitrateMbps)))
            } minimumValueLabel: {
                Text("5").font(.caption)
            } maximumValueLabel: {
                Text("50").font(.caption)
            }
            .tint(KZColor.accent)
        }
        .kzCard()
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("settings.controls"), systemImage: "gamecontroller")
            Toggle(L("settings.haptics"), isOn: plainBinding(\.hapticsEnabled))
            Toggle(L("settings.triggers"), isOn: plainBinding(\.adaptiveTriggers))
            Toggle(L("settings.swap"), isOn: plainBinding(\.swapFaceButtons))
            Toggle(L("settings.stats"), isOn: plainBinding(\.showStats))
            Text(L("settings.touch"))
                .font(.subheadline.weight(.semibold))
            Picker(L("settings.touch"), selection: plainBinding(\.touchControls)) {
                ForEach(TouchControlsMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .tint(KZColor.accent)
        .kzCard()
    }

    /// Binding for a quality value: editing it turns the preset into "custom"
    /// unless the new combination matches a preset again.
    private func binding<T>(_ keyPath: WritableKeyPath<StreamSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = model.settings
                updated[keyPath: keyPath] = newValue
                updated.refreshPreset()
                model.settings = updated
            })
    }

    private func plainBinding<T>(_ keyPath: WritableKeyPath<StreamSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = model.settings
                updated[keyPath: keyPath] = newValue
                model.settings = updated
            })
    }
}

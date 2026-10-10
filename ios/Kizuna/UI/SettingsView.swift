// Kizuna for iOS/iPadOS - settings, account, about (AGPL notice), log
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false

    /// Replace with the public repository URL when the source is published (AGPL §13).
    static let sourceURL = URL(string: "https://github.com/hemidal2696-collab/kizuna")!

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NightBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        accountCard
                        streamLinkCard
                        languageCard
                        diagnosticsCard
                        aboutCard
                    }
                    .padding(20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(L("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showSignIn) {
                PSNSignInSheet { credentials in
                    model.psnSignedIn(credentials)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        DiagnosticsCard()
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("settings.account"), systemImage: "person.crop.circle")
            if let psn = model.psn {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(psn.onlineID.isEmpty ? "PlayStation Network" : psn.onlineID)
                            .font(.headline)
                        Text("Account ID: \(psn.accountID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(KZColor.textSecondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                Button(role: .destructive) {
                    model.signOutPSN()
                } label: {
                    KZButtonLabel(title: L("psn.signout"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .kzGlassButton()
            } else {
                Text(L("add.psn.body"))
                    .font(.footnote)
                    .foregroundStyle(KZColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showSignIn = true
                } label: {
                    KZButtonLabel(title: L("add.psn.signin"), systemImage: "person.badge.key")
                }
                .kzProminentButton()
            }
        }
        .kzCard()
    }

    private var streamLinkCard: some View {
        NavigationLink {
            StreamSettingsView()
                .environmentObject(model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "dial.medium")
                    .font(.title3)
                    .foregroundStyle(KZColor.focusGradient)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.stream.title"))
                        .font(.headline)
                        .foregroundStyle(KZColor.textPrimary)
                    Text("\(model.settings.preset.title) · \(model.settings.resolution)p\(model.settings.fps) · \(model.settings.hevc ? "HEVC" : "H.264") · \(Int(model.settings.bitrateMbps)) Mbps")
                        .font(.caption)
                        .foregroundStyle(KZColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(KZColor.textSecondary)
            }
            .kzCard()
        }
        .buttonStyle(.plain)
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("settings.language"), systemImage: "globe")
            Picker(L("settings.language"), selection: $model.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
        }
        .kzCard()
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("settings.about"), systemImage: "info.circle")
            Text(L("about.version", appVersion))
                .font(.subheadline.weight(.medium))
            Text(KizunaCoreBridge.version)
                .font(.caption.monospaced())
                .foregroundStyle(KZColor.textSecondary)
            Divider().overlay(KZColor.hairline)
            Text(L("about.license.title"))
                .font(.headline)
            Text(L("about.license.body"))
                .font(.footnote)
                .foregroundStyle(KZColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: Self.sourceURL) {
                Label(L("about.source"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .foregroundStyle(KZColor.link)
            Link(destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!) {
                Label("GNU AGPL v3.0", systemImage: "doc.text")
            }
            .foregroundStyle(KZColor.link)
            Text(L("about.disclaimer"))
                .font(.caption2)
                .foregroundStyle(KZColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                LogView()
            } label: {
                Label(L("settings.log"), systemImage: "doc.plaintext")
                    .foregroundStyle(KZColor.link)
            }
        }
        .kzCard()
    }
}

struct LogView: View {
    @State private var text = LogStore.shared.snapshot()

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "—" : text)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color.black)
        .navigationTitle(L("settings.log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel(L("settings.log.copy"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    text = LogStore.shared.snapshot()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}

/// Settings card for the diagnostics log: on/off, export through the share sheet, delete.
private struct DiagnosticsCard: View {
    @State private var enabled = DiagnosticsLog.shared.enabled
    @State private var sessions = DiagnosticsLog.shared.sessionFiles().count
    @State private var exportURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("diag.title"), systemImage: "waveform.path.ecg")
            Toggle(L("diag.enabled"), isOn: $enabled)
                .onChange(of: enabled) { _, value in DiagnosticsLog.shared.enabled = value }
            Text(L("diag.privacy"))
                .font(.footnote)
                .foregroundStyle(KZColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("diag.count", sessions))
                .font(.footnote.weight(.semibold))
            HStack(spacing: 12) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        KZButtonLabel(title: L("diag.export"), systemImage: "square.and.arrow.up")
                    }
                    .kzProminentButton()
                }
                Button(role: .destructive) {
                    DiagnosticsLog.shared.clearAll()
                    sessions = 0
                    exportURL = nil
                } label: {
                    KZButtonLabel(title: L("diag.clear"), systemImage: "trash")
                }
                .kzGlassButton()
                .disabled(sessions == 0)
            }
        }
        .kzCard()
        .onAppear {
            sessions = DiagnosticsLog.shared.sessionFiles().count
            exportURL = sessions > 0 ? DiagnosticsLog.shared.exportFile() : nil
        }
    }
}

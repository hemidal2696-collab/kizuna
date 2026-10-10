// Kizuna for iOS/iPadOS - "My consoles" home screen
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import SwiftUI

struct ConsolesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var renaming: ConsoleRecord? = nil
    @State private var renameText = ""
    @State private var deleting: ConsoleRecord? = nil

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 20)]

    var body: some View {
        ZStack {
            NightBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if model.consoles.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(model.consoles) { console in
                                card(for: console)
                            }
                        }
                    }
                    if !model.unpairedDiscovered.isEmpty {
                        foundSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .refreshable {
                model.sweep()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(L("settings.title"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("consoles.add"))
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAdd) {
            AddConsoleView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .alert(L("consoles.rename"), isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })) {
            TextField(L("consoles.rename"), text: $renameText)
            Button(L("common.save")) {
                if let renaming { model.rename(renaming, to: renameText) }
                renaming = nil
            }
            Button(L("common.cancel"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(L("common.delete"), isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("common.delete"), role: .destructive) {
                if let deleting { model.delete(deleting) }
                deleting = nil
            }
            Button(L("common.cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L("consoles.delete.confirm", deleting?.displayName ?? ""))
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kizuna")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(KZColor.textPrimary)
                Text(L("app.tagline"))
                    .font(.subheadline)
                    .foregroundStyle(KZColor.textSecondary)
            }
            Spacer()
            if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("consoles.scanning"))
                        .font(.footnote)
                        .foregroundStyle(KZColor.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .kzGlass(in: Capsule())
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "playstation.logo")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(KZColor.focusGradient)
                .padding(.top, 8)
            Text(L("consoles.empty.title"))
                .font(.title2.weight(.semibold))
            Text(L("consoles.empty.body"))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(KZColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showAdd = true
            } label: {
                KZButtonLabel(title: L("consoles.add"), systemImage: "plus")
            }
            .kzProminentButton()
            .controlSize(.large)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .kzCard(padding: 28)
    }

    private var foundSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("consoles.found.title"), systemImage: "wifi")
            ForEach(model.unpairedDiscovered) { host in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.name.isEmpty ? (host.isPS5 ? "PS5" : "PS4") : host.name)
                            .font(.headline)
                        Text("\(host.isPS5 ? "PS5" : "PS4") · \(host.address)")
                            .font(.subheadline)
                            .foregroundStyle(KZColor.textSecondary)
                    }
                    Spacer()
                    StatusPill(text: L("consoles.unregistered"), color: KZColor.link)
                }
                .kzCard(padding: 18, cornerRadius: 22)
                .onTapGesture { showAdd = true }
            }
        }
    }

    private func card(for console: ConsoleRecord) -> some View {
        let state = model.state(for: console)
        let address = model.discoveredEntry(for: console)?.address ?? console.address
        return ConsoleCard(
            console: console,
            state: state,
            address: address,
            canConnectRemotely: console.canStreamRemotely && model.psn != nil,
            onConnect: { model.connect(console) },
            onConnectRemote: { model.connect(console, remote: true) },
            onWake: { model.wake(console) },
            onRename: {
                renameText = console.name
                renaming = console
            },
            onDelete: { deleting = console })
    }
}

struct ConsoleCard: View {
    let console: ConsoleRecord
    let state: ConsoleState
    let address: String
    let canConnectRemotely: Bool
    let onConnect: () -> Void
    let onConnectRemote: () -> Void
    let onWake: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var stateText: String {
        switch state {
        case .ready: return L("state.ready")
        case .standby: return L("state.standby")
        case .offline: return L("state.offline")
        case .unknown: return L("state.unknown")
        }
    }

    private var stateColor: Color {
        switch state {
        case .ready: return KZColor.success
        case .standby: return KZColor.standby
        case .offline: return KZColor.signal
        case .unknown: return Color.gray
        }
    }

    private var subtitle: String {
        if !address.isEmpty {
            return "\(console.platformLabel) · \(address)"
        }
        return "\(console.platformLabel) · " + (console.canStreamRemotely ? L("consoles.remote.only") : L("consoles.no.address"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(KZColor.focusGradient)
                        .opacity(0.9)
                    Image(systemName: "playstation.logo")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 5) {
                    Text(console.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(KZColor.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(KZColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                StatusPill(text: stateText, color: stateColor)
            }

            KZGlassGroup(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: onConnect) {
                        KZButtonLabel(title: L("consoles.connect"), systemImage: "play.fill")
                    }
                    .kzProminentButton()
                    .controlSize(.large)

                    if state == .standby || state == .offline {
                        Button(action: onWake) {
                            KZButtonLabel(title: L("consoles.wake"), systemImage: "power")
                        }
                        .kzGlassButton()
                        .controlSize(.large)
                    }

                    Spacer(minLength: 0)

                    Menu {
                        if canConnectRemotely {
                            Button(action: onConnectRemote) {
                                Label(L("consoles.connect.remote"), systemImage: "globe")
                            }
                        }
                        Button(action: onWake) {
                            Label(L("consoles.wake"), systemImage: "power")
                        }
                        Button(action: onRename) {
                            Label(L("consoles.rename"), systemImage: "pencil")
                        }
                        Button(role: .destructive, action: onDelete) {
                            Label(L("common.delete"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .kzGlass(in: Circle(), interactive: true)
                }
            }
        }
        .kzCard(padding: 22)
    }
}

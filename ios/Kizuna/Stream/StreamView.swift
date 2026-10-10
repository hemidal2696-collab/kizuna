// Kizuna for iOS/iPadOS - full-screen stream, quick menu, stats HUD
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import SwiftUI

struct StreamView: View {
    @ObservedObject var session: StreamSession
    @State private var showMenu = false
    @State private var pinText = ""

    private var isStreaming: Bool {
        if case .streaming = session.phase { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StreamVideoView(decoder: session.video)
                .ignoresSafeArea()

            if isStreaming && session.showsTouchControls {
                TouchControlsView(input: session.input)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }

            VStack {
                HStack(alignment: .top) {
                    if session.showStats && isStreaming {
                        StatsHUD(stats: session.stats)
                    }
                    Spacer()
                    Button {
                        showMenu = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .kzGlass(in: Circle(), interactive: true)
                    .opacity(isStreaming ? 0.7 : 1)
                    .accessibilityLabel(L("stream.menu"))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            phaseOverlay
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .sheet(isPresented: $showMenu) {
            QuickMenuView(session: session) {
                showMenu = false
            }
            .presentationDetents([.medium, .large])
        }
        .alert(L("stream.pin.title"), isPresented: Binding(
            get: { session.pinPrompt != nil },
            set: { if !$0 { session.pinPrompt = nil } })) {
            TextField("PIN", text: $pinText)
                .keyboardType(.numberPad)
            Button(L("common.ok")) {
                session.submitPIN(pinText)
                pinText = ""
            }
            Button(L("common.cancel"), role: .cancel) {
                session.disconnect()
            }
        } message: {
            Text(session.pinPrompt?.incorrect == true ? L("stream.pin.wrong") : L("stream.pin.body"))
        }
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch session.phase {
        case .connecting(let text):
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(text)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(session.console.displayName + (session.viaPSN ? " · PSN" : ""))
                    .font(.subheadline)
                    .foregroundStyle(KZColor.textSecondary)
                Button {
                    session.disconnect()
                } label: {
                    KZButtonLabel(title: L("common.cancel"), systemImage: "xmark")
                }
                .kzGlassButton()
            }
            .padding(30)
            .frame(maxWidth: 420)
            .kzGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        case .ended(let message, let isError):
            VStack(spacing: 16) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(isError ? KZColor.signal : KZColor.success)
                Text(isError ? L("stream.failed") : L("stream.ended"))
                    .font(.title3.weight(.semibold))
                if isError {
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(KZColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    session.close()
                } label: {
                    KZButtonLabel(title: L("common.close"), systemImage: "xmark")
                }
                .kzProminentButton()
                .controlSize(.large)
            }
            .padding(30)
            .frame(maxWidth: 440)
            .kzGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        case .streaming:
            EmptyView()
        }
    }
}

struct StatsHUD: View {
    let stats: StreamSession.Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(L("stats.bitrate"), String(format: "%.1f Mbps", stats.bitrateMbps))
            row(L("stats.fps"), String(format: "%.0f", stats.fps))
            row(L("stats.loss"), String(format: "%.1f %%", stats.packetLoss * 100))
            row(L("stats.decode"), String(format: "%.2f ms", stats.processingMs))
            row(L("stats.latency"), "\(stats.rttMs) ms")
            row(L("stats.lost"), "\(stats.framesLost)")
            row(L("stats.audio"), "\(stats.audioBufferedMs) ms · \(stats.audioUnderruns)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .kzGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(KZColor.textSecondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
        }
    }
}

struct QuickMenuView: View {
    @ObservedObject var session: StreamSession
    let close: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                NightBackground()
                ScrollView {
                    KZGlassGroup(spacing: 14) {
                        LazyVGrid(columns: columns, spacing: 14) {
                            tile(L("stream.menu.ps"), "playstation.logo") {
                                close()
                                session.pressPS()
                            }
                            tile(L("stream.menu.touchpad"), "hand.tap") {
                                close()
                                session.clickTouchpad()
                            }
                            tile(L("stream.menu.screenshot"), "camera") {
                                close()
                                session.screenshot()
                            }
                            tile(L("stream.menu.stats"), session.showStats ? "chart.bar.fill" : "chart.bar") {
                                session.showStats.toggle()
                            }
                            tile(L("stream.menu.controls"), session.showsTouchControls ? "hand.raised.fill" : "hand.raised") {
                                session.touchControlsOverride = !session.showsTouchControls
                            }
                            tile(L("stream.menu.sleep"), "moon.zzz") {
                                close()
                                session.sleepConsole()
                            }
                            tile(L("stream.menu.disconnect"), "xmark.circle", tint: KZColor.signal) {
                                close()
                                session.disconnect()
                            }
                        }
                    }
                    .padding(20)
                    Text(L("stream.menu.hint"))
                        .font(.caption)
                        .foregroundStyle(KZColor.textSecondary)
                        .padding(.horizontal, 20)
                }
            }
            .navigationTitle(L("stream.menu"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done"), action: close)
                }
            }
        }
    }

    private func tile(_ title: String, _ symbol: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint ?? KZColor.link)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(KZColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(.horizontal, 10)
            .kzGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true, tint: tint?.opacity(0.35))
        }
        .buttonStyle(.plain)
    }
}

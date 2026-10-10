// Kizuna for iOS/iPadOS - root navigation
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ConsolesView()
        }
        .fullScreenCover(item: $model.activeStream) { session in
            StreamView(session: session)
                .environmentObject(model)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.toast)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(KZColor.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .kzGlass(in: Capsule(), tint: KZColor.accent.opacity(0.5))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

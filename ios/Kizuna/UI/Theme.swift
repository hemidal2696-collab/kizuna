// Kizuna for iOS/iPadOS - palette and Liquid Glass helpers
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// Liquid Glass (iOS 26): .glassEffect / GlassEffectContainer / .glass button
// styles. On iOS 17-25 the same helpers fall back to materials and the
// classic bordered button styles.

import SwiftUI
import UIKit

enum KZColor {
    static let nightTop = Color(hex: 0x0B1530)
    static let nightBottom = Color(hex: 0x05070D)
    static let accent = Color(hex: 0x0070D1)
    static let link = Color(hex: 0x4DA3FF)
    static let signal = Color(hex: 0xFF3C28)
    static let focusStart = Color(hex: 0x2EC5FF)
    static let focusEnd = Color(hex: 0x5B7CFF)
    static let success = Color(hex: 0x22C38E)
    static let standby = Color(hex: 0xF5A524)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.66)
    static let hairline = Color.white.opacity(0.12)

    static var focusGradient: LinearGradient {
        LinearGradient(colors: [focusStart, focusEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Night gradient (#0B1530 -> #05070D) with a soft PS-blue glow.
struct NightBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [KZColor.nightTop, KZColor.nightBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [KZColor.accent.opacity(0.35), .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [KZColor.focusEnd.opacity(0.18), .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Liquid Glass surface on iOS 26, ultra-thin material before.
    @ViewBuilder
    func kzGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint {
                            shape.fill(tint.opacity(0.22))
                        }
                    }
                }
                .overlay(shape.stroke(KZColor.hairline, lineWidth: 1))
        }
    }

    /// Standard card: generous padding + rounded glass.
    func kzCard(padding: CGFloat = 20, cornerRadius: CGFloat = 28) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kzGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Primary action (Connect, Pair...).
    @ViewBuilder
    func kzProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary action (Wake, Cancel...).
    @ViewBuilder
    func kzGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Groups glass shapes so they blend/morph together on iOS 26.
struct KZGlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// Uniform button label with comfortable padding (fixes cramped text).
struct KZButtonLabel: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
            }
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
    }
}

/// Small coloured status pill (Ready / Rest mode / Offline).
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KZColor.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .kzGlass(in: Capsule(), tint: color.opacity(0.6))
    }
}

/// Section header used across the forms.
struct KZSectionHeader: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(KZColor.focusGradient)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(KZColor.textPrimary)
            Spacer()
        }
    }
}

/// Text field styled for the dark glass UI.
struct KZTextField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(KZColor.hairline, lineWidth: 1)
            )
    }
}

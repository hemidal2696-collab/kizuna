// Kizuna for iOS/iPadOS - on-screen DualSense layout (used when no controller is connected)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import SwiftUI
import UIKit

struct TouchControlsView: View {
    let input: InputManager

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let u = max(44, min(w, h) / 6.2)   // base unit, >= 44 pt touch target

            ZStack {
                // Shoulders / triggers
                TriggerPad(title: "L2", left: true, input: input, size: CGSize(width: u * 1.25, height: u * 0.62))
                    .position(x: u * 0.95, y: u * 0.55)
                PadButton(bit: KZ_BTN_L1, input: input, size: CGSize(width: u * 1.25, height: u * 0.62)) {
                    Text("L1").font(.system(size: u * 0.26, weight: .bold, design: .rounded))
                }
                .position(x: u * 2.35, y: u * 0.55)
                PadButton(bit: KZ_BTN_R1, input: input, size: CGSize(width: u * 1.25, height: u * 0.62)) {
                    Text("R1").font(.system(size: u * 0.26, weight: .bold, design: .rounded))
                }
                .position(x: w - u * 2.35, y: u * 0.55)
                TriggerPad(title: "R2", left: false, input: input, size: CGSize(width: u * 1.25, height: u * 0.62))
                    .position(x: w - u * 0.95, y: u * 0.55)

                // Touchpad
                VirtualTouchpad(input: input)
                    .frame(width: min(u * 3.6, w * 0.34), height: u * 1.1)
                    .position(x: w / 2, y: u * 0.75)

                // D-pad
                dpad(u: u)
                    .position(x: u * 1.55, y: h * 0.47)

                // Face buttons
                faceButtons(u: u)
                    .position(x: w - u * 1.55, y: h * 0.47)

                // Sticks
                VirtualStick(left: true, clickBit: KZ_BTN_L3, input: input, radius: u * 0.78)
                    .position(x: u * 3.3, y: h - u * 1.05)
                VirtualStick(left: false, clickBit: KZ_BTN_R3, input: input, radius: u * 0.78)
                    .position(x: w - u * 3.3, y: h - u * 1.05)

                // Create / PS / Options
                PadButton(bit: KZ_BTN_SHARE, input: input, size: CGSize(width: u * 0.62, height: u * 0.42)) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: u * 0.2, weight: .semibold))
                }
                .position(x: w / 2 - u * 1.05, y: h - u * 0.45)
                PadButton(bit: KZ_BTN_PS, input: input, size: CGSize(width: u * 0.62, height: u * 0.62), circular: true) {
                    Image(systemName: "playstation.logo").font(.system(size: u * 0.26, weight: .semibold))
                }
                .position(x: w / 2, y: h - u * 0.5)
                PadButton(bit: KZ_BTN_OPTIONS, input: input, size: CGSize(width: u * 0.62, height: u * 0.42)) {
                    Image(systemName: "line.3.horizontal").font(.system(size: u * 0.2, weight: .semibold))
                }
                .position(x: w / 2 + u * 1.05, y: h - u * 0.45)
            }
            .opacity(0.78)
        }
    }

    private func dpad(u: CGFloat) -> some View {
        let s = CGSize(width: u * 0.66, height: u * 0.66)
        return ZStack {
            PadButton(bit: KZ_BTN_DPAD_UP, input: input, size: s) {
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: u * 0.22))
            }
            .offset(y: -u * 0.68)
            PadButton(bit: KZ_BTN_DPAD_DOWN, input: input, size: s) {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: u * 0.22))
            }
            .offset(y: u * 0.68)
            PadButton(bit: KZ_BTN_DPAD_LEFT, input: input, size: s) {
                Image(systemName: "arrowtriangle.left.fill").font(.system(size: u * 0.22))
            }
            .offset(x: -u * 0.68)
            PadButton(bit: KZ_BTN_DPAD_RIGHT, input: input, size: s) {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: u * 0.22))
            }
            .offset(x: u * 0.68)
        }
        .frame(width: u * 2.1, height: u * 2.1)
    }

    private func faceButtons(u: CGFloat) -> some View {
        let s = CGSize(width: u * 0.7, height: u * 0.7)
        return ZStack {
            PadButton(bit: KZ_BTN_PYRAMID, input: input, size: s, circular: true) {
                Image(systemName: "triangle").font(.system(size: u * 0.26, weight: .bold))
                    .foregroundStyle(Color(hex: 0x3DDC97))
            }
            .offset(y: -u * 0.7)
            PadButton(bit: KZ_BTN_CROSS, input: input, size: s, circular: true) {
                Image(systemName: "xmark").font(.system(size: u * 0.26, weight: .bold))
                    .foregroundStyle(Color(hex: 0x7EB2FF))
            }
            .offset(y: u * 0.7)
            PadButton(bit: KZ_BTN_BOX, input: input, size: s, circular: true) {
                Image(systemName: "square").font(.system(size: u * 0.26, weight: .bold))
                    .foregroundStyle(Color(hex: 0xF28CD6))
            }
            .offset(x: -u * 0.7)
            PadButton(bit: KZ_BTN_MOON, input: input, size: s, circular: true) {
                Image(systemName: "circle").font(.system(size: u * 0.26, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
            }
            .offset(x: u * 0.7)
        }
        .frame(width: u * 2.2, height: u * 2.2)
    }
}

/// Momentary button: pressed while a finger is down on it.
struct PadButton<Content: View>: View {
    let bit: Int32
    let input: InputManager
    let size: CGSize
    var circular: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circular ? size.height / 2 : min(14, size.height / 3), style: .continuous)
        content()
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .background(shape.fill(Color.white.opacity(pressed ? 0.38 : 0.12)))
            .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        input.setOverlayButton(bit, pressed: true)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        pressed = false
                        input.setOverlayButton(bit, pressed: false)
                    })
    }
}

/// L2 / R2: analog triggers driven fully on press.
struct TriggerPad: View {
    let title: String
    let left: Bool
    let input: InputManager
    let size: CGSize

    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(14, size.height / 3), style: .continuous)
        Text(title)
            .font(.system(size: size.height * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .background(shape.fill(Color.white.opacity(pressed ? 0.38 : 0.12)))
            .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 1))
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        input.setOverlayTrigger(left: left, value: 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        pressed = false
                        input.setOverlayTrigger(left: left, value: 0)
                    })
    }
}

/// Analog stick; a quick tap without movement clicks it (L3/R3).
struct VirtualStick: View {
    let left: Bool
    let clickBit: Int32
    let input: InputManager
    let radius: CGFloat

    @State private var offset: CGSize = .zero
    @State private var touchStart: Date? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
            Circle()
                .fill(Color.white.opacity(0.32))
                .frame(width: radius * 0.95, height: radius * 0.95)
                .offset(offset)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if touchStart == nil { touchStart = value.time }
                    var t = value.translation
                    let distance = (t.width * t.width + t.height * t.height).squareRoot()
                    if distance > radius {
                        t.width *= radius / distance
                        t.height *= radius / distance
                    }
                    offset = t
                    // Screen y grows downwards, like the console's stick axis.
                    input.setOverlayStick(left: left, x: Float(t.width / radius), y: Float(t.height / radius))
                }
                .onEnded { value in
                    let moved = (value.translation.width * value.translation.width
                                 + value.translation.height * value.translation.height).squareRoot()
                    let duration = touchStart.map { value.time.timeIntervalSince($0) } ?? 1
                    touchStart = nil
                    offset = .zero
                    input.setOverlayStick(left: left, x: 0, y: 0)
                    if moved < 8 && duration < 0.25 {
                        input.tap(clickBit)
                    }
                })
    }
}

/// Virtual touchpad: drag = finger on the pad, quick tap = touchpad click.
struct VirtualTouchpad: View {
    let input: InputManager

    @State private var touchStart: Date? = nil

    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            shape
                .fill(Color.white.opacity(0.07))
                .overlay(shape.stroke(Color.white.opacity(0.3), lineWidth: 1))
                .overlay(
                    Text("TOUCHPAD")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(Color.white.opacity(0.45)))
                .contentShape(shape)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if touchStart == nil { touchStart = value.time }
                            let x = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                            let y = min(1, max(0, value.location.y / max(1, geometry.size.height)))
                            input.setOverlayTouch(active: true, x: Float(x), y: Float(y))
                        }
                        .onEnded { value in
                            input.setOverlayTouch(active: false, x: 0, y: 0)
                            let moved = (value.translation.width * value.translation.width
                                         + value.translation.height * value.translation.height).squareRoot()
                            let duration = touchStart.map { value.time.timeIntervalSince($0) } ?? 1
                            touchStart = nil
                            if moved < 8 && duration < 0.25 {
                                input.tap(KZ_BTN_TOUCHPAD)
                            }
                        })
        }
    }
}

// Kizuna for iOS/iPadOS - rumble, DualSense haptics, adaptive triggers, light bar
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// The adaptive-trigger translation (TriggerEffects below) is adapted from Pylux
// ios/Pylux/Services/StreamTriggerFeedback.swift (AGPL-3.0, Copyright (C)
// ForWard Technologies LLC / Pylux contributors).
//
// Haptics: the console streams DualSense haptics as 3 kHz stereo PCM and/or
// classic rumble values. Apple exposes no raw voice-coil output, so both are
// reduced to one intensity per side and played through CoreHaptics engines
// created for the controller's left/right handles (continuous event whose
// intensity is updated every 10 ms through a dynamic parameter).

import CoreHaptics
import Foundation
import GameController

final class ControllerFeedback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ro.kizuna.haptics", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    private var left: HapticChannel?
    private var right: HapticChannel?
    private weak var controller: GCController?

    // Guarded by lock. All values 0...1.
    private var rumbleLeft: Float = 0
    private var rumbleRight: Float = 0
    private var rumbleTime: CFAbsoluteTime = 0
    private var hapticLeft: Float = 0
    private var hapticRight: Float = 0
    private var hapticTime: CFAbsoluteTime = 0

    var hapticsEnabled = true
    var triggersEnabled = true
    /// Console "vibration intensity" setting (KZ_EVENT_HAPTIC_INTENSITY).
    var hapticScale: Float = 1
    /// Console "trigger effect intensity" setting.
    var triggerScale: Float = 1

    // MARK: Lifecycle

    func attach(_ controller: GCController?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.left?.stop()
            self.right?.stop()
            self.left = nil
            self.right = nil
            self.controller = controller
            guard let controller, let haptics = controller.haptics else { return }
            let localities = haptics.supportedLocalities
            if localities.contains(.leftHandle) && localities.contains(.rightHandle) {
                self.left = HapticChannel(haptics: haptics, locality: .leftHandle)
                self.right = HapticChannel(haptics: haptics, locality: .rightHandle)
            } else {
                // Single-actuator pads: one engine fed with max(left, right).
                self.left = HapticChannel(haptics: haptics, locality: .default)
            }
            self.startTimer()
        }
    }

    func stop() {
        let current = controller
        queue.sync {
            timer?.cancel()
            timer = nil
            left?.stop()
            right?.stop()
            left = nil
            right = nil
        }
        DispatchQueue.main.async {
            TriggerEffects.reset(controller: current)
        }
    }

    // MARK: Inputs (chiaki threads)

    func rumble(left: UInt8, right: UInt8) {
        lock.lock()
        rumbleLeft = Float(left) / 255
        rumbleRight = Float(right) / 255
        rumbleTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// DualSense haptic PCM (stereo, 3 kHz). Envelope = mean |x|, boosted.
    func haptics(_ pcm: UnsafePointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        var sumLeft: Float = 0
        var sumRight: Float = 0
        for i in 0..<frames {
            sumLeft += abs(Float(pcm[2 * i]))
            sumRight += abs(Float(pcm[2 * i + 1]))
        }
        // Voice-coil waveforms are low in amplitude: x3 maps typical effects
        // into a comfortable range for the LRA/voice-coil engines.
        let l = min(1, sumLeft / Float(frames) / 32768 * 3)
        let r = min(1, sumRight / Float(frames) / 32768 * 3)
        lock.lock()
        hapticLeft = max(l, hapticLeft * 0.5)
        hapticRight = max(r, hapticRight * 0.5)
        hapticTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    func triggers(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8]) {
        guard triggersEnabled else { return }
        let scale = triggerScale
        DispatchQueue.main.async { [weak self] in
            TriggerEffects.apply(controller: self?.controller,
                                 typeLeft: typeLeft, left: left,
                                 typeRight: typeRight, right: right,
                                 intensityScale: scale)
        }
    }

    func setLight(rgb: Int32) {
        let red = Float((rgb >> 16) & 0xFF) / 255
        let green = Float((rgb >> 8) & 0xFF) / 255
        let blue = Float(rgb & 0xFF) / 255
        DispatchQueue.main.async { [weak self] in
            self?.controller?.light?.color = GCColor(red: red, green: green, blue: blue)
        }
    }

    // MARK: 10 ms update loop (haptics queue)

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = t
        t.resume()
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        // Rumble values persist until the console changes them (safety cut after 2 s);
        // haptic envelopes decay quickly when packets stop.
        var rl = now - rumbleTime < 2 ? rumbleLeft : 0
        var rr = now - rumbleTime < 2 ? rumbleRight : 0
        if now - hapticTime > 0.03 {
            hapticLeft *= 0.6
            hapticRight *= 0.6
            if hapticLeft < 0.01 { hapticLeft = 0 }
            if hapticRight < 0.01 { hapticRight = 0 }
        }
        rl = max(rl, hapticLeft)
        rr = max(rr, hapticRight)
        lock.unlock()

        let scale = hapticsEnabled ? hapticScale : 0
        if let right {
            left?.update(intensity: rl * scale)
            right.update(intensity: rr * scale)
        } else {
            left?.update(intensity: max(rl, rr) * scale)
        }
    }
}

/// One CoreHaptics engine on one controller locality, playing a looping
/// continuous event whose intensity follows `update(intensity:)`.
private final class HapticChannel {
    private let engine: CHHapticEngine
    private var player: CHHapticAdvancedPatternPlayer?
    private var playing = false
    private var current: Float = 0

    init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality) {
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        self.engine = engine
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        engine.resetHandler = { [weak self] in
            self?.player = nil
            self?.playing = false
            try? self?.engine.start()
        }
        engine.stoppedHandler = { [weak self] _ in
            self?.player = nil
            self?.playing = false
        }
        do {
            try engine.start()
        } catch {
            LogStore.shared.info("haptics engine failed: \(error.localizedDescription)")
            return nil
        }
    }

    func update(intensity: Float) {
        let value = max(0, min(1, intensity))
        if value < 0.02 {
            if playing {
                try? player?.stop(atTime: CHHapticTimeImmediate)
                playing = false
            }
            current = 0
            return
        }
        if abs(value - current) < 0.02 && playing { return }
        current = value
        do {
            if player == nil {
                player = try makePlayer()
            }
            guard let player else { return }
            if !playing {
                try player.start(atTime: CHHapticTimeImmediate)
                playing = true
            }
            let parameter = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)
            try player.sendParameters([parameter], atTime: CHHapticTimeImmediate)
        } catch {
            player = nil
            playing = false
            try? engine.start()
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        playing = false
        engine.stop(completionHandler: nil)
    }

    private func makePlayer() throws -> CHHapticAdvancedPatternPlayer {
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [
                                      CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                      CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
                                  ],
                                  relativeTime: 0,
                                  duration: 30)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.loopEnabled = true
        return player
    }
}

/// Translates the PS5's raw trigger-effect descriptors (mode byte + 10 params per
/// trigger, as carried in the DualSense HID output report) into Apple's semantic
/// GCDualSenseAdaptiveTrigger modes. Adapted from Pylux StreamTriggerFeedback.
enum TriggerEffects {
    private enum EffectType {
        static let off: UInt8 = 0x00
        static let simpleFeedback: UInt8 = 0x01
        static let simpleWeapon: UInt8 = 0x02
        static let off2: UInt8 = 0x05
        static let simpleVibration: UInt8 = 0x06
        static let feedback: UInt8 = 0x21
        static let bow: UInt8 = 0x22
        static let galloping: UInt8 = 0x23
        static let weapon: UInt8 = 0x25
        static let vibration: UInt8 = 0x26
        static let machine: UInt8 = 0x27
    }

    static func apply(controller: GCController?,
                      typeLeft: UInt8, left: [UInt8],
                      typeRight: UInt8, right: [UInt8],
                      intensityScale: Float) {
        guard let pad = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        applyOne(pad.leftTrigger, type: typeLeft, params: left, scale: intensityScale)
        applyOne(pad.rightTrigger, type: typeRight, params: right, scale: intensityScale)
    }

    /// Releases both triggers so a resistance effect cannot stay latched.
    static func reset(controller: GCController?) {
        guard let pad = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        pad.leftTrigger.setModeOff()
        pad.rightTrigger.setModeOff()
    }

    private static func norm(_ b: UInt8) -> Float { Float(b) / 255 }
    private static func byte(_ p: [UInt8], _ i: Int) -> UInt8 { i < p.count ? p[i] : 0 }

    /// Extended modes address 10 zones through a 10-bit mask in params[0..1].
    private static func zoneSpan(_ p: [UInt8]) -> (start: Float, end: Float)? {
        let mask = UInt16(byte(p, 0)) | (UInt16(byte(p, 1)) << 8)
        guard mask != 0 else { return nil }
        var first = -1
        var last = -1
        for i in 0..<10 where mask & (1 << UInt16(i)) != 0 {
            if first < 0 { first = i }
            last = i
        }
        return (Float(first) / 9, Float(last) / 9)
    }

    /// Strongest of the packed 3-bit per-zone magnitudes.
    private static func maxPackedMagnitude(_ p: [UInt8], from firstByte: Int) -> Float {
        var maxValue: UInt32 = 0
        var bits: UInt32 = 0
        var accumulator: UInt32 = 0
        var index = firstByte
        while index < min(p.count, firstByte + 4) {
            accumulator |= UInt32(p[index]) << bits
            bits += 8
            while bits >= 3 {
                maxValue = max(maxValue, accumulator & 0x7)
                accumulator >>= 3
                bits -= 3
            }
            index += 1
        }
        return maxValue == 0 ? 0 : Float(maxValue) / 7
    }

    private static func applyOne(_ trigger: GCDualSenseAdaptiveTrigger, type: UInt8, params: [UInt8], scale: Float) {
        func scaled(_ v: Float) -> Float { min(1, v * max(0, scale)) }
        switch type {
        case EffectType.simpleFeedback:
            let strength = scaled(norm(byte(params, 1)))
            guard strength > 0 else { trigger.setModeOff(); return }
            trigger.setModeFeedbackWithStartPosition(norm(byte(params, 0)), resistiveStrength: strength)
        case EffectType.simpleWeapon:
            let start = norm(byte(params, 0))
            var end = norm(byte(params, 1))
            if end <= start { end = min(1, start + 0.1) }
            let strength = scaled(norm(byte(params, 2)))
            guard strength > 0 else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case EffectType.simpleVibration:
            let amplitude = scaled(norm(byte(params, 1)))
            guard amplitude > 0 else { trigger.setModeOff(); return }
            trigger.setModeVibrationWithStartPosition(norm(byte(params, 0)),
                                                      amplitude: amplitude,
                                                      frequency: max(0.05, norm(byte(params, 2))))
        case EffectType.feedback:
            guard let span = zoneSpan(params) else { trigger.setModeOff(); return }
            let strength = scaled(maxPackedMagnitude(params, from: 2))
            guard strength > 0 else { trigger.setModeOff(); return }
            trigger.setModeFeedbackWithStartPosition(span.start, resistiveStrength: strength)
        case EffectType.weapon, EffectType.bow:
            guard let span = zoneSpan(params) else { trigger.setModeOff(); return }
            var end = span.end
            if end <= span.start { end = min(1, span.start + 0.1) }
            let strength = scaled(Float(byte(params, 2) & 0x7) / 7)
            guard strength > 0 else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(span.start, endPosition: end, resistiveStrength: strength)
        case EffectType.vibration, EffectType.galloping, EffectType.machine:
            guard let span = zoneSpan(params) else { trigger.setModeOff(); return }
            let amplitude = scaled(maxPackedMagnitude(params, from: 2))
            guard amplitude > 0 else { trigger.setModeOff(); return }
            let frequencyByte = byte(params, 8) != 0 ? byte(params, 8) : byte(params, 9)
            trigger.setModeVibrationWithStartPosition(span.start,
                                                      amplitude: amplitude,
                                                      frequency: max(0.08, norm(frequencyByte)))
        case EffectType.off, EffectType.off2:
            trigger.setModeOff()
        default:
            trigger.setModeOff()
        }
    }
}

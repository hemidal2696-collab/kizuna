// Kizuna for iOS/iPadOS - GameController -> chiaki controller state
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// Physical controllers (DualSense, DualShock 4, Xbox, MFi, Switch Pro...) are
// read through GCExtendedGamepad and merged with the on-screen touch controls.
// Mapping is positional: south = Cross, east = Circle, west = Square,
// north = Triangle (optionally swapped A/B for Nintendo-style layouts).
// Motion axes follow Pylux's empirically derived remap (AGPL-3.0):
// PS(x, y, z) = Apple(x, z, -y), with acceleration negated (Apple reports
// gravity, the DualSense reports the reaction force).

import Foundation
import GameController
import UIKit

final class InputManager: @unchecked Sendable {
    /// Receives every merged state (input queue). Set by StreamSession.
    var sink: ((KZControllerInput) -> Void)?
    /// Main queue: a controller was attached or detached.
    var onControllerChange: ((GCController?) -> Void)?

    let feedback = ControllerFeedback()
    var swapFaceButtons = false
    /// PS5 touchpad is 1920x1080, PS4 1920x942 (chiaki GUI constants).
    var touchpadMaxY: Float = 1079

    private let queue = DispatchQueue(label: "ro.kizuna.input", qos: .userInteractive)
    private let lock = NSLock()
    private var physical = KZControllerInput()
    private var overlay = KZControllerInput()
    private var observers: [NSObjectProtocol] = []
    private(set) weak var controller: GCController?
    private var running = false

    // MARK: Lifecycle (main thread)

    func start() {
        guard !running else { return }
        running = true
        GCController.shouldMonitorBackgroundEvents = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.bindBestController()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let gone = note.object as? GCController, gone === self.controller {
                self.unbind(gone)
            }
            self.bindBestController()
        })
        observers.append(center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            self?.bindBestController()
        })
        bindBestController()
    }

    func stop() {
        running = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let controller {
            unbind(controller)
        }
        feedback.stop()
        lock.lock()
        physical = KZControllerInput()
        overlay = KZControllerInput()
        lock.unlock()
    }

    var hasController: Bool { controller != nil }

    private func bindBestController() {
        let candidate = GCController.current ?? GCController.controllers().first(where: { $0.extendedGamepad != nil })
        guard let candidate, candidate.extendedGamepad != nil else {
            if controller == nil { onControllerChange?(nil) }
            return
        }
        if candidate === controller { return }
        if let old = controller {
            unbind(old)
        }
        bind(candidate)
    }

    private func bind(_ controller: GCController) {
        self.controller = controller
        controller.handlerQueue = queue
        controller.playerIndex = .index1

        // Keep Home/Options/Menu for the game instead of system gestures.
        for element in controller.physicalInputProfile.allElements where element.isBoundToSystemGesture {
            element.preferredSystemGestureState = .disabled
        }

        controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
            self?.readController()
        }
        if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad {
            dualSense.touchpadPrimary.valueChangedHandler = { [weak self] _, _, _ in self?.readController() }
            dualSense.touchpadSecondary.valueChangedHandler = { [weak self] _, _, _ in self?.readController() }
        } else if let dualShock = controller.extendedGamepad as? GCDualShockGamepad {
            dualShock.touchpadPrimary.valueChangedHandler = { [weak self] _, _, _ in self?.readController() }
            dualShock.touchpadSecondary.valueChangedHandler = { [weak self] _, _, _ in self?.readController() }
        }
        if let motion = controller.motion {
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = true
            }
            motion.valueChangedHandler = { [weak self] _ in
                self?.readController()
            }
        }
        feedback.attach(controller)
        LogStore.shared.info("controller: \(controller.vendorName ?? "?") (\(controller.productCategory))")
        onControllerChange?(controller)
        queue.async { [weak self] in self?.readController() }
    }

    private func unbind(_ controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = nil
        if let motion = controller.motion {
            motion.valueChangedHandler = nil
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = false
            }
        }
        TriggerEffects.reset(controller: controller)
        if self.controller === controller {
            self.controller = nil
            feedback.attach(nil)
            lock.lock()
            physical = KZControllerInput()
            lock.unlock()
            push()
            onControllerChange?(nil)
        }
    }

    // MARK: Physical controller (input queue)

    private func readController() {
        guard let controller, let pad = controller.extendedGamepad else { return }
        var s = KZControllerInput()
        var buttons: UInt32 = 0
        func press(_ pressed: Bool, _ bit: Int32) {
            if pressed { buttons |= UInt32(bit) }
        }

        let south = swapFaceButtons ? pad.buttonB : pad.buttonA
        let east = swapFaceButtons ? pad.buttonA : pad.buttonB
        let west = swapFaceButtons ? pad.buttonY : pad.buttonX
        let north = swapFaceButtons ? pad.buttonX : pad.buttonY
        press(south.isPressed, KZ_BTN_CROSS)
        press(east.isPressed, KZ_BTN_MOON)
        press(west.isPressed, KZ_BTN_BOX)
        press(north.isPressed, KZ_BTN_PYRAMID)
        press(pad.dpad.up.isPressed, KZ_BTN_DPAD_UP)
        press(pad.dpad.down.isPressed, KZ_BTN_DPAD_DOWN)
        press(pad.dpad.left.isPressed, KZ_BTN_DPAD_LEFT)
        press(pad.dpad.right.isPressed, KZ_BTN_DPAD_RIGHT)
        press(pad.leftShoulder.isPressed, KZ_BTN_L1)
        press(pad.rightShoulder.isPressed, KZ_BTN_R1)
        press(pad.leftThumbstickButton?.isPressed ?? false, KZ_BTN_L3)
        press(pad.rightThumbstickButton?.isPressed ?? false, KZ_BTN_R3)
        press(pad.buttonMenu.isPressed, KZ_BTN_OPTIONS)
        press(pad.buttonOptions?.isPressed ?? false, KZ_BTN_SHARE)
        press(pad.buttonHome?.isPressed ?? false, KZ_BTN_PS)

        s.l2 = Self.triggerByte(pad.leftTrigger.value)
        s.r2 = Self.triggerByte(pad.rightTrigger.value)
        s.left_x = Self.axis(pad.leftThumbstick.xAxis.value)
        s.left_y = Self.axis(-pad.leftThumbstick.yAxis.value)
        s.right_x = Self.axis(pad.rightThumbstick.xAxis.value)
        s.right_y = Self.axis(-pad.rightThumbstick.yAxis.value)

        // Touchpad (DualSense / DualShock 4): click + up to two fingers.
        var touchButton: GCControllerButtonInput?
        var fingers: [GCControllerDirectionPad] = []
        if let dualSense = pad as? GCDualSenseGamepad {
            touchButton = dualSense.touchpadButton
            fingers = [dualSense.touchpadPrimary, dualSense.touchpadSecondary]
        } else if let dualShock = pad as? GCDualShockGamepad {
            touchButton = dualShock.touchpadButton
            fingers = [dualShock.touchpadPrimary, dualShock.touchpadSecondary]
        }
        if let touchButton {
            press(touchButton.isPressed, KZ_BTN_TOUCHPAD)
        }
        var touchActive: [Bool] = [false, false]
        var touchX: [UInt16] = [0, 0]
        var touchY: [UInt16] = [0, 0]
        for (index, finger) in fingers.prefix(2).enumerated() {
            let x = finger.xAxis.value
            let y = finger.yAxis.value
            // GameController reports (0,0) when no finger rests on the pad.
            let present = x != 0 || y != 0 || (index == 0 && (touchButton?.isTouched ?? false))
            if present {
                touchActive[index] = true
                touchX[index] = UInt16(max(0, min(1919, ((x + 1) / 2) * 1919)))
                touchY[index] = UInt16(max(0, min(touchpadMaxY, ((1 - y) / 2) * touchpadMaxY)))
            }
        }
        s.touch_active = (touchActive[0], touchActive[1])
        s.touch_x = (touchX[0], touchX[1])
        s.touch_y = (touchY[0], touchY[1])

        if let motion = controller.motion, motion.sensorsActive || !motion.sensorsRequireManualActivation,
           motion.hasRotationRate {
            let rate = motion.rotationRate
            let ax: Double
            let ay: Double
            let az: Double
            if motion.hasGravityAndUserAcceleration {
                ax = -(motion.gravity.x + motion.userAcceleration.x)
                ay = -(motion.gravity.y + motion.userAcceleration.y)
                az = -(motion.gravity.z + motion.userAcceleration.z)
            } else {
                ax = -motion.acceleration.x
                ay = -motion.acceleration.y
                az = -motion.acceleration.z
            }
            s.motion_valid = true
            s.gyro_x = Float(rate.x)
            s.gyro_y = Float(rate.z)
            s.gyro_z = Float(-rate.y)
            s.accel_x = Float(ax)
            s.accel_y = Float(az)
            s.accel_z = Float(-ay)
        }

        s.buttons = buttons
        lock.lock()
        physical = s
        lock.unlock()
        push()
    }

    private static func axis(_ value: Float) -> Int16 {
        Int16(max(-32767, min(32767, (value * 32767).rounded())))
    }

    private static func triggerByte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    // MARK: On-screen controls (main thread)

    func setOverlayButton(_ bit: Int32, pressed: Bool) {
        lock.lock()
        if pressed {
            overlay.buttons |= UInt32(bit)
        } else {
            overlay.buttons &= ~UInt32(bit)
        }
        lock.unlock()
        queue.async { [weak self] in self?.push() }
    }

    /// x, y in -1...1 (y down positive, as the console expects).
    func setOverlayStick(left: Bool, x: Float, y: Float) {
        lock.lock()
        if left {
            overlay.left_x = Self.axis(x)
            overlay.left_y = Self.axis(y)
        } else {
            overlay.right_x = Self.axis(x)
            overlay.right_y = Self.axis(y)
        }
        lock.unlock()
        queue.async { [weak self] in self?.push() }
    }

    func setOverlayTrigger(left: Bool, value: Float) {
        lock.lock()
        if left {
            overlay.l2 = Self.triggerByte(value)
        } else {
            overlay.r2 = Self.triggerByte(value)
        }
        lock.unlock()
        queue.async { [weak self] in self?.push() }
    }

    /// Normalized 0...1 position on the virtual touchpad.
    func setOverlayTouch(active: Bool, x: Float, y: Float) {
        lock.lock()
        overlay.touch_active = (active, false)
        overlay.touch_x = (UInt16(max(0, min(1919, x * 1919))), 0)
        overlay.touch_y = (UInt16(max(0, min(touchpadMaxY, y * touchpadMaxY))), 0)
        lock.unlock()
        queue.async { [weak self] in self?.push() }
    }

    /// Short press of a button (quick menu: PS, touchpad click, Create...).
    func tap(_ bit: Int32, duration: TimeInterval = 0.12) {
        setOverlayButton(bit, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.setOverlayButton(bit, pressed: false)
        }
    }

    // MARK: Merge + send (input queue)

    private func push() {
        lock.lock()
        var merged = physical
        let o = overlay
        lock.unlock()

        merged.buttons |= o.buttons
        merged.l2 = max(merged.l2, o.l2)
        merged.r2 = max(merged.r2, o.r2)
        if o.left_x != 0 || o.left_y != 0 {
            merged.left_x = o.left_x
            merged.left_y = o.left_y
        }
        if o.right_x != 0 || o.right_y != 0 {
            merged.right_x = o.right_x
            merged.right_y = o.right_y
        }
        if !merged.touch_active.0 && !merged.touch_active.1 && o.touch_active.0 {
            merged.touch_active = o.touch_active
            merged.touch_x = o.touch_x
            merged.touch_y = o.touch_y
        }
        sink?(merged)
    }
}

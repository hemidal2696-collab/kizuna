// Kizuna for iOS/iPadOS - one Remote Play streaming session
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// SessionCore owns the opaque KZSession handle and receives every C callback
// (chiaki threads). Video goes straight to VideoDecoder (which enqueues on its
// own serial queue), audio into AudioOutput's ring, haptics/rumble/triggers to
// ControllerFeedback; events hop to the main actor for the UI.

import Foundation
import GameController
import UIKit

/// Thread-safe owner of the C session. Never touched by SwiftUI directly.
final class SessionCore: @unchecked Sendable {
    let video: VideoDecoder
    let audio: AudioOutput
    let feedback: ControllerFeedback
    /// Main-queue event sink (type, code, message).
    var onEvent: ((Int32, Int32, String?) -> Void)?

    private let lock = NSLock()
    private var handle: OpaquePointer?

    init(video: VideoDecoder, audio: AudioOutput, feedback: ControllerFeedback) {
        self.video = video
        self.audio = audio
        self.feedback = feedback
    }

    private func makeCallbacks() -> KZSessionCallbacks {
        var callbacks = KZSessionCallbacks()
        callbacks.video = { data, size, _, _, user in
            guard let data, let user else { return true }
            let core = Unmanaged<SessionCore>.fromOpaque(user).takeUnretainedValue()
            return core.video.submit(data, count: size)
        }
        callbacks.audio_settings = { channels, rate, user in
            guard let user else { return }
            let core = Unmanaged<SessionCore>.fromOpaque(user).takeUnretainedValue()
            core.audio.configure(channels: channels, sampleRate: rate)
        }
        callbacks.audio_frame = { pcm, frames, _, user in
            guard let pcm, let user else { return }
            let core = Unmanaged<SessionCore>.fromOpaque(user).takeUnretainedValue()
            core.audio.push(pcm, frames: frames)
        }
        callbacks.haptics = { pcm, frames, user in
            guard let pcm, let user else { return }
            let core = Unmanaged<SessionCore>.fromOpaque(user).takeUnretainedValue()
            core.feedback.haptics(pcm, frames: frames)
        }
        callbacks.rumble = { left, right, user in
            guard let user else { return }
            let core = Unmanaged<SessionCore>.fromOpaque(user).takeUnretainedValue()
            core.feedback.rumble(left: left, right: right)
        }
        callbacks.triggers = { typeLeft, left, typeRight, right, user in
            guard let user, let left, let right else { return }
            let core = Unmanaged<SessionCore>.fromOpaque(user).takeUnretainedValue()
            let count = Int(KZ_TRIGGER_EFFECT_SIZE)
            core.feedback.triggers(typeLeft: typeLeft,
                                   left: Array(UnsafeBufferPointer(start: left, count: count)),
                                   typeRight: typeRight,
                                   right: Array(UnsafeBufferPointer(start: right, count: count)))
        }
        callbacks.event = { type, code, message, user in
            guard let user else { return }
            let core = Unmanaged<SessionCore>.fromOpaque(user).takeUnretainedValue()
            let text = message.map { String(cString: $0) }
            DispatchQueue.main.async {
                core.onEvent?(type, code, text)
            }
        }
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        return callbacks
    }

    private static func videoConfig(_ settings: StreamSettings, ps5: Bool) -> KZVideoConfig {
        var config = KZVideoConfig()
        config.resolution = Int32(settings.resolution)
        config.fps = Int32(settings.fps)
        config.bitrate_kbps = Int32(settings.bitrateMbps * 1000)
        config.hevc = settings.hevc && ps5
        config.enable_dualsense = true
        config.packet_loss_max = 0.05
        return config
    }

    func createLAN(address: String, ps5: Bool, secrets: ConsoleSecrets, settings: StreamSettings) -> Int32 {
        var video = Self.videoConfig(settings, ps5: ps5)
        var callbacks = makeCallbacks()
        var err: Int32 = 0
        let registKey = [UInt8](secrets.registKey.prefix(Int(KZ_REGIST_KEY_SIZE)))
            + [UInt8](repeating: 0, count: max(0, Int(KZ_REGIST_KEY_SIZE) - secrets.registKey.count))
        let rpKey = [UInt8](secrets.rpKey.prefix(Int(KZ_RP_KEY_SIZE)))
            + [UInt8](repeating: 0, count: max(0, Int(KZ_RP_KEY_SIZE) - secrets.rpKey.count))
        let created = kz_session_create_lan(address, ps5, registKey, rpKey, &video, &callbacks, &err)
        lock.lock()
        handle = created
        lock.unlock()
        return created == nil ? (err == 0 ? KZ_ERR_UNKNOWN : err) : KZ_OK
    }

    func createPSN(credentials: PSNCredentials, consoleDUID: String, ps5: Bool, settings: StreamSettings) -> Int32 {
        var video = Self.videoConfig(settings, ps5: ps5)
        var callbacks = makeCallbacks()
        var err: Int32 = 0
        let created = kz_session_create_psn(credentials.accessToken, consoleDUID, ps5, credentials.accountID,
                                            &video, &callbacks, &err)
        lock.lock()
        handle = created
        lock.unlock()
        return created == nil ? (err == 0 ? KZ_ERR_UNKNOWN : err) : KZ_OK
    }

    func start() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return KZ_ERR_INVALID_DATA }
        return kz_session_start(handle)
    }

    func stop() {
        lock.lock()
        if let handle { kz_session_stop(handle) }
        lock.unlock()
    }

    /// Blocking (joins chiaki threads). Call from a background queue.
    func destroy() {
        lock.lock()
        let current = handle
        handle = nil
        lock.unlock()
        if let current {
            kz_session_destroy(current)
        }
    }

    func setInput(_ input: KZControllerInput) {
        var copy = input
        lock.lock()
        if let handle { _ = kz_session_set_input(handle, &copy) }
        lock.unlock()
    }

    func requestIDR() {
        lock.lock()
        if let handle { _ = kz_session_request_idr(handle) }
        lock.unlock()
    }

    func setLoginPIN(_ pin: String) {
        lock.lock()
        if let handle { _ = kz_session_set_login_pin(handle, pin) }
        lock.unlock()
    }

    func gotoBed() {
        lock.lock()
        if let handle { _ = kz_session_goto_bed(handle) }
        lock.unlock()
    }

    func stats() -> KZSessionStats {
        var stats = KZSessionStats()
        lock.lock()
        if let handle { kz_session_get_stats(handle, &stats) }
        lock.unlock()
        return stats
    }
}

@MainActor
final class StreamSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting(String)
        case streaming
        case ended(message: String, isError: Bool)
    }

    struct Stats {
        var bitrateMbps: Double = 0
        var fps: Double = 0
        var packetLoss: Double = 0
        var processingMs: Double = 0
        var rttMs: UInt32 = 0
        var framesLost: UInt64 = 0
        var audioBufferedMs: UInt32 = 0
        var audioUnderruns: UInt64 = 0
    }

    struct PinPrompt: Identifiable {
        let id = UUID()
        let incorrect: Bool
    }

    let id = UUID()
    let console: ConsoleRecord
    let viaPSN: Bool
    let settings: StreamSettings
    let video: VideoDecoder
    let audio: AudioOutput
    let input: InputManager

    @Published var phase: Phase
    @Published var stats = Stats()
    @Published var showStats: Bool
    @Published var controllerConnected = false
    @Published var touchControlsOverride: Bool? = nil
    @Published var pinPrompt: PinPrompt? = nil
    @Published var nickname: String? = nil

    /// Called once the session is torn down (AppModel clears activeStream).
    var onClosed: (() -> Void)?

    private let core: SessionCore
    private var statsTimer: Timer?
    private var lastEnqueued: UInt64 = 0
    private var lastStatsTime = CFAbsoluteTimeGetCurrent()
    private var started = false
    private var tornDown = false
    private var userStopped = false
    private var diagnosticsStart = CFAbsoluteTimeGetCurrent()

    init(console: ConsoleRecord, viaPSN: Bool, settings: StreamSettings) {
        self.console = console
        self.viaPSN = viaPSN
        self.settings = settings
        self.showStats = settings.showStats
        self.phase = .connecting(L("stream.connecting", console.displayName))
        let decoder = VideoDecoder(hevc: settings.hevc && console.isPS5)
        let audioOutput = AudioOutput()
        let inputManager = InputManager()
        self.video = decoder
        self.audio = audioOutput
        self.input = inputManager
        self.core = SessionCore(video: decoder, audio: audioOutput, feedback: inputManager.feedback)

        let core = self.core
        video.requestIDR = { [weak core] in core?.requestIDR() }
        input.sink = { [weak core] state in core?.setInput(state) }
        input.swapFaceButtons = settings.swapFaceButtons
        input.touchpadMaxY = console.isPS5 ? 1079 : 941
        input.feedback.hapticsEnabled = settings.hapticsEnabled
        input.feedback.triggersEnabled = settings.adaptiveTriggers
        core.onEvent = { [weak self] type, code, message in
            MainActor.assumeIsolated {
                self?.handleEvent(type: type, code: code, message: message)
            }
        }
        input.onControllerChange = { [weak self] controller in
            MainActor.assumeIsolated {
                self?.controllerConnected = controller != nil
            }
        }
    }

    var showsTouchControls: Bool {
        if let touchControlsOverride { return touchControlsOverride }
        switch settings.touchControls {
        case .always: return true
        case .never: return false
        case .auto: return !controllerConnected
        }
    }

    // MARK: Lifecycle

    func startLAN(address: String, secrets: ConsoleSecrets) {
        guard !started else { return }
        started = true
        let result = core.createLAN(address: address, ps5: console.isPS5, secrets: secrets, settings: settings)
        begin(result)
    }

    func startPSN(credentials: PSNCredentials) {
        guard !started else { return }
        started = true
        let result = core.createPSN(credentials: credentials, consoleDUID: console.duid,
                                    ps5: console.isPS5, settings: settings)
        begin(result)
    }

    private func begin(_ createResult: Int32) {
        guard createResult == KZ_OK else {
            phase = .ended(message: L("error.core", KizunaCoreBridge.errorString(createResult)), isError: true)
            return
        }
        input.start()
        controllerConnected = input.hasController
        UIApplication.shared.isIdleTimerDisabled = true
        let err = core.start()
        if err != KZ_OK {
            phase = .ended(message: KizunaCoreBridge.errorString(err), isError: true)
            return
        }
        diagnosticsStart = CFAbsoluteTimeGetCurrent()
        DiagnosticsLog.shared.begin(isPS5: console.isPS5, viaPSN: viaPSN, resolution: settings.resolution,
                                    fps: settings.fps, bitrateKbps: Int(settings.bitrateMbps * 1000),
                                    hevc: settings.hevc && console.isPS5)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStats()
            }
        }
    }

    /// User pressed Disconnect.
    func disconnect() {
        userStopped = true
        core.stop()
        close()
    }

    /// Tears everything down and calls onClosed when done.
    func close() {
        guard !tornDown else { return }
        tornDown = true
        statsTimer?.invalidate()
        statsTimer = nil
        if let summary = DiagnosticsLog.shared.end() {
            LogStore.shared.info(String(format: "session %.0f min, smoothness %d%%, %llu lost frames, %llu audio underruns",
                                        summary.minutes, summary.score, summary.framesLost, summary.audioUnderruns))
        }
        input.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        let core = self.core
        let audio = self.audio
        DispatchQueue.global(qos: .userInitiated).async {
            core.destroy()   // joins chiaki threads: no more callbacks after this
            audio.stop()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onClosed?()
                }
            }
        }
    }

    /// Back from background: the display layer lost its decoder.
    func recoverVideo() {
        video.recover()
    }

    // MARK: Actions (quick menu)

    func pressPS() { input.tap(KZ_BTN_PS) }
    func clickTouchpad() { input.tap(KZ_BTN_TOUCHPAD) }
    /// PS5 default: holding Create takes a screenshot.
    func screenshot() { input.tap(KZ_BTN_SHARE, duration: 1.2) }
    func sleepConsole() { core.gotoBed() }

    func submitPIN(_ pin: String) {
        pinPrompt = nil
        core.setLoginPIN(pin)
    }

    // MARK: Events

    private func handleEvent(type: Int32, code: Int32, message: String?) {
        switch type {
        case KZ_EVENT_CONNECTED:
            phase = .streaming
            LogStore.shared.info("stream connected (\(console.platformLabel), via PSN: \(viaPSN))")
        case KZ_EVENT_PROGRESS:
            if case .connecting = phase {
                phase = .connecting(Self.stageText(code, console: console.displayName))
            }
        case KZ_EVENT_QUIT:
            let isError = !userStopped && kz_quit_reason_is_error(code)
            let text = message ?? KizunaCoreBridge.errorString(code)
            LogStore.shared.info("stream quit (\(code)): \(text)")
            DiagnosticsLog.shared.quit(code: code, text: text)
            if case .ended = phase { return }
            phase = .ended(message: isError ? text : L("stream.ended"), isError: isError)
            input.feedback.stop()
        case KZ_EVENT_LOGIN_PIN_REQUEST:
            pinPrompt = PinPrompt(incorrect: code == 1)
        case KZ_EVENT_NICKNAME:
            nickname = message
        case KZ_EVENT_LED_COLOR:
            input.feedback.setLight(rgb: code)
        case KZ_EVENT_HAPTIC_INTENSITY:
            input.feedback.hapticScale = Self.intensityScale(code)
        case KZ_EVENT_TRIGGER_INTENSITY:
            input.feedback.triggerScale = Self.intensityScale(code)
        case KZ_EVENT_MOTION_RESET, KZ_EVENT_PLAYER_INDEX, KZ_EVENT_DATA_HOLEPUNCH:
            break
        default:
            break
        }
    }

    /// Console intensity setting: 0 off, 1 strong, 2 medium, 3 weak.
    private static func intensityScale(_ code: Int32) -> Float {
        switch code {
        case 0: return 0
        case 1: return 1
        case 2: return 0.7
        case 3: return 0.4
        default: return 1
        }
    }

    private static func stageText(_ stage: Int32, console: String) -> String {
        switch stage {
        case KZ_STAGE_PSN_SESSION: return L("stream.stage.session")
        case KZ_STAGE_PSN_CONSOLE: return L("stream.stage.console")
        case KZ_STAGE_PSN_PUNCH: return L("stream.stage.punch")
        case KZ_STAGE_STREAM: return L("stream.stage.stream")
        default: return L("stream.connecting", console)
        }
    }

    private func refreshStats() {
        let native = core.stats()
        let videoStats = video.snapshot()
        let audioStats = audio.stats()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = max(0.001, now - lastStatsTime)
        let frames = videoStats.framesEnqueued &- lastEnqueued
        lastEnqueued = videoStats.framesEnqueued
        lastStatsTime = now

        var s = Stats()
        s.bitrateMbps = native.measured_bitrate_mbps
        s.fps = Double(frames) / elapsed
        s.packetLoss = native.packet_loss
        s.processingMs = videoStats.averageProcessingMs
        s.rttMs = native.rtt_ms
        s.framesLost = native.frames_lost
        s.audioBufferedMs = audioStats.buffered_ms
        s.audioUnderruns = audioStats.underruns
        stats = s

        DiagnosticsLog.shared.sample(
            seconds: Int(now - diagnosticsStart), mbps: native.measured_bitrate_mbps, loss: native.packet_loss,
            fps: s.fps, processingMs: videoStats.averageProcessingMs, rttMs: native.rtt_ms,
            framesLost: native.frames_lost, framesRecovered: native.frames_recovered,
            videoDropped: videoStats.framesDropped, rendererFailures: videoStats.rendererFailures,
            audioBufferedMs: audioStats.buffered_ms, audioUnderruns: audioStats.underruns)
    }
}

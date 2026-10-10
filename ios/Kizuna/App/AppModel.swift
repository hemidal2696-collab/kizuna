// Kizuna for iOS/iPadOS - observable app state
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// Owns: paired consoles (UserDefaults metadata + Keychain secrets), PSN
// credentials (Keychain), stream settings, LAN discovery and the active
// stream. Everything here runs on the main actor; C callbacks reach it through
// the bridge classes, which hop to the main queue first.

import Foundation
import SwiftUI
import WebKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var consoles: [ConsoleRecord] = []
    @Published private(set) var discovered: [String: DiscoveredConsole] = [:]
    @Published private(set) var psn: PSNCredentials? = nil
    @Published var settings: StreamSettings {
        didSet { settings.save() }
    }
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.defaultsKey) }
    }
    @Published var activeStream: StreamSession? = nil
    @Published var toast: String? = nil
    @Published private(set) var isScanning = false

    private let discovery = DiscoveryService()
    private var sweepTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private static let consolesKey = "kizuna.consoles"

    init() {
        KizunaCoreBridge.bootstrap()
        settings = StreamSettings.load()
        language = AppLanguage.current
        if let data = UserDefaults.standard.data(forKey: Self.consolesKey),
           let saved = try? JSONDecoder().decode([ConsoleRecord].self, from: data) {
            consoles = saved
        }
        psn = Keychain.getCodable(PSNCredentials.self, for: PSNCredentials.keychainAccount)
        discovery.onHost = { [weak self] host in
            MainActor.assumeIsolated {
                self?.didDiscover(host)
            }
        }
        startDiscovery()
    }

    // MARK: Scene

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if let activeStream {
                activeStream.recoverVideo()
            } else {
                startDiscovery()
            }
        case .background:
            if activeStream == nil {
                stopDiscovery()
            }
        default:
            break
        }
    }

    // MARK: Toast

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Discovery

    func startDiscovery() {
        guard activeStream == nil else { return }
        guard discovery.start() else { return }
        isScanning = true
        sweep()
        sweepTimer?.invalidate()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sweep()
            }
        }
    }

    func stopDiscovery() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        discovery.stop()
        isScanning = false
    }

    func sweep() {
        discovery.sweep()
        for console in consoles where !console.address.isEmpty {
            discovery.probe(console.address)
        }
        // Forget consoles that stopped answering.
        let cutoff = Date().addingTimeInterval(-15)
        let stale = discovered.filter { $0.value.seenAt < cutoff }.map { $0.key }
        for key in stale {
            discovered.removeValue(forKey: key)
        }
    }

    func probe(address: String) {
        discovery.probe(address)
    }

    private func didDiscover(_ host: DiscoveredConsole) {
        discovered[host.id] = host
        // Keep paired consoles' addresses current (DHCP) by MAC address.
        var changed = false
        for index in consoles.indices {
            let record = consoles[index]
            let sameMAC = !record.hostID.isEmpty && record.hostID.caseInsensitiveCompare(host.hostID) == .orderedSame
            let sameName = record.hostID.isEmpty && !host.name.isEmpty
                && (record.name == host.name || record.nickname == host.name)
            guard sameMAC || sameName else { continue }
            if record.address != host.address {
                consoles[index].address = host.address
                changed = true
            }
            if record.hostID.isEmpty && !host.hostID.isEmpty {
                consoles[index].hostID = host.hostID.uppercased()
                changed = true
            }
        }
        if changed { saveConsoles() }
    }

    func discoveredEntry(for console: ConsoleRecord) -> DiscoveredConsole? {
        if !console.hostID.isEmpty, let entry = discovered[console.hostID.uppercased()] {
            return entry
        }
        guard !console.address.isEmpty else { return nil }
        return discovered.values.first(where: { $0.address == console.address })
    }

    func state(for console: ConsoleRecord) -> ConsoleState {
        if let entry = discoveredEntry(for: console) {
            return entry.state == .unknown ? .ready : entry.state
        }
        return isScanning ? .offline : .unknown
    }

    /// Consoles that answered on the LAN but are not paired here yet.
    var unpairedDiscovered: [DiscoveredConsole] {
        discovered.values
            .filter { host in !consoles.contains { discoveredEntry(for: $0)?.id == host.id } }
            .sorted { $0.name < $1.name }
    }

    // MARK: Consoles

    private func saveConsoles() {
        if let data = try? JSONEncoder().encode(consoles) {
            UserDefaults.standard.set(data, forKey: Self.consolesKey)
        }
    }

    func secrets(for console: ConsoleRecord) -> ConsoleSecrets? {
        Keychain.getCodable(ConsoleSecrets.self, for: console.keychainAccount)
    }

    func rename(_ console: ConsoleRecord, to name: String) {
        guard let index = consoles.firstIndex(where: { $0.id == console.id }) else { return }
        consoles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveConsoles()
    }

    func delete(_ console: ConsoleRecord) {
        Keychain.delete(console.keychainAccount)
        consoles.removeAll { $0.id == console.id }
        saveConsoles()
    }

    func isPaired(duid: String) -> Bool {
        consoles.contains { $0.duid.caseInsensitiveCompare(duid) == .orderedSame }
    }

    /// Stores a successful registration (PIN or PSN) and returns the record.
    @discardableResult
    func saveRegistration(_ info: RegisteredHostInfo, name: String, address: String,
                          isPS5: Bool, duid: String) -> ConsoleRecord {
        let hostID = info.hostID
        var record: ConsoleRecord
        if let existing = consoles.first(where: {
            (!hostID.isEmpty && $0.hostID.caseInsensitiveCompare(hostID) == .orderedSame)
                || (!duid.isEmpty && $0.duid.caseInsensitiveCompare(duid) == .orderedSame)
        }) {
            record = existing
        } else {
            record = ConsoleRecord(name: name, address: address, isPS5: isPS5, target: info.target)
        }
        if !name.isEmpty { record.name = name }
        record.nickname = info.nickname
        if record.name.isEmpty { record.name = info.nickname }
        if !hostID.isEmpty { record.hostID = hostID }
        if !duid.isEmpty { record.duid = duid.lowercased() }
        record.isPS5 = isPS5
        record.target = info.target
        if !address.isEmpty {
            record.address = address
        } else if let entry = discovered[hostID] {
            record.address = entry.address
        }

        Keychain.setCodable(ConsoleSecrets(registKey: info.registKey, rpKey: info.rpKey, rpKeyType: info.rpKeyType),
                            for: record.keychainAccount)
        if let index = consoles.firstIndex(where: { $0.id == record.id }) {
            consoles[index] = record
        } else {
            consoles.append(record)
        }
        saveConsoles()
        LogStore.shared.info("paired \(record.platformLabel) '\(record.displayName)' (address known: \(!record.address.isEmpty))")
        return record
    }

    func wake(_ console: ConsoleRecord) {
        guard let secrets = secrets(for: console) else {
            show(L("error.noRegistration"))
            return
        }
        let address = discoveredEntry(for: console)?.address ?? console.address
        guard !address.isEmpty else {
            show(L("error.noAddress"))
            return
        }
        let result = DiscoveryService.wake(address: address, registKey: secrets.registKey, ps5: console.isPS5)
        if result == KZ_OK {
            show(L("consoles.waking", console.displayName))
            discovery.probe(address)
        } else {
            show(KizunaCoreBridge.errorString(result))
        }
    }

    // MARK: PSN

    func psnSignedIn(_ credentials: PSNCredentials) {
        psn = credentials
        Keychain.setCodable(credentials, for: PSNCredentials.keychainAccount)
        show(L("add.psn.signedin", credentials.onlineID.isEmpty ? "PSN" : credentials.onlineID))
    }

    func signOutPSN() {
        psn = nil
        Keychain.delete(PSNCredentials.keychainAccount)
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let sony = records.filter { $0.displayName.contains("sony") || $0.displayName.contains("playstation") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: sony) {}
        }
    }

    /// Fresh credentials for holepunch / device listing (refreshes when needed).
    func validPSNCredentials() async throws -> PSNCredentials {
        guard let current = psn else { throw PSNError.signInRequired }
        do {
            let fresh = try await PSNAuth.refreshedIfNeeded(current)
            if fresh != current {
                psn = fresh
                Keychain.setCodable(fresh, for: PSNCredentials.keychainAccount)
            }
            return fresh
        } catch PSNError.signInRequired {
            signOutPSN()
            throw PSNError.signInRequired
        }
    }

    // MARK: Streaming

    func canConnectLocally(_ console: ConsoleRecord) -> Bool {
        let address = discoveredEntry(for: console)?.address ?? console.address
        return !address.isEmpty && secrets(for: console) != nil
    }

    func connect(_ console: ConsoleRecord, remote: Bool = false) {
        guard activeStream == nil else { return }
        let lanAddress = discoveredEntry(for: console)?.address ?? console.address
        let seenOnLAN = discoveredEntry(for: console) != nil
        let useRemote = remote || (!seenOnLAN && console.canStreamRemotely && psn != nil)

        if useRemote {
            guard psn != nil else {
                show(L("error.needPSN"))
                return
            }
            let session = StreamSession(console: console, viaPSN: true, settings: settings)
            present(session)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let credentials = try await self.validPSNCredentials()
                    session.startPSN(credentials: credentials)
                } catch {
                    session.phase = .ended(message: error.localizedDescription, isError: true)
                }
            }
            return
        }

        guard let secrets = secrets(for: console) else {
            show(L("error.noRegistration"))
            return
        }
        guard !lanAddress.isEmpty else {
            show(L("error.noAddress"))
            return
        }
        let session = StreamSession(console: console, viaPSN: false, settings: settings)
        present(session)
        session.startLAN(address: lanAddress, secrets: secrets)
    }

    private func present(_ session: StreamSession) {
        stopDiscovery()
        session.onClosed = { [weak self] in
            guard let self else { return }
            self.activeStream = nil
            OrientationController.lockLandscape(false)
            self.startDiscovery()
        }
        activeStream = session
        OrientationController.lockLandscape(true)
    }
}

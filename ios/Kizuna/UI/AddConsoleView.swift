// Kizuna for iOS/iPadOS - add / pair a console
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// 1. PSN (recommended): sign in, list the account's consoles, pair without PIN
//    (holepunch + RUDP registration, like the official app).
// 2. LAN: consoles that answered discovery, paired with the 8-digit PIN.
// 3. Manual: IP address + PIN (+ account id when not signed in).

import SwiftUI

struct AddConsoleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showSignIn = false
    @State private var psnConsoles: [PSNConsole] = []
    @State private var loadingConsoles = false
    @State private var psnError: String? = nil

    @State private var pairingKey: String? = nil
    @State private var progressText: String? = nil
    @State private var job: RegistrationJob? = nil
    @State private var alertMessage: String? = nil
    @State private var pairedSuccessfully = false

    @State private var pinTarget: DiscoveredConsole? = nil
    @State private var lanPIN = ""

    @State private var manualIP = ""
    @State private var manualPIN = ""
    @State private var manualPS5 = true
    @State private var manualAccount = ""

    var body: some View {
        NavigationStack {
            ZStack {
                NightBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        psnCard
                        lanCard
                        manualCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(L("add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) {
                        job?.cancel()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showSignIn) {
                PSNSignInSheet { credentials in
                    model.psnSignedIn(credentials)
                    Task { await loadConsoles() }
                }
            }
            .sheet(item: $pinTarget) { host in
                lanPINSheet(host)
                    .presentationDetents([.medium])
            }
            .alert(pairedSuccessfully ? L("app.name") : L("common.error"), isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } })) {
                Button(L("common.ok")) {
                    let close = pairedSuccessfully
                    alertMessage = nil
                    pairedSuccessfully = false
                    if close { dismiss() }
                }
            } message: {
                Text(alertMessage ?? "")
            }
            .task {
                if model.psn != nil {
                    await loadConsoles()
                }
            }
        }
    }

    // MARK: PSN

    private var psnCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            KZSectionHeader(title: L("add.psn.title"), systemImage: "person.crop.circle.badge.checkmark")
            if let psn = model.psn {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(KZColor.success)
                    Text(L("add.psn.signedin", psn.onlineID.isEmpty ? "PSN" : psn.onlineID))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        Task { await loadConsoles() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loadingConsoles)
                }
                Text(L("add.psn.consoles"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(KZColor.textSecondary)
                if loadingConsoles {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L("add.psn.loading"))
                            .foregroundStyle(KZColor.textSecondary)
                    }
                } else if let psnError {
                    Text(psnError)
                        .font(.footnote)
                        .foregroundStyle(KZColor.signal)
                } else if psnConsoles.isEmpty {
                    Text(L("add.psn.none"))
                        .font(.footnote)
                        .foregroundStyle(KZColor.textSecondary)
                } else {
                    ForEach(psnConsoles) { console in
                        psnRow(console)
                    }
                }
            } else {
                Text(L("add.psn.body"))
                    .font(.subheadline)
                    .foregroundStyle(KZColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showSignIn = true
                } label: {
                    KZButtonLabel(title: L("add.psn.signin"), systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .kzProminentButton()
                .controlSize(.large)
            }
        }
        .kzCard()
    }

    private func psnRow(_ console: PSNConsole) -> some View {
        let paired = model.isPaired(duid: console.duid)
        let busy = pairingKey == console.duid
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "playstation.logo")
                    .font(.title3)
                    .foregroundStyle(KZColor.focusGradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text(console.name)
                        .font(.headline)
                    Text(console.isPS5 ? "PS5" : "PS4")
                        .font(.caption)
                        .foregroundStyle(KZColor.textSecondary)
                }
                Spacer()
                if paired {
                    StatusPill(text: L("add.psn.paired"), color: KZColor.success)
                } else if busy {
                    ProgressView()
                } else {
                    Button {
                        pairPSN(console)
                    } label: {
                        KZButtonLabel(title: L("add.psn.pair"), systemImage: "link")
                    }
                    .kzProminentButton()
                    .disabled(pairingKey != nil)
                }
            }
            if busy, let progressText {
                Text(progressText)
                    .font(.footnote)
                    .foregroundStyle(KZColor.link)
            } else if !console.remotePlayEnabled && !paired {
                Text(L("add.psn.remoteplay.off"))
                    .font(.footnote)
                    .foregroundStyle(KZColor.standby)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func loadConsoles() async {
        loadingConsoles = true
        psnError = nil
        do {
            let credentials = try await model.validPSNCredentials()
            psnConsoles = try await PSNAuth.fetchConsoles(accessToken: credentials.accessToken)
        } catch {
            psnError = error.localizedDescription
        }
        loadingConsoles = false
    }

    private func pairPSN(_ console: PSNConsole) {
        guard pairingKey == nil else { return }
        pairingKey = console.duid
        progressText = L("add.progress.session")
        Task {
            do {
                let credentials = try await model.validPSNCredentials()
                job = RegistrationJob.startPSN(
                    accessToken: credentials.accessToken,
                    consoleDUID: console.duid,
                    ps5: console.isPS5,
                    accountID: credentials.accountID,
                    progress: { stage in
                        progressText = Self.stageDescription(stage)
                    },
                    completion: { outcome in
                        finishPSN(outcome, console: console)
                    })
            } catch {
                pairingKey = nil
                progressText = nil
                alertMessage = L("add.failed", error.localizedDescription)
            }
        }
    }

    private func finishPSN(_ outcome: RegistrationJob.Outcome, console: PSNConsole) {
        pairingKey = nil
        progressText = nil
        job = nil
        switch outcome {
        case .success(let info):
            // Prefer a LAN address: the holepunch-selected one if private, else
            // whatever discovery knows for this MAC / name.
            var address = info.consoleAddress.isPrivateIPv4 ? info.consoleAddress : ""
            if address.isEmpty {
                address = model.discovered[info.hostID]?.address
                    ?? model.discovered.values.first(where: { $0.name == console.name })?.address
                    ?? ""
            }
            let record = model.saveRegistration(info, name: console.name, address: address,
                                                isPS5: console.isPS5, duid: console.duid)
            showResult(L("add.success", record.displayName), success: true)
        case .failed(let message):
            showResult(L("add.failed", message), success: false)
        case .canceled:
            break
        }
    }

    /// Alerts cannot be shown while the PIN sheet is up: close it first.
    private func showResult(_ message: String, success: Bool) {
        if pinTarget != nil {
            pinTarget = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pairedSuccessfully = success
                alertMessage = message
            }
        } else {
            pairedSuccessfully = success
            alertMessage = message
        }
    }

    private static func stageDescription(_ stage: Int32) -> String {
        switch stage {
        case KZ_STAGE_PSN_SESSION: return L("add.progress.session")
        case KZ_STAGE_PSN_CONSOLE: return L("add.progress.console")
        case KZ_STAGE_PSN_PUNCH: return L("add.progress.punch")
        default: return L("add.progress.regist")
        }
    }

    // MARK: LAN

    private var lanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("add.lan.title"), systemImage: "wifi")
            let hosts = model.unpairedDiscovered
            if hosts.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if model.isScanning {
                        ProgressView()
                    }
                    Text(L("add.lan.empty"))
                        .font(.footnote)
                        .foregroundStyle(KZColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(hosts) { host in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.name.isEmpty ? (host.isPS5 ? "PS5" : "PS4") : host.name)
                                .font(.headline)
                            Text("\(host.isPS5 ? "PS5" : "PS4") · \(host.address)")
                                .font(.caption)
                                .foregroundStyle(KZColor.textSecondary)
                        }
                        Spacer()
                        Button {
                            lanPIN = ""
                            pinTarget = host
                        } label: {
                            KZButtonLabel(title: L("add.lan.pin"), systemImage: "number")
                        }
                        .kzGlassButton()
                        .disabled(pairingKey != nil)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
                }
            }
        }
        .kzCard()
    }

    private func lanPINSheet(_ host: DiscoveredConsole) -> some View {
        NavigationStack {
            ZStack {
                NightBackground()
                VStack(alignment: .leading, spacing: 16) {
                    Text(host.name.isEmpty ? host.address : host.name)
                        .font(.title3.weight(.semibold))
                    Text(L("add.manual.body"))
                        .font(.footnote)
                        .foregroundStyle(KZColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    KZTextField(title: L("add.manual.pin"), text: $lanPIN, keyboard: .numberPad)
                    if model.psn == nil {
                        KZTextField(title: L("add.manual.account"), text: $manualAccount)
                    }
                    if pairingKey != nil, let progressText {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(progressText).font(.footnote)
                        }
                    }
                    Button {
                        let target = host.target > 0 ? host.target : (host.isPS5 ? KZ_TARGET_PS5_1 : KZ_TARGET_PS4_10)
                        pairWithPIN(address: host.address, isPS5: host.isPS5, target: target,
                                    name: host.name, pin: lanPIN)
                    } label: {
                        KZButtonLabel(title: L("add.manual.register"), systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .kzProminentButton()
                    .controlSize(.large)
                    .disabled(pairingKey != nil)
                    Spacer()
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) {
                        job?.cancel()
                        pinTarget = nil
                    }
                }
            }
        }
    }

    // MARK: Manual

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            KZSectionHeader(title: L("add.manual.title"), systemImage: "keyboard")
            Text(L("add.manual.body"))
                .font(.footnote)
                .foregroundStyle(KZColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            KZTextField(title: L("add.manual.ip"), text: $manualIP, keyboard: .numbersAndPunctuation)
            Toggle(L("add.manual.ps5"), isOn: $manualPS5)
                .tint(KZColor.accent)
            KZTextField(title: L("add.manual.pin"), text: $manualPIN, keyboard: .numberPad)
            if model.psn == nil {
                KZTextField(title: L("add.manual.account"), text: $manualAccount)
                Text(L("add.manual.account.hint"))
                    .font(.caption)
                    .foregroundStyle(KZColor.textSecondary)
            }
            if pairingKey?.hasPrefix("pin:") == true && pinTarget == nil, let progressText {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progressText).font(.footnote)
                }
            }
            Button {
                let address = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
                let known = model.discovered.values.first(where: { $0.address == address })
                var target: Int32 = manualPS5 ? Int32(KZ_TARGET_PS5_1) : Int32(KZ_TARGET_PS4_10)
                if let known, known.target > 0 {
                    target = known.target
                }
                pairWithPIN(address: address, isPS5: known?.isPS5 ?? manualPS5, target: target,
                            name: known?.name ?? "", pin: manualPIN)
            } label: {
                KZButtonLabel(title: L("add.manual.register"), systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .kzGlassButton()
            .controlSize(.large)
            .disabled(pairingKey != nil)
        }
        .kzCard()
    }

    private func pairWithPIN(address: String, isPS5: Bool, target: Int32, name: String, pin rawPIN: String) {
        let pinText = rawPIN.filter { $0.isNumber }
        guard !address.isEmpty else {
            showResult(L("add.invalid.ip"), success: false)
            return
        }
        guard pinText.count == 8, let pin = UInt32(pinText) else {
            showResult(L("add.invalid.pin"), success: false)
            return
        }
        let account = model.psn?.accountID ?? manualAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: account), decoded.count == 8 else {
            showResult(L("add.invalid.account"), success: false)
            return
        }
        pairingKey = "pin:" + address
        progressText = L("add.progress.regist")
        model.probe(address: address)
        let psnMatch = psnConsoles.first(where: { !name.isEmpty && $0.name == name })
        job = RegistrationJob.startPIN(address: address, target: target, accountID: account, pin: pin) { outcome in
            pairingKey = nil
            progressText = nil
            job = nil
            switch outcome {
            case .success(let info):
                let record = model.saveRegistration(info, name: name, address: address, isPS5: isPS5,
                                                    duid: psnMatch?.duid ?? "")
                showResult(L("add.success", record.displayName), success: true)
            case .failed(let message):
                showResult(L("add.failed", message), success: false)
            case .canceled:
                break
            }
        }
    }
}

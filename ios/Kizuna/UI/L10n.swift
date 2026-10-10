// Kizuna for iOS/iPadOS - tiny localization table (English default, Romanian)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case en
    case ro

    var id: String { rawValue }
    var displayName: String { self == .ro ? "Română" : "English" }

    static let defaultsKey = "kizuna.language"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "en") ?? .en
    }
}

/// Looks up a UI string in the current language. Unknown keys fall back to the key.
func L(_ key: String) -> String {
    guard let entry = L10n.table[key] else { return key }
    return AppLanguage.current == .ro ? entry.ro : entry.en
}

/// Formatted variant (`%@`, `%d`, `%.1f` ...).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

enum L10n {
    struct Entry {
        let ro: String
        let en: String
    }

    private static func e(_ ro: String, _ en: String) -> Entry { Entry(ro: ro, en: en) }

    static let table: [String: Entry] = [
        // General
        "app.name": e("Kizuna", "Kizuna"),
        "app.tagline": e("Remote Play pentru PS5 și PS4", "Remote Play for PS5 and PS4"),
        "common.cancel": e("Anulează", "Cancel"),
        "common.close": e("Închide", "Close"),
        "common.done": e("Gata", "Done"),
        "common.ok": e("OK", "OK"),
        "common.delete": e("Șterge", "Delete"),
        "common.retry": e("Reîncearcă", "Retry"),
        "common.save": e("Salvează", "Save"),
        "common.error": e("Eroare", "Error"),
        "common.continue": e("Continuă", "Continue"),
        "common.paste": e("Lipește", "Paste"),

        // Consoles
        "consoles.title": e("Consolele mele", "My consoles"),
        "consoles.empty.title": e("Nicio consolă încă", "No consoles yet"),
        "consoles.empty.body": e("Conectează-te cu contul PlayStation și Kizuna asociază consola automat, fără PIN.",
                                 "Sign in with your PlayStation account and Kizuna pairs your console automatically, without a PIN."),
        "consoles.add": e("Adaugă consolă", "Add console"),
        "consoles.scanning": e("Caut în rețea…", "Searching the network…"),
        "consoles.connect": e("Conectare", "Connect"),
        "consoles.connect.remote": e("Conectare prin internet", "Connect over the internet"),
        "consoles.wake": e("Trezește", "Wake"),
        "consoles.waking": e("Am trimis semnalul de trezire către %@", "Wake signal sent to %@"),
        "consoles.rename": e("Redenumește", "Rename"),
        "consoles.delete.confirm": e("Ștergi consola „%@”? Va trebui asociată din nou.", "Delete “%@”? You will have to pair it again."),
        "consoles.unregistered": e("Neasociată", "Not paired"),
        "consoles.found.title": e("Găsite în rețea", "Found on your network"),
        "consoles.no.address": e("Adresă necunoscută — pornește consola în aceeași rețea", "Unknown address — turn the console on in the same network"),
        "consoles.remote.only": e("Doar prin internet", "Internet only"),

        // States
        "state.ready": e("Pornită", "Ready"),
        "state.standby": e("Repaus", "Rest mode"),
        "state.offline": e("Indisponibilă", "Offline"),
        "state.unknown": e("Necunoscut", "Unknown"),

        // Add console
        "add.title": e("Adaugă o consolă", "Add a console"),
        "add.psn.title": e("Cont PlayStation (recomandat)", "PlayStation account (recommended)"),
        "add.psn.body": e("Te conectezi o singură dată; Kizuna află ID-ul contului și asociază consola fără PIN, ca aplicația oficială.",
                          "Sign in once; Kizuna learns your account ID and pairs the console without a PIN, like the official app."),
        "add.psn.signin": e("Conectează-te la PlayStation Network", "Sign in to PlayStation Network"),
        "add.psn.signedin": e("Conectat ca %@", "Signed in as %@"),
        "add.psn.consoles": e("Consolele contului tău", "Your account's consoles"),
        "add.psn.loading": e("Încarc lista de console…", "Loading your consoles…"),
        "add.psn.none": e("Nicio consolă cu Remote Play activat în cont.", "No console with Remote Play enabled on this account."),
        "add.psn.pair": e("Asociază automat", "Pair automatically"),
        "add.psn.paired": e("Asociată", "Paired"),
        "add.psn.remoteplay.off": e("Remote Play dezactivat pe consolă", "Remote Play is off on the console"),
        "add.lan.title": e("Găsite în rețeaua locală", "Found on your local network"),
        "add.lan.empty": e("Nicio consolă găsită încă. Verifică permisiunea „Rețea locală” și că telefonul e pe același Wi-Fi.",
                           "No console found yet. Check the Local Network permission and that you are on the same Wi-Fi."),
        "add.lan.pin": e("Asociază cu PIN", "Pair with PIN"),
        "add.manual.title": e("Manual (adresă IP + PIN)", "Manual (IP address + PIN)"),
        "add.manual.body": e("Pe consolă: Setări › Sistem › Redare la distanță › Asociază dispozitivul. Introdu codul de 8 cifre.",
                             "On the console: Settings › System › Remote Play › Pair Device. Enter the 8-digit code."),
        "add.manual.ip": e("Adresa IP a consolei", "Console IP address"),
        "add.manual.pin": e("PIN (8 cifre)", "PIN (8 digits)"),
        "add.manual.ps5": e("Este un PS5", "This is a PS5"),
        "add.manual.account": e("ID cont PSN (base64)", "PSN account ID (base64)"),
        "add.manual.account.hint": e("Completat automat după conectarea la PSN.", "Filled in automatically after signing in to PSN."),
        "add.manual.register": e("Asociază", "Pair"),
        "add.progress.session": e("Pregătesc sesiunea PSN…", "Preparing the PSN session…"),
        "add.progress.console": e("Contactez consola prin PSN…", "Contacting the console through PSN…"),
        "add.progress.punch": e("Stabilesc conexiunea directă…", "Establishing a direct connection…"),
        "add.progress.regist": e("Asociez consola…", "Pairing the console…"),
        "add.success": e("„%@” a fost asociată.", "“%@” is paired."),
        "add.failed": e("Asocierea a eșuat: %@", "Pairing failed: %@"),
        "add.invalid.pin": e("PIN-ul trebuie să aibă 8 cifre.", "The PIN must have 8 digits."),
        "add.invalid.ip": e("Introdu adresa IP a consolei.", "Enter the console's IP address."),
        "add.invalid.account": e("ID-ul contului PSN lipsește sau e invalid. Conectează-te la PSN sau introdu-l manual.",
                                 "The PSN account ID is missing or invalid. Sign in to PSN or enter it manually."),

        // PSN sign-in
        "psn.signin.title": e("Conectare PSN", "PSN sign-in"),
        "psn.signin.working": e("Finalizez conectarea…", "Finishing sign-in…"),
        "psn.signin.manual": e("Nu merge? Lipește manual", "Not working? Paste manually"),
        "psn.signin.manual.body": e("Lipește adresa paginii de redirecționare (conține „?code=”) sau codul NPSSO de la ca.account.sony.com/api/v1/ssocookie.",
                                    "Paste the redirect page address (it contains “?code=”) or the NPSSO code from ca.account.sony.com/api/v1/ssocookie."),
        "psn.signin.manual.field": e("URL de redirecționare sau NPSSO", "Redirect URL or NPSSO"),
        "psn.signin.manual.use": e("Folosește", "Use"),
        "psn.signout": e("Deconectare PSN", "Sign out of PSN"),
        "psn.expired": e("Sesiunea PSN a expirat. Conectează-te din nou.", "Your PSN session expired. Please sign in again."),
        "psn.error.invalidInput": e("Nu recunosc nici un cod, nici un NPSSO în textul lipit.", "Neither a code nor an NPSSO was found in the pasted text."),

        // Stream settings
        "settings.stream.title": e("Calitate stream", "Stream quality"),
        "settings.preset": e("Profil", "Preset"),
        "preset.lowLatency": e("Latență minimă", "Lowest latency"),
        "preset.balanced": e("Echilibrat", "Balanced"),
        "preset.maxQuality": e("Calitate maximă", "Best quality"),
        "preset.custom": e("Personalizat", "Custom"),
        "settings.resolution": e("Rezoluție", "Resolution"),
        "settings.fps": e("Cadre pe secundă", "Frame rate"),
        "settings.codec": e("Codec", "Codec"),
        "settings.codec.note": e("HEVC e mai eficient (doar PS5). PS4 folosește mereu H.264.", "HEVC is more efficient (PS5 only). PS4 always uses H.264."),
        "settings.bitrate": e("Debit: %ld Mbps", "Bitrate: %ld Mbps"),
        "settings.controls": e("Control", "Controls"),
        "settings.haptics": e("Vibrații și haptică", "Rumble and haptics"),
        "settings.triggers": e("Triggere adaptive (DualSense)", "Adaptive triggers (DualSense)"),
        "settings.touch": e("Comenzi pe ecran", "On-screen controls"),
        "touch.auto": e("Automat", "Automatic"),
        "touch.always": e("Mereu", "Always"),
        "touch.never": e("Niciodată", "Never"),
        "settings.stats": e("Afișează statistici", "Show statistics"),
        "settings.swap": e("Inversează A/B (stil Nintendo)", "Swap A/B (Nintendo layout)"),

        // Settings / about
        "settings.title": e("Setări", "Settings"),
        "diag.title": e("Jurnal de diagnostic", "Diagnostics log"),
        "diag.enabled": e("Înregistrează datele stream-ului", "Record stream data"),
        "diag.privacy": e("Doar date tehnice (bitrate, pierderi, cadre, timp de decodare, audio). Fără cont PSN, token-uri, nume de console sau adrese IP. Rămâne pe dispozitiv până îl exporți.", "Technical data only (bitrate, losses, frames, decode time, audio). No PSN account, tokens, console names or IP addresses. Stays on this device until you export it."),
        "diag.count": e("Sesiuni salvate: %ld", "Saved sessions: %ld"),
        "diag.export": e("Exportă", "Export"),
        "diag.clear": e("Șterge", "Delete"),
        "settings.account": e("Cont", "Account"),
        "settings.language": e("Limbă", "Language"),
        "settings.about": e("Despre", "About"),
        "settings.log": e("Jurnal tehnic", "Technical log"),
        "settings.log.copy": e("Copiază jurnalul", "Copy log"),
        "about.version": e("Versiune %@", "Version %@"),
        "about.license.title": e("Licență AGPL-3.0", "AGPL-3.0 license"),
        "about.license.body": e("Kizuna este software liber sub GNU Affero General Public License v3.0. Folosește biblioteca chiaki-ng și cod adaptat din Akira, TP Play și Pylux (toate AGPL-3.0). Ai dreptul să primești codul sursă complet al acestei versiuni.",
                                "Kizuna is free software under the GNU Affero General Public License v3.0. It uses the chiaki-ng library and code adapted from Akira, TP Play and Pylux (all AGPL-3.0). You are entitled to the complete source code of this version."),
        "about.source": e("Cod sursă", "Source code"),
        "about.disclaimer": e("PlayStation, PS5, PS4 și DualSense sunt mărci Sony Interactive Entertainment. Kizuna nu este afiliat cu Sony.",
                              "PlayStation, PS5, PS4 and DualSense are trademarks of Sony Interactive Entertainment. Kizuna is not affiliated with Sony."),

        // Stream
        "stream.connecting": e("Conectare la %@…", "Connecting to %@…"),
        "stream.stage.session": e("Pregătesc sesiunea PSN…", "Preparing the PSN session…"),
        "stream.stage.console": e("Trezesc consola prin PSN…", "Reaching the console through PSN…"),
        "stream.stage.punch": e("Traversez NAT-ul…", "Traversing NAT…"),
        "stream.stage.stream": e("Pornesc streamul…", "Starting the stream…"),
        "stream.ended": e("Sesiune încheiată", "Session ended"),
        "stream.failed": e("Conexiunea a eșuat", "Connection failed"),
        "stream.menu": e("Meniu rapid", "Quick menu"),
        "stream.menu.ps": e("Buton PS", "PS button"),
        "stream.menu.touchpad": e("Touchpad", "Touchpad"),
        "stream.menu.screenshot": e("Captură", "Screenshot"),
        "stream.menu.stats": e("Statistici", "Statistics"),
        "stream.menu.controls": e("Comenzi pe ecran", "On-screen controls"),
        "stream.menu.sleep": e("Pune consola în repaus", "Put console to sleep"),
        "stream.menu.disconnect": e("Deconectare", "Disconnect"),
        "stream.menu.hint": e("Captura ține apăsat butonul Create (setarea implicită a consolei).", "Screenshot holds the Create button (console default shortcut)."),
        "stream.pin.title": e("PIN de conectare", "Login PIN"),
        "stream.pin.body": e("Consola cere PIN-ul de conectare al profilului.", "The console asks for the profile's login passcode."),
        "stream.pin.wrong": e("PIN greșit, încearcă din nou.", "Wrong PIN, try again."),
        "stats.bitrate": e("Debit", "Bitrate"),
        "stats.fps": e("FPS", "FPS"),
        "stats.loss": e("Pierderi", "Loss"),
        "stats.decode": e("Procesare", "Processing"),
        "stats.latency": e("RTT", "RTT"),
        "stats.audio": e("Audio", "Audio"),
        "stats.lost": e("Cadre pierdute", "Frames lost"),

        // Errors
        "error.noRegistration": e("Consola nu e asociată pe acest dispozitiv.", "This console is not paired on this device."),
        "error.noAddress": e("Nu cunosc adresa consolei în rețeaua locală.", "The console's local address is unknown."),
        "error.needPSN": e("Pentru conectarea prin internet trebuie să fii conectat la PSN.", "Connecting over the internet requires a PSN sign-in."),
        "error.core": e("Biblioteca de streaming nu a pornit (%@).", "The streaming library failed to start (%@)."),
    ]
}

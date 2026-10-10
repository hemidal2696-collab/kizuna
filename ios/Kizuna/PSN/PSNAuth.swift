// Kizuna for iOS/iPadOS - PlayStation Network OAuth (Remote Play client)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// Constants and flows ported from Kizuna's Switch build (Akira fork, AGPL-3.0):
//   source/psn/auth_bootstrap.cpp  buildAuthorizeUrl / buildCodeExchangeBody
//   source/psn/auth.cpp            refresh (2.0 endpoint, Basic auth), NPSSO bootstrap
//   source/kizuna/psn_signin.cpp   identity lookup + account id derivation
// The sign-in sheet (PSNSignInView.swift) intercepts the redirect in a
// WKWebView, like Pylux's LoginWebView.swift (AGPL-3.0).

import Foundation

enum PSNConfig {
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let scopes = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    static let authorizeURL = "https://ca.account.sony.com/api/authz/v3/oauth/authorize"
    static let tokenURL = "https://ca.account.sony.com/api/authz/v3/oauth/token"
    static let refreshURL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
    static let tokenInfoURL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token/"
    static let devicesURL = "https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/clients"
    static let ssoCookieURL = "https://ca.account.sony.com/api/v1/ssocookie"
    static let mobileSafariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
}

struct PSNCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// base64 of the 64-bit user id, little endian (what Remote Play registration wants).
    var accountID: String
    var onlineID: String
    var userID: String
    /// NPSSO session cookie (~2 months) used to re-bootstrap tokens silently.
    var npsso: String?
    /// Client DUID the tokens were authorized for (holepunch requires the match).
    var duid: String

    static let keychainAccount = "psn.credentials"

    var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 5 * 60 }
}

struct PSNConsole: Identifiable, Hashable {
    let duid: String
    let name: String
    let isPS5: Bool
    let remotePlayEnabled: Bool

    var id: String { duid }
}

enum PSNError: LocalizedError {
    case http(Int, String)
    case invalidResponse(String)
    case noAuthorizationCode
    case signInRequired
    case invalidInput

    var errorDescription: String? {
        switch self {
        case let .http(status, message):
            return message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case let .invalidResponse(what):
            return "PSN: \(what)"
        case .noAuthorizationCode:
            return "PSN did not return an authorization code (expired NPSSO?)"
        case .signInRequired:
            return L("psn.expired")
        case .invalidInput:
            return L("psn.error.invalidInput")
        }
    }
}

/// Stops URLSession from following the authorize redirect so the code can be
/// read from the Location header (NPSSO bootstrap).
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Collects devices from the C callback (passed as an unretained user pointer).
private final class PSNDeviceBox {
    var items: [PSNConsole] = []
}

enum PSNAuth {
    private static let session = URLSession(configuration: .ephemeral)
    private static let noRedirectSession = URLSession(configuration: .ephemeral,
                                                      delegate: NoRedirectDelegate(),
                                                      delegateQueue: nil)
    private static let duidDefaultsKey = "kizuna.psn.duid"

    /// Persistent client DUID: "0000000700410080" + 32 hex.
    static var clientDUID: String {
        if let existing = UserDefaults.standard.string(forKey: duidDefaultsKey), existing.count == 48 {
            return existing
        }
        let created = KizunaCoreBridge.generateClientDUID()
        UserDefaults.standard.set(created, forKey: duidDefaultsKey)
        return created
    }

    // MARK: URL building (exactly as auth_bootstrap.cpp)

    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    static func authorizeURL(duid: String) -> URL {
        let pairs: [(String, String)] = [
            ("client_id", PSNConfig.clientID),
            ("redirect_uri", PSNConfig.redirectURI),
            ("scope", PSNConfig.scopes),
            ("response_type", "code"),
            ("service_entity", "urn:service-entity:psn"),
            ("access_type", "offline"),
            ("duid", duid),
            ("smcid", "remoteplay"),
            ("layout_type", "popup"),
            ("PlatformPrivacyWs1", "minimal"),
            ("no_captcha", "true"),
            ("cid", UUID().uuidString.lowercased()),
        ]
        // The string is built from constants and percent-encoded values: always valid.
        return URL(string: PSNConfig.authorizeURL + "?" + query(pairs))!
    }

    static func isRedirect(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix(PSNConfig.redirectURI)
    }

    /// Finds `code=` in a redirect URL (or any pasted text containing one).
    static func extractCode(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return code
        }
        guard let range = trimmed.range(of: "code=") else { return nil }
        let tail = trimmed[range.upperBound...]
        let code = tail.prefix { $0 != "&" && $0 != "#" && !$0.isWhitespace }
        return code.isEmpty ? nil : String(code).removingPercentEncoding ?? String(code)
    }

    /// Accepts a bare NPSSO or the JSON from /api/v1/ssocookie ({"npsso":"..."}).
    static func normalizeNPSSO(_ raw: String) -> String? {
        var text = raw
        if let key = text.range(of: "npsso") {
            let after = text[key.upperBound...]
            if let colon = after.firstIndex(of: ":") {
                text = String(after[after.index(after: colon)...])
            }
        }
        var token = ""
        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                token.append(ch)
            } else if !token.isEmpty {
                break
            }
        }
        return token.count == 64 ? token : nil
    }

    // MARK: Flows

    /// Code from the WKWebView redirect -> tokens -> identity.
    static func signIn(code: String, npsso: String?) async throws -> PSNCredentials {
        let duid = clientDUID
        let tokens = try await exchange(code: code)
        return try await makeCredentials(tokens: tokens, npsso: npsso, duid: duid)
    }

    /// NPSSO -> authorize (no redirect follow) -> code -> tokens -> identity.
    static func signIn(npsso: String) async throws -> PSNCredentials {
        let duid = clientDUID
        let code = try await requestCode(npsso: npsso, duid: duid)
        let tokens = try await exchange(code: code)
        return try await makeCredentials(tokens: tokens, npsso: npsso, duid: duid)
    }

    /// Returns credentials with a fresh access token (refresh token first,
    /// NPSSO bootstrap second, like Akira's Auth::refreshBlocking).
    static func refreshedIfNeeded(_ credentials: PSNCredentials, force: Bool = false) async throws -> PSNCredentials {
        if !force && !credentials.needsRefresh { return credentials }
        do {
            let tokens = try await refresh(refreshToken: credentials.refreshToken)
            var updated = credentials
            updated.accessToken = tokens.access
            updated.refreshToken = tokens.refresh.isEmpty ? credentials.refreshToken : tokens.refresh
            updated.expiresAt = Date().addingTimeInterval(TimeInterval(max(60, tokens.expiresIn)))
            return updated
        } catch {
            LogStore.shared.info("PSN refresh failed: \(error.localizedDescription)")
            if let npsso = credentials.npsso, !npsso.isEmpty {
                let duid = credentials.duid.isEmpty ? clientDUID : credentials.duid
                let code = try await requestCode(npsso: npsso, duid: duid)
                let tokens = try await exchange(code: code)
                var updated = credentials
                updated.accessToken = tokens.access
                updated.refreshToken = tokens.refresh
                updated.expiresAt = Date().addingTimeInterval(TimeInterval(max(60, tokens.expiresIn)))
                updated.duid = duid
                return updated
            }
            if let psnError = error as? PSNError, case let .http(status, _) = psnError,
               status == 400 || status == 401 {
                throw PSNError.signInRequired
            }
            throw error
        }
    }

    /// Consoles linked to the account (PS5 and PS4) with their DUIDs.
    static func fetchConsoles(accessToken: String) async throws -> [PSNConsole] {
        var result: [PSNConsole] = []
        var firstError: Error?
        for platform in ["PS5", "PS4"] {
            var components = URLComponents(string: PSNConfig.devicesURL)!
            components.queryItems = [
                URLQueryItem(name: "platform", value: platform),
                URLQueryItem(name: "includeFields", value: "device"),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "offset", value: "0"),
            ]
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let json = try await sendJSON(request)
                let clients = json["clients"] as? [[String: Any]] ?? []
                for client in clients {
                    guard let duid = client["duid"] as? String, duid.count == 64 else { continue }
                    let device = client["device"] as? [String: Any] ?? [:]
                    let name = device["name"] as? String ?? platform
                    let features = device["enabledFeatures"] as? [String] ?? []
                    result.append(PSNConsole(duid: duid.lowercased(), name: name,
                                             isPS5: platform == "PS5",
                                             remotePlayEnabled: features.contains("remotePlay")))
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if result.isEmpty {
            // Same endpoint through chiaki's own curl path (Akira's resolveRemoteDuid).
            let viaCore = await fetchConsolesViaCore(accessToken: accessToken)
            if !viaCore.isEmpty {
                return viaCore
            }
            if let firstError {
                throw firstError
            }
        }
        return result
    }

    /// chiaki_holepunch_list_devices() for PS5 and PS4 (blocking C call, run off the main thread).
    static func fetchConsolesViaCore(accessToken: String) async -> [PSNConsole] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[PSNConsole], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let box = PSNDeviceBox()
                let user = Unmanaged.passUnretained(box).toOpaque()
                for ps5 in [true, false] {
                    _ = kz_psn_list_devices(accessToken, ps5, { device, user in
                        guard let device, let user else { return }
                        let box = Unmanaged<PSNDeviceBox>.fromOpaque(user).takeUnretainedValue()
                        let d = device.pointee
                        box.items.append(PSNConsole(duid: String(cString: d.duid_hex),
                                                    name: String(cString: d.name),
                                                    isPS5: d.is_ps5,
                                                    remotePlayEnabled: d.remoteplay_enabled))
                    }, user)
                }
                withExtendedLifetime(box) {
                    continuation.resume(returning: box.items)
                }
            }
        }
    }

    // MARK: HTTP steps

    struct Tokens {
        let access: String
        let refresh: String
        let expiresIn: Int
    }

    private static func formRequest(_ urlString: String, body: [(String, String)], basicAuth: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if basicAuth {
            let credentials = Data("\(PSNConfig.clientID):\(PSNConfig.clientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data(query(body).utf8)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 30
        return request
    }

    /// buildCodeExchangeBody(): POST /api/authz/v3/oauth/token, no Basic auth.
    static func exchange(code: String) async throws -> Tokens {
        let request = formRequest(PSNConfig.tokenURL, body: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", PSNConfig.clientID),
            ("client_secret", PSNConfig.clientSecret),
            ("redirect_uri", PSNConfig.redirectURI),
            ("scope", PSNConfig.scopes),
        ], basicAuth: false)
        return try parseTokens(try await sendJSON(request))
    }

    /// Refresh on the 2.0 endpoint with Basic client auth (Akira REMOTE_PLAY_PROFILE).
    static func refresh(refreshToken: String) async throws -> Tokens {
        let request = formRequest(PSNConfig.refreshURL, body: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("scope", PSNConfig.scopes),
            ("redirect_uri", PSNConfig.redirectURI),
        ], basicAuth: true)
        return try parseTokens(try await sendJSON(request))
    }

    /// GET /2.0/oauth/token/<access_token> with Basic auth -> user_id, online_id.
    static func identity(accessToken: String) async throws -> (userID: String, onlineID: String) {
        var request = URLRequest(url: URL(string: PSNConfig.tokenInfoURL + percentEncode(accessToken))!)
        let credentials = Data("\(PSNConfig.clientID):\(PSNConfig.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 20
        let json = try await sendJSON(request)
        let userID: String
        if let text = json["user_id"] as? String {
            userID = text
        } else if let number = json["user_id"] as? NSNumber {
            userID = number.stringValue
        } else {
            throw PSNError.invalidResponse("no user_id")
        }
        let onlineID = json["online_id"] as? String ?? ""
        return (userID, onlineID)
    }

    /// base64(UInt64 user id, little endian) - see psn_signin.cpp accountIdFromUserId.
    static func accountID(fromUserID userID: String) -> String? {
        guard let value = UInt64(userID) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            bytes[i] = UInt8((value >> (8 * UInt64(i))) & 0xFF)
        }
        return Data(bytes).base64EncodedString()
    }

    /// Authorize with `Cookie: npsso=...` and read the code from Location.
    static func requestCode(npsso: String, duid: String) async throws -> String {
        var request = URLRequest(url: authorizeURL(duid: duid))
        request.setValue(PSNConfig.mobileSafariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("npsso=\(npsso)", forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 30
        let (_, response) = try await noRedirectSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PSNError.invalidResponse("no HTTP response")
        }
        if let location = http.value(forHTTPHeaderField: "Location"),
           let code = extractCode(from: location) {
            return code
        }
        if http.statusCode >= 500 {
            throw PSNError.http(http.statusCode, "")
        }
        throw PSNError.noAuthorizationCode
    }

    private static func makeCredentials(tokens: Tokens, npsso: String?, duid: String) async throws -> PSNCredentials {
        let who = try await identity(accessToken: tokens.access)
        guard let accountID = accountID(fromUserID: who.userID) else {
            throw PSNError.invalidResponse("user_id is not numeric")
        }
        LogStore.shared.info("PSN sign-in ok (online id set: \(!who.onlineID.isEmpty))")
        return PSNCredentials(accessToken: tokens.access,
                              refreshToken: tokens.refresh,
                              expiresAt: Date().addingTimeInterval(TimeInterval(max(60, tokens.expiresIn))),
                              accountID: accountID,
                              onlineID: who.onlineID,
                              userID: who.userID,
                              npsso: (npsso?.isEmpty ?? true) ? nil : npsso,
                              duid: duid)
    }

    private static func parseTokens(_ json: [String: Any]) throws -> Tokens {
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            let message = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "missing access_token"
            throw PSNError.invalidResponse(message)
        }
        let refresh = json["refresh_token"] as? String ?? ""
        let expires = (json["expires_in"] as? NSNumber)?.intValue ?? 3600
        return Tokens(access: access, refresh: refresh, expiresIn: expires)
    }

    private static func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PSNError.invalidResponse("no HTTP response")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let message = (object?["error_description"] as? String)
                ?? (object?["error"] as? String)
                ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw PSNError.http(http.statusCode, message)
        }
        guard let object else {
            throw PSNError.invalidResponse("invalid JSON")
        }
        return object
    }
}

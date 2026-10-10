// Kizuna for iOS/iPadOS - PSN sign-in sheet (WKWebView)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
// Approach adapted from Pylux ios/Pylux/Views/LoginWebView.swift (AGPL-3.0,
// Copyright (C) ForWard Technologies LLC / Pylux contributors): Safari-like
// WKWebView, popup windows loaded in place, cookies read from the data store.
//
// Flow: load the Remote Play authorize URL -> the user signs in on Sony's page
// -> Sony redirects to https://remoteplay.dl.playstation.net/remoteplay/redirect?code=...
// -> we cancel that navigation, keep the code, read the `npsso` cookie (for
// silent re-authentication later) and exchange the code for tokens.

import SwiftUI
import UIKit
import WebKit

struct PSNSignInSheet: View {
    let onComplete: (PSNCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var errorMessage: String?
    @State private var showManual = false
    @State private var manualText = ""
    @State private var authorizeURL = PSNAuth.authorizeURL(duid: PSNAuth.clientDUID)

    var body: some View {
        NavigationStack {
            ZStack {
                PSNWebView(url: authorizeURL) { code, npsso in
                    complete(code: code, npsso: npsso)
                }
                .ignoresSafeArea(edges: .bottom)

                if working {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(L("psn.signin.working"))
                            .font(.headline)
                    }
                    .padding(28)
                    .kzGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
            .navigationTitle(L("psn.signin.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { showManual.toggle() }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .accessibilityLabel(L("psn.signin.manual"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if showManual {
                    manualPanel
                        .padding(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert(L("common.error"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })) {
                Button(L("common.ok"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var manualPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("psn.signin.manual"))
                .font(.headline)
            Text(L("psn.signin.manual.body"))
                .font(.footnote)
                .foregroundStyle(KZColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            KZTextField(title: L("psn.signin.manual.field"), text: $manualText, keyboard: .URL)
            HStack {
                Button {
                    if let pasted = UIPasteboard.general.string {
                        manualText = pasted
                    }
                } label: {
                    KZButtonLabel(title: L("common.paste"), systemImage: "doc.on.clipboard")
                }
                .kzGlassButton()
                Spacer()
                Button {
                    useManualInput()
                } label: {
                    KZButtonLabel(title: L("psn.signin.manual.use"), systemImage: "checkmark")
                }
                .kzProminentButton()
                .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
        }
        .kzCard()
    }

    private func useManualInput() {
        let text = manualText
        if let code = PSNAuth.extractCode(from: text) {
            complete(code: code, npsso: nil)
        } else if let npsso = PSNAuth.normalizeNPSSO(text) {
            run { try await PSNAuth.signIn(npsso: npsso) }
        } else {
            errorMessage = PSNError.invalidInput.errorDescription
        }
    }

    private func complete(code: String, npsso: String?) {
        run { try await PSNAuth.signIn(code: code, npsso: npsso) }
    }

    private func run(_ operation: @escaping () async throws -> PSNCredentials) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            do {
                let credentials = try await operation()
                working = false
                onComplete(credentials)
                dismiss()
            } catch {
                working = false
                errorMessage = error.localizedDescription
                // A used code cannot be exchanged twice: start a fresh authorize.
                authorizeURL = PSNAuth.authorizeURL(duid: PSNAuth.clientDUID)
            }
        }
    }
}

/// WKWebView that reports the authorization code once Sony redirects.
struct PSNWebView: UIViewRepresentable {
    let url: URL
    let onCode: (String, String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "Version/18.5 Mobile/15E148 Safari/604.1"

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = PSNConfig.mobileSafariUA
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCode = onCode
        // A new authorize URL is only set after a failed exchange: reload it.
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            context.coordinator.captured = false
            webView.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCode: (String, String?) -> Void
        var loadedURL: URL?
        var captured = false

        init(onCode: @escaping (String, String?) -> Void) {
            self.onCode = onCode
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, PSNAuth.isRedirect(url) {
                decisionHandler(.cancel)
                capture(url, in: webView)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url, PSNAuth.isRedirect(url) {
                webView.stopLoading()
                capture(url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // The redirect host may not resolve / may be blocked: the code is
            // still in the failing URL.
            let nsError = error as NSError
            if let failing = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL, PSNAuth.isRedirect(failing) {
                capture(failing, in: webView)
            } else if let text = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
                      let failing = URL(string: text), PSNAuth.isRedirect(failing) {
                capture(failing, in: webView)
            }
        }

        // Sony opens some steps (2FA, privacy) as popups: keep them in this view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func capture(_ url: URL, in webView: WKWebView) {
            guard !captured, let code = PSNAuth.extractCode(from: url.absoluteString) else { return }
            captured = true
            let callback = onCode
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let npsso = cookies.first(where: { $0.name == "npsso" && $0.domain.contains("sony.com") })?.value
                DispatchQueue.main.async {
                    callback(code, npsso)
                }
            }
        }
    }
}

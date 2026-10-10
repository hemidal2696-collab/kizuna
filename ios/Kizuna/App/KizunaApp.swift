// Kizuna for iOS/iPadOS
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import SwiftUI
import UIKit

@main
struct KizunaApp: App {
    @UIApplicationDelegateAdaptor(KizunaAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(KZColor.accent)
                .id(model.language) // rebuild every string when the language changes
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

/// Supplies per-screen orientation locking (the stream is landscape-only on iPhone).
final class KizunaAppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        KizunaCoreBridge.bootstrap()
        return true
    }

    func application(_ application: UIApplication,
                      supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return Self.orientationMask
    }
}

enum OrientationController {
    /// iPhone: force landscape while streaming, free rotation otherwise.
    @MainActor
    static func lockLandscape(_ locked: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let mask: UIInterfaceOrientationMask = locked ? .landscape : .allButUpsideDown
        KizunaAppDelegate.orientationMask = mask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                print("[Kizuna] orientation update failed: \(error.localizedDescription)")
            }
        }
    }
}

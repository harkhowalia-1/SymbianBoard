// SwiftUI shell for the EKA2L1 iOS port.
//
// scenePhase is the iOS contract for "app is foreground / background". The
// emulator must stop touching the EAGL context the moment we leave .active
// or the system will tear down our drawable and crash the next GL call.

import SwiftUI
import UIKit

// SwiftUI Menu is backed by a UICollectionView on current iOS releases. UIKit's
// type-selection setup crashes while building that context-menu collection, so
// provide the no-op hook before any menus are presented.
extension UICollectionView {
    @objc func _configureTypeSelectInteractionIfNeeded() {}
}

// Supplies the emulator screen's orientation policy. It allows every direction
// by default and narrows to the current direction when the in-game lock is on.
final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        window?.windowScene?.session.role == .windowExternalDisplayNonInteractive
            ? .all : lockedInterfaceOrientationMask
    }
}

@main
struct EKA2L1App: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainSceneContent()
        }
    }
}

private struct MainSceneContent: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ContentView()
        .background(MacWindowShaper())
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                EKA2L1Bridge.shared.resumeNetworking()
                EKA2L1Bridge.shared.resume()
                ExternalDisplay.shared.setForeground(true)
            case .inactive, .background:
                ExternalDisplay.shared.setForeground(false)
                EKA2L1Bridge.shared.pause()
                // pause() deactivates the audio session, which CoreHaptics
                // shares; don't keep the iOS 16 fallback's generators alive
                // across that. SwiftUI handles this itself on iOS 17+.
                Haptics.release()
                // Only .background gets the process suspended, and a suspended
                // app's sockets come back defunct. A passing .inactive (control
                // centre, a call banner) must not drop a live netplay search.
                if newPhase == .background {
                    EKA2L1Bridge.shared.suspendNetworking()
                }
            @unknown default:
                break
            }
        }
    }
}

// On a Mac the app opens in a phone-shaped window (portrait, like the N8)
// rather than the default iPad-sized landscape one, and can't be squeezed
// smaller than a phone screen.
private struct MacWindowShaper: UIViewRepresentable {
    static var runsOnMac: Bool {
        ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        guard Self.runsOnMac else { return view }
        DispatchQueue.main.async {
            guard let scene = view.window?.windowScene else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 380, height: 700)
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 160, y: 60, width: 440, height: 860)))
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

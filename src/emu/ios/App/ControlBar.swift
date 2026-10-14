import SwiftUI
import UIKit

// The phone controls shown under a running Symbian app, so it can be driven
// like the phone it came from:
//
//   - N8: green call key, the N8's Menu key (back to the home screen), red end
//     key — the keys under an N8's screen.
//   - Android: back (Symbian's back softkey), home, and the overview key, which
//     opens the emulator options.
//   - iPhone: only the home bar; swipe it up to leave the app.
//
// Chosen in the home screen's ⋯ menu; stored under "controls.style".
enum ControlBarStyle: String, CaseIterable, Identifiable {
    case symbian
    case android
    case homeBar

    static let storageKey = "controls.style"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .symbian: return "Nokia N8"
        case .android: return "Android"
        case .homeBar: return "iPhone home bar"
        }
    }
}

struct AppControlBar: View {
    let style: ControlBarStyle
    let actions: KeypadMenuActions
    let goHome: () -> Void

    var body: some View {
        switch style {
        case .symbian:
            symbianBar
        case .android:
            androidBar
        case .homeBar:
            HomeIndicatorBar(goHome: goHome)
        }
    }

    // MARK: N8

    private var symbianBar: some View {
        HStack(spacing: 0) {
            phoneKey(color: Color(red: 0.18, green: 0.72, blue: 0.29), symbol: "phone.fill",
                     scan: Scan.call, label: "Call")
                .frame(maxWidth: .infinity)
            n8MenuKey
            phoneKey(color: Color(red: 0.86, green: 0.16, blue: 0.16), symbol: "phone.down.fill",
                     scan: Scan.end, label: "End")
                .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .trailing) {
            optionsKey(symbol: "ellipsis")
                .padding(.trailing, 6)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(barBackground)
    }

    // The silver key under an N8's screen, with the Symbian menu glyph.
    private var n8MenuKey: some View {
        Button(action: goHome) {
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.52)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(white: 0.18))
            }
            .frame(width: 92, height: 30)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Menu")
    }

    private func phoneKey(color: Color, symbol: String, scan: UInt32, label: String) -> some View {
        Button {
            Haptics.impact(.light)
            EKA2L1Bridge.shared.tapRawKey(scan)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 64, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    // MARK: Android

    private var androidBar: some View {
        HStack(spacing: 0) {
            navButton(symbol: "arrowtriangle.left", label: "Back") {
                Haptics.impact(.light)
                EKA2L1Bridge.shared.tapRawKey(Scan.rightSoft)
            }
            navButton(symbol: "circle", label: "Home", action: goHome)
            optionsKey(symbol: "square")
                .frame(maxWidth: .infinity)
        }
        .frame(height: 48)
        .background(Color.black.opacity(0.92))
    }

    private func navButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    // MARK: Shared

    // The emulator's own options (layout editing, screenshot, game settings,
    // exit), the same menu the keypad's menu key carries.
    private func optionsKey(symbol: String) -> some View {
        SystemMenuKey(actions: actions, symbol: symbol, bare: true)
            .foregroundColor(.white.opacity(0.85))
    }

    private var barBackground: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
            }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// The bar along the bottom edge of an iPhone app. A short swipe up (or a tap)
// leaves the emulator screen; the touch area is kept small and centred so it
// stays clear of the guest's soft keys in the corners.
struct HomeIndicatorBar: View {
    let goHome: () -> Void

    @State private var lift: CGFloat = 0

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.75))
            .frame(width: 134, height: 5)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .offset(y: lift)
            .frame(width: 180, height: 30)
            .contentShape(Rectangle())
            .padding(.bottom, 4)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        lift = min(0, value.translation.height / 3)
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.25)) { lift = 0 }
                        if value.translation.height < -24 {
                            goHome()
                        }
                    }
            )
            .onTapGesture(perform: goHome)
            .accessibilityLabel("Home")
            .accessibilityAddTraits(.isButton)
    }
}

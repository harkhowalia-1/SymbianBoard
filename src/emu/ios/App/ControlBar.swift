import SwiftUI
import UIKit

// The N8's keys under a running Symbian app: the silver Menu key (back to the
// home screen), and — only in the phone's calling apps — the green call and
// red end keys, plus a small ⋯ for the emulator's own options.
//
// The keys show while an app opens and then tuck away into a slim silver
// handle along the bottom edge, so the app gets the whole screen; tapping or
// swiping up on the handle brings them back for a few seconds.
struct AppControlBar: View {
    let appUID: UInt32
    let actions: KeypadMenuActions
    let goHome: () -> Void

    @State private var expanded = true
    @State private var collapseWork: DispatchWorkItem?

    // Apps whose UI expects the call keys: Telephone, Log, Contacts, Speed
    // dial and Call mailbox on S60v5 / Symbian^3.
    private static let callKeyApps: Set<UInt32> = [
        0x100058B3, 0x101F4CD5, 0x101F4CCE, 0x1000590A, 0x100058F5,
    ]

    private var showsCallKeys: Bool { Self.callKeyApps.contains(appUID) }

    var body: some View {
        ZStack(alignment: .bottom) {
            if expanded {
                keys
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                handle
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: expanded)
        .onAppear { scheduleCollapse(after: 4) }
    }

    // MARK: Keys

    private var keys: some View {
        HStack(spacing: 0) {
            if showsCallKeys {
                phoneKey(color: Color(red: 0.18, green: 0.72, blue: 0.29), symbol: "phone.fill",
                         scan: Scan.call, label: "Call")
                    .frame(maxWidth: .infinity)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
            n8MenuKey
            if showsCallKeys {
                phoneKey(color: Color(red: 0.86, green: 0.16, blue: 0.16), symbol: "phone.down.fill",
                         scan: Scan.end, label: "End")
                    .frame(maxWidth: .infinity)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .trailing) {
            SystemMenuKey(actions: actions, symbol: "ellipsis", bare: true)
                .foregroundColor(.white.opacity(0.85))
                .padding(.trailing, 6)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
                }
        )
        // Any touch on the bar keeps it up a little longer.
        .simultaneousGesture(TapGesture().onEnded { scheduleCollapse(after: 4) })
    }

    // The silver key under an N8's screen.
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
            scheduleCollapse(after: 4)
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

    // MARK: Handle

    // A short silver bar, like the N8's Menu key seen edge-on.
    private var handle: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
            .frame(width: 92, height: 5)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .frame(width: 180, height: 28)
            .contentShape(Rectangle())
            .padding(.bottom, 4)
            .onTapGesture(perform: reveal)
            .gesture(DragGesture(minimumDistance: 6).onEnded { value in
                if value.translation.height < -12 { reveal() }
            })
            .accessibilityLabel("Show phone keys")
            .accessibilityAddTraits(.isButton)
    }

    private func reveal() {
        Haptics.impact(.light)
        expanded = true
        scheduleCollapse(after: 4)
    }

    private func scheduleCollapse(after seconds: Double) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { expanded = false }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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

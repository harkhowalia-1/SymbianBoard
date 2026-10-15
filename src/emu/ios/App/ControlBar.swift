import SwiftUI
import UIKit

// The N8's body below its screen, under a running Symbian app: the silver
// rounded-rectangle Menu key (back to the home screen) always sits in the
// middle, like the phone's one hardware key; the green call and red end keys
// join it only in the phone's calling apps, and a small ⋯ carries the
// emulator's own options.
struct AppControlBar: View {
    let appUID: UInt32
    let actions: KeypadMenuActions
    let goHome: () -> Void

    // Apps whose UI expects the call keys: Telephone, Log, Contacts, Speed
    // dial and Call mailbox on S60v5 / Symbian^3.
    private static let callKeyApps: Set<UInt32> = [
        0x100058B3, 0x101F4CD5, 0x101F4CCE, 0x1000590A, 0x100058F5,
    ]

    private var showsCallKeys: Bool { Self.callKeyApps.contains(appUID) }

    var body: some View {
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
                .foregroundColor(.white.opacity(0.7))
                .padding(.trailing, 6)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(phoneBody)
    }

    // Dark anodised aluminium, like the N8's chin, with a hairline where the
    // glass ends.
    private var phoneBody: some View {
        LinearGradient(colors: [Color(white: 0.19), Color(white: 0.11), Color(white: 0.07)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
            }
    }

    // The N8's Menu key: a small silver rounded rectangle with a chamfered
    // edge and the Symbian menu glyph.
    private var n8MenuKey: some View {
        Button(action: goHome) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.90), Color(white: 0.68), Color(white: 0.52)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.35)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.7), radius: 2, y: 1.5)
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(white: 0.22))
            }
            .frame(width: 66, height: 34)
            .contentShape(Rectangle())
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
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

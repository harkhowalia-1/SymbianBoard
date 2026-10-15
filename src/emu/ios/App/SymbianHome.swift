import SwiftUI
import UIKit

// Which home screen the app shows: the iPhone-style springboard, or a Symbian^3
// menu, as if the whole phone were running (like Parallels showing either the
// apps on their own or the full Windows desktop). Stored under "home.style".
enum HomeScreenStyle: String, CaseIterable, Identifiable {
    case iphone
    case symbian

    static let storageKey = "home.style"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iphone: return "iPhone"
        case .symbian: return "Symbian"
        }
    }
}

// The Symbian^3 Menu, the way an N8 shows it: its own status bar on top, a
// grid of the phone's app icons with names underneath, and the Options / Exit
// softkeys at the bottom, over the N8's dark wallpaper. Installed apps come
// first, then the ROM's own, the order a phone's Menu lists them after an
// install.
struct SymbianHomeView<InstallMenu: View, MoreMenu: View>: View {
    let apps: [EKA2L1AppItem]
    let deviceName: String
    let busy: Bool
    let zoomNamespace: Namespace.ID
    let onOpen: (EKA2L1AppItem) -> Void
    let onUninstall: (EKA2L1AppItem) -> Void
    let onAddToHomeScreen: (EKA2L1AppItem) -> Void
    @ViewBuilder let installMenu: () -> InstallMenu
    @ViewBuilder let moreMenu: () -> MoreMenu

    @AppStorage(HomeScreenStyle.storageKey) private var homeStyle = HomeScreenStyle.iphone.rawValue
    @State private var selected: UInt32?
    @State private var pendingRemoval: EKA2L1AppItem?

    private var orderedApps: [EKA2L1AppItem] {
        let byName: (EKA2L1AppItem, EKA2L1AppItem) -> Bool = {
            $0.name.localizedCompare($1.name) == .orderedAscending
        }
        let named = apps.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        return named.filter { !$0.system }.sorted(by: byName) + named.filter(\.system).sorted(by: byName)
    }

    var body: some View {
        VStack(spacing: 0) {
            SymbianStatusBar(operatorName: deviceName, busy: busy)
            titleBar
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 6) {
                    ForEach(orderedApps, id: \.uid) { app in
                        menuItem(app)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            softkeys
        }
        .background(SymbianWallpaper())
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .confirmationDialog(Text("Delete “\(pendingRemoval?.name ?? "")”?"),
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingRemoval) { app in
            Button("Delete", role: .destructive) {
                pendingRemoval = nil
                onUninstall(app)
            }
            Button("common.cancel", role: .cancel) { pendingRemoval = nil }
        }
    }

    private var titleBar: some View {
        HStack {
            Text("Menu")
                .font(.system(size: 19, weight: .regular))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
        )
    }

    private func menuItem(_ app: EKA2L1AppItem) -> some View {
        VStack(spacing: 5) {
            SymbianIcon(uid: app.uid, side: 58)
                .zoomSource(id: app.uid, in: zoomNamespace)
            Text(app.name)
                .font(.system(size: 12.5))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            // Symbian^3 highlights the touched item with a soft blue glow.
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.55, blue: 0.95).opacity(0.55),
                                              Color(red: 0.10, green: 0.30, blue: 0.70).opacity(0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .opacity(selected == app.uid ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selected = app.uid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                selected = nil
                onOpen(app)
            }
        }
        .contextMenu {
            Button {
                onOpen(app)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            Button {
                onAddToHomeScreen(app)
            } label: {
                Label("Add to Home Screen…", systemImage: "plus.app")
            }
            if !app.system {
                Button(role: .destructive) {
                    pendingRemoval = app
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(.isButton)
    }

    // Options (left) and Exit (right): Options carries installing apps and the
    // app settings; Exit leaves the Symbian view for the iPhone home screen.
    private var softkeys: some View {
        HStack {
            Menu {
                Menu {
                    installMenu()
                } label: {
                    Label("Install application", systemImage: "square.and.arrow.down")
                }
                Divider()
                moreMenu()
            } label: {
                Text("Options")
                    .font(.system(size: 17))
                    .foregroundColor(.white)
                    .frame(width: 110, height: 44, alignment: .leading)
            }
            .disabled(busy)

            Spacer()

            if busy {
                ProgressView().tint(.white)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { homeStyle = HomeScreenStyle.iphone.rawValue }
            } label: {
                Text("Exit")
                    .font(.system(size: 17))
                    .foregroundColor(.white)
                    .frame(width: 110, height: 44, alignment: .trailing)
            }
            .accessibilityHint("Switches to the iPhone home screen")
        }
        .padding(.horizontal, 16)
        .background(
            LinearGradient(colors: [Color(white: 0.20), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// A Symbian app icon as the phone draws it: no plate, just the icon.
private struct SymbianIcon: View {
    let uid: UInt32
    let side: CGFloat

    @State private var icon: UIImage?

    var body: some View {
        Group {
            if let icon {
                Image(uiImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: side * 0.5, weight: .light))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(width: side, height: side)
        .onAppear {
            let uid = self.uid
            let px = UInt((side * UIScreen.main.scale).rounded())
            if let hit = SymbianIconCache.cached(uid: uid, px: px) {
                icon = hit
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let image = SymbianIconCache.load(uid: uid, px: px)
                DispatchQueue.main.async { if self.uid == uid { icon = image } }
            }
        }
    }
}

// The Symbian^3 status bar: signal and operator on the left, clock and battery
// on the right, on a dark glossy strip.
struct SymbianStatusBar: View {
    let operatorName: String
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            signalBars
            Text(operatorName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 13, weight: .medium))
            }
            batteryGlyph
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.black)
    }

    private var signalBars: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<5) { bar in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color(red: 0.35, green: 0.85, blue: 0.35))
                    .frame(width: 3, height: CGFloat(4 + bar * 2))
            }
        }
    }

    private var batteryGlyph: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: 22, height: 11)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(red: 0.35, green: 0.85, blue: 0.35))
                        .frame(width: 16, height: 7)
                        .padding(.leading, 2)
                }
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.9))
                .frame(width: 2, height: 5)
        }
    }
}

// The N8's default look: deep blue fading to black.
private struct SymbianWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.04, green: 0.10, blue: 0.25), Color(red: 0.01, green: 0.03, blue: 0.08),
                                .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

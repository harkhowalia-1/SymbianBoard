import SwiftUI
import UIKit
import UniformTypeIdentifiers

// iPhone-style home screen for the booted Symbian device.
//
//   - Pages of icons (4 columns on a phone, more on an iPad), a dock below
//     them and page dots between the two, over a gradient wallpaper.
//   - The device's built-in ROM apps live in a "Symbian" folder; installed
//     packages get their own icons, which is how the real phone would show
//     them after a SIS install.
//   - Long-press an icon for its quick actions; "Edit Home Screen" (or a
//     long-press on the wallpaper) starts jiggle mode, where icons can be
//     dragged around, onto the dock or across pages, and installed apps carry
//     a remove badge.
//
// The arrangement is kept per device (firmware code) in UserDefaults, since
// every device has its own app registry.

// MARK: - Layout model

// One slot on a page or in the dock.
enum HomeItem: Hashable, Codable {
    case app(UInt32)
    case systemFolder

    var key: String {
        switch self {
        case .app(let uid): return String(format: "app:%08X", uid)
        case .systemFolder: return "folder:system"
        }
    }

    init?(key: String) {
        if key == "folder:system" {
            self = .systemFolder
        } else if key.hasPrefix("app:"), let uid = UInt32(key.dropFirst(4), radix: 16) {
            self = .app(uid)
        } else {
            return nil
        }
    }
}

private struct StoredHomeLayout: Codable {
    var items: [String]
    var dock: [String]
}

// Order of the home pages (flattened; pages are cut from it by capacity) and
// of the dock, reconciled against the device's app list whenever it changes.
@MainActor
final class HomeLayoutStore: ObservableObject {
    @Published private(set) var items: [HomeItem] = []
    @Published private(set) var dock: [HomeItem] = []

    private var deviceKey = ""
    private var loadedKey: String?

    nonisolated static let dockCapacity = 4

    private static func defaultsKey(_ device: String) -> String {
        "springboard.layout.\(device.lowercased())"
    }

    // Brings the stored arrangement in line with what's installed: apps that
    // went away are dropped, new ones land in the first free slot at the end
    // (where a fresh install shows up on an iPhone too).
    func sync(deviceKey: String, apps: [EKA2L1AppItem], showSystemFolder: Bool) {
        // An empty list means the device is still coming up; seeding from it
        // would save an empty first-run layout.
        guard !apps.isEmpty else { return }
        if loadedKey != deviceKey {
            self.deviceKey = deviceKey
            loadedKey = deviceKey
            load(apps: apps)
        }

        let systemApps = apps.filter(\.system)
        var valid = Set(apps.map { HomeItem.app($0.uid) })
        if showSystemFolder && !systemApps.isEmpty {
            valid.insert(.systemFolder)
        }

        var newDock = dock.filter { valid.contains($0) }
        var newItems = items.filter { valid.contains($0) && !newDock.contains($0) }
        if newDock.count > Self.dockCapacity {
            newItems.insert(contentsOf: newDock[Self.dockCapacity...], at: 0)
            newDock = Array(newDock.prefix(Self.dockCapacity))
        }

        let placed = Set(newItems + newDock)
        for app in apps.filter({ !$0.system }).sorted(by: { $0.name.localizedCompare($1.name) == .orderedAscending })
        where !placed.contains(.app(app.uid)) {
            newItems.append(.app(app.uid))
        }
        if valid.contains(.systemFolder) && !placed.contains(.systemFolder) {
            newItems.append(.systemFolder)
        }

        if newItems != items { items = newItems }
        if newDock != dock { dock = newDock }
        save()
    }

    // ROM apps that aren't placed on a page or the dock; those make up the
    // Symbian folder.
    func folderApps(from apps: [EKA2L1AppItem]) -> [EKA2L1AppItem] {
        let placed = Set(items + dock)
        return apps.filter { $0.system && !placed.contains(.app($0.uid)) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // Drop `item` at `index` of the home order (clamped), taking it out of
    // wherever it was.
    func move(_ item: HomeItem, toHomeIndex index: Int) {
        var newItems = items
        var newDock = dock
        let original = newItems.firstIndex(of: item)
        newItems.removeAll { $0 == item }
        newDock.removeAll { $0 == item }
        var target = index
        if let original, original < index { target -= 1 }
        newItems.insert(item, at: max(0, min(target, newItems.count)))
        items = newItems
        dock = newDock
        save()
    }

    // Put `item` into the dock at `index`. A full dock pushes its last icon
    // back onto the home pages, so nothing is ever lost from the screen.
    func move(_ item: HomeItem, toDockIndex index: Int) {
        var newItems = items
        var newDock = dock
        let original = newDock.firstIndex(of: item)
        newItems.removeAll { $0 == item }
        newDock.removeAll { $0 == item }
        var target = index
        if let original, original < index { target -= 1 }
        newDock.insert(item, at: max(0, min(target, newDock.count)))
        if newDock.count > Self.dockCapacity {
            newItems.insert(newDock.removeLast(), at: 0)
        }
        items = newItems
        dock = newDock
        save()
    }

    private func load(apps: [EKA2L1AppItem]) {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey(deviceKey)),
           let stored = try? JSONDecoder().decode(StoredHomeLayout.self, from: data) {
            items = stored.items.compactMap(HomeItem.init(key:))
            dock = stored.dock.compactMap(HomeItem.init(key:))
            return
        }
        // First run on this device: lay it out like a phone out of the box.
        // The ROM's everyday apps go in the dock and on the first page; the
        // rest of its system apps stay in the Symbian folder.
        var used = Set<UInt32>()
        func pick(_ needles: [String]) -> HomeItem? {
            guard let app = apps.first(where: { app in
                app.system && !used.contains(app.uid) &&
                    needles.contains { app.name.lowercased().hasPrefix($0) }
            }) else { return nil }
            used.insert(app.uid)
            return .app(app.uid)
        }

        // The dialer is matched by its whole name, so "Phone switch" doesn't
        // pass for it; the rest by prefix.
        var seededDock: [HomeItem] = []
        if let dialer = apps.first(where: { $0.system && ["phone", "dialer", "telephone"].contains($0.name.lowercased()) }) {
            used.insert(dialer.uid)
            seededDock.append(.app(dialer.uid))
        }
        for needles in [["messag"], ["web", "browser"], ["music", "player"], ["contacts"]]
        where seededDock.count < Self.dockCapacity {
            if let item = pick(needles) { seededDock.append(item) }
        }
        dock = seededDock

        let pageWanted = [["camera"], ["gallery", "photos"], ["videos"], ["calendar"], ["clock"], ["mail"],
                          ["contacts"], ["notes"], ["calculator"], ["fm radio", "radio"], ["files", "file manager"],
                          ["settings"], ["search"], ["voice recorder", "recorder"], ["themes"], ["profiles"],
                          ["maps", "ovi maps"], ["store", "ovi store"]]
        items = pageWanted.compactMap(pick)
    }

    private func save() {
        guard !deviceKey.isEmpty else { return }
        let stored = StoredHomeLayout(items: items.map(\.key), dock: dock.map(\.key))
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey(deviceKey))
        }
    }
}

// MARK: - Icons

// Decoded Symbian icons, shared by the home screen, folders and the shortcut
// exporter. Decoding MIF/SVG is not free, so each one is done once per launch.
enum SymbianIconCache {
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func cached(uid: UInt32, px: UInt) -> UIImage? {
        cache.object(forKey: "\(uid)@\(px)" as NSString)
    }

    // Blocking; call off the main queue.
    static func load(uid: UInt32, px: UInt) -> UIImage? {
        let key = "\(uid)@\(px)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = EKA2L1Bridge.iconPNGData(uid: uid, sizePx: px),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func invalidate() {
        cache.removeAllObjects()
    }
}

// The app's Symbian icon on an iOS-style rounded plate. Symbian icons are
// drawn on a transparent canvas in all sorts of shapes, so a plate behind them
// is what makes a page of them read as an iPhone home screen.
struct SymbianAppTile: View {
    let uid: UInt32
    let side: CGFloat

    @State private var icon: UIImage?

    private var decodePx: UInt { UInt((side * UIScreen.main.scale).rounded()) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.86)],
                                     startPoint: .top, endPoint: .bottom))
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(side * 0.12)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: side * 0.42, weight: .light))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: side * 0.05, y: side * 0.02)
        .onAppear(perform: load)
        .onChange(of: uid) { _ in
            icon = nil
            load()
        }
    }

    private func load() {
        let uid = self.uid
        let px = decodePx
        if let hit = SymbianIconCache.cached(uid: uid, px: px) {
            icon = hit
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = SymbianIconCache.load(uid: uid, px: px)
            DispatchQueue.main.async {
                if self.uid == uid { self.icon = image }
            }
        }
    }
}

// Folder icon: a frosted plate holding up to nine miniature icons.
private struct FolderTile: View {
    let apps: [EKA2L1AppItem]
    let side: CGFloat

    var body: some View {
        let inner = side * 0.78
        let mini = (inner - side * 0.08) / 3
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .fill(.ultraThinMaterial)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(mini), spacing: side * 0.04), count: 3),
                      spacing: side * 0.04) {
                ForEach(apps.prefix(9), id: \.uid) { app in
                    SymbianAppTile(uid: app.uid, side: mini)
                        .shadow(radius: 0)
                }
            }
            .frame(width: inner, height: inner, alignment: .topLeading)
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Wallpaper

enum HomeWallpaper: String, CaseIterable, Identifiable {
    case aurora, sunset, ocean, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .graphite: return "Graphite"
        }
    }

    var colors: [Color] {
        switch self {
        case .aurora:
            return [Color(red: 0.16, green: 0.10, blue: 0.42), Color(red: 0.05, green: 0.45, blue: 0.62),
                    Color(red: 0.20, green: 0.75, blue: 0.62)]
        case .sunset:
            return [Color(red: 0.36, green: 0.10, blue: 0.40), Color(red: 0.90, green: 0.32, blue: 0.36),
                    Color(red: 0.99, green: 0.70, blue: 0.40)]
        case .ocean:
            return [Color(red: 0.02, green: 0.10, blue: 0.30), Color(red: 0.05, green: 0.35, blue: 0.70),
                    Color(red: 0.45, green: 0.78, blue: 0.95)]
        case .graphite:
            return [Color(white: 0.08), Color(white: 0.22), Color(white: 0.38)]
        }
    }
}

private struct WallpaperView: View {
    let wallpaper: HomeWallpaper

    var body: some View {
        // Overlays, so the oversized blooms can't widen the screen's layout.
        LinearGradient(colors: wallpaper.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                // Soft light blooms, so the gradient has some depth behind the glass.
                ZStack {
                    Circle()
                        .fill(wallpaper.colors.last!.opacity(0.55))
                        .frame(width: 420, height: 420)
                        .blur(radius: 120)
                        .offset(x: 140, y: -260)
                    Circle()
                        .fill(wallpaper.colors.first!.opacity(0.7))
                        .frame(width: 460, height: 460)
                        .blur(radius: 140)
                        .offset(x: -160, y: 300)
                }
            }
            .clipped()
            .ignoresSafeArea()
    }
}

// MARK: - Grid metrics

private struct HomeMetrics {
    let columns: Int
    let rows: Int
    let iconSide: CGFloat
    let cellHeight: CGFloat
    let dockColumns: Int

    var capacity: Int { columns * rows }

    init(size: CGSize) {
        let pad = size.width >= 600
        iconSide = pad ? 76 : 62
        cellHeight = iconSide + (pad ? 40 : 34)
        if pad {
            columns = size.width > size.height ? 8 : 6
        } else {
            columns = size.width > size.height ? 7 : 4
        }
        rows = max(2, Int(size.height / cellHeight))
        dockColumns = HomeLayoutStore.dockCapacity
    }
}

// MARK: - Springboard

struct SpringboardView<InstallMenu: View, MoreMenu: View>: View {
    let apps: [EKA2L1AppItem]
    let deviceKey: String
    let busy: Bool
    let zoomNamespace: Namespace.ID
    let onOpen: (EKA2L1AppItem) -> Void
    let onUninstall: (EKA2L1AppItem) -> Void
    let onAddToHomeScreen: (EKA2L1AppItem) -> Void
    @ViewBuilder let installMenu: () -> InstallMenu
    @ViewBuilder let moreMenu: () -> MoreMenu

    @AppStorage("springboard.wallpaper") private var wallpaperRaw = HomeWallpaper.aurora.rawValue
    @AppStorage("springboard.showSystemFolder") private var showSystemFolder = true
    @AppStorage(HomeScreenStyle.storageKey) private var homeStyle = HomeScreenStyle.iphone.rawValue

    @StateObject private var layout = HomeLayoutStore()
    @State private var page = 0
    @State private var editing = false
    @State private var openFolder = false
    @State private var pendingRemoval: EKA2L1AppItem?
    @State private var edgeFlip: DispatchWorkItem?

    private var wallpaper: HomeWallpaper { HomeWallpaper(rawValue: wallpaperRaw) ?? .aurora }

    private var appsByUID: [UInt32: EKA2L1AppItem] {
        Dictionary(apps.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        GeometryReader { proxy in
            let gridSize = CGSize(width: proxy.size.width - 32, height: max(200, proxy.size.height - 210))
            let metrics = HomeMetrics(size: gridSize)
            let pages = paged(layout.items, capacity: metrics.capacity)

            ZStack {
                WallpaperView(wallpaper: wallpaper)

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.top, 6)

                    ZStack {
                        TabView(selection: $page) {
                            ForEach(pages.indices, id: \.self) { index in
                                pageGrid(pages[index], pageIndex: index, metrics: metrics)
                                    .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))

                        if layout.items.isEmpty && layout.dock.isEmpty {
                            emptyHint
                        }

                        if editing {
                            edgeDropZones(pageCount: pages.count, metrics: metrics)
                        }
                    }

                    pageDots(count: pages.count)
                        .padding(.vertical, 10)

                    dockView(metrics: metrics)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                if openFolder {
                    folderOverlay(metrics: metrics)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .zIndex(2)
                }
            }
            .onChange(of: pages.count) { count in
                if page >= count { page = max(0, count - 1) }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: syncLayout)
        .onChange(of: apps) { _ in syncLayout() }
        .onChange(of: deviceKey) { _ in
            page = 0
            syncLayout()
        }
        .onChange(of: showSystemFolder) { _ in syncLayout() }
        .confirmationDialog(Text("Remove “\(pendingRemoval?.name ?? "")”?"),
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingRemoval) { app in
            Button("Delete App", role: .destructive) {
                pendingRemoval = nil
                onUninstall(app)
            }
            Button("common.cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("Deleting this app also deletes its data from the Symbian device.")
        }
    }

    private func syncLayout() {
        layout.sync(deviceKey: deviceKey, apps: apps, showSystemFolder: showSystemFolder)
    }

    private func paged(_ items: [HomeItem], capacity: Int) -> [[HomeItem]] {
        guard !items.isEmpty else { return [[]] }
        var pages = stride(from: 0, to: items.count, by: capacity).map {
            Array(items[$0..<min($0 + capacity, items.count)])
        }
        // While editing, an empty page at the end gives icons somewhere to go.
        if editing { pages.append([]) }
        return pages
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Menu {
                installMenu()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .glassCircle()
            }
            .accessibilityLabel("Install Symbian app")
            .disabled(busy)

            Spacer()

            if busy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .glassCapsule()
            }

            Spacer()

            if editing {
                Button("Done") { stopEditing() }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .glassCapsule()
            } else {
                Menu {
                    Button {
                        startEditing()
                    } label: {
                        Label("Edit Home Screen", systemImage: "apps.iphone")
                    }
                    Menu {
                        Picker("Wallpaper", selection: $wallpaperRaw) {
                            ForEach(HomeWallpaper.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    } label: {
                        Label("Wallpaper", systemImage: "photo")
                    }
                    Toggle(isOn: $showSystemFolder) {
                        Label("Show Symbian Folder", systemImage: "folder")
                    }
                    Picker(selection: $homeStyle) {
                        ForEach(HomeScreenStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("Home Screen Style", systemImage: "iphone.gen1")
                    }
                    .pickerStyle(.menu)
                    Divider()
                    moreMenu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .glassCircle()
                }
                .disabled(busy)
            }
        }
        .foregroundColor(.white)
        .frame(height: 44)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .light))
            Text("No apps yet")
                .font(.title3.weight(.semibold))
            Text("Tap + to install a Symbian app (.sis or .sisx).")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .opacity(0.8)
        }
        .foregroundColor(.white)
        .padding(32)
        .allowsHitTesting(false)
    }

    private func pageDots(count: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == page ? 0.95 : 0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule()
        .opacity(count > 1 ? 1 : 0)
    }

    // MARK: Pages

    private func pageGrid(_ items: [HomeItem], pageIndex: Int, metrics: HomeMetrics) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: metrics.columns)
        let base = pageIndex * metrics.capacity
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { offset, item in
                iconCell(item, metrics: metrics, showLabel: true)
                    .frame(height: metrics.cellHeight)
                    .dropDestination(for: String.self) { keys, _ in
                        guard editing, let key = keys.first, let dropped = HomeItem(key: key) else { return false }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            layout.move(dropped, toHomeIndex: base + offset)
                        }
                        return true
                    }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
        // Empty space on a page: long-press starts editing, a tap ends it,
        // and dropping an icon there appends it to that page.
        .contentShape(Rectangle())
        // Simultaneous, so the page view's own scroll gestures can't swallow them.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in startEditing() })
        .simultaneousGesture(TapGesture().onEnded { if editing { stopEditing() } })
        .dropDestination(for: String.self) { keys, _ in
            guard editing, let key = keys.first, let dropped = HomeItem(key: key) else { return false }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                layout.move(dropped, toHomeIndex: min(base + items.count, layout.items.count))
            }
            return true
        }
    }

    // Holding a dragged icon against the left or right edge turns the page.
    private func edgeDropZones(pageCount: Int, metrics: HomeMetrics) -> some View {
        HStack {
            edgeZone { page = max(0, page - 1) }
            Spacer()
            edgeZone { page = min(pageCount - 1, page + 1) }
        }
    }

    private func edgeZone(_ flip: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: 28)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { _, _ in false } isTargeted: { targeted in
                edgeFlip?.cancel()
                guard targeted else { return }
                let work = DispatchWorkItem { withAnimation { flip() } }
                edgeFlip = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
            }
    }

    // MARK: Dock

    private func dockView(metrics: HomeMetrics) -> some View {
        HStack(spacing: 0) {
            if layout.dock.isEmpty {
                Text(editing ? "Drag apps here" : "")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
            }
            ForEach(Array(layout.dock.enumerated()), id: \.element) { offset, item in
                iconCell(item, metrics: metrics, showLabel: false)
                    .frame(maxWidth: .infinity)
                    .dropDestination(for: String.self) { keys, _ in
                        guard editing, let key = keys.first, let dropped = HomeItem(key: key) else { return false }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            layout.move(dropped, toDockIndex: offset)
                        }
                        return true
                    }
            }
        }
        .frame(height: metrics.iconSide + 30)
        .padding(.horizontal, 8)
        .glassPlatter(cornerRadius: 34)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { keys, _ in
            guard editing, let key = keys.first, let dropped = HomeItem(key: key) else { return false }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                layout.move(dropped, toDockIndex: layout.dock.count)
            }
            return true
        }
    }

    // MARK: Icons

    @ViewBuilder
    private func iconCell(_ item: HomeItem, metrics: HomeMetrics, showLabel: Bool) -> some View {
        switch item {
        case .app(let uid):
            if let app = appsByUID[uid] {
                appIcon(app, item: item, metrics: metrics, showLabel: showLabel)
            }
        case .systemFolder:
            folderIcon(metrics: metrics, showLabel: showLabel)
        }
    }

    private func appIcon(_ app: EKA2L1AppItem, item: HomeItem, metrics: HomeMetrics, showLabel: Bool) -> some View {
        let cell = VStack(spacing: 6) {
            SymbianAppTile(uid: app.uid, side: metrics.iconSide)
                .zoomSource(id: app.uid, in: zoomNamespace)
                .overlay(alignment: .topLeading) {
                    if editing && !app.system {
                        removeBadge { pendingRemoval = app }
                    }
                }
            if showLabel {
                iconLabel(app.name)
            }
        }
        .jiggle(editing, seed: app.uid)
        .contentShape(Rectangle())
        .onTapGesture {
            if editing { return }
            onOpen(app)
        }

        return Group {
            if editing {
                cell.draggable(item.key) {
                    SymbianAppTile(uid: app.uid, side: metrics.iconSide)
                }
            } else {
                cell.contextMenu {
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
                    Button {
                        UIPasteboard.general.string = String(format: "0x%08X", app.uid)
                    } label: {
                        Label(String(format: "Copy UID 0x%08X", app.uid), systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button {
                        startEditing()
                    } label: {
                        Label("Edit Home Screen", systemImage: "apps.iphone")
                    }
                    if !app.system {
                        Button(role: .destructive) {
                            pendingRemoval = app
                        } label: {
                            Label("Remove App", systemImage: "minus.circle")
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(.isButton)
    }

    private func folderIcon(metrics: HomeMetrics, showLabel: Bool) -> some View {
        let folderApps = layout.folderApps(from: apps)
        let cell = VStack(spacing: 6) {
            FolderTile(apps: folderApps, side: metrics.iconSide)
            if showLabel {
                iconLabel("Symbian")
            }
        }
        .jiggle(editing, seed: 7)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { openFolder = true }
        }
        return Group {
            if editing {
                cell.draggable(HomeItem.systemFolder.key) {
                    FolderTile(apps: folderApps, side: metrics.iconSide)
                }
            } else {
                cell.contextMenu {
                    Button {
                        startEditing()
                    } label: {
                        Label("Edit Home Screen", systemImage: "apps.iphone")
                    }
                }
            }
        }
    }

    private func iconLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .frame(maxWidth: 78)
    }

    private func removeBadge(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.black)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(white: 0.9)))
                .shadow(radius: 1)
        }
        .buttonStyle(.plain)
        .offset(x: -7, y: -7)
    }

    // MARK: Folder

    private func folderOverlay(metrics: HomeMetrics) -> some View {
        let folderApps = layout.folderApps(from: apps)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: min(4, metrics.columns))
        return ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { openFolder = false }
                }

            VStack(spacing: 18) {
                Text("Symbian")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(folderApps, id: \.uid) { app in
                            VStack(spacing: 6) {
                                SymbianAppTile(uid: app.uid, side: metrics.iconSide)
                                    .zoomSource(id: app.uid, in: zoomNamespace)
                                iconLabel(app.name)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(app) }
                            .contextMenu {
                                Button {
                                    onAddToHomeScreen(app)
                                } label: {
                                    Label("Add to Home Screen…", systemImage: "plus.app")
                                }
                                Button {
                                    withAnimation {
                                        layout.move(.app(app.uid), toHomeIndex: layout.items.count)
                                    }
                                } label: {
                                    Label("Move to Home Screen", systemImage: "square.grid.2x2")
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .frame(maxHeight: 460)
                .glassPlatter(cornerRadius: 38)
                .padding(.horizontal, 28)
            }
        }
    }

    // MARK: Edit mode

    private func startEditing() {
        guard !editing else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { editing = true }
    }

    private func stopEditing() {
        withAnimation(.easeInOut(duration: 0.2)) { editing = false }
    }
}

// MARK: - Modifiers

private struct JiggleModifier: ViewModifier {
    let active: Bool
    let seed: UInt32

    @State private var tilted = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? (tilted ? 1.8 : -1.8) : 0))
            .animation(active
                       ? .easeInOut(duration: 0.12 + Double(seed % 5) * 0.008).repeatForever(autoreverses: true)
                       : .default,
                       value: tilted)
            .onChange(of: active) { on in tilted = on }
            .onAppear { if active { tilted = true } }
    }
}

private extension View {
    func jiggle(_ active: Bool, seed: UInt32) -> some View {
        modifier(JiggleModifier(active: active, seed: seed))
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(Circle().fill(.ultraThinMaterial))
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
        }
    }

    @ViewBuilder
    func glassPlatter(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial))
        }
    }
}

extension View {
    // Icon → app zoom, like opening an app from the iPhone home screen (iOS 18+).
    @ViewBuilder
    func zoomSource(id: UInt32, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomTransition(id: UInt32, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

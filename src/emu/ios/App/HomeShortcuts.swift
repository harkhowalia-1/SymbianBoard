import AppIntents
import SwiftUI
import UIKit

// Shortcuts that open one Symbian app straight from outside the emulator:
//
//   - every app has a launch link, symbianboard://launch?uid=0x…&device=<code>,
//     which the app opens into that app's emulator screen (booting the right
//     device first when it isn't the one running);
//   - the Shortcuts app sees each installed app through App Intents, so an
//     "Open <app>" shortcut can be added to the iPhone Home Screen or run
//     from Siri and Spotlight;
//   - "Add to Home Screen…" can also write a configuration profile holding a
//     Home Screen web clip with the app's own icon, which launches through the
//     same link without going through the Shortcuts app.

// MARK: - Launch links

struct SymbianLaunchRequest: Equatable, Sendable {
    let uid: UInt32
    // Firmware code of the device that has the app installed; nil means
    // "whichever device is booted".
    let deviceCode: String?
}

enum SymbianLaunchURL {
    static let scheme = "symbianboard"

    static func make(uid: UInt32, deviceCode: String?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "launch"
        var query = [URLQueryItem(name: "uid", value: String(format: "0x%08X", uid))]
        if let deviceCode, !deviceCode.isEmpty {
            query.append(URLQueryItem(name: "device", value: deviceCode))
        }
        components.queryItems = query
        return components.url!
    }

    static func parse(_ url: URL) -> SymbianLaunchRequest? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "launch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "uid" })?.value?.lowercased() else { return nil }
        let uid = raw.hasPrefix("0x") ? UInt32(raw.dropFirst(2), radix: 16) : UInt32(raw)
        guard let uid else { return nil }
        let device = items.first(where: { $0.name == "device" })?.value
        return SymbianLaunchRequest(uid: uid, deviceCode: device)
    }
}

// Hands launch requests from App Intents (which run outside the view tree) to
// the home screen, which owns navigation.
@MainActor
final class SymbianLaunchRouter: ObservableObject {
    static let shared = SymbianLaunchRouter()

    @Published var pending: SymbianLaunchRequest?

    private init() {}
}

// MARK: - Catalog of launchable apps

// The installed apps of every device the app has booted, kept on disk so the
// Shortcuts app can list them even while the emulator isn't running. Icons are
// stored next to it as PNGs for the Shortcuts picker.
struct SymbianCatalogEntry: Codable, Hashable, Sendable {
    let uid: UInt32
    let name: String
    let deviceCode: String
    let deviceName: String
    let system: Bool

    var id: String { "\(deviceCode.lowercased()):\(String(format: "%08X", uid))" }
}

enum SymbianAppCatalog {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Shortcuts", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("catalog.json") }

    static func iconURL(for entry: SymbianCatalogEntry) -> URL {
        directory.appendingPathComponent("\(entry.id.replacingOccurrences(of: ":", with: "_")).png")
    }

    static func load() -> [SymbianCatalogEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([SymbianCatalogEntry].self, from: data)) ?? []
    }

    // Replaces one device's entries with its current app list and refreshes
    // their icons in the background.
    static func update(device: EKA2L1DeviceItem, apps: [EKA2L1AppItem]) {
        let entries = apps.map {
            SymbianCatalogEntry(uid: $0.uid, name: $0.name, deviceCode: device.firmwareCode,
                                deviceName: device.displayName, system: $0.system)
        }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var all = load().filter { $0.deviceCode.caseInsensitiveCompare(device.firmwareCode) != .orderedSame }
            all.append(contentsOf: entries)
            if let data = try? JSONEncoder().encode(all) {
                try? data.write(to: file, options: .atomic)
            }
            for entry in entries where !fm.fileExists(atPath: iconURL(for: entry).path) {
                if let image = SymbianIconCache.load(uid: entry.uid, px: 180),
                   let png = HomeScreenIconRenderer.png(for: image) {
                    try? png.write(to: iconURL(for: entry), options: .atomic)
                }
            }
        }
    }
}

// MARK: - App Intents

struct SymbianAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Symbian App"
    static let defaultQuery = SymbianAppQuery()

    let id: String
    let name: String
    let uid: UInt32
    let deviceCode: String
    let deviceName: String

    init(_ entry: SymbianCatalogEntry) {
        id = entry.id
        name = entry.name
        uid = entry.uid
        deviceCode = entry.deviceCode
        deviceName = entry.deviceName
        iconURL = SymbianAppCatalog.iconURL(for: entry)
    }

    private let iconURL: URL

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(deviceName)", image: .init(url: iconURL))
    }
}

struct SymbianAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SymbianAppEntity] {
        let wanted = Set(identifiers)
        return SymbianAppCatalog.load().filter { wanted.contains($0.id) }.map(SymbianAppEntity.init)
    }

    func entities(matching string: String) async throws -> [SymbianAppEntity] {
        SymbianAppCatalog.load()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(SymbianAppEntity.init)
    }

    // Installed packages first, then the ROM's own apps.
    func suggestedEntities() async throws -> [SymbianAppEntity] {
        SymbianAppCatalog.load()
            .sorted { ($0.system ? 1 : 0, $0.name) < ($1.system ? 1 : 0, $1.name) }
            .map(SymbianAppEntity.init)
    }
}

struct OpenSymbianAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Symbian App"
    static let description = IntentDescription("Opens a Symbian app in SymbianBoard.")
    static let openAppWhenRun = true

    @Parameter(title: "App")
    var app: SymbianAppEntity

    init() {}

    init(app: SymbianAppEntity) {
        self.app = app
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$app)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        SymbianLaunchRouter.shared.pending = SymbianLaunchRequest(uid: app.uid, deviceCode: app.deviceCode)
        return .result()
    }
}

struct SymbianBoardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSymbianAppIntent(),
                    phrases: ["Open \(\.$app) in \(.applicationName)",
                              "Launch \(\.$app) with \(.applicationName)"],
                    shortTitle: "Open Symbian App",
                    systemImageName: "apps.iphone")
    }
}

// MARK: - Home Screen icon profile

enum HomeScreenIconRenderer {
    // A 180pt iOS icon: the Symbian icon centred on a light plate. Home Screen
    // icons are masked to the squircle by the system, so the plate is square.
    static func png(for icon: UIImage) -> Data? {
        let side: CGFloat = 180
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            let colors = [UIColor(white: 0.99, alpha: 1).cgColor, UIColor(white: 0.86, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: side), options: [])
            }
            let inset = side * 0.13
            icon.draw(in: CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2))
        }
        return image.pngData()
    }
}

enum HomeScreenProfile {
    // Writes a .mobileconfig with one web clip that opens the app's launch
    // link. Returns the file, ready to share or save to Files.
    static func write(name: String, uid: UInt32, deviceCode: String?) throws -> URL {
        let url = SymbianLaunchURL.make(uid: uid, deviceCode: deviceCode)
        let iconData = SymbianIconCache.load(uid: uid, px: 180).flatMap(HomeScreenIconRenderer.png(for:))
        let slug = String(format: "%08x", uid) + "." + (deviceCode ?? "any").lowercased()

        var clip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.symbianboard.webclip.\(slug)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": name,
            "Label": name,
            "URL": url.absoluteString,
            "IsRemovable": true,
            "FullScreen": true,
            "Precomposed": true,
        ]
        if let iconData { clip["Icon"] = iconData }

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.symbianboard.profile.\(slug)",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "\(name) (SymbianBoard)",
            "PayloadDescription": "Adds a Home Screen icon that opens \(name) in SymbianBoard.",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [clip],
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        let safeName = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .joined(separator: "-")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName.isEmpty ? "SymbianApp" : safeName).mobileconfig")
        try data.write(to: file, options: .atomic)
        return file
    }
}

// MARK: - "Add to Home Screen" sheet

struct AddToHomeScreenSheet: View {
    let app: EKA2L1AppItem
    let device: EKA2L1DeviceItem?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var profileURL: URL?
    @State private var errorText: String?
    @State private var copied = false

    private var launchURL: URL { SymbianLaunchURL.make(uid: app.uid, deviceCode: device?.firmwareCode) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        SymbianAppTile(uid: app.uid, side: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.headline)
                            Text(device?.displayName ?? "Current device")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    if let profileURL {
                        ShareLink(item: profileURL) {
                            Label("Save Home Screen Icon Profile", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            makeProfile()
                        } label: {
                            Label("Create Home Screen Icon", systemImage: "plus.app")
                        }
                    }
                    if let errorText {
                        Text(errorText).foregroundColor(.red)
                    }
                } header: {
                    Text("Home Screen icon")
                } footer: {
                    Text("Save the profile to Files, open it there, then install it from Settings › General › VPN & Device Management. The icon opens \(app.name) directly.")
                }

                Section {
                    Button {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    } label: {
                        Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                    }
                } header: {
                    Text("With the Shortcuts app")
                } footer: {
                    Text("Create a shortcut with the “Open Symbian App” action, choose \(app.name), then use “Add to Home Screen” from the shortcut's share menu. You can also ask Siri to “Open \(app.name) in SymbianBoard”.")
                }

                Section {
                    Button {
                        UIPasteboard.general.url = launchURL
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Launch Link", systemImage: copied ? "checkmark" : "link")
                    }
                } footer: {
                    Text(launchURL.absoluteString).textSelection(.enabled)
                }
            }
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: makeProfile)
    }

    private func makeProfile() {
        do {
            profileURL = try HomeScreenProfile.write(name: app.name, uid: app.uid, deviceCode: device?.firmwareCode)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

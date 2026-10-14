import SwiftUI

// Zero-setup first launch.
//
// Builds made with a pre-installed device (see SYMBIANBOARD_BUNDLED_DEVICE_DIR
// in src/emu/ios/CMakeLists.txt) carry it in the bundle as BundledDevice/,
// laid out exactly like the emulator's data tree. On the first launch it is
// copied into Documents/data before the emulator starts, so the emulator finds
// an installed device and boots it — no firmware import, no onboarding.
enum BundledDevice {
    static var bundleURL: URL? {
        Bundle.main.url(forResource: "BundledDevice", withExtension: nil)
    }

    private static var dataURL: URL {
        URL(fileURLWithPath: documentsRoot()).appendingPathComponent("data", isDirectory: true)
    }

    // True when the app ships a device and none has been installed yet.
    static var needsProvisioning: Bool {
        guard bundleURL != nil else { return false }
        return !FileManager.default.fileExists(atPath: dataURL.appendingPathComponent("devices.yml").path)
    }

    // Copies the bundled tree into the data folder. Folders that already exist
    // are merged into, so a drive the emulator created early is kept; files
    // that exist are left alone. The copy clones on APFS, so it takes seconds
    // rather than the minutes a firmware unpack would.
    static func provision() throws {
        guard let source = bundleURL else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try merge(from: source, into: dataURL, fm: fm)
    }

    private static func merge(from source: URL, into destination: URL, fm: FileManager) throws {
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue,
                   (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try merge(from: item, into: target, fm: fm)
                }
                continue
            }
            try fm.copyItem(at: item, to: target)
        }
    }
}

// Shown while the bundled device is copied into place: a dark screen with the
// phone booting, like the moment a Symbian phone powers on.
struct StartupSplash: View {
    var message = "Starting Symbian…"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "iphone.gen1")
                    .font(.system(size: 54, weight: .thin))
                    .foregroundStyle(.white.opacity(0.9))
                Text("SymbianBoard")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                ProgressView()
                    .tint(.white)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

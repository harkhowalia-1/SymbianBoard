import AVFoundation
import MediaPlayer
import Photos
import UIKit

// Shares media between the iPhone and the Symbian phone:
//
//   - iPhone photos → C:\Data\Images\iPhone, where the N8's Gallery finds them
//     (the newest ones, as JPEGs sized for the phone, dated like the originals).
//   - iPhone music → C:\Data\Sounds\iPhone for the Music player. Only songs
//     stored on the iPhone can be copied: Apple Music streaming / DRM tracks
//     have no file an app may read.
//   - Pictures Symbian apps save (camera shots, screenshots, edits) → iPhone
//     Photos.
//
// Every change is reported to the guest's media harvester through the emulated
// metadata file server plugin, so it shows up without restarting anything.
@MainActor
final class MediaBridge {
    static let shared = MediaBridge()

    static let galleryUID: UInt32 = 0x200009EE
    static let musicPlayerUID: UInt32 = 0x102072C3

    private let maxPhotos = 500
    private let maxSongs = 300
    private var photoSyncRunning = false
    private var musicSyncRunning = false

    private init() {}

    // MARK: Entry points

    // Called once the device is up: refreshes whatever the user already allowed,
    // without asking for anything.
    func syncAuthorizedLibraries() {
        if Self.photoAccessGranted { Task { await syncPhotos() } }
        if MPMediaLibrary.authorizationStatus() == .authorized { Task { await syncMusic() } }
        Task { await exportGuestPicturesToPhotos() }
    }

    // Before a Symbian app opens: Gallery asks for the photo library, the Music
    // player for the music library, the first time each one runs.
    func prepare(forAppUID uid: UInt32) async {
        switch uid {
        case Self.galleryUID:
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            if Self.photoAccessGranted { Task { await syncPhotos() } }
        case Self.musicPlayerUID:
            if MPMediaLibrary.authorizationStatus() == .notDetermined {
                _ = await withCheckedContinuation { continuation in
                    MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
                }
            }
            if MPMediaLibrary.authorizationStatus() == .authorized { Task { await syncMusic() } }
        default:
            break
        }
    }

    // After leaving a Symbian app: hand anything it saved to the iPhone.
    func appDidClose() {
        Task { await exportGuestPicturesToPhotos() }
    }

    private static var photoAccessGranted: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    // MARK: Paths

    private var driveC: URL? {
        EKA2L1Bridge.currentDeviceDriveCPath().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MediaBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadManifest(_ name: String) -> [String: String] {
        guard let data = try? Data(contentsOf: stateDirectory.appendingPathComponent(name)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveManifest(_ manifest: [String: String], _ name: String) {
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: stateDirectory.appendingPathComponent(name), options: .atomic)
        }
    }

    private static func guestPath(_ components: String...) -> String {
        "C:\\" + components.joined(separator: "\\")
    }

    // MARK: Photos → Gallery

    private func syncPhotos() async {
        guard !photoSyncRunning, let driveC else { return }
        photoSyncRunning = true
        defer { photoSyncRunning = false }

        let folder = driveC.appendingPathComponent("Data/Images/iPhone", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = maxPhotos
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var manifest = loadManifest("photos.json")
        var wanted = Set<String>()
        var created: [String] = []

        var list: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in list.append(asset) }

        for asset in list {
            wanted.insert(asset.localIdentifier)
            if let existing = manifest[asset.localIdentifier],
               FileManager.default.fileExists(atPath: folder.appendingPathComponent(existing).path) {
                continue
            }
            guard let jpeg = await Self.jpegData(for: asset) else { continue }
            let name = Self.photoFileName(for: asset)
            let url = folder.appendingPathComponent(name)
            do {
                try jpeg.write(to: url, options: .atomic)
                if let date = asset.creationDate {
                    try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date],
                                                           ofItemAtPath: url.path)
                }
                manifest[asset.localIdentifier] = name
                created.append(Self.guestPath("Data", "Images", "iPhone", name))
            } catch {
                continue
            }
        }

        // Photos deleted on the iPhone (or pushed out of the newest-N window).
        var deleted: [String] = []
        for (identifier, name) in manifest where !wanted.contains(identifier) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            manifest.removeValue(forKey: identifier)
            deleted.append(Self.guestPath("Data", "Images", "iPhone", name))
        }

        saveManifest(manifest, "photos.json")
        EKA2L1Bridge.reportGuestFileEvents(created, type: .created)
        EKA2L1Bridge.reportGuestFileEvents(deleted, type: .deleted)
    }

    private static func photoFileName(for asset: PHAsset) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = asset.creationDate.map(formatter.string(from:)) ?? "00000000_000000"
        // Local identifiers are "<UUID>/L0/001": the UUID's head keeps names unique.
        let suffix = String(asset.localIdentifier.prefix(8))
        return "IMG_\(stamp)_\(suffix).jpg"
    }

    // A JPEG no larger than 1600 px: plenty for a 640×360 screen, and quick for
    // the phone's thumbnailer.
    private static func jpegData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let target = CGSize(width: 1600, height: 1600)
        let image: UIImage? = await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                                  options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
        return image?.jpegData(compressionQuality: 0.85)
    }

    // MARK: Music → Music player

    private func syncMusic() async {
        guard !musicSyncRunning, let driveC else { return }
        musicSyncRunning = true
        defer { musicSyncRunning = false }

        let folder = driveC.appendingPathComponent("Data/Sounds/iPhone", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let songs = (MPMediaQuery.songs().items ?? []).filter { $0.assetURL != nil && !$0.hasProtectedAsset }
        var manifest = loadManifest("music.json")
        var wanted = Set<String>()
        var created: [String] = []

        for song in songs.prefix(maxSongs) {
            let key = String(song.persistentID)
            wanted.insert(key)
            if let existing = manifest[key], FileManager.default.fileExists(atPath: folder.appendingPathComponent(existing).path) {
                continue
            }
            guard let source = song.assetURL else { continue }
            let name = Self.songFileName(song)
            let destination = folder.appendingPathComponent(name)
            if await Self.exportSong(from: source, to: destination) {
                manifest[key] = name
                created.append(Self.guestPath("Data", "Sounds", "iPhone", name))
            }
        }

        var deleted: [String] = []
        for (key, name) in manifest where !wanted.contains(key) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            manifest.removeValue(forKey: key)
            deleted.append(Self.guestPath("Data", "Sounds", "iPhone", name))
        }

        saveManifest(manifest, "music.json")
        EKA2L1Bridge.reportGuestFileEvents(created, type: .created)
        EKA2L1Bridge.reportGuestFileEvents(deleted, type: .deleted)
    }

    private static func songFileName(_ song: MPMediaItem) -> String {
        let artist = song.artist ?? "Unknown Artist"
        let title = song.title ?? "Track \(song.persistentID)"
        let raw = "\(artist) - \(title)"
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let clean = raw.components(separatedBy: illegal).joined(separator: " ")
        return String(clean.prefix(100)) + ".m4a"
    }

    private static func exportSong(from source: URL, to destination: URL) async -> Bool {
        try? FileManager.default.removeItem(at: destination)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source),
                                                presetName: AVAssetExportPresetAppleM4A) else { return false }
        export.outputURL = destination
        export.outputFileType = .m4a
        await export.export()
        return export.status == .completed
    }

    // MARK: Symbian pictures → iPhone Photos

    // Pictures under `roots` that are new or changed since `seen` recorded them
    // (path → modification time), skipping the iPhone folder this bridge fills.
    nonisolated private static func changedPictures(under roots: [URL], seen: inout [String: String]) -> [URL] {
        let pictureTypes: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp"]
        var changed: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles]) else { continue }
            while let file = enumerator.nextObject() as? URL {
                if file.lastPathComponent.caseInsensitiveCompare("iPhone") == .orderedSame {
                    enumerator.skipDescendants()
                    continue
                }
                guard pictureTypes.contains(file.pathExtension.lowercased()) else { continue }
                let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    .map { String($0.timeIntervalSince1970) } ?? "0"
                if seen[file.path] == stamp { continue }
                seen[file.path] = stamp
                changed.append(file)
            }
        }
        return changed
    }

    // New pictures saved anywhere under C:\Data\Images or E:\Images, except the
    // iPhone folder this bridge fills itself.
    private func exportGuestPicturesToPhotos() async {
        guard Self.photoAccessGranted else { return }
        var roots: [URL] = []
        if let driveC { roots.append(driveC.appendingPathComponent("Data/Images", isDirectory: true)) }
        if let driveE = EKA2L1Bridge.currentDeviceDriveEPath() {
            roots.append(URL(fileURLWithPath: driveE).appendingPathComponent("Images", isDirectory: true))
        }

        var exported = loadManifest("exported.json")
        let firstRun = exported.isEmpty && !UserDefaults.standard.bool(forKey: "mediabridge.exportBaselineDone")
        let changed = Self.changedPictures(under: roots, seen: &exported)
        // The ROM's own sample pictures are already there on first run: record
        // them as seen instead of copying them to the iPhone.
        let newFiles = firstRun ? [] : changed

        UserDefaults.standard.set(true, forKey: "mediabridge.exportBaselineDone")
        saveManifest(exported, "exported.json")
        guard !newFiles.isEmpty else { return }

        try? await PHPhotoLibrary.shared().performChanges {
            for file in newFiles {
                PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: file)
            }
        }
    }
}

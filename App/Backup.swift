// Camera backup: uploads new photos and videos from the iPhone's library into the
// "Camera backup" folder, encrypted like everything else. Only what's taken after it's turned
// on (like the Android app). Runs when the app opens, when the library changes while it's open,
// and in the background whenever iOS allows (BGProcessingTask; iOS picks the time, usually
// overnight on charge).

import BackgroundTasks
import Foundation
import Network
import Photos
import UIKit
import UniformTypeIdentifiers

@MainActor
final class Backup: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = Backup()
    nonisolated static let taskId = "com.cellocloud.backup"
    static let folderName = "Camera backup"

    weak var cloud: Cloud?
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var pending = 0

    private let defaults = UserDefaults.standard
    private var task: Task<Void, Never>?
    private var observing = false

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "backup.enabled") {
        didSet { defaults.set(enabled, forKey: "backup.enabled") }
    }
    @Published var cellular: Bool = UserDefaults.standard.bool(forKey: "backup.cellular") {
        didSet { defaults.set(cellular, forKey: "backup.cellular") }
    }
    private var since: Date {
        get { defaults.object(forKey: "backup.since") as? Date ?? Date() }
        set { defaults.set(newValue, forKey: "backup.since") }
    }

    // Local ids of what's already up (a small file; ids aren't secrets but stay on the phone).
    private lazy var done: Set<String> = {
        guard let data = try? Data(contentsOf: Backup.doneFile), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }()
    private static var doneFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backup-done.json")
    }
    private func saveDone() { try? JSONEncoder().encode(Array(done)).write(to: Backup.doneFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }

    /// Turning it on asks for photo access and starts from now.
    func turnOn() async -> Bool {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            status = "CelloCloud isn't allowed to see your photos. Allow it in Settings → Apps → CelloCloud → Photos."
            return false
        }
        since = Date()
        done = []
        saveDone()
        enabled = true
        status = "On. New photos and videos will be backed up."
        start()
        return true
    }

    func turnOff() {
        enabled = false
        task?.cancel()
        status = ""
    }

    /// Signed out: forget everything about backup.
    func reset() {
        task?.cancel()
        enabled = false
        cellular = false
        done = []
        try? FileManager.default.removeItem(at: Backup.doneFile)
        defaults.removeObject(forKey: "backup.since")
        status = ""
        pending = 0
    }

    func start() {
        guard enabled, task == nil else { return }
        if !observing, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        task = Task { await self.run(); self.task = nil; Backup.schedule() }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.start() }
    }

    /// Ask iOS for background time to finish backing up.
    nonisolated static func schedule() {
        let req = BGProcessingTaskRequest(identifier: taskId)
        req.requiresNetworkConnectivity = true
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { t in
            Task { @MainActor in
                Backup.shared.start()
                t.expirationHandler = { Task { @MainActor in Backup.shared.task?.cancel() } }
                while Backup.shared.task != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                t.setTaskCompleted(success: true)
            }
        }
    }

    private func onAllowedNetwork() async -> Bool {
        if cellular { return true }
        let monitor = NWPathMonitor()
        let path: NWPath = await withCheckedContinuation { cont in
            monitor.pathUpdateHandler = { p in monitor.cancel(); cont.resume(returning: p) }
            monitor.start(queue: DispatchQueue(label: "backup.net"))
        }
        return path.status == .satisfied && !path.isExpensive && !path.isConstrained
    }

    private func run() async {
        guard enabled, let cloud, cloud.session != nil else { return }
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            status = "CelloCloud isn't allowed to see your photos. Allow it in Settings → Apps → CelloCloud → Photos."
            return
        }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate > %@ AND (mediaType == %d OR mediaType == %d)",
                                     since as NSDate, PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: opts)
        var todo: [PHAsset] = []
        result.enumerateObjects { a, _, _ in todo.append(a) }
        todo.removeAll { done.contains($0.localIdentifier) }
        pending = todo.count
        guard !todo.isEmpty else { status = enabled ? "Up to date." : ""; return }
        guard await onAllowedNetwork() else { status = "Waiting for Wi-Fi (\(todo.count) to back up)."; return }

        running = true
        defer { running = false }
        // A little extra time if the app is closed mid-upload.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "backup") {}
        defer { UIApplication.shared.endBackgroundTask(bg) }
        do {
            let folder = try await cloud.folder(named: Backup.folderName)
            for asset in todo {
                try Task.checkCancellation()
                status = "Backing up… \(pending) left"
                try await upload(asset, to: folder, cloud: cloud)
                done.insert(asset.localIdentifier)
                saveDone()
                pending -= 1
            }
            status = "Up to date."
        } catch is CancellationError {
            status = "Paused (\(pending) left)."
        } catch {
            status = "Backup stopped: \(error.localizedDescription)"
        }
    }

    private func upload(_ asset: PHAsset, to folder: String, cloud: Cloud) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        guard let res = wanted.lazy.compactMap({ t in resources.first { $0.type == t } }).first ?? resources.first else { return }
        let url = Files.newPickedFile(named: res.originalFilename)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true // photos kept in iCloud
        try await PHAssetResourceManager.default().writeData(for: res, toFile: url, options: opts)
        let type = UTType(res.uniformTypeIdentifier)?.preferredMIMEType ?? Files.guessType(res.originalFilename)
        try await cloud.upload(file: url, name: res.originalFilename, type: type, mtime: asset.creationDate, parent: folder)
    }
}

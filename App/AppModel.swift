// App-wide state: who's signed in, storage used, and the upload/download queue.

import Foundation
import SwiftUI

struct Transfer: Identifiable {
    enum State: Equatable { case waiting, working, done, failed(String) }
    let id = UUID()
    let name: String
    let size: Int64
    let isUpload: Bool
    var done: Int64 = 0
    var state: State = .waiting

    var finished: Bool { state != .waiting && state != .working }
    var fraction: Double { size > 0 ? min(1, Double(done) / Double(size)) : (state == .done ? 1 : 0) }
}

/// A file waiting to upload (a private copy, deleted once it's up).
private struct Pending {
    let transferId: UUID
    let url: URL
    let name: String
    let type: String?
    let mtime: Date?
    let parent: String?
}

@MainActor
final class AppModel: ObservableObject {
    let cloud = Cloud()
    @Published var signedIn: Bool
    @Published var account: Account?
    @Published var transfers: [Transfer] = []
    /// Bumped when files change, so open screens reload.
    @Published var changes = 0
    /// Shown once after sign-up.
    @Published var recoveryKey: String?

    private var queue: [Pending] = []
    private var uploading = false

    init() {
        signedIn = cloud.session != nil
        Backup.shared.cloud = cloud
    }

    var username: String { cloud.session?.username ?? "" }

    func refreshAccount() async {
        do { account = try await cloud.me() } catch let e as ApiError where e.status == 401 { await signOut() } catch {}
    }

    func didSignIn() {
        signedIn = true
        Task { await refreshAccount() }
    }

    func signOut() async {
        queue.removeAll()
        transfers.removeAll()
        await cloud.signOut()
        account = nil
        signedIn = false
    }

    func accountDeleted() {
        queue.removeAll()
        transfers.removeAll()
        account = nil
        signedIn = false
    }

    // ---- uploads ----
    func enqueue(url: URL, name: String, type: String? = nil, mtime: Date? = nil, parent: String?) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let t = Transfer(name: name, size: size, isUpload: true)
        transfers.append(t)
        queue.append(Pending(transferId: t.id, url: url, name: name, type: type, mtime: mtime, parent: parent))
        if !uploading { Task { await runUploads() } }
    }

    private func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { change(&transfers[i]) }
    }

    private func runUploads() async {
        uploading = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "uploads") {}
        defer { UIApplication.shared.endBackgroundTask(bg) }
        while !queue.isEmpty {
            let p = queue.removeFirst()
            update(p.transferId) { $0.state = .working }
            do {
                try await cloud.upload(file: p.url, name: p.name, type: p.type, mtime: p.mtime, parent: p.parent) { sent in
                    Task { @MainActor in self.update(p.transferId) { $0.done = sent } }
                }
                update(p.transferId) { $0.state = .done; $0.done = $0.size }
                // Finished uploads tidy themselves away; failed ones stay so you can see why.
                let id = p.transferId
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { transfers.removeAll { $0.id == id } }
                }
            } catch {
                update(p.transferId) { $0.state = .failed(error.localizedDescription) }
                if (error as? ApiError)?.status == 401 { await signOut(); break }
            }
            try? FileManager.default.removeItem(at: p.url.deletingLastPathComponent())
            changes += 1
        }
        uploading = false
        await refreshAccount()
    }

    var activeTransfers: Bool { transfers.contains { $0.state == .waiting || $0.state == .working } }

    func clearFinished() { transfers.removeAll { $0.finished } }

    // ---- opening files ----
    /// Decrypts a file for viewing/sharing; progress shows as a transfer.
    func open(_ item: Item) async throws -> URL {
        let t = Transfer(name: item.name, size: item.size, isUpload: false, state: .working)
        transfers.append(t)
        do {
            let url = try await cloud.download(item) { f in
                Task { @MainActor in self.update(t.id) { $0.done = Int64(f * Double(item.size)) } }
            }
            transfers.removeAll { $0.id == t.id }
            return url
        } catch {
            transfers.removeAll { $0.id == t.id }
            if (error as? ApiError)?.status == 401 { await signOut() }
            throw error
        }
    }
}

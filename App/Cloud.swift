// Everything the app does with the server, with the encryption in between: the server only
// ever sees sealed bytes. One instance for the app (AppModel.cloud), shared with camera backup.

import CelloCloudCore
import CryptoKit
import Foundation
import UIKit

/// A file or folder with its details decrypted.
struct Item: Identifiable, Hashable {
    let node: Node
    let meta: Meta
    var broken = false

    var id: String { node.id }
    var name: String { meta.name }
    var isDir: Bool { node.kind == "dir" }
    var type: String { meta.type ?? "application/octet-stream" }
    var isImage: Bool { type.hasPrefix("image/") }
    var isVideo: Bool { type.hasPrefix("video/") }
    var isMedia: Bool { isImage || isVideo }
    var size: Int64 { meta.size ?? 0 }
    /// When the file was taken/changed (as uploaded), else when it was uploaded.
    var date: Date { Date(timeIntervalSince1970: Double((meta.mtime ?? 0) > 0 ? meta.mtime! : node.created) / 1000) }
}

final class Cloud: @unchecked Sendable {
    let api = Api()
    private(set) var session: Session? {
        didSet { api.token = session?.token }
    }
    private let thumbs = NSCache<NSString, UIImage>()

    init() {
        session = SessionStore.load()
        api.token = session?.token
    }

    private var vault: SymmetricKey {
        get throws {
            guard let v = session?.vault else { throw ApiError(code: "not_signed_in", status: 401) }
            return v
        }
    }

    // ---- account -------------------------------------------------------------------------
    private func keep(_ username: String, _ account: Account, _ vault: SymmetricKey) {
        session = SessionStore.save(username: username, token: account.token ?? "", vault: vault)
    }

    /// PBKDF2 is slow on purpose: off the main thread.
    private func passwordKeys(_ password: String, _ salt: String) async throws -> Crypto.PasswordKeys {
        try await Task.detached(priority: .userInitiated) { try Crypto.passwordKeys(password, saltHex: salt) }.value
    }

    func signIn(username: String, password: String) async throws {
        let keys = try await passwordKeys(password, try await api.salt(username))
        let account = try await api.login(username, authKey: keys.authKey)
        guard let raw = try? Crypto.openB64(keys.encKey, account.wrappedVault) else { throw ApiError(code: "wrong_login", status: 401) }
        keep(username, account, Crypto.key(raw))
    }

    /// - Returns: the recovery key, as text to show once.
    func signUp(username: String, password: String) async throws -> String {
        let salt = Crypto.hex(Crypto.random(16))
        let keys = try await passwordKeys(password, salt)
        let vault = Crypto.random(32)
        let recovery = Crypto.random(32)
        let rk = Crypto.recoveryKeys(recovery)
        let account = try await api.signup([
            "username": username, "salt": salt, "authKey": keys.authKey, "agreed": true,
            "wrappedVault": try Crypto.sealB64(keys.encKey, vault),
            "recAuth": rk.recAuth, "recWrapped": try Crypto.sealB64(rk.encKey, vault),
        ])
        keep(username, account, Crypto.key(vault))
        return Crypto.recoveryText(recovery)
    }

    func recover(username: String, recoveryText: String, newPassword: String) async throws {
        guard let recovery = Crypto.parseRecoveryText(recoveryText) else { throw ApiError(code: "wrong_recovery_key", status: 400) }
        let rk = Crypto.recoveryKeys(recovery)
        let raw = try Crypto.openB64(rk.encKey, try await api.recoverStart(username, recAuth: rk.recAuth))
        let vault = Crypto.key(raw)
        let account = try await api.recoverFinish(username, recAuth: rk.recAuth, newPassword: try await newPasswordFields(newPassword, vault))
        keep(username, account, vault)
    }

    private func newPasswordFields(_ password: String, _ vault: SymmetricKey) async throws -> [String: Any?] {
        let salt = Crypto.hex(Crypto.random(16))
        let keys = try await passwordKeys(password, salt)
        let raw = vault.withUnsafeBytes { Data($0) }
        return ["salt": salt, "authKey": keys.authKey, "wrappedVault": try Crypto.sealB64(keys.encKey, raw)]
    }

    func changePassword(current: String, next: String) async throws {
        guard let s = session else { throw ApiError(code: "not_signed_in", status: 401) }
        let cur = try await passwordKeys(current, try await api.salt(s.username))
        let token = try await api.changePassword(authKey: cur.authKey, newPassword: try await newPasswordFields(next, s.vault))
        if let token { session = SessionStore.save(username: s.username, token: token, vault: s.vault) }
    }

    func deleteAccount(password: String) async throws {
        guard let s = session else { return }
        let keys = try await passwordKeys(password, try await api.salt(s.username))
        try await api.deleteAccount(authKey: keys.authKey)
        await forget()
    }

    func signOut() async {
        try? await api.logout()
        await forget()
    }

    @MainActor func forget() {
        SessionStore.clear()
        session = nil
        thumbs.removeAllObjects()
        Backup.shared.reset()
        Files.clearOpened()
    }

    func me() async throws -> Account { try await api.me() }

    // ---- files -------------------------------------------------------------------------------
    func decrypt(_ nodes: [Node]) throws -> [Item] {
        let key = try vault
        return nodes.map { n in
            if let raw = try? Crypto.openB64(key, n.meta), let meta = try? JSONDecoder().decode(Meta.self, from: raw) {
                return Item(node: n, meta: meta)
            }
            return Item(node: n, meta: Meta(name: "(can't decrypt)"), broken: true)
        }
    }

    func list(_ parent: String?) async throws -> [Item] {
        try decrypt(try await api.list(parent)).sorted {
            $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func photos() async throws -> [Item] {
        try decrypt(try await api.allFiles()).filter { !$0.broken && $0.isMedia }.sorted { $0.date > $1.date }
    }

    private func sealMeta(_ meta: Meta) throws -> String { try Crypto.sealB64(try vault, try JSONEncoder().encode(meta)) }

    @discardableResult
    func newFolder(parent: String?, name: String) async throws -> String {
        try await api.create(parent: parent, kind: "dir", meta: try sealMeta(Meta(name: String(name.trimmed.prefix(200)))))
    }

    func rename(_ item: Item, to name: String) async throws {
        var meta = item.meta
        meta.name = String(name.trimmed.prefix(200))
        try await api.update(item.id, meta: try sealMeta(meta))
    }

    func move(_ item: Item, to parent: String?) async throws { try await api.update(item.id, parent: .some(parent)) }

    func delete(_ item: Item) async throws { try await api.remove(item.id) }

    /// A top-level folder by name (made if missing), e.g. "Camera backup".
    func folder(named name: String) async throws -> String {
        if let found = try await list(nil).first(where: { $0.isDir && $0.name == name }) { return found.id }
        return try await newFolder(parent: nil, name: name)
    }

    /// Retries flaky connections; doesn't retry what won't change (quota, storage, sign-in).
    private func retry<T>(_ block: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await block() } catch let e as ApiError where e.isTransient && attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000) << UInt64(attempt))
            }
        }
    }

    /**
     Encrypts and uploads any file: its details (name, type, size, date, key) sealed with the
     vault key, its contents in 4 MB pieces each sealed with the file's own key.
     */
    @discardableResult
    func upload(file: URL, name: String, type: String?, mtime: Date?, parent: String?,
                progress: @escaping (Int64) -> Void = { _ in }) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let fileKeyRaw = Crypto.random(32)
        let fileKey = Crypto.key(fileKeyRaw)
        let type = type ?? Files.guessType(name)
        let meta = Meta(name: name, type: type, size: size, mtime: Int64((mtime ?? Date()).timeIntervalSince1970 * 1000),
                        key: fileKeyRaw.base64EncodedString())
        let sealedMeta = try sealMeta(meta)
        let id = try await retry { try await api.create(parent: parent, kind: "file", meta: sealedMeta) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var chunks = 0
        var sent: Int64 = 0
        while true {
            try Task.checkCancellation()
            let plain = try handle.read(upToCount: Crypto.chunkSize) ?? Data()
            if plain.isEmpty && chunks > 0 { break }
            let sealed = try Crypto.seal(fileKey, plain)
            let index = chunks
            try await retry { try await api.putChunk(id, index, sealed) }
            chunks += 1
            sent += Int64(plain.count)
            progress(sent)
            if plain.count < Crypto.chunkSize { break }
        }
        if type.hasPrefix("image/") || type.hasPrefix("video/"), let thumb = await Files.makeThumb(file, type: type),
           let sealed = try? Crypto.seal(fileKey, thumb) {
            try? await retry { try await api.putThumb(id, sealed) }
        }
        let count = chunks
        try await retry { try await api.finish(id, chunks: count) }
        return id
    }

    /// Downloads and decrypts a whole file into a private temporary file (deleted on sign-out
    /// and next launch), piece by piece.
    func download(_ item: Item, progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        guard let keyText = item.meta.key, let raw = Data(base64Encoded: keyText) else { throw ApiError(code: "broken_file", status: 0) }
        let key = Crypto.key(raw)
        let dest = Files.openedFile(id: item.id, name: item.name)
        if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber, size.int64Value == item.size {
            return dest // already opened this session
        }
        let partial = dest.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.complete])
        let handle = try FileHandle(forWritingTo: partial)
        do {
            for i in 0..<max(item.node.chunks, 0) {
                try Task.checkCancellation()
                let sealed = try await retry { try await api.getChunk(item.id, i) }
                try handle.write(contentsOf: try Crypto.open(key, sealed))
                progress(Double(i + 1) / Double(max(item.node.chunks, 1)))
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: partial, to: dest)
        return dest
    }

    func thumbnail(_ item: Item) async -> UIImage? {
        if let hit = thumbs.object(forKey: item.id as NSString) { return hit }
        guard item.node.thumb, !item.broken, let keyText = item.meta.key, let raw = Data(base64Encoded: keyText),
              let sealed = try? await api.getThumb(item.id), let bytes = try? Crypto.open(Crypto.key(raw), sealed),
              let image = UIImage(data: bytes) else { return nil }
        let ready = await image.byPreparingForDisplay() ?? image
        thumbs.setObject(ready, forKey: item.id as NSString)
        return ready
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

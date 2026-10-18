// Talking to the CelloCloud server (https://cloud.cellosig.com). Signed in with a bearer
// token; every change carries X-CelloCloud: 1 like the website's requests.

import Foundation

struct Node: Decodable, Hashable, Identifiable {
    let id: String
    let parent: String?
    let kind: String
    let meta: String
    let size: Int64
    let chunks: Int
    let thumb: Bool
    let created: Int64
    let updated: Int64?
}

struct Account: Decodable {
    let username: String
    let quota: Int64
    let used: Int64
    let wrappedVault: String
    let storage: String?
    let token: String?
}

/// A file's or folder's details, as encrypted inside Node.meta. Folders only have a name.
struct Meta: Codable, Hashable {
    var name: String
    var type: String?
    var size: Int64?
    var mtime: Int64?
    var key: String?
}

struct ApiError: LocalizedError {
    let code: String
    let status: Int

    var errorDescription: String? {
        switch code {
        case "wrong_login": return "Wrong username or password."
        case "wrong_recovery_key": return "That recovery key doesn't match this account."
        case "username_taken": return "That username is taken. Try another one."
        case "bad_username": return "Usernames are 3–32 characters: lowercase letters, numbers, dots, dashes, underscores."
        case "rate_limited": return "Too many attempts. Wait a few minutes and try again."
        case "quota_full": return "Your storage is full. Delete some files to make room."
        case "storage_offline": return "Storage is offline right now. Your files are safe — try again later."
        case "storage_full": return "The server's storage is full right now. Try again later."
        case "not_signed_in": return "Your session ended. Please sign in again."
        case "terms_not_accepted": return "Please accept the terms to create an account."
        case "offline": return "Can't reach CelloCloud. Check your internet connection."
        case "broken_file": return "This file can't be opened (its details are damaged)."
        default: return "Something went wrong (\(code))."
        }
    }

    /// Worth trying again: flaky connections and busy servers, not quota/storage/sign-in.
    var isTransient: Bool { status == 0 || status == 408 || status == 429 || (status >= 500 && !code.hasPrefix("storage_")) }
}

final class Api {
    static let base = URL(string: "https://cloud.cellosig.com")!
    var token: String?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func call(_ method: String, _ path: String, json: [String: Any?]? = nil, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: path, relativeTo: Api.base)!)
        req.httpMethod = method
        req.setValue("1", forHTTPHeaderField: "x-cellocloud")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: Api.plain(json))
        } else if let body {
            req.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
            req.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ApiError(code: "offline", status: 0)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ApiError(code: code ?? "http_\(status)", status: status)
        }
        return data
    }

    /// Optionals (and nested field lists) as JSONSerialization wants them: nil → null.
    private static func plain(_ value: Any?) -> Any {
        switch value {
        case .none: return NSNull()
        case let dict as [String: Any?]: return dict.mapValues { plain($0) }
        case let .some(v): return v
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
    private func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
    private func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

    // ---- account ----
    func salt(_ username: String) async throws -> String {
        (object(try await call("GET", "/api/salt?u=\(q(username))"))["salt"] as? String) ?? ""
    }
    func signup(_ fields: [String: Any?]) async throws -> Account { try decode(Account.self, try await call("POST", "/api/signup", json: fields)) }
    func login(_ username: String, authKey: String) async throws -> Account {
        try decode(Account.self, try await call("POST", "/api/login", json: ["username": username, "authKey": authKey]))
    }
    func recoverStart(_ username: String, recAuth: String) async throws -> String {
        (object(try await call("POST", "/api/recover", json: ["username": username, "recAuth": recAuth]))["recWrapped"] as? String) ?? ""
    }
    func recoverFinish(_ username: String, recAuth: String, newPassword: [String: Any?]) async throws -> Account {
        try decode(Account.self, try await call("POST", "/api/recover", json: ["username": username, "recAuth": recAuth, "newPassword": newPassword]))
    }
    func logout() async throws { _ = try await call("POST", "/api/logout", json: [:]) }
    func me() async throws -> Account { try decode(Account.self, try await call("GET", "/api/me")) }
    /// @return the new session token (other devices are signed out).
    func changePassword(authKey: String, newPassword: [String: Any?]) async throws -> String? {
        object(try await call("POST", "/api/me/password", json: ["authKey": authKey, "newPassword": newPassword]))["token"] as? String
    }
    func deleteAccount(authKey: String) async throws { _ = try await call("DELETE", "/api/me", json: ["authKey": authKey]) }

    // ---- files ----
    private struct Nodes: Decodable { let nodes: [Node] }
    func list(_ parent: String?) async throws -> [Node] {
        try decode(Nodes.self, try await call("GET", "/api/nodes" + (parent.map { "?parent=\(q($0))" } ?? ""))).nodes
    }
    func allFiles() async throws -> [Node] { try decode(Nodes.self, try await call("GET", "/api/nodes?all=files")).nodes }
    func create(parent: String?, kind: String, meta: String) async throws -> String {
        (object(try await call("POST", "/api/nodes", json: ["parent": parent, "kind": kind, "meta": meta]))["id"] as? String) ?? ""
    }
    func putChunk(_ id: String, _ n: Int, _ data: Data) async throws { _ = try await call("PUT", "/api/nodes/\(id)/chunks/\(n)", body: data) }
    func getChunk(_ id: String, _ n: Int) async throws -> Data { try await call("GET", "/api/nodes/\(id)/chunks/\(n)") }
    func putThumb(_ id: String, _ data: Data) async throws { _ = try await call("PUT", "/api/nodes/\(id)/thumb", body: data) }
    func getThumb(_ id: String) async throws -> Data { try await call("GET", "/api/nodes/\(id)/thumb") }
    func finish(_ id: String, chunks: Int) async throws { _ = try await call("POST", "/api/nodes/\(id)/finish", json: ["chunks": chunks]) }
    func update(_ id: String, meta: String? = nil, parent: String?? = nil) async throws {
        var fields: [String: Any?] = [:]
        if let meta { fields["meta"] = meta }
        if let parent { fields["parent"] = parent }
        _ = try await call("PATCH", "/api/nodes/\(id)", json: fields)
    }
    func remove(_ id: String) async throws { _ = try await call("DELETE", "/api/nodes/\(id)", json: [:]) }
}

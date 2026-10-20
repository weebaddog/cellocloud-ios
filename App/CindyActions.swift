// What Cindy (the user's assistant on their PC) can do in CelloCloud while she's switched on
// (Settings > Cindy). Everything goes through the CelloCloud server with this app's session, encrypted
// on this iPhone exactly like the app's own uploads.

import Foundation

enum CindyActions {
    @MainActor static func install(_ model: AppModel) {
        Cindy.shared.configure(id: "cellocloud", name: "CelloCloud", actions: all(model))
    }

    private static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    private static func line(_ i: Item) -> String {
        i.isDir ? "📁 \(i.name)" : "\(i.name)  \(i.size.bytes)  \(day(i.date))"
    }

    @MainActor private static func signedIn(_ model: AppModel) throws {
        if !model.signedIn { throw CindyError("Not signed in to CelloCloud on this iPhone") }
    }

    /// "Work/Taxes" → that folder's id (nil = the top level).
    @MainActor private static func folder(_ model: AppModel, _ path: String) async throws -> String? {
        var parent: String?
        for part in path.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let items = try await model.cloud.list(parent)
            guard let f = items.first(where: { $0.isDir && $0.name.caseInsensitiveCompare(part) == .orderedSame })
                ?? items.first(where: { $0.isDir && $0.name.localizedCaseInsensitiveContains(part) }) else {
                throw CindyError("No folder called \(part)")
            }
            parent = f.id
        }
        return parent
    }

    @MainActor private static func allFiles(_ model: AppModel) async throws -> [Item] {
        try model.cloud.decrypt(try await model.cloud.api.allFiles()).filter { !$0.broken }
    }

    @MainActor static func all(_ model: AppModel) -> [Cindy.Action] {
        [
            Cindy.Action(name: "storage", desc: "How much CelloCloud storage is used and left") { _ in
                try signedIn(model)
                let a = try await model.cloud.me()
                return "\(a.used.bytes) of \(a.quota.bytes) used" + (a.storage.map { $0 == "ok" ? "" : " (server storage: \($0))" } ?? "")
            },
            Cindy.Action(name: "list_folder", desc: "What's in a folder",
                         params: ["folder": "folder path like Work/Taxes, empty for the top level"]) { a in
                try signedIn(model)
                let items = try await model.cloud.list(try await folder(model, a.text("folder")))
                return items.prefix(60).map(line).joined(separator: "\n").ifEmpty("That folder is empty")
            },
            Cindy.Action(name: "search_files", desc: "Find files by name", params: ["query": "part of the file name"]) { a in
                try signedIn(model)
                let q = a.text("query")
                return try await allFiles(model).filter { $0.name.localizedCaseInsensitiveContains(q) }
                    .sorted { $0.date > $1.date }.prefix(30).map(line).joined(separator: "\n").ifEmpty("No file names match \(q)")
            },
            Cindy.Action(name: "recent_files", desc: "The newest files", params: ["limit": "how many, default 15"]) { a in
                try signedIn(model)
                return try await allFiles(model).sorted { $0.date > $1.date }.prefix(min(max(a.int("limit", 15), 1), 60))
                    .map(line).joined(separator: "\n").ifEmpty("No files yet")
            },
            Cindy.Action(name: "save_note", desc: "Save a text note to CelloCloud (in the \"Cindy notes\" folder)",
                         params: ["title": "note title", "text": "the note"]) { a in
                try signedIn(model)
                let title = a.text("title").trimmed.isEmpty ? "Note \(day(Date()))" : a.text("title").trimmed
                let name = String(title.replacingOccurrences(of: "/", with: "-").prefix(100)) + ".txt"
                let url = Files.newPickedFile(named: name)
                try Data(a.text("text").utf8).write(to: url)
                let parent = try await model.cloud.folder(named: "Cindy notes")
                model.enqueue(url: url, name: name, type: "text/plain", parent: parent)
                return "Saving \(name) to Cindy notes"
            },
            Cindy.Action(name: "new_folder", desc: "Make a folder", params: ["name": "folder name", "in": "parent folder path, empty for the top level"]) { a in
                try signedIn(model)
                let name = a.text("name").trimmed
                if name.isEmpty { throw CindyError("The folder needs a name") }
                try await model.cloud.newFolder(parent: try await folder(model, a.text("in")), name: name)
                model.changes += 1
                return "Made the folder \(name)"
            },
            Cindy.Action(name: "delete_file", desc: "Delete a file (by its exact name)", params: ["name": "the file's name"], risky: true) { a in
                try signedIn(model)
                let name = a.text("name")
                let matches = try await allFiles(model).filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                guard matches.count == 1, let item = matches.first else {
                    throw CindyError(matches.isEmpty ? "No file called \(name)" : "\(matches.count) files are called \(name); delete it in the app")
                }
                try await model.cloud.delete(item)
                model.changes += 1
                return "Deleted \(item.name)"
            },
            Cindy.Action(name: "camera_backup", desc: "Whether camera backup is on and how it's going") { _ in
                let b = Backup.shared
                return (b.enabled ? "Camera backup is on" : "Camera backup is off") + (b.status.isEmpty ? "" : ": \(b.status)")
            },
        ]
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

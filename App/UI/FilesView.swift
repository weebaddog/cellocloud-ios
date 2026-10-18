import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct FolderRef: Hashable {
    let id: String
    let name: String
}

struct FilesTab: View {
    @State private var path: [FolderRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            FolderView(folder: nil, title: "My files")
                .navigationDestination(for: FolderRef.self) { FolderView(folder: $0.id, title: $0.name) }
        }
        .safeAreaInset(edge: .bottom) { TransfersBar() }
    }
}

struct FolderView: View {
    let folder: String?
    let title: String

    @EnvironmentObject private var model: AppModel
    @State private var items: [Item]?
    @State private var error: String?
    @State private var opening: Item?
    @State private var pickingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @State private var askingFolderName = false
    @State private var renaming: Item?
    @State private var nameText = ""
    @State private var deleting: Item?
    @State private var moving: Item?

    var body: some View {
        List {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if let items {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("This folder is empty", systemImage: "folder")
                    } description: {
                        Text("Upload photos and files with the + button.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(items) { item in
                    row(item)
                        .swipeActions {
                            Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                            Button { nameText = item.name; renaming = item } label: { Label("Rename", systemImage: "pencil") }
                        }
                        .contextMenu {
                            if !item.isDir && !item.broken {
                                Button { opening = item } label: { Label("Open", systemImage: "eye") }
                            }
                            Button { nameText = item.name; renaming = item } label: { Label("Rename", systemImage: "pencil") }
                            Button { moving = item } label: { Label("Move", systemImage: "folder") }
                            Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { pickingPhotos = true } label: { Label("Upload photos & videos", systemImage: "photo.on.rectangle") }
                    Button { pickingFiles = true } label: { Label("Upload files", systemImage: "doc") }
                    Button { nameText = ""; askingFolderName = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add")
            }
        }
        .refreshable { await load() }
        .task(id: model.changes) { await load() }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoSelection, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, picked in
            guard !picked.isEmpty else { return }
            photoSelection = []
            Task { await Picking.uploadPhotos(picked, parent: folder, model: model) }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Picking.uploadFiles(urls, parent: folder, model: model) }
        }
        .modifier(NamePrompt(title: "New folder", isPresented: $askingFolderName, text: $nameText) { name in
            act { try await model.cloud.newFolder(parent: folder, name: name) }
        })
        .modifier(NamePrompt(title: "Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                             text: $nameText) { name in
            if let item = renaming, name != item.name { act { try await model.cloud.rename(item, to: name) } }
        })
        .confirmationDialog(deleting.map { $0.isDir ? "Delete the folder \"\($0.name)\" and everything in it?" : "Delete \"\($0.name)\"?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = deleting { act { try await model.cloud.delete(item); await model.refreshAccount() } }
            }
        } message: { Text("This can't be undone.") }
        .sheet(item: $moving) { item in
            MoveSheet(item: item) { target in act { try await model.cloud.move(item, to: target) } }
        }
        .opensFiles($opening)
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        let content = HStack(spacing: 12) {
            ThumbView(item: item)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(2).foregroundStyle(item.broken ? .secondary : .primary)
                Text(item.isDir ? "Folder" : "\(item.size.bytes) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if item.isDir {
            NavigationLink(value: FolderRef(id: item.id, name: item.name)) { content }
        } else {
            Button { if !item.broken { opening = item } } label: { content }.buttonStyle(.plain)
        }
    }

    private func load() async {
        do {
            items = try await model.cloud.list(folder)
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? ApiError)?.status == 401 { await model.signOut(); return }
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); model.changes += 1 } catch { self.error = error.localizedDescription }
        }
    }
}

/// Pick a folder to move something into.
struct MoveSheet: View {
    let item: Item
    let move: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MoveLevel(item: item, folder: nil, title: "My files", move: { move($0); dismiss() })
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct MoveLevel: View {
    let item: Item
    let folder: String?
    let title: String
    let move: (String?) -> Void
    @EnvironmentObject private var model: AppModel
    @State private var dirs: [Item]?

    var body: some View {
        List {
            if let dirs {
                ForEach(dirs.filter { $0.id != item.id }) { d in
                    NavigationLink { MoveLevel(item: item, folder: d.id, title: d.name, move: move) } label: {
                        Label(d.name, systemImage: "folder.fill")
                    }
                }
                if dirs.isEmpty { Text("No folders here").foregroundStyle(.secondary) }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Move to \(title)") { move(folder) }.bold().disabled(folder == item.node.parent)
            }
        }
        .task { dirs = (try? await model.cloud.list(folder))?.filter(\.isDir) ?? [] }
    }
}

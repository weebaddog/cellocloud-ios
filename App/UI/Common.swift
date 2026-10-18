// Pieces shared by the Files and Photos screens: thumbnails, picking photos/files to upload,
// opening a file (decrypt → QuickLook), and the transfers bar.

import AVFoundation
import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// ---- thumbnails ----
struct ThumbView: View {
    let item: Item
    var square = false
    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(item.isDir ? Color.clear : Color.secondary.opacity(0.12))
                Image(systemName: Files.symbol(for: item))
                    .font(square ? .title2 : .title3)
                    .foregroundStyle(item.isDir ? Color.brand : .secondary)
            }
        }
        .clipped()
        .task(id: item.id) {
            if item.node.thumb { image = await model.cloud.thumbnail(item) }
        }
    }
}

// ---- picking things to upload ----
/// A photo or video from the photo picker, copied to a private file.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try PickedMedia(copying: received.file) }
        FileRepresentation(importedContentType: .image) { received in try PickedMedia(copying: received.file) }
    }

    init(copying source: URL) throws {
        url = Files.newPickedFile(named: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
    }
}

enum Picking {
    /// When a photo or video was taken, from inside the file (the picker doesn't say).
    static func captureDate(_ url: URL, type: String) async -> Date? {
        if type.hasPrefix("image/") {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                  let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return f.date(from: text)
        }
        if type.hasPrefix("video/") {
            return try? await AVURLAsset(url: url).load(.creationDate)?.load(.dateValue)
        }
        return nil
    }

    @MainActor
    static func uploadPhotos(_ items: [PhotosPickerItem], parent: String?, model: AppModel) async {
        for item in items {
            guard let picked = try? await item.loadTransferable(type: PickedMedia.self) else { continue }
            let name = picked.url.lastPathComponent
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) })?.preferredMIMEType
                ?? Files.guessType(name)
            let date = await captureDate(picked.url, type: type)
            model.enqueue(url: picked.url, name: name, type: type, mtime: date, parent: parent)
        }
    }

    @MainActor
    static func uploadFiles(_ urls: [URL], parent: String?, model: AppModel) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = Files.newPickedFile(named: url.lastPathComponent)
            do { try FileManager.default.copyItem(at: url, to: copy) } catch { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            model.enqueue(url: copy, name: url.lastPathComponent, mtime: mtime, parent: parent)
        }
    }
}

// ---- opening a file ----
/// Decrypts and shows a file with QuickLook (photos, videos, PDFs, documents…); its share
/// button saves to Photos or Files or sends it anywhere.
struct OpenFileModifier: ViewModifier {
    @Binding var item: Item?
    @EnvironmentObject private var model: AppModel
    @State private var url: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: item) { _, now in
                guard let now else { return }
                task = Task {
                    do { url = try await model.open(now) } catch is CancellationError {} catch {
                        self.error = error.localizedDescription
                    }
                    item = nil
                }
            }
            .overlay {
                if let item, let t = model.transfers.last(where: { !$0.isUpload && $0.name == item.name }) {
                    VStack(spacing: 12) {
                        Text("Decrypting \(item.name)…").font(.headline).lineLimit(2).multilineTextAlignment(.center)
                        ProgressView(value: t.fraction).frame(width: 200)
                        Button("Cancel", role: .cancel) { task?.cancel() }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(40)
                }
            }
            .quickLookPreview($url)
            .alert("Couldn't open it", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
    }
}

extension View {
    func opensFiles(_ item: Binding<Item?>) -> some View { modifier(OpenFileModifier(item: item)) }
}

// ---- transfers ----
struct TransfersBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let shown = model.transfers.filter(\.isUpload).suffix(3)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.activeTransfers ? "Uploading" : "Uploads finished").font(.subheadline.bold())
                    Spacer()
                    if !model.activeTransfers {
                        Button { model.clearFinished() } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary).accessibilityLabel("Clear")
                    }
                }
                ForEach(Array(shown)) { t in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(t.name).font(.caption).lineLimit(1)
                            Spacer()
                            switch t.state {
                            case .waiting: Text("Waiting").font(.caption2).foregroundStyle(.secondary)
                            case .working: Text("\(Int(t.fraction * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            case .done: Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if case .failed(let why) = t.state {
                            Text(why).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                        } else {
                            ProgressView(value: t.fraction).tint(t.state == .done ? .green : .brand)
                        }
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }
}

/// A one-line text prompt (new folder, rename).
struct NamePrompt: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    @Binding var text: String
    let action: (String) -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            TextField("Name", text: $text)
            Button("Cancel", role: .cancel) {}
            Button("OK") { if !text.trimmed.isEmpty { action(text.trimmed) } }
        }
    }
}

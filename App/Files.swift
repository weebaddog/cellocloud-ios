// Local file helpers: file types, thumbnails made before encrypting, and where decrypted
// copies live while you look at them (deleted on sign-out and on the next launch).

import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum Files {
    static func guessType(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    static func symbol(for item: Item) -> String {
        if item.isDir { return "folder.fill" }
        if item.isImage { return "photo" }
        if item.isVideo { return "film" }
        let t = item.type
        if t == "application/pdf" { return "doc.richtext" }
        if t.hasPrefix("audio/") { return "music.note" }
        if t.hasPrefix("text/") { return "doc.text" }
        if t.contains("zip") || t.contains("compressed") { return "doc.zipper" }
        return "doc"
    }

    // ---- decrypted copies ----
    private static var openedDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opened", isDirectory: true)
    }

    static func openedFile(id: String, name: String) -> URL {
        let dir = openedDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the real name (QuickLook and "Save to Files" use it) but never a path.
        var safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if safe.isEmpty || safe == "." || safe == ".." { safe = "file" }
        return dir.appendingPathComponent(safe)
    }

    static func clearOpened() {
        try? FileManager.default.removeItem(at: openedDir)
        try? FileManager.default.removeItem(at: pickedDir)
    }

    /// Where picked photos and files are copied while they wait to upload.
    static var pickedDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true) }

    static func newPickedFile(named name: String) -> URL {
        let dir = pickedDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name.isEmpty ? "file" : name)
    }

    // ---- thumbnails (480 px JPEG, like the website and Android app) ----
    static func makeThumb(_ url: URL, type: String) async -> Data? {
        let maxSide: CGFloat = 480
        var image: CGImage?
        if type.hasPrefix("image/") {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide,
                ] as CFDictionary)
            }
        } else {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxSide, height: maxSide)
            image = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            if image == nil { image = try? await gen.image(at: .zero).image }
        }
        guard let image else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

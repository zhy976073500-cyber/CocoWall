import Foundation
import ImageIO
import UIKit

/// One imported .tendies archive, as persisted in Documents/imported.json.
/// The archive copy itself lives in Documents/Imported/<storedFileName>;
/// the extracted descriptor tree is only a staging artefact (see
/// TendiesPackage) and is re-created from the copy when a write happens.
struct ImportedWallpaper: Identifiable, Codable, Hashable {
    let id: String
    let descriptorUUID: String
    let descriptorIdentifier: String
    let displayName: String
    let role: String
    /// Original file name at import time (shown in the list).
    let fileName: String
    /// Name of the stored copy inside Documents/Imported/.
    let storedFileName: String
    let importedAt: Date
    /// Downsampled JPEG of the background preview, inside
    /// Documents/Imported/. Optional so imported.json written by older
    /// builds (which lacks these keys) still decodes — synthesized Codable
    /// reads missing optional keys as nil.
    let previewFileName: String?
    /// Unmodified copy of the floating-layer image (alpha preserved),
    /// inside Documents/Imported/.
    let floatingPreviewFileName: String?
}

enum ImportedWallpaperStore {
    static var importedDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var indexURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("imported.json")
    }

    static func load() -> [ImportedWallpaper] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ImportedWallpaper].self, from: data)) ?? []
    }

    static func save(_ records: [ImportedWallpaper]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    enum ImportError: LocalizedError {
        case notTendies
        case invalidPackage(String)
        var errorDescription: String? {
            switch self {
            case .notTendies: return "所选文件不是 .tendies 壁纸包。"
            case .invalidPackage(let why): return "壁纸包无法解析：\(why)"
            }
        }
    }

    /// Copies the picked archive into Documents/Imported/ and parses it with
    /// TendiesPackage to harvest the descriptor metadata. On any parse
    /// failure the stored copy is removed again and the error rethrown.
    static func importArchive(from source: URL) throws -> ImportedWallpaper {
        guard source.pathExtension.lowercased() == "tendies" else {
            throw ImportError.notTendies
        }
        let fm = FileManager.default
        let storedName = UUID().uuidString + ".tendies"
        let stored = importedDirectory.appendingPathComponent(storedName)
        try fm.copyItem(at: source, to: stored)
        do {
            let staging = fm.temporaryDirectory
                .appendingPathComponent("TendiesStage", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let pkg = try TendiesPackage.load(from: stored, into: staging)
            // Previews are best-effort: a package without usable static
            // imagery still imports fine, just without thumbnails.
            let storedBase = (storedName as NSString).deletingPathExtension
            let previews = makePreviews(from: pkg, storedBase: storedBase)
            return ImportedWallpaper(
                id: UUID().uuidString,
                descriptorUUID: pkg.descriptorUUID,
                descriptorIdentifier: pkg.descriptorIdentifier,
                displayName: pkg.displayName,
                role: pkg.role,
                fileName: source.lastPathComponent,
                storedFileName: storedName,
                importedAt: Date(),
                previewFileName: previews.preview,
                floatingPreviewFileName: previews.floating
            )
        } catch let error as TendiesPackage.ParseError {
            try? fm.removeItem(at: stored)
            switch error {
            case .noDescriptor:
                throw ImportError.invalidPackage("包内没有 descriptors 描述符")
            case .multipleDescriptors:
                throw ImportError.invalidPackage("包内含多个描述符，暂只支持单个")
            case .missingWallpaperPlist:
                throw ImportError.invalidPackage("包内缺少 Wallpaper.plist")
            }
        } catch {
            try? fm.removeItem(at: stored)
            throw error
        }
    }

    /// Fallback import path when the picker misbehaves: anything dropped
    /// into the app's Documents folder (Files ▸ On My iPhone ▸ CocoWall,
    /// file sharing is enabled) or Documents/Inbox is imported in place.
    /// Names already imported are skipped; unparsable files are reported
    /// by name rather than aborting the whole scan.
    static func scanDocuments(existing: [ImportedWallpaper])
        -> (added: [ImportedWallpaper], failed: [String]) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var candidates: [URL] = []
        for dir in [docs, docs.appendingPathComponent("Inbox", isDirectory: true)] {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            candidates += entries.filter { $0.pathExtension.lowercased() == "tendies" }
        }
        let known = Set(existing.map(\.fileName))
        var added: [ImportedWallpaper] = []
        var failed: [String] = []
        for url in candidates where !known.contains(url.lastPathComponent) {
            do {
                added.append(try importArchive(from: url))
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        return (added, failed)
    }

    // MARK: - Previews

    /// Full URL of the stored background preview, if the record has one.
    static func previewURL(for record: ImportedWallpaper) -> URL? {
        guard let name = record.previewFileName else { return nil }
        return importedDirectory.appendingPathComponent(name)
    }

    /// Full URL of the stored floating-layer preview, if the record has one.
    static func floatingPreviewURL(for record: ImportedWallpaper) -> URL? {
        guard let name = record.floatingPreviewFileName else { return nil }
        return importedDirectory.appendingPathComponent(name)
    }

    /// Extracts preview files for an already-parsed package into
    /// Documents/Imported/. Never throws: any failure just leaves the
    /// corresponding name nil.
    private static func makePreviews(from pkg: TendiesPackage, storedBase: String)
        -> (preview: String?, floating: String?) {
        let candidates = pkg.previewAssetCandidates()
        var previewName: String?
        var floatingName: String?
        if let floating = candidates.floatings.first {
            // Copied unchanged — re-encoding would kill the alpha channel
            // the floating layer composites with.
            let ext = floating.pathExtension.isEmpty ? "png" : floating.pathExtension
            let name = storedBase + "-floating." + ext
            let dest = importedDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: floating, to: dest)) != nil {
                floatingName = name
            }
        }
        // Still preview: walk the background candidates in score order
        // until one actually converts — the top-scoring file is not
        // guaranteed decodable. If no background converts, fall back to
        // the floating candidates: the preview screen composites the
        // floating layer over black, so a still rendered from it is
        // what the user sees there, and the list thumbnail should match
        // instead of showing a grey placeholder.
        let name = storedBase + "-preview.jpg"
        let dest = importedDirectory.appendingPathComponent(name)
        for source in candidates.backgrounds + candidates.floatings {
            if writePreviewJPEG(from: source, to: dest) {
                previewName = name
                break
            }
        }
        return (previewName, floatingName)
    }

    /// Downsamples `source` to a 900px-max JPEG at `dest`. ImageIO
    /// thumbnails handle heic natively; if that path fails, fall back to
    /// a UIImage resize. Returns false when neither works.
    private static func writePreviewJPEG(from source: URL, to dest: URL) -> Bool {
        if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    imageSource, 0, options as CFDictionary),
               let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85) {
                return (try? data.write(to: dest, options: .atomic)) != nil
            }
        }
        guard let image = UIImage(contentsOfFile: source.path) else { return false }
        let maxSide = max(image.size.width, image.size.height)
        var output = image
        if maxSide > 900 {
            let scale = 900 / maxSide
            let newSize = CGSize(width: image.size.width * scale,
                                 height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            output = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        guard let data = output.jpegData(compressionQuality: 0.85) else { return false }
        return (try? data.write(to: dest, options: .atomic)) != nil
    }

    /// Backfill / repair for a record whose stored still preview is
    /// missing or unusable: re-parses the stored archive and regenerates
    /// the preview files with the current selection logic. The caller
    /// decides when this is needed by looking at the stored file, not at
    /// the record's fields — a record can carry a floating-layer file
    /// (so it looks "has previews") yet still lack a still preview
    /// because its background pick failed to convert at import time.
    /// Returns a copy of the record carrying the regenerated file names
    /// whenever at least one preview file was (re)written — even when
    /// the names are unchanged, so the caller refreshes its rows and
    /// the thumbnails re-read the repaired files.
    static func ensurePreview(for record: ImportedWallpaper) -> ImportedWallpaper? {
        let fm = FileManager.default
        let stored = importedDirectory.appendingPathComponent(record.storedFileName)
        guard fm.fileExists(atPath: stored.path) else { return nil }
        let staging = fm.temporaryDirectory
            .appendingPathComponent("TendiesStage", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let pkg = try? TendiesPackage.load(from: stored, into: staging) else {
            return nil
        }
        let storedBase = (record.storedFileName as NSString).deletingPathExtension
        let previews = makePreviews(from: pkg, storedBase: storedBase)
        guard previews.preview != nil || previews.floating != nil else { return nil }
        let newPreview = previews.preview ?? record.previewFileName
        let newFloating = previews.floating ?? record.floatingPreviewFileName
        return ImportedWallpaper(
            id: record.id,
            descriptorUUID: record.descriptorUUID,
            descriptorIdentifier: record.descriptorIdentifier,
            displayName: record.displayName,
            role: record.role,
            fileName: record.fileName,
            storedFileName: record.storedFileName,
            importedAt: record.importedAt,
            previewFileName: newPreview,
            floatingPreviewFileName: newFloating
        )
    }

    static func removeFile(for record: ImportedWallpaper) {
        let fm = FileManager.default
        try? fm.removeItem(at: importedDirectory.appendingPathComponent(record.storedFileName))
        if let name = record.previewFileName {
            try? fm.removeItem(at: importedDirectory.appendingPathComponent(name))
        }
        if let name = record.floatingPreviewFileName {
            try? fm.removeItem(at: importedDirectory.appendingPathComponent(name))
        }
    }
}

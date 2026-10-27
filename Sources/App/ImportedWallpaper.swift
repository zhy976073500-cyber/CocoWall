import Foundation

/// One imported .tendies archive, as persisted in Documents/imported.json.
/// The archive copy itself lives in Documents/Imported/<storedFileName>;
/// the extracted descriptor tree is only a staging artefact (see
/// TendiesPackage) and is re-created from the copy when a write happens.
struct ImportedWallpaper: Identifiable, Codable {
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
            return ImportedWallpaper(
                id: UUID().uuidString,
                descriptorUUID: pkg.descriptorUUID,
                descriptorIdentifier: pkg.descriptorIdentifier,
                displayName: pkg.displayName,
                role: pkg.role,
                fileName: source.lastPathComponent,
                storedFileName: storedName,
                importedAt: Date()
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

    static func removeFile(for record: ImportedWallpaper) {
        try? FileManager.default.removeItem(
            at: importedDirectory.appendingPathComponent(record.storedFileName))
    }
}

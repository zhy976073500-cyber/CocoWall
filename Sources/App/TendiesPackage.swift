import Foundation
import ZIPFoundation

/// A parsed .tendies archive: one PosterBoard descriptor tree.
/// Mirrors tools/tendies_inspect.py, which is verified against a real sample.
/// Format notes live in SPEC.md.
struct TendiesPackage: Identifiable {
    let id = UUID()
    /// Directory the archive was extracted into (staging area for the writer).
    let extractedURL: URL
    let descriptorUUID: String
    let descriptorIdentifier: String
    let role: String
    let displayName: String
    let family: String?
    let logicalScreenClass: String?
    let backgroundCA: String?
    let floatingCA: String?

    enum ParseError: Error {
        case noDescriptor, multipleDescriptors, missingWallpaperPlist
    }

    /// Extracts the archive into `staging` and reads its descriptor metadata.
    static func load(from archiveURL: URL, into staging: URL) throws -> TendiesPackage {
        let fm = FileManager.default
        let work = staging.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.unzipItem(at: archiveURL, to: work)

        let descriptorsRoot = work.appendingPathComponent("descriptors")
        let uuids = try fm.contentsOfDirectory(atPath: descriptorsRoot.path)
            .filter { !$0.hasPrefix(".") }
        guard uuids.count == 1, let uuid = uuids.first else {
            throw uuids.isEmpty ? ParseError.noDescriptor : ParseError.multipleDescriptors
        }
        let root = descriptorsRoot.appendingPathComponent(uuid)

        func text(_ name: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(name),
                         encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        // Find the single .wallpaper directory under versions/<v>/contents/.
        let versions = root.appendingPathComponent("versions")
        var wallpaperDir: URL?
        if let vlist = try? fm.contentsOfDirectory(atPath: versions.path) {
            for v in vlist {
                let contents = versions.appendingPathComponent("\(v)/contents")
                if let entries = try? fm.contentsOfDirectory(atPath: contents.path) {
                    for e in entries where e.hasSuffix(".wallpaper") {
                        wallpaperDir = contents.appendingPathComponent(e)
                    }
                }
            }
        }
        guard let wpDir = wallpaperDir else { throw ParseError.missingWallpaperPlist }

        let plistURL = wpDir.appendingPathComponent("Wallpaper.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] ?? [:]
        let assets = (plist["assets"] as? [String: Any])?["lockAndHome"] as? [String: Any]
        let def = assets?["default"] as? [String: Any]

        return TendiesPackage(
            extractedURL: work,
            descriptorUUID: uuid,
            descriptorIdentifier: text("com.apple.posterkit.provider.descriptor.identifier"),
            role: text("com.apple.posterkit.role.identifier"),
            displayName: (plist["name"] as? String) ?? uuid,
            family: plist["family"] as? String,
            logicalScreenClass: plist["logicalScreenClass"] as? String,
            backgroundCA: def?["backgroundAnimationFileName"] as? String,
            floatingCA: def?["floatingAnimationFileNameKey"] as? String
        )
    }
}

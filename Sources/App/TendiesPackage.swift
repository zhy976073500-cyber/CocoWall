import Foundation
import ZIPFoundation

/// A parsed .tendies archive: one PosterBoard descriptor tree.
/// Mirrors tools/tendies_inspect.py, which is verified against a real sample.
/// Format notes live in SPEC.md.
struct TendiesPackage: Identifiable {
    let id = UUID()
    /// Directory the archive was extracted into (staging area for the writer).
    let extractedURL: URL
    /// The single .wallpaper directory inside the descriptor tree.
    let wallpaperDirectory: URL
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
            wallpaperDirectory: wpDir,
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

    /// Finds the best static preview images in the extracted tree.
    /// Heuristic mirrors the proven one in AirCard-iOS (TendiesEngine):
    /// every image file is scored by what its path looks like — proxy /
    /// adjusted renders and background / settling stills are the frames
    /// PosterBoard itself would show; anything inside a .ca bundle is a
    /// layer asset and ranks lower. `floating` is the best image whose
    /// path mentions "floating"; `background` is the best of the rest
    /// (nil when the package only ships floating imagery, e.g. a purely
    /// programmatic CA wallpaper, in which case both may be nil).
    func previewAssets() -> (background: URL?, floating: URL?) {
        let candidates = previewAssetCandidates()
        return (candidates.backgrounds.first, candidates.floatings.first)
    }

    /// The same scoring as previewAssets(), but returns every candidate
    /// in best-first order instead of only the winners. Callers that
    /// convert the pick into a thumbnail need the runners-up: the top
    /// scoring file can turn out to be one ImageIO cannot decode (an
    /// exotic encoding inside a .ca bundle, say), and the next
    /// candidate down is usually a perfectly usable still.
    func previewAssetCandidates() -> (backgrounds: [URL], floatings: [URL]) {
        let fm = FileManager.default
        let imageExtensions: Set<String> = ["heic", "png", "jpg", "jpeg"]
        var scored: [(url: URL, score: Int, size: Int64)] = []
        guard let enumerator = fm.enumerator(
            at: extractedURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []) else { return ([], []) }
        while let item = enumerator.nextObject() as? URL {
            let pathLower = item.path.lowercased()
            if pathLower.contains("__macosx") { continue }
            if item.lastPathComponent == ".DS_Store" { continue }
            guard imageExtensions.contains(item.pathExtension.lowercased()) else { continue }
            var score = 10
            if pathLower.contains("proxy") || pathLower.contains("adjusted") { score += 90 }
            if pathLower.contains("background") || pathLower.contains("settling") { score += 70 }
            if pathLower.contains("preview") || pathLower.contains("thumb") { score += 50 }
            if pathLower.contains("asset.resource") { score += 40 }
            if pathLower.contains(".ca/") { score += 20 }
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize.map(Int64.init) ?? 0
            scored.append((url: item, score: score, size: size))
        }
        func ranked(_ candidates: [(url: URL, score: Int, size: Int64)]) -> [URL] {
            candidates.sorted { a, b in
                a.score != b.score ? a.score > b.score : a.size > b.size
            }.map(\.url)
        }
        let floatings = ranked(scored.filter { $0.url.path.lowercased().contains("floating") })
        let backgrounds = ranked(scored.filter { !$0.url.path.lowercased().contains("floating") })
        return (backgrounds, floatings)
    }
}

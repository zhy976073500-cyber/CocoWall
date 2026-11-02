//
//  TendiesEngine.swift
//  AirCard-iOS
//
//  Engine for parsing, extracting, and flashing PosterBoard .tendies wallpapers.
//

import UIKit
import Foundation
import AirliftFFI

public final class TendiesEngine {
    public static let shared = TendiesEngine()

    public static var tendiesStorageDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tendies", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Import & Parse

    public func importTendie(from sourceURL: URL) async throws -> TendieItem {
        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = sourceURL.lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        let destinationURL = Self.tendiesStorageDirectory.appendingPathComponent(fileName)

        if sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                let fileData = try Data(contentsOf: sourceURL)
                try fileData.write(to: destinationURL, options: .atomic)
            }
        }

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw NSError(
                domain: "TendiesEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to store wallpaper file at \(destinationURL.path)"]
            )
        }

        // Staging extraction to inspect contents
        let tempExtractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendie_inspect_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempExtractDir)
        }

        let extractRC = destinationURL.path.withCString { arcC in
            tempExtractDir.path.withCString { dstC in
                al_zip_extract_all(arcC, dstC)
            }
        }

        guard extractRC == 0 else {
            throw NSError(
                domain: "TendiesEngine",
                code: Int(extractRC),
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract .tendies zip archive (code \(extractRC))"]
            )
        }

        // Analyze file structure
        var isContainer = false
        var unsafeContainer = false
        var descriptorCount = 0
        var posterType: TendiePosterType = .collections

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: tempExtractDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var candidateImages: [(url: URL, score: Int)] = []

        while let itemURL = enumerator?.nextObject() as? URL {
            let pathLower = itemURL.path.lowercased()
            let nameLower = itemURL.lastPathComponent.lowercased()

            if pathLower.contains("__macosx") || nameLower == ".ds_store" {
                continue
            }

            if pathLower.contains("/container/") || pathLower.hasSuffix("/container") {
                isContainer = true
                if nameLower.contains("pbfposterextensiondatastoresqlitedatabase.sqlite3") {
                    unsafeContainer = true
                }
            }

            // Image discovery
            let ext = itemURL.pathExtension.lowercased()
            if ["heic", "png", "jpg", "jpeg"].contains(ext) {
                var score = 10
                if pathLower.contains("proxy") || pathLower.contains("adjusted") {
                    score += 90
                } else if pathLower.contains("background") || pathLower.contains("settling") {
                    score += 70
                } else if pathLower.contains("preview") || pathLower.contains("thumb") {
                    score += 50
                } else if pathLower.contains("asset.resource") {
                    score += 40
                }
                candidateImages.append((itemURL, score))
            }
        }

        // Use findDescriptorsWithExtensions to get accurate descriptor count and poster type
        let foundDescriptors = findDescriptorsWithExtensions(in: tempExtractDir, defaultExt: "com.apple.WallpaperKit.CollectionsPoster")
        descriptorCount = max(foundDescriptors.count, 1)

        if let first = foundDescriptors.first {
            if first.ext == "com.apple.MercuryPoster" || first.ext == "com.apple.Posters.MercuryPosterApp" {
                posterType = .mercury
            } else if first.ext == "com.apple.PhotosUIPrivate.PhotosPosterProvider" {
                posterType = .suggestedPhotos
            } else {
                posterType = isContainer ? .container : .collections
            }
        } else if isContainer {
            posterType = .container
        }

        // Pick best preview image
        candidateImages.sort { $0.score > $1.score }
        var previewData: Data? = nil

        for candidate in candidateImages {
            if let img = UIImage(contentsOfFile: candidate.url.path) {
                let thumb = self.downsample(image: img, maxDimension: 600)
                if let jpeg = thumb.jpegData(compressionQuality: 0.85) {
                    previewData = jpeg
                    break
                }
            }
        }

        return TendieItem(
            name: baseName,
            fileName: fileName,
            relativePath: fileName,
            isContainer: isContainer,
            unsafeContainer: unsafeContainer,
            descriptorCount: descriptorCount,
            posterType: posterType,
            previewImageData: previewData,
            dateImported: Date(),
            isSelected: true
        )
    }

    // MARK: - Downsample Thumbnail

    private func downsample(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Auto-detect PosterBoard Container

    public func detectPosterBoardContainer(pairingPath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outContainer: UnsafeMutablePointer<CChar>? = nil
                var outError: UnsafeMutablePointer<CChar>? = nil

                let rc = pairingPath.withCString { pairC in
                    "com.apple.PosterBoard".withCString { bundleC in
                        al_find_app_container(pairC, bundleC, nil, nil, &outContainer, &outError)
                    }
                }

                if rc == 0, let p = outContainer {
                    let containerStr = String(cString: p)
                    al_string_free(p)
                    continuation.resume(returning: containerStr)
                } else {
                    let errStr = outError.flatMap { p in
                        let s = String(cString: p)
                        al_string_free(p)
                        return s
                    } ?? "Failed to find PosterBoard container"
                    continuation.resume(throwing: NSError(
                        domain: "TendiesEngine",
                        code: Int(rc),
                        userInfo: [NSLocalizedDescriptionKey: errStr]
                    ))
                }
            }
        }
    }

    // MARK: - Send Respring Signal via Tunnel

    public func sendRespringSignal(pairingPath: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pC in
                    al_device_respring(pC, nil, nil, &outError)
                }
                if let p = outError {
                    al_string_free(p)
                }
                continuation.resume(returning: rc == 0)
            }
        }
    }

    // MARK: - Flash Tendies to Device

    public func flashTendies(
        items: [TendieItem],
        containerPath: String,
        resetProtections: Bool,
        pairingPath: String,
        log: @escaping (String) -> Void,
        progress: @escaping (Double) -> Void,
        onDescriptorInstalled: ((TendieItem, String, String) -> Void)? = nil
    ) async throws {
        guard !items.isEmpty else {
            log("⚠️ No wallpapers selected to flash")
            return
        }

        var normalizedContainer = containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedContainer.hasSuffix("/") {
            normalizedContainer = String(normalizedContainer.dropLast())
        }
        if normalizedContainer.isEmpty {
            throw NSError(
                domain: "TendiesEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PosterBoard Container path is required."]
            )
        }

        let majorVer = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let structVersion = (majorVer <= 16) ? 59 : 61

        log("🚀 Starting PosterBoard injection into \(normalizedContainer)")
        log("ℹ️ Target PosterBoard structure version: \(structVersion) (iOS \(majorVer))")

        let totalItems = Double(items.count)

        // Run #146: round stage timing (see SPEC #146).
        let engineStart = DispatchTime.now()
        let stageTotals = FlashStageTotals()

        // Reload-preferences payload, staged once up front. As of run
        // #112 it is written inside each descriptor's install
        // transaction (Walllive shape: primary spot + combined
        // preferences in one Books snapshot/restore cycle), not in a
        // separate phase after the loop.
        let stagePrefDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendie_pref_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagePrefDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagePrefDir)
        }

        let prefPlistURL = stagePrefDir.appendingPathComponent("com.apple.PosterBoard.unprotectedUserDefaults.plist")
        let prefDict: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": true,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster",
                "com.apple.MercuryPoster",
                "com.apple.Posters.MercuryPosterApp",
                "com.apple.PhotosUIPrivate.PhotosPosterProvider"
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
            ]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: prefDict, format: .binary, options: 0)
        try plistData.write(to: prefPlistURL)

        // Preference targets: PosterBoard container, then the mobile
        // global preferences the system daemon looks up (Walllive's
        // primary + global pair, written combined by the transaction).
        let targetPrefDir = "\(normalizedContainer)/Library/Preferences"
        let mobilePrefDir = "/var/mobile/Library/Preferences"

        for (itemIndex, item) in items.enumerated() {
            // Run #146: per-package wall time （本地准备 + 全部事务）.
            let itemStart = DispatchTime.now()
            log("\n📦 [\(itemIndex + 1)/\(items.count)] Processing '\(item.name)'…")

            let tempStageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tendie_flash_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempStageDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempStageDir)
            }

            let extractRC = item.fileURL.path.withCString { arcC in
                tempStageDir.path.withCString { dstC in
                    al_zip_extract_all(arcC, dstC)
                }
            }
            guard extractRC == 0 else {
                log("❌ Failed to extract '\(item.name)'")
                continue
            }

            log("  🖼 Locating wallpaper descriptors…")
            let descriptors = findDescriptorsWithExtensions(in: tempStageDir, defaultExt: item.posterType.extensionBundleId)
            log("  ✨ Found \(descriptors.count) descriptor(s) to install")

            for (descIndex, descItem) in descriptors.enumerated() {
                let targetUUID = UUID().uuidString.uppercased()
                log("  [\(descIndex + 1)/\(descriptors.count)] Descriptor \(targetUUID) for \(descItem.ext)…")

                // Run #122: rewrite the descriptor's packaged
                // identifier set to a fresh, self-consistent set —
                // unconditionally (the old code skipped packages
                // carrying suggestionMetadata, which are exactly the
                // ones whose full identifier set can collide).
                rewriteDescriptorIdentifiers(in: descItem.url, packageName: item.name, log: log)

                // 1. Primary destination: matches descriptor extension bundle ID.
                //    Run #112: installed via the Walllive-shaped transaction —
                //    primary spot only + combined reload-preferences write in
                //    a single Books snapshot/restore cycle (see Rust core).
                let primaryParentDir = "\(normalizedContainer)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(descItem.ext)/descriptors"
                try await injectPrimaryTransaction(
                    folderURL: descItem.url,
                    targetParentDir: primaryParentDir,
                    destName: targetUUID,
                    prefFileURL: prefPlistURL,
                    prefTargetA: targetPrefDir,
                    prefTargetB: mobilePrefDir,
                    pairingPath: pairingPath,
                    packageLabel: item.name,
                    stageTotals: stageTotals,
                    log: log
                )

                // Run #124: report each descriptor the moment its
                // install transaction has succeeded, so the caller
                // can register store UUID -> source library item
                // (the cleanup list's authoritative thumbnail /
                // display-name source). A throw above skips this —
                // only descriptors that actually landed register.
                onDescriptorInstalled?(item, descItem.ext, targetUUID)

                // 2. Mirror destination (modern .Posters.<Name>App container):
                //    deferred this transaction, mirroring Walllive's
                //    primary_only install shape (install.result paths=1).
                var modernExt: String? = nil
                if descItem.ext == "com.apple.WallpaperKit.CollectionsPoster" {
                    modernExt = "com.apple.Posters.CollectionsPosterApp"
                } else if descItem.ext == "com.apple.MercuryPoster" {
                    modernExt = "com.apple.Posters.MercuryPosterApp"
                }

                if let modernExt = modernExt, majorVer >= 18 {
                    log("    airlift: comparison mode=primary_only mirror_deferred=1 target=\(modernExt)")
                }
            }

            // Run #146: per-package total （本地解包/定位/改标识 + 事务）.
            log("[计时] 刷入·单包合计 \(cwStageText(cwStageMS(itemStart, DispatchTime.now()))) ms（\(item.name)）")

            progress(Double(itemIndex + 1) / (totalItems + 1))
        }

        // Run #112: the reload preferences are no longer a separate
        // phase — each descriptor's install transaction writes them
        // combined (both targets, one sync) before its Books restore.

        // Run #146: round totals from the per-transaction stage timers.
        if stageTotals.transactions > 0 {
            log("[计时] 刷入·建连合计 \(cwStageText(stageTotals.connectMS)) ms")
            log("[计时] 刷入·暂存合计 \(cwStageText(stageTotals.stageMS)) ms（归档共 \(cwStageText(stageTotals.stageBytes)) 字节）")
            log("[计时] 刷入·等同步合计 \(cwStageText(stageTotals.syncMS)) ms")
            log("[计时] 刷入·写刷新偏好合计 \(cwStageText(stageTotals.preferencesMS)) ms")
        }
        log("[计时] 刷入·引擎合计 \(cwStageText(cwStageMS(engineStart, DispatchTime.now()))) ms（\(items.count) 包）")

        progress(1.0)
        log("\n🎉 All wallpapers injected successfully! Open Lock Screen settings or long-press lockscreen to choose your new wallpaper.")
    }

    // MARK: - Tree Writer Helper

    private func writeDirectoryTree(
        sourceBaseDir: URL,
        targetBaseDir: String,
        pairingPath: String,
        log: @escaping (String) -> Void
    ) async throws {
        let fileManager = FileManager.default

        // Gather all directories that contain files
        var dirsToWrite: Set<URL> = []
        if let enumerator = fileManager.enumerator(
            at: sourceBaseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let itemURL = enumerator.nextObject() as? URL {
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir {
                    dirsToWrite.insert(itemURL.deletingLastPathComponent())
                }
            }
        }

        // If no subfiles, write the source dir itself if not empty
        if dirsToWrite.isEmpty {
            let files = (try? fileManager.contentsOfDirectory(atPath: sourceBaseDir.path)) ?? []
            if !files.isEmpty {
                dirsToWrite.insert(sourceBaseDir)
            }
        }

        let canonicalSource = sourceBaseDir.resolvingSymlinksInPath().path

        for dir in dirsToWrite {
            let canonicalDir = dir.resolvingSymlinksInPath().path
            var relPath = ""
            if canonicalDir.hasPrefix(canonicalSource) {
                relPath = String(canonicalDir.dropFirst(canonicalSource.count))
                relPath = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }

            let targetDir: String
            if relPath.isEmpty {
                targetDir = targetBaseDir
            } else {
                targetDir = "\(targetBaseDir)/\(relPath)"
            }

            log("  Writing to \(targetDir)…")

            var writeOk = false
            var errDesc: String? = nil

            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    var outError: UnsafeMutablePointer<CChar>? = nil
                    let rc = pairingPath.withCString { pairC in
                        dir.path.withCString { srcC in
                            targetDir.withCString { tgtC in
                                al_exploit_write_dir(pairC, srcC, tgtC, { _, msg in
                                    guard let msg = msg else { return }
                                    let line = String(cString: msg)
                                    DispatchQueue.main.async {
                                        AppViewModel.shared?.tendiesFlashLog.append("    " + line)
                                    }
                                }, nil, &outError)
                            }
                        }
                    }
                    if let p = outError {
                        errDesc = String(cString: p)
                        al_string_free(p)
                    }
                    writeOk = (rc == 0)
                    cont.resume()
                }
            }

            if !writeOk {
                throw NSError(
                    domain: "TendiesEngine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to write directory: \(errDesc ?? "exploit error")"]
                )
            }
        }
    }

    // MARK: - Descriptor Identifier Rewrite (run #122)

    /// Rewrites the descriptor's packaged identifier set to a fresh,
    /// self-consistent set before installation, and logs the mapping.
    ///
    /// Why: PosterBoard keys a collection by the identifiers INSIDE
    /// the descriptor — not by the store folder's UUID, which is
    /// already fresh per flash. Identifier landing points, enumerated
    /// on the two sample packages in the repo (identifiers "9998"
    /// without and "7400" with suggestion metadata):
    ///   1. `com.apple.posterkit.provider.descriptor.identifier` —
    ///      plain text file, content is exactly the base ("7400").
    ///   2. `…identifierURL.suggestionMetadata.plist` (keyed archive,
    ///      only on pre-packaged descriptors): the gallery item's
    ///      `descriptorIdentifier` string is base + suffix
    ///      ("7400.DYNAMIC"); its `identifier` string is a UUID.
    ///   3. `versions/*/contents/<pkg>.wallpaper/Wallpaper.plist`:
    ///      `identifier` (top level and under assets.lockAndHome.
    ///      default) as INTEGERS, plus the `*AnimationFileName*`
    ///      strings naming the .ca bundles ("7400.…_Background-…ca").
    ///   4. `versions/*/contents/com.apple.posterkit.provider.
    ///      contents.userInfo`: `wallpaperRepresentingIdentifier`
    ///      (string, the base) and `wallpaperRepresentingFileName`
    ///      (the .wallpaper directory name).
    ///   5. Path components: the `<base>.….wallpaper` directory and
    ///      the `<base>.…_*.ca` directories inside it carry the base
    ///      as a name prefix and are referenced by 3/4.
    /// Packages authored by the same pipeline ship the SAME set, so
    /// a second install reads as the same collection and the system
    /// chooser shows only the newest (run #114/#115 finding). The
    /// pre-#122 code returned early whenever a suggestionMetadata
    /// plist existed — exactly the packages carrying the full set —
    /// and randomized only a subset of fields otherwise.
    ///
    /// Method: the fresh base has the SAME digit count as the old
    /// one, so every derived string keeps its length. Plain plists
    /// are rewritten structurally (string rule everywhere; the
    /// integer rule only for values under an `identifier` key, the
    /// two enumerated integer spots). Keyed archives ($archiver
    /// plists, whose UID graph must not be round-tripped) are
    /// rewritten by length-preserving byte replacement of the exact
    /// identifier strings (UTF-8 and UTF-16BE forms). The
    /// suggestionMetadata gallery UUID is re-rolled the same way.
    /// Directory/file names carrying the old prefix are renamed to
    /// match. Nothing else is touched: provider bundle ids, role
    /// strings, class names and unrelated numbers are not the base.
    ///
    /// Guard (the old code's documented hazard, kept): a descriptor
    /// whose identifier set has no numeric base is a system
    /// extension package whose identifier is a required string
    /// SYMBOL (Mercury "v6x.colorA", Unity2025, Kaleidoscope) —
    /// rewriting it would break extension lookup. Such packages are
    /// skipped with a log line; they are not CollectionsPoster
    /// .tendies packages.
    func rewriteDescriptorIdentifiers(in folderURL: URL, packageName: String, log: @escaping (String) -> Void) {
        let fm = FileManager.default
        let descIdURL = folderURL.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
        let suggestionURL = folderURL.appendingPathComponent("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")

        func isNumericBase(_ s: String) -> Bool {
            s.count >= 3 && s.allSatisfy { $0.isNumber }
        }
        func parsePlist(_ url: URL) -> (root: Any, format: PropertyListSerialization.PropertyListFormat)? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else { return nil }
            return (root, format)
        }
        func collectStrings(_ value: Any, into set: inout Set<String>) {
            switch value {
            case let s as String: set.insert(s)
            case let d as [String: Any]: for v in d.values { collectStrings(v, into: &set) }
            case let a as [Any]: for v in a { collectStrings(v, into: &set) }
            default: break
            }
        }

        // --- Discover the old identifier set -------------------------
        var oldBase: String? = nil
        if let raw = try? String(contentsOf: descIdURL, encoding: .utf8) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isNumericBase(t) { oldBase = t }
        }
        // Versions subtree: Wallpaper.plist `identifier` (Int) and
        // userInfo `wallpaperRepresentingIdentifier` as fallbacks.
        var versionFiles: [URL] = []
        if let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: []) {
            while let u = en.nextObject() as? URL {
                if u.path.contains("__MACOSX") { continue }
                versionFiles.append(u)
            }
        }
        if oldBase == nil {
            for u in versionFiles where u.lastPathComponent == "Wallpaper.plist" {
                if let (root, _) = parsePlist(u), let dict = root as? [String: Any] {
                    if let n = dict["identifier"] as? NSNumber, isNumericBase("\(n.intValue)") {
                        oldBase = "\(n.intValue)"; break
                    }
                    if let s = dict["identifier"] as? String, isNumericBase(s) {
                        oldBase = s; break
                    }
                }
            }
        }
        if oldBase == nil {
            for u in versionFiles where u.lastPathComponent == "com.apple.posterkit.provider.contents.userInfo" {
                if let (root, _) = parsePlist(u), let dict = root as? [String: Any],
                   let s = dict["wallpaperRepresentingIdentifier"] as? String, isNumericBase(s) {
                    oldBase = s; break
                }
            }
        }
        // Suggestion metadata: a "<digits>.<suffix>" string.
        var suggestionStrings: Set<String> = []
        if let (root, _) = parsePlist(suggestionURL) {
            collectStrings(root, into: &suggestionStrings)
            if oldBase == nil {
                for s in suggestionStrings {
                    if let dot = s.firstIndex(of: ".") {
                        let head = String(s[s.startIndex..<dot])
                        if isNumericBase(head) { oldBase = head; break }
                    }
                }
            }
        }

        guard let old = oldBase, let oldInt = Int(old) else {
            log("    airlift: airlift.identifiers.rewritten package=\(packageName) skipped=no_numeric_base")
            return
        }

        // Fresh base, same digit count (keeps every derived string
        // the same length for the keyed-archive byte replacement).
        var newInt = oldInt
        while newInt == oldInt {
            if old.count <= 4 {
                newInt = Int.random(in: 1000...9999)
            } else {
                newInt = Int.random(in: 10000...99999)
            }
        }
        let new = "\(newInt)"

        func mapString(_ s: String) -> String {
            if s == old { return new }
            if s.hasPrefix(old + ".") { return new + String(s.dropFirst(old.count)) }
            return s
        }
        func isUUIDString(_ s: String) -> Bool {
            s.count == 36 && UUID(uuidString: s) != nil
        }

        // Old identifier strings (for the log + byte replacement).
        var oldSet: Set<String> = [old]
        for u in versionFiles {
            if let (root, _) = parsePlist(u) {
                var strings = Set<String>()
                collectStrings(root, into: &strings)
                for s in strings where s == old || s.hasPrefix(old + ".") { oldSet.insert(s) }
            }
        }
        for s in suggestionStrings where s == old || s.hasPrefix(old + ".") { oldSet.insert(s) }
        // Suggestion gallery UUID(s): re-rolled, suggestion file only.
        var uuidMap: [String: String] = [:]
        for s in suggestionStrings where isUUIDString(s) {
            uuidMap[s] = UUID().uuidString.uppercased()
        }

        // --- Apply ---------------------------------------------------
        // 1. descriptor.identifier text file.
        if let raw = try? String(contentsOf: descIdURL, encoding: .utf8) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let mapped = mapString(t)
            if mapped != t {
                try? mapped.data(using: .utf8)?.write(to: descIdURL)
            }
        }

        // 2. Every other file: structural rewrite for plain plists,
        //    length-preserving byte replacement for keyed archives.
        func rewriteValue(_ value: Any, key: String?, changed: inout Bool) -> Any {
            switch value {
            case let s as String:
                let m = mapString(s)
                if m != s { changed = true }
                return m
            case let n as NSNumber:
                if (key == "identifier" || key == "wallpaperRepresentingIdentifier"),
                   n.doubleValue == Double(oldInt),
                   n.doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                    changed = true
                    return NSNumber(value: newInt)
                }
                return value
            case let d as [String: Any]:
                var out = [String: Any](minimumCapacity: d.count)
                for (k, v) in d { out[k] = rewriteValue(v, key: k, changed: &changed) }
                return out
            case let a as [Any]:
                return a.map { rewriteValue($0, key: key, changed: &changed) }
            default:
                return value
            }
        }
        func byteReplace(_ url: URL, extraPairs: [String: String]) {
            guard var data = try? Data(contentsOf: url) else { return }
            var pairs: [String: String] = [:]
            for s in oldSet { pairs[s] = mapString(s) }
            for (k, v) in extraPairs { pairs[k] = v }
            var touched = false
            for (oldS, newS) in pairs where oldS != newS && oldS.count == newS.count {
                for encoding in [String.Encoding.utf8, .utf16BigEndian] {
                    guard let oldBytes = oldS.data(using: encoding),
                          let newBytes = newS.data(using: encoding),
                          oldBytes.count == newBytes.count, !oldBytes.isEmpty else { continue }
                    var replaced = Data()
                    var rest = data
                    var hit = false
                    while let range = rest.range(of: oldBytes) {
                        hit = true
                        replaced.append(rest[..<range.lowerBound])
                        replaced.append(newBytes)
                        rest = rest[range.upperBound...]
                    }
                    if hit {
                        replaced.append(rest)
                        data = replaced
                        touched = true
                    }
                }
            }
            if touched { try? data.write(to: url) }
        }

        for u in versionFiles where u != descIdURL {
            // .DS_Store is Finder metadata that records the OLD
            // directory names verbatim — the one place the old
            // identifier would otherwise linger in the installed
            // tree. It is meaningless to PosterBoard; drop it.
            if u.lastPathComponent == ".DS_Store" {
                try? fm.removeItem(at: u)
                continue
            }
            guard let (root, format) = parsePlist(u) else { continue }
            let isArchive = (root as? [String: Any])?["$archiver"] != nil
            if isArchive {
                byteReplace(u, extraPairs: u == suggestionURL ? uuidMap : [:])
            } else {
                var changed = false
                let rewritten = rewriteValue(root, key: nil, changed: &changed)
                if changed,
                   let out = try? PropertyListSerialization.data(fromPropertyList: rewritten, format: format, options: 0) {
                    try? out.write(to: u)
                }
            }
        }

        // 3. Rename path components carrying the old prefix,
        //    deepest first so parents move after their children.
        var renameCandidates: [URL] = []
        if let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil, options: []) {
            while let u = en.nextObject() as? URL {
                if u.path.contains("__MACOSX") { continue }
                if u.lastPathComponent.hasPrefix(old + ".") {
                    renameCandidates.append(u)
                }
            }
        }
        for u in renameCandidates.sorted(by: { $0.path.count > $1.path.count }) {
            let newName = new + String(u.lastPathComponent.dropFirst(old.count))
            let dest = u.deletingLastPathComponent().appendingPathComponent(newName)
            try? fm.moveItem(at: u, to: dest)
        }

        let oldDesc = oldSet.sorted().joined(separator: ",")
        let newDesc = oldSet.map { mapString($0) }.sorted().joined(separator: ",")
        let uuidDesc = uuidMap.isEmpty ? "" : " suggestionUUID=\(uuidMap.keys.sorted().joined(separator: ","))->\(uuidMap.values.sorted().joined(separator: ","))"
        log("    airlift: airlift.identifiers.rewritten package=\(packageName) old=\(oldDesc) new=\(newDesc)\(uuidDesc)")
    }

    // MARK: - Folder Injector Helper (Single Atomic Move via AirTraffic)

    private func injectDescriptorFolder(
        folderURL: URL,
        targetParentDir: String,
        destName: String,
        pairingPath: String,
        log: @escaping (String) -> Void
    ) async throws {
        log("  📦 Injecting '\(destName)' into \(targetParentDir)…")
        var errDesc: String? = nil
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pairC in
                    folderURL.path.withCString { folderC in
                        targetParentDir.withCString { parentC in
                            destName.withCString { destC in
                                al_exploit_inject_folder(
                                    pairC,
                                    folderC,
                                    parentC,
                                    destC,
                                    { _, msg in
                                        guard let msg = msg else { return }
                                        let line = String(cString: msg)
                                        DispatchQueue.main.async {
                                            AppViewModel.shared?.tendiesFlashLog.append("    " + line)
                                        }
                                    },
                                    nil,
                                    &outError
                                )
                            }
                        }
                    }
                }
                if let p = outError {
                    errDesc = String(cString: p)
                    al_string_free(p)
                }
                cont.resume(returning: rc == 0)
            }
        }

        if !ok {
            throw NSError(
                domain: "TendiesEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to inject descriptor: \(errDesc ?? "exploit error")"]
            )
        }
    }

    // MARK: - Run #146 flash-transaction stage timing (diagnostic only)

    /// Records when the Rust flash transaction's stage-marker log
    /// lines reach the FFI callback, so the stages inside the single
    /// FFI call （建连/暂存/等同步/写偏好） can be bracketed from
    /// Swift without touching the core. First occurrence wins; a
    /// stage whose markers never arrive yields no segment — numbers
    /// are never fabricated. Written only from the FFI-calling thread
    /// while the call is in flight, read after it returns there.
    final class FlashTransactionStageTimer {
        let start = DispatchTime.now()
        private(set) var afcConnected: DispatchTime?
        private(set) var archiveSized: DispatchTime?
        private(set) var archiveBytes: Int?
        private(set) var stagedVerified: DispatchTime?
        private(set) var descriptorDone: DispatchTime?
        private(set) var preferencesBegin: DispatchTime?
        private(set) var preferencesEnd: DispatchTime?

        func observe(_ line: String) {
            let now = DispatchTime.now()
            if afcConnected == nil, line.contains("airlift: AFC client connected") {
                afcConnected = now
            }
            if archiveSized == nil, line.contains("airlift: folder archive size: ") {
                archiveSized = now
                if let range = line.range(of: "folder archive size: ") {
                    archiveBytes = Int(line[range.upperBound...].prefix { $0.isNumber })
                }
            }
            if stagedVerified == nil, line.contains("airlift: staged folder verified in AFC") {
                stagedVerified = now
            }
            if descriptorDone == nil, line.contains("airlift.install.descriptor.completed") {
                descriptorDone = now
            }
            if preferencesBegin == nil, line.contains("airlift.preferences.combined.begin") {
                preferencesBegin = now
            }
            if preferencesEnd == nil, line.contains("airlift.install.preferences.primary.end") {
                preferencesEnd = now
            }
        }
    }

    /// Running totals across one flashTendies round, fed by each
    /// transaction's stage timer; the round's 合计 lines print from
    /// these.
    final class FlashStageTotals {
        var connectMS = 0
        var stageMS = 0
        var stageBytes = 0
        var syncMS = 0
        var preferencesMS = 0
        var transactions = 0
    }

    // MARK: - Primary Transaction Injector (Walllive shape, run #112)

    /// One Walllive-shaped install transaction in the Rust core:
    /// primary-spot descriptor inject + combined reload-preferences
    /// write (both targets, one sync) inside a single Books
    /// snapshot/restore cycle. The mirror spot is deferred by design.
    private func injectPrimaryTransaction(
        folderURL: URL,
        targetParentDir: String,
        destName: String,
        prefFileURL: URL,
        prefTargetA: String,
        prefTargetB: String,
        pairingPath: String,
        packageLabel: String,
        stageTotals: FlashStageTotals,
        log: @escaping (String) -> Void
    ) async throws {
        log("  📦 Injecting '\(destName)' into \(targetParentDir)…")
        var errDesc: String? = nil
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                // Run #146: stage timer rides the FFI log callback's
                // ctx (previously unused) — observation only.
                let stageTimer = FlashTransactionStageTimer()
                let stageTimerCtx = Unmanaged.passRetained(stageTimer).toOpaque()
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pairC in
                    folderURL.path.withCString { folderC in
                        targetParentDir.withCString { parentC in
                            destName.withCString { destC in
                                prefFileURL.path.withCString { prefC in
                                    prefTargetA.withCString { aC in
                                        prefTargetB.withCString { bC in
                                            al_exploit_flash_transaction(
                                                pairC,
                                                folderC,
                                                parentC,
                                                destC,
                                                prefC,
                                                aC,
                                                bC,
                                                { ctx, msg in
                                                    guard let msg = msg else { return }
                                                    let line = String(cString: msg)
                                                    if let ctx = ctx {
                                                        Unmanaged<FlashTransactionStageTimer>.fromOpaque(ctx).takeUnretainedValue().observe(line)
                                                    }
                                                    DispatchQueue.main.async {
                                                        AppViewModel.shared?.tendiesFlashLog.append("    " + line)
                                                    }
                                                },
                                                stageTimerCtx,
                                                &outError
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if let p = outError {
                    errDesc = String(cString: p)
                    al_string_free(p)
                }

                // Run #146: per-transaction stage-timing report on the
                // caller's log channel; segments whose markers never
                // arrived are skipped, never estimated.
                Unmanaged<FlashTransactionStageTimer>.fromOpaque(stageTimerCtx).release()
                stageTotals.transactions += 1
                if let afc = stageTimer.afcConnected {
                    let ms = cwStageMS(stageTimer.start, afc)
                    stageTotals.connectMS += ms
                    log("[计时] 刷入·建连 \(cwStageText(ms)) ms（\(packageLabel)）")
                }
                if let sized = stageTimer.archiveSized, let staged = stageTimer.stagedVerified {
                    let ms = cwStageMS(sized, staged)
                    stageTotals.stageMS += ms
                    if let bytes = stageTimer.archiveBytes {
                        stageTotals.stageBytes += bytes
                        log("[计时] 刷入·暂存传输 \(cwStageText(ms)) ms（\(packageLabel)，归档 \(cwStageText(bytes)) 字节）")
                    } else {
                        log("[计时] 刷入·暂存传输 \(cwStageText(ms)) ms（\(packageLabel)）")
                    }
                }
                if let staged = stageTimer.stagedVerified, let done = stageTimer.descriptorDone {
                    let ms = cwStageMS(staged, done)
                    stageTotals.syncMS += ms
                    log("[计时] 刷入·等同步落位 \(cwStageText(ms)) ms（\(packageLabel)）")
                }
                if let begin = stageTimer.preferencesBegin, let end = stageTimer.preferencesEnd {
                    let ms = cwStageMS(begin, end)
                    stageTotals.preferencesMS += ms
                    log("[计时] 刷入·写刷新偏好 \(cwStageText(ms)) ms（\(packageLabel)）")
                }

                cont.resume(returning: rc == 0)
            }
        }

        if !ok {
            throw NSError(
                domain: "TendiesEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to inject descriptor: \(errDesc ?? "exploit error")"]
            )
        }
    }

    // MARK: - Find Descriptors With Targeted Extensions

    func isDescriptorFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name == "__MACOSX" { return false }

        // Must not be the container root or Library itself
        let ignoredNames: Set<String> = [
            "container", "library", "application support", "prbposterextensiondatastore",
            "extensions", "descriptors", "ordered-descriptors",
            "mercury-descriptors", "mercurydescriptors", "video-descriptors", "videodescriptors"
        ]
        if ignoredNames.contains(name.lowercased()) {
            return false
        }

        // 1. Has "versions" directory
        let versions = url.appendingPathComponent("versions")
        if fm.fileExists(atPath: versions.path) { return true }

        // 2. Has "providerInfo.plist"
        let providerInfo = url.appendingPathComponent("providerInfo.plist")
        if fm.fileExists(atPath: providerInfo.path) { return true }

        // 3. Has "com.apple.posterkit.provider.descriptor.identifier"
        let descId = url.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
        if fm.fileExists(atPath: descId.path) { return true }

        // 4. Has "Wallpaper.plist"
        let wallpaper = url.appendingPathComponent("Wallpaper.plist")
        if fm.fileExists(atPath: wallpaper.path) { return true }

        // 5. Ends with .wallpaper
        if url.pathExtension.lowercased() == "wallpaper" { return true }

        return false
    }

    func determineExtension(for folderURL: URL, defaultExt: String) -> String {
        let pathLower = folderURL.path.lowercased()

        // 1. Check path components for .../Extensions/<bundleID>/descriptors/<desc>
        let components = folderURL.pathComponents
        for i in 0..<components.count {
            if components[i].lowercased() == "extensions", i + 1 < components.count {
                let cand = components[i + 1]
                if cand.contains(".") {
                    return cand
                }
            }
            if components[i].lowercased() == "descriptors", i > 0 {
                let cand = components[i - 1]
                if cand.contains(".") && !cand.lowercased().contains("store") {
                    return cand
                }
            }
        }

        // 2. Check metadata inside suggestionMetadata.plist if present
        let metadataURL = folderURL.appendingPathComponent("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        if let data = try? Data(contentsOf: metadataURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let objects = plist["$objects"] as? [Any] {
            for obj in objects {
                if let str = obj as? String {
                    if str.hasPrefix("com.apple.") && str.contains("Poster") {
                        return str
                    }
                }
            }
        }

        // 3. Check descriptor identifier content (e.g. "v6x.colorA" or "v5..." -> Mercury)
        let descIdURL = folderURL.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
        if let descId = try? String(contentsOf: descIdURL, encoding: .utf8) {
            let trimmed = descId.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("v6") || trimmed.hasPrefix("v5") || trimmed.hasPrefix("v4") || trimmed.contains(".color") {
                return "com.apple.MercuryPoster"
            }
        }

        // 4. Path string hints
        if pathLower.contains("mercury") {
            return "com.apple.MercuryPoster"
        }
        if pathLower.contains("video") || pathLower.contains("photo") {
            return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        }
        if pathLower.contains("collection") || pathLower.contains("wallpaperkit") {
            return "com.apple.WallpaperKit.CollectionsPoster"
        }
        if pathLower.contains("kaleidoscope") {
            return "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
        }
        if pathLower.contains("unity") {
            return "com.apple.Posters.UnityPosterApp.UnityPosterExtension"
        }

        return defaultExt
    }

    public func findDescriptorsWithExtensions(in rootURL: URL, defaultExt: String) -> [(ext: String, url: URL)] {
        let fileManager = FileManager.default
        var results: [(ext: String, url: URL)] = []

        if isDescriptorFolder(rootURL) {
            let ext = determineExtension(for: rootURL, defaultExt: defaultExt)
            return [(ext: ext, url: rootURL)]
        }

        // Recursive traversal to discover all descriptor directories
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [(ext: defaultExt, url: rootURL)] }

        while let itemURL = enumerator.nextObject() as? URL {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if itemURL.lastPathComponent.hasPrefix(".") || itemURL.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }

            if isDescriptorFolder(itemURL) {
                let ext = determineExtension(for: itemURL, defaultExt: defaultExt)
                results.append((ext: ext, url: itemURL))
                enumerator.skipDescendants() // Do not look for nested descriptors inside a descriptor folder
            }
        }

        return results.isEmpty ? [(ext: defaultExt, url: rootURL)] : results
    }
}

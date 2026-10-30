import Foundation

/// Descriptor discovery, extension resolution and identifier rewrite
/// for .tendies flashing.
///
/// These are a faithful Swift port of the corresponding helpers in
/// AirCard-iOS's TendiesEngine.swift (MIT, Johnny Franks / Mak5er —
/// see NOTICE), kept rule-for-rule identical: the vendored AirliftFFI
/// core performs the device write, and these helpers decide *what*
/// is written where, exactly as the upstream app decides it.
enum TendiesFlash {
    /// Default extension when nothing in the package says otherwise —
    /// the same default TendiesEngine's import pass uses.
    static let defaultExtension = "com.apple.WallpaperKit.CollectionsPoster"

    static func isDescriptorFolder(_ url: URL) -> Bool {
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
        if fm.fileExists(atPath: url.appendingPathComponent("versions").path) { return true }

        // 2. Has "providerInfo.plist"
        if fm.fileExists(atPath: url.appendingPathComponent("providerInfo.plist").path) { return true }

        // 3. Has "com.apple.posterkit.provider.descriptor.identifier"
        if fm.fileExists(atPath: url.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier").path) { return true }

        // 4. Has "Wallpaper.plist"
        if fm.fileExists(atPath: url.appendingPathComponent("Wallpaper.plist").path) { return true }

        // 5. Ends with .wallpaper
        if url.pathExtension.lowercased() == "wallpaper" { return true }

        return false
    }

    static func determineExtension(for folderURL: URL, defaultExt: String) -> String {
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

    static func findDescriptorsWithExtensions(in rootURL: URL, defaultExt: String) -> [(ext: String, url: URL)] {
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

    /// Plist identifier randomization, matching the upstream rules:
    /// a descriptor carrying suggestionMetadata is pre-packaged with
    /// matching identifiers and is left completely untouched; otherwise
    /// the descriptor identifier file is rewritten only when its
    /// content is a pure integer, and the two plist identifier fields
    /// follow. Returns whether any file was rewritten.
    @discardableResult
    static func updatePlistIdentifiers(in folderURL: URL, randomizedID: Int) -> Bool {
        // If suggestion metadata exists, the descriptor is pre-packaged with matching
        // descriptorIdentifier and wallpaper identifiers (e.g. 7400.DYNAMIC <-> 7400).
        // Randomizing only Wallpaper.plist desynchronizes PosterKit's suggestion lookup!
        let suggestionMetadataURL = folderURL.appendingPathComponent("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        if FileManager.default.fileExists(atPath: suggestionMetadataURL.path) {
            return false
        }

        var rewrote = false
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        while let fileURL = enumerator.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent

            if fileName == "com.apple.posterkit.provider.descriptor.identifier" {
                // ONLY randomize if the file content is a pure integer!
                // For extensions like Mercury, Unity, Kaleidoscope, descriptor identifiers are
                // required string symbols (e.g. "v6x.colorA", "Unity2025")!
                // Overwriting them breaks extension lookup!
                if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                    if (try? "\(randomizedID)".write(to: fileURL, atomically: true, encoding: .utf8)) != nil {
                        rewrote = true
                    }
                }
            } else if fileName == "com.apple.posterkit.provider.contents.userInfo" {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)) as? [String: Any],
                   plist["wallpaperRepresentingIdentifier"] != nil {
                    plist["wallpaperRepresentingIdentifier"] = randomizedID
                    if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                        if (try? updated.write(to: fileURL)) != nil {
                            rewrote = true
                        }
                    }
                }
            } else if fileName.hasSuffix("Wallpaper.plist") {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)) as? [String: Any] {
                    plist["identifier"] = randomizedID
                    if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                        if (try? updated.write(to: fileURL)) != nil {
                            rewrote = true
                        }
                    }
                }
            }
        }
        return rewrote
    }

    /// The PosterBoard refresh / file-protection-reset plist, byte
    /// content identical to the dictionary TendiesEngine stages:
    /// same keys, same values, same order, binary serialization.
    static func refreshPlistData() throws -> Data {
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
        return try PropertyListSerialization.data(fromPropertyList: prefDict, format: .binary, options: 0)
    }
}

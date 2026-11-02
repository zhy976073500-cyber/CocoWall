//
//  TendiesPackage.swift
//  TendiesPreview (Phase 0 probe)
//
//  On-disk analysis of an extracted .tendies: locate every .ca package
//  under descriptors/, classify it (Background / Floating / Foreground),
//  and mine its main.caml as TEXT for the diagnostics panel (state names,
//  transition count, asset references). Text mining is also the fallback
//  source for state names when the private layer API cannot enumerate
//  states at runtime (see StateControllerBridge).
//
//  Real-package facts this is built against (verified 2026-11-02):
//  - 7400:  three .ca dirs, index.xml is either minimal (rootDocument
//    only) or full (documentWidth/Height etc.); states are
//    <LKState name="Locked|Unlock|Sleep">.
//  - Cubes: two .ca dirs, iPad geometry in the .wallpaper name
//    (-810w-1080h@2x), root layer bounds 3176x3176, 24 states named
//    "Lock|Home|Sleep <Orientation> <Light|Dark>".
//  - Assets are referenced from CAML as src="assets/<file>" relative to
//    the .ca directory; 7400's Background.ca also ships a Root_Layer.js
//    (registered in diagnostics, NEVER executed by this probe).
//

import Foundation

enum CAPackageKind: Int, Comparable {
    case background = 0
    case floating = 1
    case foreground = 2
    case other = 3

    static func < (a: CAPackageKind, b: CAPackageKind) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .background: return "Background"
        case .floating: return "Floating"
        case .foreground: return "Foreground"
        case .other: return "Other"
        }
    }

    static func classify(dirName: String) -> CAPackageKind {
        let n = dirName.lowercased()
        if n.contains("background") { return .background }
        if n.contains("floating") { return .floating }
        if n.contains("foreground") { return .foreground }
        return .other
    }
}

struct CAPackageDiskInfo {
    /// Directory of the .ca package on disk (after extraction).
    let dir: URL
    let kind: CAPackageKind
    /// Name of the enclosing *.wallpaper directory ("" if none found).
    let wallpaperName: String
    /// Logical canvas size: parsed from the wallpaper dir name
    /// (-390w-844h@3x), falling back to index.xml document size,
    /// then to 390x844.
    let logicalSize: CGSize
    /// File name of the root CAML document (index.xml rootDocument).
    let rootDocumentName: String
    /// Raw text of the root CAML document ("" if unreadable).
    let camlText: String
    /// State names mined from CAML text, in document order, de-duplicated.
    let stateNamesFromCAML: [String]
    /// Count of <..StateTransition ...> elements in the CAML text
    /// (StateTransitionElement entries are NOT counted).
    let transitionCountFromCAML: Int
    /// Files under assets/ (names only, sorted).
    let assetFiles: [String]
    /// assets/*.js — registered only, never executed (SPEC: no JS).
    let jsAssets: [String]
    /// Every src="..." reference in the CAML, de-duplicated, in order.
    let referencedSrcs: [String]
    /// Referenced srcs with no corresponding file inside the .ca dir.
    let missingSrcs: [String]

    var displayName: String { dir.lastPathComponent }
    var mainCAMLURL: URL { dir.appendingPathComponent(rootDocumentName) }
}

enum TendiesScanner {

    /// Find all .ca package directories under an extracted .tendies root.
    static func scan(extractedRoot: URL) -> [CAPackageDiskInfo] {
        let fm = FileManager.default
        var caDirs: [URL] = []
        if let enumerator = fm.enumerator(at: extractedRoot,
                                          includingPropertiesForKeys: [.isDirectoryKey],
                                          options: []) {
            for case let url as URL in enumerator {
                if url.path.contains("__MACOSX") { continue }
                if url.pathExtension.lowercased() == "ca",
                   (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    caDirs.append(url)
                }
            }
        }
        return caDirs
            .map { analyze(caDir: $0) }
            .sorted { ($0.kind, $0.displayName) < ($1.kind, $1.displayName) }
    }

    static func analyze(caDir: URL) -> CAPackageDiskInfo {
        let fm = FileManager.default
        let kind = CAPackageKind.classify(dirName: caDir.lastPathComponent)

        // Enclosing *.wallpaper directory (walk up the path components).
        var wallpaperName = ""
        for comp in caDir.pathComponents.reversed() {
            if comp.lowercased().hasSuffix(".wallpaper") { wallpaperName = comp; break }
        }

        // index.xml is a plist: rootDocument + optional document size.
        var rootDocument = "main.caml"
        var docSize: CGSize? = nil
        let indexURL = caDir.appendingPathComponent("index.xml")
        if let data = try? Data(contentsOf: indexURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dict = plist as? [String: Any] {
            if let rd = dict["rootDocument"] as? String, !rd.isEmpty { rootDocument = rd }
            if let w = dict["documentWidth"] as? NSNumber,
               let h = dict["documentHeight"] as? NSNumber {
                docSize = CGSize(width: w.doubleValue, height: h.doubleValue)
            }
        }

        let logicalSize = parseLogicalSize(from: wallpaperName)
            ?? parseLogicalSize(from: caDir.lastPathComponent)
            ?? docSize
            ?? CGSize(width: 390, height: 844)

        let camlURL = caDir.appendingPathComponent(rootDocument)
        let camlText = (try? String(contentsOf: camlURL, encoding: .utf8)) ?? ""

        // assets/ listing.
        let assetsDir = caDir.appendingPathComponent("assets", isDirectory: true)
        var assetFiles: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: assetsDir.path) {
            assetFiles = items.filter { !$0.hasPrefix("._") && $0 != ".DS_Store" }.sorted()
        }
        let jsAssets = assetFiles.filter { $0.lowercased().hasSuffix(".js") }

        // src="..." references (how CAML points at assets, relative to .ca dir).
        let srcs = regexCaptures(#"src="([^"]+)""#, in: camlText)
        var seen = Set<String>()
        let referenced = srcs.filter { seen.insert($0).inserted }
        let missing = referenced.filter {
            !fm.fileExists(atPath: caDir.appendingPathComponent($0).path)
        }

        return CAPackageDiskInfo(
            dir: caDir,
            kind: kind,
            wallpaperName: wallpaperName,
            logicalSize: logicalSize,
            rootDocumentName: rootDocument,
            camlText: camlText,
            stateNamesFromCAML: stateNames(in: camlText),
            transitionCountFromCAML: transitionCount(in: camlText),
            assetFiles: assetFiles,
            jsAssets: jsAssets,
            referencedSrcs: referenced,
            missingSrcs: missing
        )
    }

    // MARK: - CAML text mining

    /// <LKState name="..."> / <CAState name="..."> in document order.
    /// LKState is the tag name PosterBoard packages use; QuartzCore's
    /// parser is expected to map it onto its internal state class.
    static func stateNames(in caml: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for name in regexCaptures(#"<(?:LKState|CAState)\s+name="([^"]+)""#, in: caml) {
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// Count state *transitions*: opening tags whose element name ends in
    /// "StateTransition" followed by space or '>'. The longer
    /// "StateTransitionElement" name is deliberately excluded by the
    /// trailing-character class.
    static func transitionCount(in caml: String) -> Int {
        regexMatches(#"<[A-Za-z]*StateTransition[\s>]"#, in: caml)
    }

    /// Logical size encoded in names like "7400.WWDC_2022-390w-844h@3x~iphone".
    static func parseLogicalSize(from name: String) -> CGSize? {
        guard let re = try? NSRegularExpression(pattern: #"-(\d+(?:\.\d+)?)w-(\d+(?:\.\d+)?)h"#),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              m.numberOfRanges == 3,
              let wr = Range(m.range(at: 1), in: name),
              let hr = Range(m.range(at: 2), in: name),
              let w = Double(name[wr]), let h = Double(name[hr]), w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: - Regex helpers

    /// Capture group 1 of every match.
    static func regexCaptures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    static func regexMatches(_ pattern: String, in text: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

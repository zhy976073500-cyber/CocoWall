import Foundation
import UIKit
import SwiftUI
import AirliftFFI

// MARK: - AppViewModel

@MainActor
final class AppViewModel: ObservableObject {

    /// Static sink for Rust log lines — set in init so AirliftApp can forward them.
    static var sharedLogSink: ((String) -> Void)? = nil
    static weak var shared: AppViewModel? = nil

    // MARK: - Pairing
    @Published var pairingStatus: String = ""
    @Published var pairingPIN: String? = nil
    @Published var hasPairingFile: Bool = false
    @Published var pairingFileName: String = ""
    @Published var pairingPhase: PairingPhase = .idle
    @Published var documentsPlistFiles: [String] = []

    enum PairingPhase: Equatable {
        case idle, pairing
    }

    // MARK: - VPN / Network
    @Published var vpnUp: Bool = false
    @Published var wifiUp: Bool = false
    @Published var networkDetail: String = ""
    @Published var deviceIP: String = "10.7.0.1" {
        didSet {
            syncTargetHostsToRust()
        }
    }

    // MARK: - Tab
    @Published var selectedTab: AppTab = .pairing

    enum FlashPhase: Equatable {
        case idle, running, done(ok: Bool)
    }

    // MARK: - Passcode Themes tab
    @Published var passcodeMode: CreatorMode = .applyTheme
    @Published var loadedTheme: PasscodeThemeInfo? = nil
    @Published var documentsThemes: [String] = []
    @Published var sliceMode: SliceMode = .posterSlice

    // Poster slice
    @Published var posterImage: UIImage? = nil
    @Published var posterZoom: CGFloat = 1.0
    @Published var posterOffset: CGPoint = .zero
    @Published var maskToCircles: Bool = false
    @Published var slicedKeys: [String: UIImage] = [:]

    // Individual keys
    @Published var customKeys: [String: UIImage] = [:]
    @Published var rawIndividualImages: [String: UIImage] = [:]
    @Published var individualOffsets: [String: CGPoint] = [:]
    @Published var individualZooms: [String: CGFloat] = [:]
    @Published var selectedKeyDigit: String? = nil

    @Published var passthmFlashPhase: FlashPhase = .idle
    @Published var passthmFlashProgress: Double = 0
    @Published var passthmFlashLog: [String] = []

    // MARK: - Tendies / Wallpapers tab
    @Published var tendieItems: [TendieItem] = []
    @Published var posterBoardContainer: String = ""
    @Published var isDetectingContainer: Bool = false
    @Published var resetPBProtections: Bool = true
    @Published var tendiesFlashPhase: FlashPhase = .idle
    @Published var tendiesFlashProgress: Double = 0
    @Published var tendiesFlashLog: [String] = []
    @Published var isNeoSpringing: Bool = false

    // MARK: - AirCard UI States & Properties
    static var detectedDeviceLanguage: PasscodeLanguageTarget {
        let code = Locale.preferredLanguages.first?.components(separatedBy: "-").first?.lowercased() ?? "en"
        for target in PasscodeLanguageTarget.allCases {
            if target.code == code {
                return target
            }
        }
        return .en
    }

    @Published var targetTelephonyVersion: String = "TelephonyUI-10"
    @Published var passcodeLanguageTarget: PasscodeLanguageTarget = AppViewModel.detectedDeviceLanguage
    @Published var passcodeBoldTarget: PasscodeBoldTarget = .both
    @Published var showSuccessAlert: Bool = false
    @Published var successAlertMessage: String = ""
    @Published var exportedThemeURL: URL? = nil
    @Published var showShareSheet: Bool = false

    // MARK: - Shared
    @Published var errorMessage: String? = nil
    @Published var log: [String] = []
    @Published var showDeletePairingConfirm: Bool = false

    init() {
        Self.shared = self
        refreshPairingFile()
        refreshNetworkStatus()
        scanDocumentsDirectory()
        posterBoardContainer = UserDefaults.standard.string(forKey: "aircard.posterboard_container") ?? ""
        loadSavedTendies()

        // Hook Rust log output into our log array.
        AppViewModel.sharedLogSink = { [weak self] line in
            self?.log.append(line)
        }
    }

    // MARK: - Documents directory scanner

    /// Scans the app's Documents folder (accessible via Files app: "On My iPhone › Airlift")
    /// for any pairing plists or .passthm themes dropped by the user.
    func scanDocumentsDirectory() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: docs.path) else { return }

        // Find plists (exclude internal canonical copies)
        documentsPlistFiles = items.filter { item in
            let lower = item.lowercased()
            let isPairingExt = lower.hasSuffix(".plist") || lower.hasSuffix(".mobiledevicepairing") || lower.hasSuffix(".mobilepair")
            let isCanonical = item == "aircard_pairing.plist" || item == "airlift_pairing.plist" || item == "Info.plist"
            return isPairingExt && !isCanonical
        }.sorted()

        // Find .passthm themes
        documentsThemes = items.filter { $0.hasSuffix(".passthm") }.sorted()

        // Auto-discover any .tendies dropped into Documents or Documents/Tendies
        scanDocumentsForTendies()
    }

    func scanDocumentsForTendies() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tendiesDir = TendiesEngine.tendiesStorageDirectory
        
        var foundURLs: [URL] = []
        if let rootItems = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for u in rootItems where u.pathExtension.lowercased() == "tendies" {
                let target = tendiesDir.appendingPathComponent(u.lastPathComponent)
                if u.path != target.path && !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.copyItem(at: u, to: target)
                }
                foundURLs.append(target)
            }
        }
        if let storedItems = try? FileManager.default.contentsOfDirectory(at: tendiesDir, includingPropertiesForKeys: nil) {
            for u in storedItems where u.pathExtension.lowercased() == "tendies" {
                if !foundURLs.contains(u) {
                    foundURLs.append(u)
                }
            }
        }

        let newURLs = foundURLs.filter { url in
            !tendieItems.contains(where: { $0.fileName == url.lastPathComponent })
        }

        guard !newURLs.isEmpty else { return }

        Task {
            await self.importTendieFiles(urls: newURLs)
        }
    }

    @discardableResult
    func importPairingFile(from sourceURL: URL, originalName: String? = nil) -> Bool {
        let isSecured = sourceURL.startAccessingSecurityScopedResource()
        defer { if isSecured { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else {
            errorMessage = "Selected pairing file is empty or could not be read."
            return false
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aircardURL = docs.appendingPathComponent("aircard_pairing.plist")
        let airliftURL = docs.appendingPathComponent("airlift_pairing.plist")

        do {
            try data.write(to: aircardURL, options: .atomic)
            try data.write(to: airliftURL, options: .atomic)

            if let orig = originalName, !orig.isEmpty,
               orig != "aircard_pairing.plist" && orig != "airlift_pairing.plist" {
                let origURL = docs.appendingPathComponent(orig)
                if origURL.path != sourceURL.path {
                    try? data.write(to: origURL, options: .atomic)
                }
            }

            PairingController.customPairingFilePath = aircardURL.path
            refreshPairingFile()
            let display = originalName ?? sourceURL.lastPathComponent
            pairingStatus = "Pairing file loaded ✅ (\(display))"
            log.append("Imported pairing file: \(display) (\(data.count) bytes)")
            return true
        } catch {
            errorMessage = "Failed to save pairing file: \(error.localizedDescription)"
            return false
        }
    }

    func selectPairingFile(filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent(filename).path
        let canonical = PairingController.syncCanonicalPairingFile(from: path)
        let exists = FileManager.default.fileExists(atPath: canonical) &&
            ((try? FileManager.default.attributesOfItem(atPath: canonical)[.size] as? Int) ?? 0) > 0
        hasPairingFile = exists
        pairingFileName = exists ? (path as NSString).lastPathComponent : ""
        if exists {
            pairingStatus = "Active: \(pairingFileName) ✅"
            log.append("Selected pairing file: \(pairingFileName)")
        }
        scanDocumentsDirectory()
    }

    // MARK: - Pairing File

    func refreshPairingFile() {
        let path = PairingController.pairingFilePath()
        let exists = FileManager.default.fileExists(atPath: path) &&
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) > 0
        hasPairingFile = exists
        pairingFileName = exists ? (path as NSString).lastPathComponent : ""
        scanDocumentsDirectory()
    }


    var pairingFileSizeString: String {
        let path = PairingController.pairingFilePath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func startPairing() {
        pairingPhase = .pairing
        pairingPIN = nil
        pairingStatus = "Starting local host…"
        errorMessage = nil

        let ctrl = PairingController.shared

        Task {
            do {
                let path = try await ctrl.startAndWait()
                await MainActor.run {
                    self.pairingPhase = .idle
                    self.refreshPairingFile()
                    self.pairingStatus = "Paired successfully! ✅"
                    self.log.append("Pairing complete: \(path)")
                }
            } catch is CancellationError {
                self.pairingPhase = .idle
                self.pairingStatus = "Cancelled."
            } catch {
                self.pairingPhase = .idle
                self.pairingStatus = ""
                self.errorMessage = "Pairing failed: \(error.localizedDescription)"
            }
        }

        // Poll PairingController status every 0.2s while pairing
        Task {
            while pairingPhase == .pairing {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    guard self.pairingPhase == .pairing else { return }
                    self.pairingStatus = ctrl.pairingStatus
                    self.pairingPIN   = ctrl.pairingPIN
                }
            }
        }
    }

    func cancelPairing() {
        PairingController.shared.softCancel()
        pairingPhase = .idle
        pairingStatus = ""
    }

    func deletePairingFile() {
        PairingController.deleteStoredPairingCredentials()
        hasPairingFile = false
        pairingFileName = ""
        pairingStatus = "Pairing file deleted"
        log.append("Deleted active pairing credentials")
        scanDocumentsDirectory()
    }

    // MARK: - Network

    func refreshNetworkStatus() {
        let ip = deviceIP
        let (vpn, wifi, detail) = NetworkStatus.summarize(deviceIP: ip)
        vpnUp = vpn
        wifiUp = wifi
        networkDetail = detail
        syncTargetHostsToRust()
    }

    /// Synchronizes the active device IP and candidate host addresses to the Rust core
    /// so the RSD tunnel connects over the non-loopback VPN interface rather than 127.0.0.1.
    func syncTargetHostsToRust() {
        let ip = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty {
            ip.withCString { _ = al_set_target_host($0) }
        } else {
            _ = al_set_target_host(nil)
        }

        var candidates: [String] = []
        if !ip.isEmpty {
            candidates.append(ip)
        }
        for cand in NetworkStatus.tunnelHostCandidates() {
            if !candidates.contains(cand) {
                candidates.append(cand)
            }
        }
        let cStrings = candidates.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) }
        ptrs.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                _ = al_set_target_hosts(base, buf.count)
            }
        }
    }

    // MARK: - Poster Slice

    var effectiveKeys: [String: UIImage] {
        sliceMode == .posterSlice ? slicedKeys : customKeys
    }

    func setPosterImage(_ img: UIImage) {
        posterImage = img
        posterZoom = 1.0
        posterOffset = .zero
        updatePosterSlicing()
    }

    func updatePosterSlicing() {
        guard let img = posterImage else { slicedKeys = [:]; return }
        slicedKeys = ImageEngine.slicePoster(
            image: img,
            zoom: posterZoom,
            offset: posterOffset,
            maskToCircles: maskToCircles
        )
    }

    func setIndividualKey(digit: String, image: UIImage) {
        rawIndividualImages[digit] = image
        individualOffsets[digit] = .zero
        individualZooms[digit] = 1.0
        selectedKeyDigit = digit
        updateIndividualKey(digit: digit)
    }

    func updateIndividualKey(digit: String) {
        guard let raw = rawIndividualImages[digit] else { return }
        let offset = individualOffsets[digit] ?? .zero
        let zoom   = individualZooms[digit] ?? 1.0
        if let cropped = ImageEngine.cropToCircle(
            image: raw,
            targetSize: CGSize(width: 225, height: 225),
            circleDiameter: 222.0,
            zoom: zoom,
            offset: offset
        ) {
            customKeys[digit] = cropped
        }
    }

    func clearIndividualKey(digit: String) {
        customKeys.removeValue(forKey: digit)
        rawIndividualImages.removeValue(forKey: digit)
        individualOffsets.removeValue(forKey: digit)
        individualZooms.removeValue(forKey: digit)
        if selectedKeyDigit == digit { selectedKeyDigit = nil }
    }

    func clearAllCreator() {
        posterImage = nil
        posterZoom = 1.0
        posterOffset = .zero
        slicedKeys.removeAll()
        customKeys.removeAll()
        rawIndividualImages.removeAll()
        individualOffsets.removeAll()
        individualZooms.removeAll()
        selectedKeyDigit = nil
    }

    // MARK: - Passthm Load

    func loadPassthm(url: URL) {
        Task.detached {
            let result = PasscodeThemeReader.inspect(url: url)
            await MainActor.run {
                if let (keys, rawData, count) = result {
                    self.loadedTheme = PasscodeThemeInfo(
                        name: url.deletingPathExtension().lastPathComponent,
                        filePath: url.path,
                        fileCount: count,
                        keysPreview: keys,
                        rawKeyData: rawData
                    )
                } else {
                    self.errorMessage = "Failed to read .passthm — invalid or unsupported format."
                }
            }
        }
    }

    func loadPassthmFromDocuments(filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(filename)
        loadPassthm(url: url)
    }

    func clearLoadedTheme() {
        loadedTheme = nil
        passthmFlashPhase = .idle
        passthmFlashProgress = 0
        passthmFlashLog.removeAll()
    }

    // MARK: - Passthm Flash

    var canFlashPassthm: Bool {
        guard hasPairingFile && passthmFlashPhase != .running else { return false }
        switch passcodeMode {
        case .applyTheme:
            return loadedTheme != nil && !(loadedTheme?.keysPreview.isEmpty ?? true)
        case .themeCreator:
            return !effectiveKeys.isEmpty
        }
    }

    func flashPassthm() {
        guard canFlashPassthm else { return }

        let isCreator = (passcodeMode == .themeCreator)
        let keys: [String: UIImage]
        let rawKeys: [String: Data]

        if isCreator {
            keys = effectiveKeys
            rawKeys = [:] // CRITICAL: Never use rawKeyData from previously loaded zip in creator mode!
        } else if let theme = loadedTheme {
            keys = theme.keysPreview
            rawKeys = theme.rawKeyData
        } else {
            return
        }

        guard !keys.isEmpty else {
            errorMessage = "No key images loaded."
            return
        }

        passthmFlashPhase    = .running
        passthmFlashProgress = 0
        passthmFlashLog.removeAll()
        errorMessage = nil
        syncTargetHostsToRust()

        if !vpnUp {
            passthmFlashLog.append("⚠️ Notice: Loopback VPN (LocalDevVPN or SideStore WireGuard) is strongly recommended for on-device operations.")
        }

        let pairingPath = PairingController.pairingFilePath()
        let targetVer = targetTelephonyVersion
        let targetLang = passcodeLanguageTarget
        let targetBold = passcodeBoldTarget
        let detected = AppViewModel.detectedDeviceLanguage.code

        Task.detached { [weak self] in
            guard let self = self else { return }

            let stageThemeDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("airlift_passthm_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: stageThemeDir, withIntermediateDirectories: true)

            let langs: [String]
            if targetLang == .all {
                langs = KeypadLocales.all
            } else {
                var l = [targetLang.code]
                if targetLang.code != "other" {
                    l.append("other")
                }
                if targetLang.code != detected && detected != "other" && !l.contains(detected) {
                    l.append(detected)
                }
                langs = l
            }
            let boldSuffixes: [String]
            switch targetBold {
            case .both: boldSuffixes = ["", "-bold"]
            case .boldOnly: boldSuffixes = ["-bold"]
            case .regularOnly: boldSuffixes = [""]
            }

            // Stage keypad images with all configured language & weight variants
            for (digit, image) in keys {
                let imgData: Data
                if let raw = rawKeys[digit] {
                    imgData = raw
                } else if let png = image.pngData() {
                    imgData = png
                } else {
                    continue
                }
                let stdSubtext = KeypadLayout.subtexts[digit] ?? ""

                for lang in langs {
                    for bld in boldSuffixes {
                        if digit == "0" {
                            // Blank variant: lang-0---white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-0---white\(bld).png"))
                            // Plus variant: lang-0-+--white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-0-+--white\(bld).png"))
                        } else if digit == "1" {
                            // Blank variant: lang-1---white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-1---white\(bld).png"))
                        } else {
                            // 1. Blank subtext
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)---white\(bld).png"))

                            // 2. Standard Latin subtext
                            if !stdSubtext.isEmpty {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(stdSubtext)--white\(bld).png"))
                                let noSpace = stdSubtext.replacingOccurrences(of: " ", with: "")
                                if noSpace != stdSubtext {
                                    try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(noSpace)--white\(bld).png"))
                                }
                            }

                            // 3. Cyrillic subtexts
                            if (lang == "ru" || targetLang == .all), let ruSub = KeypadLocales.cyrillicRU[digit] {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(ruSub)--white\(bld).png"))
                            }
                            if (lang == "uk" || targetLang == .all), let ukSub = KeypadLocales.cyrillicUK[digit] {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(ukSub)--white\(bld).png"))
                            }
                        }
                    }
                }
            }

            // iOS TelephonyUI @3x high-res indicator marker
            try? Data().write(to: stageThemeDir.appendingPathComponent("_big"))

            await MainActor.run {
                self.passthmFlashLog.append("⚡ Staged theme assets (\(targetVer) · \(langs.joined(separator: ", ").uppercased()) · \(targetBold.code)). Injecting into iOS caches…")
                self.passthmFlashProgress = 0.2
            }

            let targetDirs: [String]
            if targetVer == "all" {
                targetDirs = [
                    "/var/mobile/Library/Caches/TelephonyUI-10",
                    "/var/mobile/Library/Caches/TelephonyUI-9",
                    "/var/mobile/Library/Caches/TelephonyUI-8"
                ]
            } else {
                targetDirs = [
                    "/var/mobile/Library/Caches/\(targetVer)"
                ]
            }

            var allOk = true
            var lastErr: String? = nil

            for (idx, targetPath) in targetDirs.enumerated() {
                let targetName = (targetPath as NSString).lastPathComponent
                await MainActor.run {
                    self.passthmFlashLog.append("  Writing to \(targetName)…")
                }

                var stepOk = false
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var outError: UnsafeMutablePointer<CChar>? = nil
                        let rc = pairingPath.withCString { pairC in
                            stageThemeDir.path.withCString { srcC in
                                targetPath.withCString { tgtC in
                                    al_exploit_write_dir(pairC, srcC, tgtC, { _, msg in
                                        guard let msg = msg else { return }
                                        let line = String(cString: msg)
                                        DispatchQueue.main.async { AppViewModel.shared?.passthmFlashLog.append("    " + line) }
                                    }, nil, &outError)
                                }
                            }
                        }
                        if let p = outError {
                            lastErr = String(validatingUTF8: p)
                            al_string_free(p)
                        }
                        stepOk = (rc == 0)
                        cont.resume()
                    }
                }

                if !stepOk {
                    allOk = false
                    await MainActor.run {
                        self.passthmFlashLog.append("  ⚠️ Write to \(targetName) failed: \(lastErr ?? "error")")
                    }
                } else {
                    await MainActor.run {
                        self.passthmFlashLog.append("  ✅ Injected into \(targetName)")
                    }
                }

                await MainActor.run {
                    self.passthmFlashProgress = 0.2 + Double(idx + 1) * 0.25
                }
            }

            try? FileManager.default.removeItem(at: stageThemeDir)

            await MainActor.run {
                if allOk {
                    self.passthmFlashProgress = 1.0
                    self.passthmFlashPhase = .done(ok: true)
                    self.passthmFlashLog.append("🎉 Passcode theme applied! Lock your iPhone to see it.")
                    self.successAlertMessage = "Passcode theme successfully applied!\n\nLock your iPhone (or restart) to see your new passcode keypad."
                    self.showSuccessAlert = true
                } else {
                    self.passthmFlashPhase = .done(ok: false)
                    self.passthmFlashLog.append("❌ One or more theme injections failed.")
                }
            }
        }
    }

    func exportPassthm() -> URL? {
        let keys = effectiveKeys
        guard !keys.isEmpty else {
            errorMessage = "Please configure at least one key before exporting."
            return nil
        }
        do {
            let zipData = try PasscodeThemePackager.buildPassthm(
                keys: keys,
                telephonyVersion: targetTelephonyVersion,
                language: passcodeLanguageTarget,
                bold: passcodeBoldTarget
            )
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AirCard_Custom_\(Int(Date().timeIntervalSince1970)).passthm")
            try zipData.write(to: tempURL)
            self.exportedThemeURL = tempURL
            self.showShareSheet = true
            return tempURL
        } catch {
            errorMessage = "Failed to export theme: \(error.localizedDescription)"
            return nil
        }
    }

    func resetPosterPosition() {
        posterZoom = 1.0
        posterOffset = .zero
        updatePosterSlicing()
    }

    func adoptThemeIntoCreator() {
        guard let theme = loadedTheme else { return }
        for (digit, img) in theme.keysPreview {
            customKeys[digit] = img
            rawIndividualImages[digit] = img
            individualOffsets[digit] = .zero
            individualZooms[digit] = 1.0
        }
        selectedKeyDigit = nil
        sliceMode = .individualKeys
        passcodeMode = .themeCreator
    }

    func appendLog(_ line: String) {
        log.append(line)
    }

    // MARK: - Tendies / Wallpapers

    func loadSavedTendies() {
        if let data = UserDefaults.standard.data(forKey: "aircard.saved_tendies"),
           let items = try? JSONDecoder().decode([TendieItem].self, from: data) {
            self.tendieItems = items.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        }
    }

    func saveTendieItems() {
        if let data = try? JSONEncoder().encode(tendieItems) {
            UserDefaults.standard.set(data, forKey: "aircard.saved_tendies")
        }
    }

    func importTendieFiles(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var importedCount = 0
        var lastImportedName = ""
        for url in urls {
            do {
                let item = try await TendiesEngine.shared.importTendie(from: url)
                await MainActor.run {
                    self.tendieItems.removeAll(where: { $0.fileName == item.fileName })
                    self.tendieItems.append(item)
                    self.saveTendieItems()
                    importedCount += 1
                    lastImportedName = item.name
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteTendie(item: TendieItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        tendieItems.removeAll(where: { $0.id == item.id })
        saveTendieItems()
    }

    func autoDetectPosterBoardContainer(silent: Bool = false) async {
        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            if !silent {
                await MainActor.run {
                    self.errorMessage = "No pairing file active. Pair your device first in the Pairing tab."
                }
            }
            return
        }

        await MainActor.run { self.isDetectingContainer = true }
        defer {
            Task { @MainActor in self.isDetectingContainer = false }
        }

        do {
            let container = try await TendiesEngine.shared.detectPosterBoardContainer(pairingPath: pairingPath)
            await MainActor.run {
                self.posterBoardContainer = container
                UserDefaults.standard.set(container, forKey: "aircard.posterboard_container")
            }
        } catch {
            if !silent {
                await MainActor.run {
                    self.errorMessage = "Auto-detect failed: \(error.localizedDescription)\nEnsure LocalDevVPN is connected and device is unlocked."
                }
            }
        }
    }

    func flashSelectedTendies() async {
        let selected = tendieItems.filter { $0.isSelected }
        guard !selected.isEmpty else {
            errorMessage = "No wallpapers selected to flash."
            return
        }

        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            errorMessage = "No pairing file active. Please pair your device first."
            return
        }

        var container = posterBoardContainer.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.isEmpty {
            do {
                container = try await TendiesEngine.shared.detectPosterBoardContainer(pairingPath: pairingPath)
                self.posterBoardContainer = container
                UserDefaults.standard.set(container, forKey: "aircard.posterboard_container")
            } catch {
                errorMessage = "PosterBoard container could not be found automatically. Ensure LocalDevVPN is connected and iPhone is unlocked."
                return
            }
        }

        tendiesFlashPhase = .running
        tendiesFlashProgress = 0
        tendiesFlashLog = []

        do {
            try await TendiesEngine.shared.flashTendies(
                items: selected,
                containerPath: container,
                resetProtections: resetPBProtections,
                pairingPath: pairingPath,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.tendiesFlashLog.append(line)
                    }
                },
                progress: { [weak self] p in
                    DispatchQueue.main.async {
                        self?.tendiesFlashProgress = p
                    }
                }
            )
            tendiesFlashPhase = .done(ok: true)
            tendiesFlashProgress = 1.0
            tendiesFlashLog.append("🎉 Wallpapers applied successfully!")
            tendiesFlashLog.append("⚡ Triggering NeoSpring respring...")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.isNeoSpringing = true
                RespringHelper.triggerNeoSpring()
            }
        } catch {
            tendiesFlashLog.append("❌ Error: \(error.localizedDescription)")
            tendiesFlashPhase = .done(ok: false)
        }
    }

    func respringDevice() {
        tendiesFlashLog.append("⚡ Triggering NeoSpring respring...")
        isNeoSpringing = true
        RespringHelper.triggerNeoSpring()
    }

    func reset() {
        passthmFlashPhase = .idle
        passthmFlashProgress = 0
        tendiesFlashPhase = .idle
        tendiesFlashProgress = 0
        errorMessage = nil
    }
}

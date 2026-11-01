import Foundation
import UIKit
import SwiftUI
import ImageIO
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
    @Published var selectedTab: AppTab = .wallpapers

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
    private var previewRegenInFlight: Set<UUID> = []

    // MARK: - Device PosterBoard store (detect / cleanup)
    /// Descriptors actually present in the device's PosterBoard data store
    /// (from PosterStoreHelper — NOT the local imported-.tendies library).
    @Published var devicePosters: [DevicePosterItem] = []
    @Published var devicePosterSelection: Set<String> = []
    @Published var isScanningDevicePosters: Bool = false
    @Published var isCleaningDevicePosters: Bool = false
    @Published var devicePosterStatus: String = ""
    @Published var showDevicePosterSheet: Bool = false

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
        // End any pairing Live Activity left over from a prior process.
        PairingLiveActivityController.endStaleActivities()
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
            errorMessage = "所选配对文件为空或无法读取。"
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
            pairingStatus = "配对文件已载入 ✅（\(display)）"
            log.append("已导入配对文件：\(display)（\(data.count) 字节）")
            return true
        } catch {
            errorMessage = "保存配对文件失败：\(error.localizedDescription)"
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
            pairingStatus = "当前使用：\(pairingFileName) ✅"
            log.append("已选择配对文件：\(pairingFileName)")
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
        pairingStatus = "正在启动本机配对服务…"
        errorMessage = nil
        PairingLiveActivityController.shared.begin()

        let ctrl = PairingController.shared

        Task {
            do {
                let path = try await ctrl.startAndWait()
                await MainActor.run {
                    self.pairingPhase = .idle
                    self.refreshPairingFile()
                    self.pairingStatus = "配对成功！✅"
                    self.log.append("配对完成：\(path)")
                    PairingLiveActivityController.shared.succeeded()
                }
            } catch is CancellationError {
                self.pairingPhase = .idle
                self.pairingStatus = "已取消。"
                PairingLiveActivityController.shared.failed(message: "配对已取消")
            } catch {
                self.pairingPhase = .idle
                self.pairingStatus = ""
                self.errorMessage = "配对失败：\(error.localizedDescription)"
                PairingLiveActivityController.shared.failed(message: "配对失败")
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
                    if let pin = self.pairingPIN {
                        PairingLiveActivityController.shared.pinReady(pin)
                    }
                }
            }
        }
    }

    func cancelPairing() {
        PairingController.shared.softCancel()
        pairingPhase = .idle
        pairingStatus = ""
        PairingLiveActivityController.shared.failed(message: "配对已取消")
    }

    func deletePairingFile() {
        PairingController.deleteStoredPairingCredentials()
        hasPairingFile = false
        pairingFileName = ""
        pairingStatus = "配对文件已删除"
        log.append("已删除当前配对凭据")
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
                    self.errorMessage = "读取 .passthm 失败——格式无效或不受支持。"
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
            errorMessage = "没有已载入的按键图片。"
            return
        }

        passthmFlashPhase    = .running
        passthmFlashProgress = 0
        passthmFlashLog.removeAll()
        errorMessage = nil
        syncTargetHostsToRust()

        if !vpnUp {
            passthmFlashLog.append("⚠️ 提示：强烈建议先连接回环 VPN（LocalDevVPN 或 SideStore WireGuard）再进行设备操作。")
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
                self.passthmFlashLog.append("⚡ 主题素材已暂存（\(targetVer) · \(langs.joined(separator: ", ").uppercased()) · \(targetBold.code)）。正在注入 iOS 缓存…")
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
                    self.passthmFlashLog.append("  正在写入 \(targetName)…")
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
                        self.passthmFlashLog.append("  ⚠️ 写入 \(targetName) 失败：\(lastErr ?? "error")")
                    }
                } else {
                    await MainActor.run {
                        self.passthmFlashLog.append("  ✅ 已注入 \(targetName)")
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
                    self.passthmFlashLog.append("🎉 密码盘主题已应用！锁定 iPhone 即可看到效果。")
                    self.successAlertMessage = "密码盘主题应用成功！\n\n锁定 iPhone（或重启）即可看到新的密码键盘。"
                    self.showSuccessAlert = true
                } else {
                    self.passthmFlashPhase = .done(ok: false)
                    self.passthmFlashLog.append("❌ 有一个或多个主题注入失败。")
                }
            }
        }
    }

    func exportPassthm() -> URL? {
        let keys = effectiveKeys
        guard !keys.isEmpty else {
            errorMessage = "导出前请至少设置一个按键。"
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
                .appendingPathComponent("CocoWall_Custom_\(Int(Date().timeIntervalSince1970)).passthm")
            try zipData.write(to: tempURL)
            self.exportedThemeURL = tempURL
            self.showShareSheet = true
            return tempURL
        } catch {
            errorMessage = "导出主题失败：\(error.localizedDescription)"
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
            // 选择状态不跨启动保留：每次载入都回到未选中，由用户手动勾选。
            self.tendieItems = items
                .filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
                .map { item in
                    var item = item
                    item.isSelected = false
                    return item
                }
        }
    }

    func saveTendieItems() {
        if let data = try? JSONEncoder().encode(tendieItems) {
            UserDefaults.standard.set(data, forKey: "aircard.saved_tendies")
        }
    }

    // MARK: - Tendies 预览再生

    /// 条目展示时若已存预览缺失或解码失败，从其 .tendies 包内重新提取并回写。
    /// 导入时的提取只在导入当下跑一次、失败静默置空，结果又随条目持久化，
    /// 展示侧原本只读已存数据、从不重试，所以在这里补一层展示时再生。
    /// 另对存量条目做一次性 V2 升级：无标记时即使已有可用预览，也用新策略
    /// （按最大图选）重提一次，提到了就覆盖，提不到保留旧预览；跑完无论
    /// 成败都置标记（UserDefaults 键 cocowall.previewV2.<条目 id>），避免
    /// 每次展示重复解压。有标记时回到原行为：仅缺失或解码失败才再生。
    func regenerateTendiePreview(itemID: UUID) {
        guard let idx = tendieItems.firstIndex(where: { $0.id == itemID }) else { return }
        let item = tendieItems[idx]
        let v2Key = "cocowall.previewV2.\(itemID.uuidString)"
        let v2Done = UserDefaults.standard.bool(forKey: v2Key)
        if v2Done, let data = item.previewImageData, UIImage(data: data) != nil { return }
        guard !previewRegenInFlight.contains(itemID) else { return }
        previewRegenInFlight.insert(itemID)
        let packageURL = item.fileURL
        Task {
            let data = await Task.detached(priority: .utility) {
                AppViewModel.extractPreviewData(from: packageURL)
            }.value
            previewRegenInFlight.remove(itemID)
            if !v2Done { UserDefaults.standard.set(true, forKey: v2Key) }
            guard let data,
                  let current = tendieItems.firstIndex(where: { $0.id == itemID }) else { return }
            tendieItems[current].previewImageData = data
            saveTendieItems()
        }
    }

    /// 从 .tendies 包提取预览图：图片扩展名候选先按像素总数从大到小选
    /// （像素相同再比导入时同一套关键词分数）——拼图层式包里人物本体
    /// 往往是最大的那张，关键词打分会把它们全压到最低分、选出碎片图。
    /// 候选全灭时放宽到包内第一张可解码的位图资产（按内容嗅探，不看扩展名）。
    /// 返回下采样后的 JPEG 数据，规格与导入时一致（最长边 600、质量 0.85）。
    nonisolated static func extractPreviewData(from packageURL: URL) -> Data? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendie_preview_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rc = packageURL.path.withCString { arcC in
            tempDir.path.withCString { dstC in
                al_zip_extract_all(arcC, dstC)
            }
        }
        guard rc == 0 else { return nil }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var allFiles: [URL] = []
        var candidates: [(url: URL, pixels: Int, score: Int)] = []
        while let url = enumerator.nextObject() as? URL {
            let pathLower = url.path.lowercased()
            let nameLower = url.lastPathComponent.lowercased()
            if pathLower.contains("__macosx") || nameLower == ".ds_store" { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            allFiles.append(url)

            let ext = url.pathExtension.lowercased()
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
                candidates.append((url, pixelCount(ofFile: url), score))
            }
        }

        candidates.sort {
            if $0.pixels != $1.pixels { return $0.pixels > $1.pixels }
            return $0.score > $1.score
        }
        for candidate in candidates {
            if let data = jpegThumbnail(fromFile: candidate.url) { return data }
        }

        let skipExts: Set<String> = ["plist", "json", "txt", "strings", "ca", "car", "zip", "mlmodel", "bin"]
        for url in allFiles {
            if skipExts.contains(url.pathExtension.lowercased()) { continue }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 40_000_000 { continue }
            if let data = jpegThumbnail(fromFile: url) { return data }
        }
        return nil
    }

    /// 只读图片的像素总数（CGImageSource 读元数据，不做全量解码）；读不到返回 0。
    nonisolated static func pixelCount(ofFile url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return 0 }
        return width * height
    }

    /// 读图、下采样、转 JPEG（与导入时的预览生成规格一致）。
    nonisolated static func jpegThumbnail(fromFile url: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let size = image.size
        let maxSide = max(size.width, size.height)
        var thumb = image
        if maxSide > 600 {
            let scale = 600 / maxSide
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        return thumb.jpegData(compressionQuality: 0.85)
    }

    func importTendieFiles(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var importedCount = 0
        var lastImportedName = ""
        for url in urls {
            do {
                var item = try await TendiesEngine.shared.importTendie(from: url)
                // 导入后默认不勾选（引擎构造时为选中，这里在导入赋值处改回未选中）。
                item.isSelected = false
                await MainActor.run {
                    self.tendieItems.removeAll(where: { $0.fileName == item.fileName })
                    self.tendieItems.append(item)
                    self.saveTendieItems()
                    importedCount += 1
                    lastImportedName = item.name
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "导入 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
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
                    self.errorMessage = "没有生效的配对文件。请先在「配对」页配对设备。"
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
                    self.errorMessage = "自动检测失败：\(error.localizedDescription)\n请确认 LocalDevVPN 已连接且设备已解锁。"
                }
            }
        }
    }

    func flashSelectedTendies() async {
        let selected = tendieItems.filter { $0.isSelected }
        guard !selected.isEmpty else {
            errorMessage = "没有选中要刷入的壁纸。"
            return
        }

        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            errorMessage = "没有生效的配对文件。请先配对设备。"
            return
        }

        var container = posterBoardContainer.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.isEmpty {
            do {
                container = try await TendiesEngine.shared.detectPosterBoardContainer(pairingPath: pairingPath)
                self.posterBoardContainer = container
                UserDefaults.standard.set(container, forKey: "aircard.posterboard_container")
            } catch {
                errorMessage = "无法自动找到 PosterBoard 容器。请确认 LocalDevVPN 已连接且 iPhone 已解锁。"
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
            tendiesFlashLog.append("🎉 壁纸应用成功！")
            tendiesFlashLog.append("正在刷新系统壁纸…")

            // 先试免注销刷新（只重启 PosterBoard 守护进程）；本版不自动注销兜底：
            // 未确认时只如实提示，用户可自行点「注销（NeoSpring）」手动注销。
            PosterRefreshHelper.attemptRefresh(
                pairingPath: pairingPath,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.tendiesFlashLog.append(line)
                    }
                }
            ) { [weak self] confirmed, _ in
                guard let self else { return }
                if confirmed {
                    self.tendiesFlashLog.append("✅ 系统壁纸已刷新，免注销生效。")
                } else {
                    self.tendiesFlashLog.append("⚠️ 壁纸已写入，自动刷新未确认（本版不自动注销；如未生效可手动点注销）。")
                }
            }
        } catch {
            tendiesFlashLog.append("❌ 错误：\(error.localizedDescription)")
            tendiesFlashPhase = .done(ok: false)
        }
    }

    func respringDevice() {
        tendiesFlashLog.append("⚡ 正在触发 NeoSpring 注销…")
        isNeoSpringing = true
        RespringHelper.triggerNeoSpring()
    }

    // MARK: - Device PosterBoard store detection / cleanup

    /// PRBPosterExtensionDataStore layout version: 61 on iOS 17+, 59 below
    /// (same split the flash path uses).
    private var posterStoreStructVersion: Int {
        let major = Int(UIDevice.current.systemVersion.split(separator: ".").first ?? "0") ?? 0
        return major >= 17 ? 61 : 59
    }

    /// Shared preamble for the device-store operations: pairing file must
    /// exist, and the PosterBoard container must be known (auto-detect and
    /// persist it exactly like the flash flow does). Returns nil after
    /// recording the reason in devicePosterStatus.
    private func posterStoreContext() async -> (pairingPath: String, container: String)? {
        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            devicePosterStatus = "没有生效的配对文件。请先配对设备。"
            return nil
        }
        var container = posterBoardContainer.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.isEmpty {
            do {
                container = try await TendiesEngine.shared.detectPosterBoardContainer(pairingPath: pairingPath)
                self.posterBoardContainer = container
                UserDefaults.standard.set(container, forKey: "aircard.posterboard_container")
            } catch {
                devicePosterStatus = "无法自动找到 PosterBoard 容器：\(error.localizedDescription)"
                return nil
            }
        }
        return (pairingPath, container)
    }

    /// 检测本机已导入的壁纸： enumerates the descriptors actually present in
    /// the device's PosterBoard data store (device-side truth; never the
    /// local library list).
    func detectDevicePosters(clearStatus: Bool = true) async {
        guard !isScanningDevicePosters else { return }
        if clearStatus { devicePosterStatus = "" }
        guard let ctx = await posterStoreContext() else { return }

        isScanningDevicePosters = true
        devicePosters = []
        devicePosterSelection = []
        let version = posterStoreStructVersion
        let result: Result<[DevicePosterItem], PosterStoreError> = await withCheckedContinuation { cont in
            PosterStoreHelper.listImported(
                pairingPath: ctx.pairingPath,
                containerPath: ctx.container,
                structVersion: version,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.tendiesFlashLog.append(line)
                    }
                }
            ) { result in
                cont.resume(returning: result)
            }
        }
        isScanningDevicePosters = false
        switch result {
        case .success(let items):
            devicePosters = items
            if items.isEmpty && devicePosterStatus.isEmpty {
                devicePosterStatus = "设备数据仓里没有检测到已导入的壁纸。"
            }
        case .failure(let err):
            devicePosterStatus = "检测失败：\(err.localizedDescription)"
        }
    }

    /// 清理所选： deletes the selected descriptors from the device data
    /// store, refreshes the list, then tries the no-respring PosterBoard
    /// refresh so the removal takes effect.
    func cleanupSelectedDevicePosters() async {
        guard !isCleaningDevicePosters else { return }
        let targets = devicePosters.filter { devicePosterSelection.contains($0.id) }
        guard !targets.isEmpty else { return }
        guard let ctx = await posterStoreContext() else { return }

        isCleaningDevicePosters = true
        let version = posterStoreStructVersion
        let result: Result<(deleted: Int, failed: Int), PosterStoreError> = await withCheckedContinuation { cont in
            PosterStoreHelper.deleteImported(
                pairingPath: ctx.pairingPath,
                containerPath: ctx.container,
                structVersion: version,
                targets: targets,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.tendiesFlashLog.append(line)
                    }
                }
            ) { result in
                cont.resume(returning: result)
            }
        }

        switch result {
        case .success(let r):
            var message = "清理完成：成功 \(r.deleted) 条"
            if r.failed > 0 { message += "，失败 \(r.failed) 条" }
            message += "。"
            await detectDevicePosters(clearStatus: false)
            devicePosterStatus = message
            isCleaningDevicePosters = false
            // Removal only takes effect once PosterBoard re-reads its
            // store — try the免注销 refresh; on failure just report it
            // (this版不自动注销, same rule as the flash flow).
            PosterRefreshHelper.attemptRefresh(
                pairingPath: ctx.pairingPath,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.tendiesFlashLog.append(line)
                    }
                }
            ) { [weak self] confirmed, _ in
                guard let self else { return }
                if confirmed {
                    self.devicePosterStatus += "已刷新 PosterBoard，删除已生效。"
                } else {
                    self.devicePosterStatus += "自动刷新未确认，如列表未更新可手动点注销生效。"
                }
            }
        case .failure(let err):
            isCleaningDevicePosters = false
            devicePosterStatus = "清理失败：\(err.localizedDescription)"
        }
    }

    func reset() {
        passthmFlashPhase = .idle
        passthmFlashProgress = 0
        tendiesFlashPhase = .idle
        tendiesFlashProgress = 0
        errorMessage = nil
    }
}

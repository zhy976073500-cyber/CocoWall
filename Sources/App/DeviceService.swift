import AirliftFFI
import Foundation

/// PosterBoard write primitives exposed by the device layer.
///
/// All implementations run in the vendored AirliftFFI Rust core
/// (AirCard-iOS's library, copied verbatim — see
/// rust-core/VENDORED.md) behind the C FFI. FFIDeviceService below is
/// the real wiring: every call crosses into the core, streams its log
/// lines to the optional sink, and surfaces core errors verbatim —
/// never papered over.
///
/// The full apply sequence (`applyWallpaper`) is orchestrated here in
/// Swift and mirrors AirCard-iOS's TendiesEngine.flashTendies step for
/// step: fresh extraction, descriptor discovery with the upstream
/// extension rules, a new uppercase UUID per descriptor, identifier
/// rewrite under the upstream conditions, primary injection, the
/// iOS 18+ dual injection, and the refresh plist written to both
/// preference locations.
protocol DeviceService {
    /// Resolves the on-device PosterBoard data container path.
    func detectPosterBoardContainer(pairingFile: URL) async throws -> String
    /// Injects one folder into `targetParentDir` on the device as
    /// `destName`.
    func injectFolder(
        _ folder: URL, targetParentDir: String, destName: String, pairingFile: URL
    ) async throws
    /// Writes every file directly inside a local directory into a
    /// device directory (Books-class AirTraffic sync).
    func writeDirectory(_ source: URL, targetDir: String, pairingFile: URL) async throws
    /// Full wallpaper apply for one stored .tendies archive:
    /// container lookup, extraction, descriptor discovery, identifier
    /// rewrite, primary inject, iOS 18+ dual inject, refresh plist.
    func applyWallpaper(archive: URL, pairingFile: URL) async throws -> WallpaperApplyReport
    /// Reads back how many descriptors the gallery currently holds.
    func galleryDescriptorCount(containerPath: String) async throws -> Int
    /// Restarts the device (SpringBoard respring) via DiagnosticsRelay.
    func respring(pairingFile: URL) async throws
}

/// Outcome of one apply run, produced by the Swift orchestration.
struct WallpaperApplyReport {
    /// Target descriptor UUID of the (first) injected descriptor.
    let uuid: String
    let identifierRewritten: Bool
    /// The upstream core exposes no gallery count readback; its
    /// injection call is itself the confirmation (the same standard
    /// the upstream app applies). These stay nil.
    let primaryBefore: Int?
    let primaryAfter: Int?
    /// nil = the injection calls succeeded; the upstream flow has no
    /// separate unconfirmed state.
    let primaryUnconfirmed: String?
    /// "ok" | "skipped" | "failed: <error>"
    let dual: String
    let productVersion: String?
}

enum DeviceServiceError: LocalizedError {
    case notLinked
    case coreFailed(String)
    var errorDescription: String? {
        switch self {
        case .notLinked:
            return "设备写入服务尚未链接（AirliftFFI 未集成到本 App），此操作暂不可用。"
        case .coreFailed(let message):
            return message
        }
    }
}

/// Placeholder used where the FFI is not wanted (previews): every
/// primitive throws DeviceServiceError.notLinked so callers surface an
/// honest failure.
struct UnavailableDeviceService: DeviceService {
    func detectPosterBoardContainer(pairingFile: URL) async throws -> String {
        throw DeviceServiceError.notLinked
    }

    func injectFolder(
        _ folder: URL, targetParentDir: String, destName: String, pairingFile: URL
    ) async throws {
        throw DeviceServiceError.notLinked
    }

    func writeDirectory(_ source: URL, targetDir: String, pairingFile: URL) async throws {
        throw DeviceServiceError.notLinked
    }

    func applyWallpaper(archive: URL, pairingFile: URL) async throws -> WallpaperApplyReport {
        throw DeviceServiceError.notLinked
    }

    func galleryDescriptorCount(containerPath: String) async throws -> Int {
        throw DeviceServiceError.notLinked
    }

    func respring(pairingFile: URL) async throws {
        throw DeviceServiceError.notLinked
    }
}

/// Per-call log routing for the core's C log callback: the box is
/// retained for exactly the duration of one blocking FFI call.
private final class CoreLogBox {
    let sink: (String) -> Void
    init(sink: @escaping (String) -> Void) { self.sink = sink }
}

private func coreLogTrampoline(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let ctx, let msg else { return }
    Unmanaged<CoreLogBox>.fromOpaque(ctx).takeUnretainedValue().sink(String(cString: msg))
}

/// Real FFI-backed service. All work runs off the main actor on a
/// detached task: the core calls block while the device answers.
struct FFIDeviceService: DeviceService {
    /// Provenance label of the linked core; shown in Settings.
    static var coreVersion: String { CoreBridge.version }

    /// Optional recipient for the core's per-call log lines (the apply
    /// UI uses it to render the segmented progress log live).
    var logSink: ((String) -> Void)?

    init(logSink: ((String) -> Void)? = nil) {
        self.logSink = logSink
    }

    func detectPosterBoardContainer(pairingFile: URL) async throws -> String {
        try await Self.offMain { try self.detectContainerSync(pairingFile: pairingFile) }
    }

    func injectFolder(
        _ folder: URL, targetParentDir: String, destName: String, pairingFile: URL
    ) async throws {
        try await Self.offMain {
            try self.injectFolderSync(
                folder, targetParentDir: targetParentDir, destName: destName, pairingFile: pairingFile)
        }
    }

    func writeDirectory(_ source: URL, targetDir: String, pairingFile: URL) async throws {
        try await Self.offMain {
            try self.writeDirectorySync(source, targetDir: targetDir, pairingFile: pairingFile)
        }
    }

    func applyWallpaper(archive: URL, pairingFile: URL) async throws -> WallpaperApplyReport {
        try await Self.offMain { try self.applySync(archive: archive, pairingFile: pairingFile) }
    }

    func galleryDescriptorCount(containerPath: String) async throws -> Int {
        // The upstream core exposes no count entry point: its
        // injection call is itself the confirmation, and the gallery
        // is checked by eye after the respring. Say so instead of
        // inventing a number.
        throw DeviceServiceError.coreFailed(
            "核心未提供计数入口：注入调用成功即为确认，最终效果请在重启后到锁屏图库查看。")
    }

    func respring(pairingFile: URL) async throws {
        try await Self.offMain { try self.respringSync(pairingFile: pairingFile) }
    }

    // MARK: - Synchronous FFI primitives

    private func detectContainerSync(pairingFile: URL) throws -> String {
        var container: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = self.withLog { cb, ctx in
            pairingFile.path.withCString { pairing in
                "com.apple.PosterBoard".withCString { bundle in
                    al_find_app_container(pairing, bundle, cb, ctx, &container, &error)
                }
            }
        }
        defer {
            al_string_free(container)
            al_string_free(error)
        }
        if rc == 0, let container {
            return String(cString: container)
        }
        throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
    }

    private func injectFolderSync(
        _ folder: URL, targetParentDir: String, destName: String, pairingFile: URL
    ) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = self.withLog { cb, ctx in
            pairingFile.path.withCString { pairing in
                folder.path.withCString { folderPath in
                    targetParentDir.withCString { parent in
                        destName.withCString { dest in
                            al_exploit_inject_folder(
                                pairing, folderPath, parent, dest, cb, ctx, &error)
                        }
                    }
                }
            }
        }
        defer { al_string_free(error) }
        if rc != 0 {
            throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
        }
    }

    private func writeDirectorySync(_ source: URL, targetDir: String, pairingFile: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = self.withLog { cb, ctx in
            pairingFile.path.withCString { pairing in
                source.path.withCString { src in
                    targetDir.withCString { dst in
                        al_exploit_write_dir(pairing, src, dst, cb, ctx, &error)
                    }
                }
            }
        }
        defer { al_string_free(error) }
        if rc != 0 {
            throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
        }
    }

    private func respringSync(pairingFile: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = self.withLog { cb, ctx in
            pairingFile.path.withCString { pairing in
                al_device_respring(pairing, cb, ctx, &error)
            }
        }
        defer { al_string_free(error) }
        if rc != 0 {
            throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
        }
    }

    // MARK: - Apply orchestration (mirrors TendiesEngine.flashTendies)

    private func applySync(archive: URL, pairingFile: URL) throws -> WallpaperApplyReport {
        let fm = FileManager.default
        let log = { (line: String) in self.logSink?(line) }

        // Container path, normalized exactly as flashTendies does.
        var container = try detectContainerSync(pairingFile: pairingFile)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if container.hasSuffix("/") {
            container = String(container.dropLast())
        }
        guard !container.isEmpty else {
            throw DeviceServiceError.coreFailed("PosterBoard 容器路径为空，无法注入。")
        }

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let major = osVersion.majorVersion
        let structVersion = major <= 16 ? 59 : 61
        log("应用：开始注入 PosterBoard（结构版本 \(structVersion)，iOS \(major)）")
        log("应用：容器 \(container)")

        // Fresh extraction of the stored archive, as flashTendies does.
        let stageDir = fm.temporaryDirectory
            .appendingPathComponent("tendie_flash_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        let extractRC = archive.path.withCString { arcC in
            stageDir.path.withCString { dstC in
                al_zip_extract_all(arcC, dstC)
            }
        }
        guard extractRC == 0 else {
            throw DeviceServiceError.coreFailed("解包 .tendies 失败（核心返回 \(extractRC)）")
        }

        let descriptors = TendiesFlash.findDescriptorsWithExtensions(
            in: stageDir, defaultExt: TendiesFlash.defaultExtension)
        log("应用：找到 \(descriptors.count) 个 descriptor")

        var firstUUID = ""
        var anyRewrite = false
        var dualAttempted = false
        var dualFailure: String?

        for desc in descriptors {
            let targetUUID = UUID().uuidString.uppercased()
            if firstUUID.isEmpty { firstUUID = targetUUID }
            let randomizedID = Int.random(in: 10000...99999)
            if TendiesFlash.updatePlistIdentifiers(in: desc.url, randomizedID: randomizedID) {
                anyRewrite = true
            }

            // 1. Primary destination: matches descriptor extension bundle ID
            let primaryParent = "\(container)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(desc.ext)/descriptors"
            log("应用：注入 \(targetUUID)（\(desc.ext)）→ \(primaryParent)")
            try injectFolderSync(
                desc.url, targetParentDir: primaryParent, destName: targetUUID, pairingFile: pairingFile)

            // 2. On iOS 18+, also dual-inject to the modern .Posters.<Name>App container
            var modernExt: String?
            if desc.ext == "com.apple.WallpaperKit.CollectionsPoster" {
                modernExt = "com.apple.Posters.CollectionsPosterApp"
            } else if desc.ext == "com.apple.MercuryPoster" {
                modernExt = "com.apple.Posters.MercuryPosterApp"
            }
            if let modernExt, major >= 18 {
                dualAttempted = true
                let modernParent = "\(container)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(modernExt)/descriptors"
                log("应用：双写 \(targetUUID) → \(modernParent)")
                do {
                    try injectFolderSync(
                        desc.url, targetParentDir: modernParent, destName: targetUUID, pairingFile: pairingFile)
                } catch {
                    dualFailure = error.localizedDescription
                    log("应用：双写失败（尽力而为）：\(dualFailure ?? "")")
                }
            }
        }

        // Always force PosterBoard cache refresh and file protections reset
        log("应用：写入刷新 plist（强制 PosterBoard 重读图库并重置文件保护）")
        let prefStage = fm.temporaryDirectory
            .appendingPathComponent("tendie_pref_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: prefStage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: prefStage) }
        let prefPlistURL = prefStage.appendingPathComponent(
            "com.apple.PosterBoard.unprotectedUserDefaults.plist")
        try TendiesFlash.refreshPlistData().write(to: prefPlistURL)

        try writeDirectorySync(
            prefStage, targetDir: "\(container)/Library/Preferences", pairingFile: pairingFile)
        // Also write to mobile global preferences for system daemon lookup (best effort)
        do {
            try writeDirectorySync(
                prefStage, targetDir: "/var/mobile/Library/Preferences", pairingFile: pairingFile)
        } catch {
            log("应用：全局偏好写入失败（尽力而为）：\(error.localizedDescription)")
        }
        log("应用：注入完成")

        let dualStatus: String
        if !dualAttempted {
            dualStatus = "skipped"
        } else if let dualFailure {
            dualStatus = "failed: \(dualFailure)"
        } else {
            dualStatus = "ok"
        }

        return WallpaperApplyReport(
            uuid: firstUUID,
            identifierRewritten: anyRewrite,
            primaryBefore: nil,
            primaryAfter: nil,
            primaryUnconfirmed: nil,
            dual: dualStatus,
            productVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")
    }

    // MARK: - Helpers

    /// Runs `work` with the core log callback wired to `logSink` when
    /// one is set; the box lives exactly for the call.
    private func withLog<T>(_ work: (ALLogCallback?, UnsafeMutableRawPointer?) -> T) -> T {
        guard let logSink else { return work(nil, nil) }
        let box = CoreLogBox(sink: logSink)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<CoreLogBox>.fromOpaque(ctx).release() }
        return work(coreLogTrampoline, ctx)
    }

    private static func message(from error: UnsafeMutablePointer<CChar>?, rc: Int32) -> String {
        if let error {
            return String(cString: error)
        }
        return "核心调用失败（rc=\(rc)）"
    }

    private static func offMain<T: Sendable>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }
}

import CocoWallCore
import Foundation

/// PosterBoard write primitives exposed by the device layer.
///
/// The shapes mirror the write-channel operations catalogued in
/// research/write-path.md, plus the two read-side operations the flow
/// needs: locating the PosterBoard container and the full wallpaper
/// apply sequence.
///
/// All implementations run in the Rust `idevice` core (cocowall-core)
/// behind the C FFI. FFIDeviceService below is the real wiring: every
/// call crosses into the core, streams its log lines to the optional
/// sink, and surfaces core errors verbatim — never papered over.
protocol DeviceService {
    /// Resolves the on-device PosterBoard data container path.
    func detectPosterBoardContainer(pairingFile: URL) async throws -> String
    /// Injects one folder into `targetParentDir` on the device as
    /// `destName`, verified by reading the gallery count back.
    func injectFolder(
        _ folder: URL, targetParentDir: String, destName: String, pairingFile: URL
    ) async throws
    /// Writes every file directly inside a local directory into a
    /// device directory (Books-class AirTraffic sync).
    func writeDirectory(_ source: URL, targetDir: String, pairingFile: URL) async throws
    /// Full wallpaper apply for one extracted descriptor folder:
    /// container lookup, fresh UUID + identifier rewrite on a staging
    /// copy, primary inject, iOS 18+ dual inject, refresh plist.
    func applyWallpaper(descriptorDir: URL, pairingFile: URL) async throws -> WallpaperApplyReport
    /// Reads back how many descriptors the gallery currently holds.
    func galleryDescriptorCount(containerPath: String) async throws -> Int
    /// Restarts the device (SpringBoard respring) via DiagnosticsRelay.
    func respring(pairingFile: URL) async throws
}

/// Parsed from the JSON report cw_wallpaper_apply returns.
struct WallpaperApplyReport: Decodable {
    let uuid: String
    let identifierRewritten: Bool
    let primaryBefore: Int
    let primaryAfter: Int
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
            return "设备写入服务尚未链接（idevice FFI 未集成到本 App），此操作暂不可用。"
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

    func applyWallpaper(descriptorDir: URL, pairingFile: URL) async throws -> WallpaperApplyReport {
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
    /// Answered by the core itself; shown in Settings as proof of link.
    static var coreVersion: String { CoreBridge.version }

    /// Optional recipient for the core's per-call log lines (the apply
    /// UI uses it to render the segmented progress log live).
    var logSink: ((String) -> Void)?

    init(logSink: ((String) -> Void)? = nil) {
        self.logSink = logSink
    }

    func detectPosterBoardContainer(pairingFile: URL) async throws -> String {
        try await Self.offMain {
            var container: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let rc = self.withLog { cb, ctx in
                pairingFile.path.withCString { pairing in
                    "com.apple.PosterBoard".withCString { bundle in
                        cw_find_app_container(pairing, bundle, cb, ctx, &container, &error)
                    }
                }
            }
            defer {
                cw_string_free(container)
                cw_string_free(error)
            }
            if rc == 0, let container {
                return String(cString: container)
            }
            throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
        }
    }

    func injectFolder(
        _ folder: URL, targetParentDir: String, destName: String, pairingFile: URL
    ) async throws {
        try await Self.offMain {
            var error: UnsafeMutablePointer<CChar>?
            let rc = self.withLog { cb, ctx in
                pairingFile.path.withCString { pairing in
                    folder.path.withCString { folderPath in
                        targetParentDir.withCString { parent in
                            destName.withCString { dest in
                                cw_exploit_inject_folder(
                                    pairing, folderPath, parent, dest, cb, ctx, &error)
                            }
                        }
                    }
                }
            }
            defer { cw_string_free(error) }
            if rc != 0 {
                throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
            }
        }
    }

    func writeDirectory(_ source: URL, targetDir: String, pairingFile: URL) async throws {
        try await Self.offMain {
            var error: UnsafeMutablePointer<CChar>?
            let rc = self.withLog { cb, ctx in
                pairingFile.path.withCString { pairing in
                    source.path.withCString { src in
                        targetDir.withCString { dst in
                            cw_exploit_write_dir(pairing, src, dst, cb, ctx, &error)
                        }
                    }
                }
            }
            defer { cw_string_free(error) }
            if rc != 0 {
                throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
            }
        }
    }

    func applyWallpaper(descriptorDir: URL, pairingFile: URL) async throws -> WallpaperApplyReport {
        let json = try await Self.offMain {
            var report: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let rc = self.withLog { cb, ctx in
                pairingFile.path.withCString { pairing in
                    descriptorDir.path.withCString { dir in
                        cw_wallpaper_apply(pairing, dir, cb, ctx, &report, &error)
                    }
                }
            }
            defer {
                cw_string_free(report)
                cw_string_free(error)
            }
            if rc == 0, let report {
                return String(cString: report)
            }
            throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
        }
        guard let data = json.data(using: .utf8),
              let report = try? JSONDecoder().decode(WallpaperApplyReport.self, from: data)
        else {
            throw DeviceServiceError.coreFailed("核心返回的应用报告无法解析：\(json)")
        }
        return report
    }

    func galleryDescriptorCount(containerPath: String) async throws -> Int {
        // The core exposes no standalone count entry point: the count is
        // read back inside the injection flow itself (device.rs) and
        // reported with its result. Say so instead of inventing a number.
        throw DeviceServiceError.coreFailed(
            "核心未提供独立的计数入口：gallery 计数在注入流程内回读校验。")
    }

    func respring(pairingFile: URL) async throws {
        try await Self.offMain {
            var error: UnsafeMutablePointer<CChar>?
            let rc = self.withLog { cb, ctx in
                pairingFile.path.withCString { pairing in
                    cw_device_respring(pairing, cb, ctx, &error)
                }
            }
            defer { cw_string_free(error) }
            if rc != 0 {
                throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
            }
        }
    }

    // MARK: - Helpers

    /// Runs `work` with the core log callback wired to `logSink` when
    /// one is set; the box lives exactly for the call.
    private func withLog<T>(_ work: (CWLogCallback?, UnsafeMutableRawPointer?) -> T) -> T {
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

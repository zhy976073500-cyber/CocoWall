import CocoWallCore
import Foundation

/// PosterBoard write primitives exposed by the device layer.
///
/// The shapes mirror the airlift exploit entry points catalogued in
/// research/write-path.md (exploit_inject_folder / exploit_write_batch /
/// exploit_write_single_file), plus the two read-side operations the flow
/// needs: locating the PosterBoard container and reading back the gallery
/// descriptor count after an injection.
///
/// Implementations run in the Rust `idevice` core (cocowall-core) behind
/// the C FFI, linked as CocoWallCore.xcframework. FFIDeviceService below
/// is the real wiring: every call crosses into the core. The injection
/// ring (AFC staging + AirTraffic sync) has not landed in the core yet,
/// so those calls come back with the core's own
/// "注入环未落地" error — surfaced verbatim, never papered over.
protocol DeviceService {
    /// Resolves the on-device PosterBoard data container path.
    func detectPosterBoardContainer(pairingFile: URL) async throws -> String
    /// Injects one descriptor folder into the container's descriptors store.
    func injectFolder(_ folder: URL, pairingFile: URL) async throws
    /// Batch-writes files staged for an AirTraffic sync.
    func writeBatch(files: [URL], pairingFile: URL) async throws
    /// Writes a single file (e.g. the patched Books.plist).
    func writeSingleFile(_ file: URL, pairingFile: URL) async throws
    /// Reads back how many descriptors the gallery currently holds.
    func galleryDescriptorCount(containerPath: String) async throws -> Int
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

/// Placeholder used until the idevice FFI lands: every primitive throws
/// DeviceServiceError.notLinked so callers surface an honest failure.
struct UnavailableDeviceService: DeviceService {
    func detectPosterBoardContainer(pairingFile: URL) async throws -> String {
        throw DeviceServiceError.notLinked
    }

    func injectFolder(_ folder: URL, pairingFile: URL) async throws {
        throw DeviceServiceError.notLinked
    }

    func writeBatch(files: [URL], pairingFile: URL) async throws {
        throw DeviceServiceError.notLinked
    }

    func writeSingleFile(_ file: URL, pairingFile: URL) async throws {
        throw DeviceServiceError.notLinked
    }

    func galleryDescriptorCount(containerPath: String) async throws -> Int {
        throw DeviceServiceError.notLinked
    }
}

/// Real FFI-backed service. All work runs off the main actor on a
/// detached task: the core calls block while the device answers.
struct FFIDeviceService: DeviceService {
    /// Answered by the core itself; shown in Settings as proof of link.
    static var coreVersion: String { CoreBridge.version }

    func detectPosterBoardContainer(pairingFile: URL) async throws -> String {
        try await Self.offMain {
            var container: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let rc = pairingFile.path.withCString { pairing in
                "com.apple.PosterBoard".withCString { bundle in
                    cw_find_app_container(pairing, bundle, nil, nil, &container, &error)
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

    func injectFolder(_ folder: URL, pairingFile: URL) async throws {
        try await Self.offMain {
            var error: UnsafeMutablePointer<CChar>?
            let rc = pairingFile.path.withCString { pairing in
                folder.path.withCString { folderPath in
                    "".withCString { parent in
                        "".withCString { dest in
                            cw_exploit_inject_folder(
                                pairing, folderPath, parent, dest, nil, nil, &error)
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

    func writeBatch(files: [URL], pairingFile: URL) async throws {
        // The core's write primitive is directory-shaped; a batch is
        // staged from the files' common parent directory.
        guard let first = files.first else { return }
        try await writeDir(
            source: first.deletingLastPathComponent(), target: "", pairingFile: pairingFile)
    }

    func writeSingleFile(_ file: URL, pairingFile: URL) async throws {
        try await writeDir(
            source: file.deletingLastPathComponent(), target: "", pairingFile: pairingFile)
    }

    func galleryDescriptorCount(containerPath: String) async throws -> Int {
        // The core exposes no standalone count entry point: the count is
        // read back inside the injection flow itself (device.rs) and
        // reported with its result. Say so instead of inventing a number.
        throw DeviceServiceError.coreFailed(
            "核心未提供独立的计数入口：gallery 计数在注入流程内回读校验。")
    }

    // MARK: - Helpers

    private func writeDir(source: URL, target: String, pairingFile: URL) async throws {
        try await Self.offMain {
            var error: UnsafeMutablePointer<CChar>?
            let rc = pairingFile.path.withCString { pairing in
                source.path.withCString { src in
                    target.withCString { dst in
                        cw_exploit_write_dir(pairing, src, dst, nil, nil, &error)
                    }
                }
            }
            defer { cw_string_free(error) }
            if rc != 0 {
                throw DeviceServiceError.coreFailed(Self.message(from: error, rc: rc))
            }
        }
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

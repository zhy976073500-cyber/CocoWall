import Foundation

/// PosterBoard write primitives exposed by the device layer.
///
/// The shapes mirror the airlift exploit entry points catalogued in
/// research/write-path.md (exploit_inject_folder / exploit_write_batch /
/// exploit_write_single_file), plus the two read-side operations the flow
/// needs: locating the PosterBoard container and reading back the gallery
/// descriptor count after an injection.
///
/// The real implementations run in the Rust `idevice` core behind a C FFI,
/// which is NOT linked into this build yet. Until it is, the only
/// implementation is UnavailableDeviceService and every call fails loudly
/// instead of pretending a write happened.
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
    var errorDescription: String? {
        switch self {
        case .notLinked:
            return "设备写入服务尚未链接（idevice FFI 未集成到本 App），此操作暂不可用。"
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

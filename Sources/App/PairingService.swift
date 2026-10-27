import Foundation

/// Pairing state and entry points.
///
/// Two routes, forked by OS version (see SPEC.md / research):
/// - iOS 27+: on-device RPPairing host — publish the Bonjour pairable-host
///   service, the user confirms a PIN in Settings › Developer Mode, and the
///   core writes an RPPairing file.
/// - iOS 17–26: import an existing pairing file (.mobiledevicepairing /
///   .plist / .mobilepair) produced by SideStore, iLoader, AltStore,
///   Jitterbug or a computer.
///
/// All protocol work runs in the Rust core (cocowall-core) behind the C FFI;
/// this type is the Swift-side state machine only.
@MainActor
final class PairingService: ObservableObject {
    enum State {
        case unpaired
        case hosting(pin: String?)          // iOS 27+ host is live, waiting for the device
        case paired(filePath: String)
        case failed(String)
    }
    @Published private(set) var state: State = .unpaired

    static var pairingDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pairing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The one stored pairing file: Documents/pairing/pairing.plist.
    static var pairingFileURL: URL {
        pairingDirectory.appendingPathComponent("pairing.plist")
    }

    init() {
        // A pairing file stored by a previous launch is still valid input
        // for the core, so restore the paired state from disk.
        if FileManager.default.fileExists(atPath: Self.pairingFileURL.path) {
            state = .paired(filePath: Self.pairingFileURL.path)
        }
    }

    var pairingFilePath: String? {
        if case .paired(let path) = state { return path }
        return nil
    }

    enum PairingError: LocalizedError {
        case notAPlistDictionary
        var errorDescription: String? {
            "文件不是有效的 plist 字典，不是可用的配对文件。"
        }
    }

    /// Validates imported pairing data (must parse as a plist dictionary)
    /// and stores it as Documents/pairing/pairing.plist.
    func importPairing(data: Data) {
        do {
            let object = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
            guard object is [String: Any] else { throw PairingError.notAPlistDictionary }
            try data.write(to: Self.pairingFileURL, options: .atomic)
            state = .paired(filePath: Self.pairingFileURL.path)
        } catch {
            state = .failed("配对文件导入失败：\(error.localizedDescription)")
        }
    }

    func importFailed(_ error: Error) {
        state = .failed("配对文件读取失败：\(error.localizedDescription)")
    }

    func forget() {
        try? FileManager.default.removeItem(at: Self.pairingFileURL)
        state = .unpaired
    }

    // MARK: - iOS 27+ on-device host (core-backed; wired in M1)

    func startOnDevicePairing() {
        // TODO(M1): call core pairing host; ready callback publishes the
        // Bonjour service, PIN callback moves state to .hosting(pin:).
        // Until the core is linked this must not pretend to be broadcasting.
        state = .failed("机内配对尚未集成（Rust 核心未链接），请先导入配对文件。")
    }
}

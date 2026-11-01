//
//  PosterStoreHelper.swift
//  CocoWall
//
//  Device-side PosterBoard data-store detection + cleanup: asks the Rust
//  core (al_poster_store_list / al_poster_store_delete) to enumerate the
//  descriptors actually present in the device's PRBPosterExtensionDataStore
//  (AFC over the RSD tunnel) and to delete user-selected ones — deletion
//  moves each descriptor out of the store via an AirTraffic/Books sync
//  into a Media quarantine copy (the Walllive-verified mechanism), then
//  re-audits every deleted path absent on a fresh connection. This is
//  deliberately separate from the local imported-.tendies library — the
//  items here come from the device, not from the app's own records.
//

import Foundation
import AirliftFFI

/// One descriptor found in the device's PosterBoard data store.
public struct DevicePosterItem: Identifiable, Hashable, Codable {
    public let extensionId: String
    public let uuid: String
    public let identifier: String
    public let packageName: String
    public let name: String

    public var id: String { "\(extensionId)/\(uuid)" }

    /// FFI delete target string ("<extension>/<uuid>").
    public var target: String { id }

    enum CodingKeys: String, CodingKey {
        case extensionId = "extension"
        case uuid
        case identifier
        case packageName
        case name
    }
}

public enum PosterStoreError: LocalizedError {
    case failed(status: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .failed(let status, let message):
            return message.isEmpty ? "设备检测失败（\(status)）" : message
        }
    }
}

public enum PosterStoreHelper {

    /// Boxed log sink so the C log callback can forward Rust log lines
    /// (the airlift.poster_store.* stage trail) to Swift.
    final class LogBox {
        let handler: (String) -> Void
        init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    }

    private struct ListResponse: Codable {
        let items: [DevicePosterItem]
    }

    struct DeleteResponse: Codable {
        struct ItemResult: Codable {
            let `extension`: String
            let uuid: String
            let ok: Bool
            /// Media quarantine folder the descriptor was moved into
            /// (run #115: decoded so the caller can persist a recovery
            /// receipt; the Rust payload has carried it all along).
            let quarantine: String
        }
        let deleted: Int
        let failed: Int
        let results: [ItemResult]
    }

    /// One airlift-quarantine-* folder found in the device Media
    /// root (run #115 recovery). Provenance fields are best-effort
    /// content reads; the delete receipts outrank them.
    struct QuarantineItem: Codable {
        let quarantine: String
        let uuid: String
        let descriptorIdentifier: String
        let packageName: String
        let providerGuess: String
    }

    private struct QuarantineListResponse: Codable {
        let items: [QuarantineItem]
    }

    struct RestoreResponse: Codable {
        struct ItemResult: Codable {
            let `extension`: String
            let uuid: String
            let quarantine: String
            let ok: Bool
        }
        let restored: Int
        let failed: Int
        let results: [ItemResult]
    }

    /// Lists the descriptors actually present in the device data store.
    /// Completion is called on the main queue.
    public static func listImported(
        pairingPath: String,
        containerPath: String,
        structVersion: Int,
        log: @escaping (String) -> Void,
        completion: @escaping (Result<[DevicePosterItem], PosterStoreError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let box = LogBox(log)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            var outJSON: UnsafeMutablePointer<CChar>?
            var outStatus: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pC in
                containerPath.withCString { cC in
                    al_poster_store_list(
                        pC, cC, Int64(structVersion),
                        posterStoreLogThunk, ctx,
                        &outJSON, &outStatus, &outError
                    )
                }
            }
            Unmanaged<LogBox>.fromOpaque(ctx).release()

            let json = outJSON.map { String(cString: $0) }
            let status = outStatus.map { String(cString: $0) } ?? "connectFailed"
            let message = outError.map { String(cString: $0) } ?? ""
            if let outJSON { al_string_free(outJSON) }
            if let outStatus { al_string_free(outStatus) }
            if let outError { al_string_free(outError) }

            let result: Result<[DevicePosterItem], PosterStoreError>
            if rc == 0, let json, let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(ListResponse.self, from: data) {
                result = .success(decoded.items)
            } else {
                result = .failure(.failed(status: status, message: message))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Deletes the given descriptors from the device data store.
    /// Completion is called on the main queue with the full response
    /// (counts + per-item results incl. quarantine folders).
    public static func deleteImported(
        pairingPath: String,
        containerPath: String,
        structVersion: Int,
        targets: [DevicePosterItem],
        log: @escaping (String) -> Void,
        completion: @escaping (Result<DeleteResponse, PosterStoreError>) -> Void
    ) {
        let targetsCSV = targets.map { $0.target }.joined(separator: ",")
        DispatchQueue.global(qos: .userInitiated).async {
            let box = LogBox(log)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            var outJSON: UnsafeMutablePointer<CChar>?
            var outStatus: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pC in
                containerPath.withCString { cC in
                    targetsCSV.withCString { tC in
                        al_poster_store_delete(
                            pC, cC, Int64(structVersion), tC,
                            posterStoreLogThunk, ctx,
                            &outJSON, &outStatus, &outError
                        )
                    }
                }
            }
            Unmanaged<LogBox>.fromOpaque(ctx).release()

            let json = outJSON.map { String(cString: $0) }
            let status = outStatus.map { String(cString: $0) } ?? "connectFailed"
            let message = outError.map { String(cString: $0) } ?? ""
            if let outJSON { al_string_free(outJSON) }
            if let outStatus { al_string_free(outStatus) }
            if let outError { al_string_free(outError) }

            let result: Result<DeleteResponse, PosterStoreError>
            if rc == 0, let json, let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(DeleteResponse.self, from: data) {
                result = .success(decoded)
            } else {
                result = .failure(.failed(status: status, message: message))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Lists the quarantine folders previous deletes left in the
    /// device Media root (run #115 recovery).
    public static func listQuarantine(
        pairingPath: String,
        log: @escaping (String) -> Void,
        completion: @escaping (Result<[QuarantineItem], PosterStoreError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let box = LogBox(log)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            var outJSON: UnsafeMutablePointer<CChar>?
            var outStatus: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc: Int32 = 1 // BISECT PROBE (#119): FFI call stubbed out
            Unmanaged<LogBox>.fromOpaque(ctx).release()

            let json = outJSON.map { String(cString: $0) }
            let status = outStatus.map { String(cString: $0) } ?? "connectFailed"
            let message = outError.map { String(cString: $0) } ?? ""
            if let outJSON { al_string_free(outJSON) }
            if let outStatus { al_string_free(outStatus) }
            if let outError { al_string_free(outError) }

            let result: Result<[QuarantineItem], PosterStoreError>
            if rc == 0, let json, let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(QuarantineListResponse.self, from: data) {
                result = .success(decoded.items)
            } else {
                result = .failure(.failed(status: status, message: message))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Restores the given quarantine entries back into the device
    /// data store. `targets` are (quarantine folder, provider,
    /// uuid-or-empty) triples; restore is not limited to the cleanup
    /// provider scope.
    public static func restoreQuarantine(
        pairingPath: String,
        containerPath: String,
        structVersion: Int,
        targets: [(quarantine: String, extensionId: String, uuid: String)],
        log: @escaping (String) -> Void,
        completion: @escaping (Result<RestoreResponse, PosterStoreError>) -> Void
    ) {
        let targetsCSV = targets
            .map { "\($0.quarantine)|\($0.extensionId)|\($0.uuid)" }
            .joined(separator: ",")
        DispatchQueue.global(qos: .userInitiated).async {
            let box = LogBox(log)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            var outJSON: UnsafeMutablePointer<CChar>?
            var outStatus: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc: Int32 = 1 // BISECT PROBE (#119): FFI call stubbed out
            Unmanaged<LogBox>.fromOpaque(ctx).release()

            let json = outJSON.map { String(cString: $0) }
            let status = outStatus.map { String(cString: $0) } ?? "connectFailed"
            let message = outError.map { String(cString: $0) } ?? ""
            if let outJSON { al_string_free(outJSON) }
            if let outStatus { al_string_free(outStatus) }
            if let outError { al_string_free(outError) }

            let result: Result<RestoreResponse, PosterStoreError>
            if rc == 0, let json, let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(RestoreResponse.self, from: data) {
                result = .success(decoded)
            } else {
                result = .failure(.failed(status: status, message: message))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// One quarantine folder as shown in the cleanup UI (run #115):
/// the Rust scan result merged with the delete receipt when one
/// exists (receipt provider/UUID win over content guesses).
public struct QuarantineDisplayItem: Identifiable {
    public let quarantine: String
    public let uuid: String
    public let extensionId: String
    public let name: String
    /// False when neither a receipt nor a content guess could name
    /// the provider — restore stays disabled for such entries.
    public let providerKnown: Bool

    public var id: String { quarantine }
}

/// Delete receipts (run #115): the authoritative provenance for a
/// quarantine folder — which provider + UUID its descriptor belongs
/// to. Recorded from the delete response at cleanup time and kept
/// in UserDefaults; content-based guesses from the quarantine scan
/// are only a fallback for folders deleted before receipts existed
/// (e.g. the run #114 cleanup).
public enum PosterStoreReceipts {
    public struct Receipt: Codable {
        public let quarantine: String
        public let extensionId: String
        public let uuid: String
    }

    private static let key = "posterStoreQuarantineReceipts.v1"

    public static func load() -> [String: Receipt] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Receipt].self, from: data)
        else { return [:] }
        return decoded
    }

    public static func record(_ newReceipts: [Receipt]) {
        guard !newReceipts.isEmpty else { return }
        var all = load()
        for r in newReceipts { all[r.quarantine] = r }
        save(all)
    }

    public static func remove(quarantine: String) {
        var all = load()
        guard all.removeValue(forKey: quarantine) != nil else { return }
        save(all)
    }

    private static func save(_ all: [String: Receipt]) {
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// C log-callback thunk for the poster-store FFIs (ctx is a retained LogBox).
private func posterStoreLogThunk(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let ctx, let msg else { return }
    let box = Unmanaged<PosterStoreHelper.LogBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(String(cString: msg))
}

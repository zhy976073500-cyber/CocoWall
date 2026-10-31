//
//  PosterStoreHelper.swift
//  CocoWall
//
//  Device-side PosterBoard data-store detection + cleanup: asks the Rust
//  core (al_poster_store_list / al_poster_store_delete) to enumerate the
//  descriptors actually present in the device's PRBPosterExtensionDataStore
//  and to delete user-selected ones, via AFC over the RSD tunnel. This is
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

    private struct DeleteResponse: Codable {
        struct ItemResult: Codable {
            let `extension`: String
            let uuid: String
            let ok: Bool
        }
        let deleted: Int
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
    /// Completion is called on the main queue with (deleted, failed).
    public static func deleteImported(
        pairingPath: String,
        containerPath: String,
        structVersion: Int,
        targets: [DevicePosterItem],
        log: @escaping (String) -> Void,
        completion: @escaping (Result<(deleted: Int, failed: Int), PosterStoreError>) -> Void
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

            let result: Result<(deleted: Int, failed: Int), PosterStoreError>
            if rc == 0, let json, let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(DeleteResponse.self, from: data) {
                result = .success((deleted: decoded.deleted, failed: decoded.failed))
            } else {
                result = .failure(.failed(status: status, message: message))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// C log-callback thunk for the poster-store FFIs (ctx is a retained LogBox).
private func posterStoreLogThunk(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let ctx, let msg else { return }
    let box = Unmanaged<PosterStoreHelper.LogBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(String(cString: msg))
}

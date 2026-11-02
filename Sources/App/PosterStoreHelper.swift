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

    public struct DeleteResponse: Codable {
        public struct ItemResult: Codable {
            public let `extension`: String
            public let uuid: String
            public let ok: Bool
            /// Media quarantine folder the descriptor was moved into
            /// (part of the delete mechanism's own reporting: deletion
            /// is a move, not an erase).
            public let quarantine: String
        }
        public let deleted: Int
        public let failed: Int
        public let results: [ItemResult]
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
            // Run #146: stage timing observed from the Rust core's own
            // stage-marker log lines as they arrive on this thread (see
            // SPEC #146 for the segment brackets). Pure observation —
            // the caller's handler still receives every line unchanged.
            let timer = PosterStoreStageTimer()
            let box = LogBox({ line in
                timer.observe(line)
                log(line)
            })
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
            let timerEnd = DispatchTime.now()

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

            // Run #146: stage-timing report on the same log channel.
            if let session = timer.session {
                log("[计时] 清理·建连 \(cwStageText(cwStageMS(timer.start, session))) ms")
                log("[计时] 清理·枚举 \(cwStageText(cwStageMS(session, timerEnd))) ms\(timer.sawRetry ? "（含失败重试）" : "")")
            }
            switch result {
            case .success(let items):
                log("[计时] 清理·检测总计 \(cwStageText(cwStageMS(timer.start, timerEnd))) ms（\(items.count) 条）")
            case .failure:
                log("[计时] 清理·检测总计 \(cwStageText(cwStageMS(timer.start, timerEnd))) ms（失败）")
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
            // Run #146: stage timing, same observation pattern as
            // listImported above (see SPEC #146).
            let timer = PosterStoreStageTimer()
            let box = LogBox({ line in
                timer.observe(line)
                log(line)
            })
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
            let timerEnd = DispatchTime.now()

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

            // Run #146: stage-timing report on the same log channel.
            // The 复查 segment exists only when the core's fresh-
            // connection commit-audit marker arrived (see SPEC #146).
            let targetCount = targets.count
            if let session = timer.session {
                log("[计时] 清理·建连 \(cwStageText(cwStageMS(timer.start, session))) ms")
                if let op = timer.operationBegin {
                    log("[计时] 清理·枚举（前置审计） \(cwStageText(cwStageMS(session, op))) ms")
                    log("[计时] 清理·删除移隔离 \(cwStageText(cwStageMS(op, timer.commitFresh ?? timerEnd))) ms（\(targetCount) 张）")
                } else if let cf = timer.commitFresh {
                    log("[计时] 清理·枚举（前置审计） \(cwStageText(cwStageMS(session, cf))) ms")
                }
                if let cf = timer.commitFresh {
                    log("[计时] 清理·复查（新连接） \(cwStageText(cwStageMS(cf, timerEnd))) ms")
                }
            }
            log("[计时] 清理·删除总计 \(cwStageText(cwStageMS(timer.start, timerEnd))) ms（\(targetCount) 张）")
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

// MARK: - Run #146 stage timing (diagnostic only; see SPEC #146)

/// Milliseconds between two monotonic timestamps.
func cwStageMS(_ start: DispatchTime, _ end: DispatchTime) -> Int {
    Int((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

/// Thousands-grouped integer for [计时] log lines.
func cwStageText(_ value: Int) -> String {
    var digits = String(value)
    var grouped = ""
    while digits.count > 3 {
        grouped = "," + String(digits.suffix(3)) + grouped
        digits = String(digits.dropLast(3))
    }
    return digits + grouped
}

/// Records when the Rust poster-store core's stage-marker log lines
/// arrive at the Swift FFI boundary, so the stages inside the single
/// FFI call can be bracketed without touching the core. First
/// occurrence wins; a stage whose markers never arrive simply gets
/// no [计时] line — numbers are never fabricated. Written only from
/// the FFI-calling thread while the call is in flight, read after it
/// returns on the same thread.
final class PosterStoreStageTimer {
    let start = DispatchTime.now()
    private(set) var session: DispatchTime?
    private(set) var operationBegin: DispatchTime?
    private(set) var commitFresh: DispatchTime?
    private(set) var sawRetry = false

    func observe(_ line: String) {
        if line.contains("airlift.poster_store.audit.retry") { sawRetry = true }
        if session == nil, line.contains("airlift.poster_store.audit.session") {
            session = DispatchTime.now()
        }
        if operationBegin == nil, line.contains("airlift.delete.operation.begin") {
            operationBegin = DispatchTime.now()
        }
        if commitFresh == nil, line.contains("airlift.delete.commit.connection=fresh") {
            commitFresh = DispatchTime.now()
        }
    }
}

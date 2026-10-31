//
//  PosterRefreshHelper.swift
//  CocoWall
//
//  Walllive-style PosterBoard refresh: after a successful wallpaper sync,
//  ask the Rust core (al_poster_refresh) to restart ONLY the PosterBoard
//  daemon via DVT ProcessControl over the existing RSD tunnel, so new
//  wallpapers take effect without a full NeoSpring respring. Callers fall
//  back to the legacy NeoSpring path whenever the refresh is not confirmed.
//

import Foundation
import AirliftFFI

public enum PosterRefreshHelper {

    /// Boxed log sink so the C log callback can forward Rust log lines
    /// (the full airlift poster_refresh.* stage trail) to Swift.
    final class LogBox {
        let handler: (String) -> Void
        init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    }

    /// Attempts the PosterBoard-only refresh off the main thread.
    ///
    /// - Parameters:
    ///   - pairingPath: path to the active pairing file
    ///     (PairingController.pairingFilePath()).
    ///   - log: receives Rust log lines from arbitrary threads — hop to the
    ///     main queue before touching UI state.
    ///   - completion: called on the main queue with
    ///     (confirmed, machine-readable status string from the Rust core:
    ///     "confirmed" / "connectFailed" / "serviceUnavailable" /
    ///     "pidNotFound" / "killFailed" / "verifyTimeout").
    public static func attemptRefresh(
        pairingPath: String,
        log: @escaping (String) -> Void,
        completion: @escaping (_ confirmed: Bool, _ status: String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let box = LogBox(log)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            var outStatus: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pC in
                al_poster_refresh(pC, posterRefreshLogThunk, ctx, &outStatus, &outError)
            }
            Unmanaged<LogBox>.fromOpaque(ctx).release()

            let status = outStatus.map { String(cString: $0) }
                ?? (rc == 0 ? "confirmed" : "connectFailed")
            if let outStatus { al_string_free(outStatus) }
            if let outError { al_string_free(outError) }

            let confirmed = (rc == 0)
            DispatchQueue.main.async {
                completion(confirmed, status)
            }
        }
    }
}

/// C log-callback thunk for al_poster_refresh (ctx is a retained LogBox).
private func posterRefreshLogThunk(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let ctx, let msg else { return }
    let box = Unmanaged<PosterRefreshHelper.LogBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(String(cString: msg))
}

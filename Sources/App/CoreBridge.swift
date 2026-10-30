import AirliftFFI
import Foundation

/// Swift face of the vendored AirliftFFI core's global log sink.
///
/// The core is AirCard-iOS's Rust library, vendored verbatim (see
/// rust-core/VENDORED.md); it has no version entry point, so `version`
/// is a plain label naming what is linked. Core log lines (pairing /
/// tunnel progress from the tracing subscriber) are forwarded to the
/// unified log.
enum CoreBridge {
    /// Provenance label shown in Settings as proof of what is linked.
    static var version: String {
        "airlift-ffi 0.1.0 · AirCard-iOS v1.3.2 · 40640c4"
    }

    /// Installs the core's log callback once; core `tracing` events are
    /// forwarded here for the rest of the app's lifetime.
    static func installLogging() {
        _ = al_log_init(alCoreLogCallback, nil)
    }
}

/// C callback target for core log lines. Must stay a non-capturing
/// closure: it is handed to C as a plain function pointer.
private let alCoreLogCallback: ALLogCallback = { _, msg in
    guard let msg else { return }
    NSLog("[airlift] %@", String(cString: msg))
}

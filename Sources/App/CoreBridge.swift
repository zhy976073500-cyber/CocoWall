import CocoWallCore
import Foundation

/// Swift face of the cocowall-core link canary + log sink.
///
/// If the app links and launches, the Rust core is in the binary:
/// `version` is answered by the core itself, and core log lines
/// (pairing / tunnel progress) are forwarded to the unified log.
enum CoreBridge {
    /// e.g. "cocowall-core 0.1.0 · idevice 0.1.68". The C string is
    /// static storage owned by the core — never freed from Swift.
    static var version: String {
        guard let p = cw_core_version() else { return "（核心版本读取失败）" }
        return String(cString: p)
    }

    /// Installs the core's log callback once; core `tracing` events are
    /// forwarded here for the rest of the app's lifetime.
    static func installLogging() {
        _ = cw_log_init(cwCoreLogCallback, nil)
    }
}

/// C callback target for core log lines. Must stay a non-capturing
/// closure: it is handed to C as a plain function pointer.
private let cwCoreLogCallback: CWLogCallback = { _, msg in
    guard let msg else { return }
    NSLog("[cocowall-core] %@", String(cString: msg))
}

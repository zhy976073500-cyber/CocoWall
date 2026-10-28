import CocoWallCore
import Combine
import Foundation

/// Pairing state and entry points.
///
/// Two routes, forked by OS version (see SPEC.md / research):
/// - iOS 27+: on-device RPPairing host — the core binds a listener and
///   hands the Bonjour service details to this class, which publishes
///   them with NetService (no multicast entitlement needed); the user
///   enters the PIN the core issues into Settings › Privacy & Security ›
///   Developer Mode › Pair with CocoWall, and the core writes the
///   RPPairing file into the sandbox.
/// - iOS 17–26: import an existing pairing file (.mobiledevicepairing /
///   .plist / .mobilepair) produced by SideStore, iLoader, AltStore,
///   Jitterbug or a computer.
///
/// All protocol work runs in the Rust core (cocowall-core) behind the
/// C FFI; this type is the Swift-side state machine only.
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
        // for the core, so restore the paired state from disk. Same
        // validity bar as the host completion path: exists and non-empty.
        if Self.storedPairingFileSize() > 0 {
            state = .paired(filePath: Self.pairingFileURL.path)
        }
    }

    /// Byte size of the stored pairing file, 0 when absent/unreadable.
    private static func storedPairingFileSize() -> Int {
        let attrs = try? FileManager.default
            .attributesOfItem(atPath: pairingFileURL.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// Reconciles `state` with the pairing file actually on disk.
    ///
    /// Called when the app returns to the foreground and whenever the
    /// settings page appears: pairing involves a trip into the system
    /// Settings app, during which this app may be suspended and the
    /// host's completion hop lost — while the core may still have
    /// finished and written the file. Trusting the disk over a stale
    /// in-memory state lets the UI heal itself without an app restart.
    func refreshFromDisk() {
        let url = Self.pairingFileURL
        guard Self.storedPairingFileSize() > 0 else {
            // No usable file: a `.paired` state would be a lie.
            if !hostRunning, case .paired = state {
                state = .unpaired
            }
            return
        }
        if hostRunning {
            // The host owns the state while it runs — but if it wrote
            // the file during *this* run and its completion never
            // landed (suspension), adopt the on-disk result and retire
            // the stuck host generation so its late return is ignored.
            // The mtime guard keeps an earlier session's file from
            // falsely completing a fresh host run.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let started = hostStartedAt,
               let mtime = attrs?[.modificationDate] as? Date,
               mtime >= started.addingTimeInterval(-2) {
                hostGeneration += 1
                hostRunning = false
                hostStartedAt = nil
                keepAlive.stop()
                stopAdvertising()
                hostServiceID = nil
                state = .paired(filePath: url.path)
            }
            return
        }
        // Any non-paired state with a valid file on disk is stale.
        guard case .paired = state else {
            state = .paired(filePath: url.path)
            return
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
        hostGeneration += 1   // invalidate any in-flight host completion
        hostRunning = false
        hostStartedAt = nil
        keepAlive.stop()
        stopAdvertising()
        hostServiceID = nil
        try? FileManager.default.removeItem(at: Self.pairingFileURL)
        UserDefaults.standard.removeObject(forKey: Self.altIRKKey)
        state = .unpaired
    }

    // MARK: - iOS 27+ on-device host (core-backed)

    private var netService: NetService?
    private var hostRunning = false
    private var hostGeneration = 0
    private var hostStartedAt: Date?

    /// Silent-audio keep-alive, alive only while the host is up: it
    /// keeps the process (and with it the Bonjour advertisement and
    /// the Rust host) running while the user is over in Settings.
    private let keepAlive = PairingKeepAlive()

    /// Bonjour service name the core asked us to publish (e.g.
    /// "idevice_pair-84d6be"), set when the ready callback fires and
    /// cleared when the host ends. The settings card shows it so the
    /// user can pick the right row in Developer Mode › 配对设备, and
    /// its presence doubles as the honest "broadcasting" signal —
    /// it only exists once the core's listener is bound.
    @Published private(set) var hostServiceID: String?

    /// Persisted host altIRK: keeps this host's identity stable so a
    /// device that already paired recognises it next time.
    private static let altIRKKey = "cocowall.pairingHostAltIRK"
    private var storedAltIRK: String {
        UserDefaults.standard.string(forKey: Self.altIRKKey) ?? ""
    }

    /// Starts the core pairing host on a background queue. The call
    /// blocks until the device connects and the handshake resolves, so
    /// all UI progress arrives through the ready / PIN callbacks.
    func startOnDevicePairing() {
        guard !hostRunning else { return }
        hostRunning = true
        hostGeneration += 1
        let generation = hostGeneration
        hostStartedAt = Date()
        hostServiceID = nil
        state = .hosting(pin: nil)
        // From here the user will leave for Settings; keep the process
        // alive so the advertisement and host survive the trip.
        keepAlive.start()

        let outPath = Self.pairingFileURL.path
        let altIRK = storedAltIRK
        let ctx = Unmanaged.passRetained(self).toOpaque()

        DispatchQueue.global(qos: .userInitiated).async {
            var result = CWPairResult()
            let rc = "0.0.0.0".withCString { bind in
                "CocoWall".withCString { name in
                    "Mac17,7".withCString { model in
                        outPath.withCString { out in
                            altIRK.withCString { irk in
                                cw_pairing_run_host(
                                    bind, 0, name, model, out, irk,
                                    pairingReadyCallback, pairingPinCallback,
                                    ctx, &result)
                            }
                        }
                    }
                }
            }
            let outcome = PairingOutcome(
                rc: rc,
                error: Self.takeString(result.error),
                deviceName: Self.takeString(result.device_name),
                filePath: Self.takeString(result.pairing_file_path),
                altIRKHex: Self.takeString(result.host_alt_irk_hex))
            cw_pairing_result_free(&result)

            Task { @MainActor in
                let service = Unmanaged<PairingService>.fromOpaque(ctx).takeUnretainedValue()
                service.finishOnDevicePairing(outcome, generation: generation)
                Unmanaged<PairingService>.fromOpaque(ctx).release()
            }
        }
    }

    private func finishOnDevicePairing(_ outcome: PairingOutcome, generation: Int) {
        hostRunning = false
        hostStartedAt = nil
        keepAlive.stop()
        stopAdvertising()
        hostServiceID = nil
        guard generation == hostGeneration else { return }  // forgotten / superseded
        if outcome.rc == 0 {
            if !outcome.altIRKHex.isEmpty {
                UserDefaults.standard.set(outcome.altIRKHex, forKey: Self.altIRKKey)
            }
            let path = outcome.filePath.isEmpty ? Self.pairingFileURL.path : outcome.filePath
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            if size > 0 {
                state = .paired(filePath: path)
            } else {
                state = .failed("配对握手完成，但配对文件为空，请重试。")
            }
        } else {
            state = .failed(outcome.error.isEmpty ? "配对失败（rc=\(outcome.rc)）" : outcome.error)
        }
    }

    private static func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        return String(cString: p)
    }

    // MARK: Bonjour advertising (driven by the core's ready callback)

    fileprivate func advertise(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        hostServiceID = serviceID
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
    }

    fileprivate func notePin(_ pin: String) {
        if case .hosting = state {
            state = .hosting(pin: pin)
        }
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

/// Value snapshot of a finished CWPairResult, taken on the background
/// queue before the C strings are freed.
private struct PairingOutcome {
    let rc: Int32
    let error: String
    let deviceName: String
    let filePath: String
    let altIRKHex: String
}

// MARK: - C callbacks (non-capturing; handed to the core as fn pointers)

private let pairingReadyCallback: CWPairReadyCallback = { ctx, serviceID, port, keys, vals, count in
    guard let ctx, let serviceID else { return }
    let service = Unmanaged<PairingService>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)
    var txt: [String: Data] = [:]
    if let keys, let vals {
        for i in 0..<Int(count) {
            if let k = keys[i], let v = vals[i] {
                txt[String(cString: k)] = Data(String(cString: v).utf8)
            }
        }
    }
    let p = Int32(port)
    Task { @MainActor in
        service.advertise(serviceID: id, port: p, txt: txt)
    }
}

private let pairingPinCallback: CWPairPinCallback = { pin, ctx in
    guard let ctx, let pin else { return }
    let service = Unmanaged<PairingService>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    Task { @MainActor in
        service.notePin(pinString)
    }
}

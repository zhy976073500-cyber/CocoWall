import Foundation
import UIKit
import SwiftUI
import ImageIO
import Combine
import AirliftFFI

// MARK: - Flash registry entry (run #124)

/// One flash-registry row: a descriptor that landed in the device
/// PosterBoard data store, mapped back to the local library item it
/// was flashed from. Keyed in the registry by the store id
/// ("<extension>/<uuid>", the same string as DevicePosterItem.id).
/// Persisted as JSON in UserDefaults (key
/// "cocowall.flash_registry"), following the same pattern as the
/// saved library itself ("aircard.saved_tendies").
struct FlashRegistryEntry: Codable, Equatable {
    /// TendieItem.id (uuidString) of the source library entry.
    var itemID: String
    /// The library entry's display name at flash time — shown in the
    /// cleanup list even if the library entry is later removed.
    var itemName: String
    /// TendieItem.relativePath — secondary identity for finding the
    /// live library entry if its id is no longer present.
    var relativePath: String
}

/// Support level of the device's iOS version for this tool
/// (run #124). See AppViewModel.systemSupportLevel(version:).
enum SystemSupportLevel {
    /// iOS 17.0 – 27.1: inside the supported range.
    case supported
    /// Below iOS 17.0: the PosterBoard store layout this tool
    /// writes is not available.
    case tooOld
    /// iOS 27.2+: the AirTraffic channel is patched; flashing may
    /// fail — shown as a risk warning, not a block.
    case patchedRisk
}

/// 壁纸库排序键（run #148 第五件）：文件名（自然排序，
/// 数字按数值序）/ 导入时间（模型 dateImported，引擎在
/// 导入当下写入）/ 文件大小（已存包实际字节数）。每键
/// 固定默认方向：name 升序、imported 最新在前、size
/// 从大到小；tendieSortReversed 整体反转。
enum TendieSortOrder: String, CaseIterable {
    case name
    case imported
    case size

    var title: String {
        switch self {
        case .name: return "按文件名"
        case .imported: return "按导入时间"
        case .size: return "按文件大小"
        }
    }
}

/// 清理实时进度（run #148）：阶段 + 计数 + 确定型比例。
/// 比例口径：检测段小权重（0.08）、删除段按已确认目标
/// 线性占 0.1–0.8、复查 0.85、刷新 0.95（收尾段由
/// AppViewModel 在删后重检测 + PosterBoard 刷新期间置位）。
struct CleanupProgressState: Equatable {
    enum Phase: Equatable {
        case detecting, deleting, reviewing, refreshing
    }
    var phase: Phase
    var completed: Int
    var total: Int

    var fraction: Double {
        switch phase {
        case .detecting:
            return 0.08
        case .deleting:
            guard total > 0 else { return 0.1 }
            return 0.1 + 0.7 * Double(completed) / Double(total)
        case .reviewing:
            return 0.85
        case .refreshing:
            return 0.95
        }
    }

    var stageText: String {
        switch phase {
        case .detecting: return "检测中"
        case .deleting: return "删除中"
        case .reviewing: return "复查中"
        case .refreshing: return "刷新中"
        }
    }
}

// MARK: - AppViewModel

@MainActor
final class AppViewModel: ObservableObject {

    /// Static sink for Rust log lines — set in init so AirliftApp can forward them.
    static var sharedLogSink: ((String) -> Void)? = nil
    static weak var shared: AppViewModel? = nil

    // MARK: - 远程配置（run #159）

    /// 配置服务由刷入链路所在的 VM 持有并初始化（发布方案
    /// 「公告模块与核心适度绑定」）：界面层不直接建服务，
    /// 经 VM 的两个转发属性订阅弹窗与验签状态；验签状态
    /// 还并入壁纸页状态胶囊的内部状态计算（TendiesView）。
    let remoteConfig = RemoteConfigService()
    @Published private(set) var remotePrompt: RemoteConfigService.Prompt? = nil
    @Published private(set) var remoteConfigVerified: Bool = false
    private var remoteConfigCancellables: Set<AnyCancellable> = []

    // MARK: - Pairing
    @Published var pairingStatus: String = ""
    @Published var pairingPIN: String? = nil
    @Published var hasPairingFile: Bool = false
    @Published var pairingFileName: String = ""
    @Published var pairingPhase: PairingPhase = .idle
    /// run #155: 配对期间把 PairingController 的 PIN 直订转发给
    /// Live Activity 的订阅（码一发布就送达，不只靠轮询顺带）。
    private var pairingPINForwarding: AnyCancellable?
    @Published var documentsPlistFiles: [String] = []

    enum PairingPhase: Equatable {
        case idle, pairing
    }

    // MARK: - VPN / Network
    @Published var vpnUp: Bool = false
    @Published var wifiUp: Bool = false
    @Published var networkDetail: String = ""
    /// 回环连接成功提醒（run #166）：仅当用户点按任一页的
    /// 回环连接控件（经 userToggleLoopback）发起连接时置
    /// 位；共享隧道状态随后真正跃迁到 .connected 才经既有
    /// toast 通道（run #148）弹一次并清位。启动时状态的
    /// 恢复/被动观察不置位 → 不弹；断开不弹；已连接期间
    /// 状态重复发布不重弹（清位保证）；连接失败落回断开
    /// 态时清位，不把提醒攒到日后被动连上时误弹。
    private var loopbackToastArmed = false
    private var loopbackCancellables: Set<AnyCancellable> = []
    @Published var deviceIP: String = "10.7.0.1" {
        didSet {
            syncTargetHostsToRust()
        }
    }

    // MARK: - Tab
    @Published var selectedTab: AppTab = .wallpapers

    enum FlashPhase: Equatable {
        case idle, running, done(ok: Bool)
    }

    // MARK: - Passcode Themes tab
    @Published var passcodeMode: CreatorMode = .applyTheme
    @Published var loadedTheme: PasscodeThemeInfo? = nil
    @Published var documentsThemes: [String] = []
    @Published var sliceMode: SliceMode = .posterSlice

    // Poster slice
    @Published var posterImage: UIImage? = nil
    @Published var posterZoom: CGFloat = 1.0
    @Published var posterOffset: CGPoint = .zero
    @Published var maskToCircles: Bool = false
    @Published var slicedKeys: [String: UIImage] = [:]

    // Individual keys
    @Published var customKeys: [String: UIImage] = [:]
    @Published var rawIndividualImages: [String: UIImage] = [:]
    @Published var individualOffsets: [String: CGPoint] = [:]
    @Published var individualZooms: [String: CGFloat] = [:]
    @Published var selectedKeyDigit: String? = nil

    @Published var passthmFlashPhase: FlashPhase = .idle
    @Published var passthmFlashProgress: Double = 0
    @Published var passthmFlashLog: [String] = []

    // MARK: - Tendies / Wallpapers tab
    @Published var tendieItems: [TendieItem] = []
    @Published var posterBoardContainer: String = ""
    @Published var isDetectingContainer: Bool = false
    @Published var resetPBProtections: Bool = true
    @Published var tendiesFlashPhase: FlashPhase = .idle
    @Published var tendiesFlashProgress: Double = 0
    @Published var tendiesFlashLog: [String] = []
    @Published var isNeoSpringing: Bool = false
    private var previewRegenInFlight: Set<UUID> = []
    /// 预览再生等待队列（run #148）：展开页快速滑动时
    /// 单元格 .task 会成批请求再生，无上限并发解压会把
    /// CPU 打满、反过来卡滚动；改为排队 + 并发上限泵送。
    private var previewRegenQueue: [UUID] = []
    private static let previewRegenMaxConcurrent = 3

    // MARK: - Device PosterBoard store (detect / cleanup)
    /// Descriptors actually present in the device's PosterBoard data store
    /// (from PosterStoreHelper — NOT the local imported-.tendies library).
    @Published var devicePosters: [DevicePosterItem] = []
    @Published var devicePosterSelection: Set<String> = []
    @Published var isScanningDevicePosters: Bool = false
    @Published var isCleaningDevicePosters: Bool = false
    @Published var devicePosterStatus: String = ""
    /// Cleanup-list thumbnails (run #122; layered matching run #124):
    /// DevicePosterItem.id -> JPEG preview borrowed from the matching
    /// local library entry (see prepareDevicePosterThumbnails).
    @Published var devicePosterThumbs: [String: Data] = [:]
    /// Cleanup-list display names (run #124): DevicePosterItem.id ->
    /// local library display name, for rows whose source library
    /// entry is known (flash registry hit, or exact package-name
    /// match). Rows without an entry keep the store-reported name.
    @Published var devicePosterDisplayNames: [String: String] = [:]
    @Published var showDevicePosterSheet: Bool = false

    // MARK: - 成功提示 toast（run #148）

    /// 轻量浮层提示的当前文案（nil = 不显示）：刷入/导入/
    /// 清理成功后由 showToast 写入，约 1.6 秒自动清除；
    /// 呈现挂在 ContentView 根层（胶囊 + 对勾，不挡操作）。
    /// 失败一律走原有 errorMessage / 状态文案通道，绝不
    /// 经这里冒充成功。
    @Published var toastMessage: String? = nil
    private var toastDismissTask: Task<Void, Never>? = nil

    /// 显示一条成功 toast；连发时以最后一条为准并重新计时。
    func showToast(_ message: String) {
        toastMessage = message
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - 清理实时进度（run #148）

    /// 清理一轮的实时进度（nil = 没有清理在进行）：阶段 +
    /// 已确认数/总数，由 PosterStoreHelper 的进度回调（rust
    /// 阶段标记映射）与本类在删后刷新段的衔接共同驱动，
    /// 清理页据此画确定型进度条；删除流程本身不因进度改动。
    @Published var cleanupProgress: CleanupProgressState? = nil

    // MARK: - 壁纸库排序（run #148 第五件）

    /// 当前排序键（持久化于 UserDefaults，三选一）；写入即
    /// 存盘并重排 tendieItems——展开页网格与壁纸页轮播共用
    /// tendieItems 同一顺序，两处天然一致。
    @Published var tendieSortOrder: TendieSortOrder = TendieSortOrder(
        rawValue: UserDefaults.standard.string(forKey: "cocowall.tendie_sort_order") ?? ""
    ) ?? .imported {
        didSet {
            UserDefaults.standard.set(tendieSortOrder.rawValue, forKey: "cocowall.tendie_sort_order")
            applyTendieSort()
        }
    }

    /// 排序方向反转（持久化）：false = 每键的固定默认方向
    /// （文件名升序 / 导入时间最新在前 / 文件大小从大到小）。
    @Published var tendieSortReversed: Bool = UserDefaults.standard.bool(forKey: "cocowall.tendie_sort_reversed") {
        didSet {
            UserDefaults.standard.set(tendieSortReversed, forKey: "cocowall.tendie_sort_reversed")
            applyTendieSort()
        }
    }

    // MARK: - AirCard UI States & Properties
    static var detectedDeviceLanguage: PasscodeLanguageTarget {
        let code = Locale.preferredLanguages.first?.components(separatedBy: "-").first?.lowercased() ?? "en"
        for target in PasscodeLanguageTarget.allCases {
            if target.code == code {
                return target
            }
        }
        return .en
    }

    @Published var targetTelephonyVersion: String = "TelephonyUI-10"
    @Published var passcodeLanguageTarget: PasscodeLanguageTarget = AppViewModel.detectedDeviceLanguage
    @Published var passcodeBoldTarget: PasscodeBoldTarget = .both
    @Published var showSuccessAlert: Bool = false
    @Published var successAlertMessage: String = ""
    @Published var exportedThemeURL: URL? = nil
    @Published var showShareSheet: Bool = false

    // MARK: - Shared
    @Published var errorMessage: String? = nil

    // MARK: - 诊断日志（run #169）
    //
    // 容器检测等关键步骤失败时，把真正的原因连同现场信息记下来，
    // 供作者页头像三击复制与设置页「问题反馈」附带。平时不显示，
    // 不写用户可见日志；只保留最近一次失败。
    @Published var lastDiagnosticsLog: String? = nil

    /// 记录一次失败的诊断日志：时间、版本、系统、回环与配对状态、
    /// 失败步骤、底层原始错误。调用方在各自 catch 里记一笔即可。
    func recordDiagnostics(step: String, error: Error) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let lines = [
            "CocoWall 诊断日志",
            "时间：\(formatter.string(from: Date()))",
            "App 版本：\(RemoteConfigService.currentAppVersion) (build \(build))",
            "iOS 版本：\(UIDevice.current.systemVersion)",
            "回环：\(vpnUp ? "已连接" : "未连接")",
            "配对文件：\(FileManager.default.fileExists(atPath: PairingController.pairingFilePath()) ? "已就绪" : "无")",
            "失败步骤：\(step)",
            "原始错误：\(error.localizedDescription)",
        ]
        lastDiagnosticsLog = lines.joined(separator: "\n")
    }

    /// run #171：当前状态快照——无失败日志时头像三击 / 问题反馈
    /// 复制的兜底。格式与 recordDiagnostics 同款（同头、同字段），
    /// 只是「失败步骤」一行改为「当前状态（未发生失败）」、无
    /// 「原始错误」行。Sage 22:25 反馈：只连了回环、没触发过失败
    /// 就去点头像，结果只拿到「暂无诊断日志」——状态本身就是
    /// 值得发给作者的信息。
    func currentDiagnosticsSnapshot() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let lines = [
            "CocoWall 诊断日志",
            "时间：\(formatter.string(from: Date()))",
            "App 版本：\(RemoteConfigService.currentAppVersion) (build \(build))",
            "iOS 版本：\(UIDevice.current.systemVersion)",
            "回环：\(vpnUp ? "已连接" : "未连接")",
            "配对文件：\(FileManager.default.fileExists(atPath: PairingController.pairingFilePath()) ? "已就绪" : "无")",
            "当前状态（未发生失败）",
        ]
        return lines.joined(separator: "\n")
    }
    @Published var log: [String] = []
    @Published var showDeletePairingConfirm: Bool = false

    init() {
        Self.shared = self
        // End any pairing Live Activity left over from a prior process.
        PairingLiveActivityController.endStaleActivities()
        refreshPairingFile()
        refreshNetworkStatus()
        scanDocumentsDirectory()
        posterBoardContainer = UserDefaults.standard.string(forKey: "aircard.posterboard_container") ?? ""
        loadSavedTendies()

        // Hook Rust log output into our log array.
        AppViewModel.sharedLogSink = { [weak self] line in
            self?.log.append(line)
        }

        // 远程配置（run #159）：转发弹窗与验签状态给界面层，
        // 并启动配置服务（init 已同步读验签缓存；此处评估
        // 一次弹窗并异步拉网络，全程静默不阻塞）。
        remoteConfig.$prompt
            .sink { [weak self] p in self?.remotePrompt = p }
            .store(in: &remoteConfigCancellables)
        remoteConfig.$verificationState
            .sink { [weak self] state in self?.remoteConfigVerified = (state == .verified) }
            .store(in: &remoteConfigCancellables)
        remoteConfig.start()

        // 回环连接成功提醒（run #166）：订阅共享隧道状态——
        // 跃迁到 .connected 且提醒已置位（用户点按发起）时
        // 弹一次；落回断开态清位。另订 lastError 兜底：
        // start() 在保存配置/启动阶段失败时状态可能根本
        // 不变、不会再发布断开态，靠错误置位来清位（不能
        // 用 isBusy 落沿判失败——成功路径上忙碌结束可能
        // 早于 .connecting 状态到达，会误清）。判定只读
        // 共享实例的公开状态，不改 LoopbackTunnelManager
        // 本体。
        LoopbackTunnelManager.shared.$status
            .sink { [weak self] status in
                guard let self else { return }
                if status == .connected {
                    if self.loopbackToastArmed {
                        self.loopbackToastArmed = false
                        self.showToast("不用的时候记得断开回环链接哦～")
                    }
                } else if status == .disconnected || status == .invalid {
                    self.loopbackToastArmed = false
                }
            }
            .store(in: &loopbackCancellables)
        LoopbackTunnelManager.shared.$lastError
            .sink { [weak self] error in
                if error != nil { self?.loopbackToastArmed = false }
            }
            .store(in: &loopbackCancellables)
    }

    // MARK: - Documents directory scanner

    /// Scans the app's Documents folder (accessible via Files app: "On My iPhone › Airlift")
    /// for any pairing plists or .passthm themes dropped by the user.
    func scanDocumentsDirectory() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: docs.path) else { return }

        // Find plists (exclude internal canonical copies)
        documentsPlistFiles = items.filter { item in
            let lower = item.lowercased()
            let isPairingExt = lower.hasSuffix(".plist") || lower.hasSuffix(".mobiledevicepairing") || lower.hasSuffix(".mobilepair")
            let isCanonical = item == "aircard_pairing.plist" || item == "airlift_pairing.plist" || item == "Info.plist"
            return isPairingExt && !isCanonical
        }.sorted()

        // Find .passthm themes
        documentsThemes = items.filter { $0.hasSuffix(".passthm") }.sorted()

        // Auto-discover any .tendies dropped into Documents or Documents/Tendies
        scanDocumentsForTendies()
    }

    func scanDocumentsForTendies() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tendiesDir = TendiesEngine.tendiesStorageDirectory
        
        var foundURLs: [URL] = []
        if let rootItems = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for u in rootItems where u.pathExtension.lowercased() == "tendies" {
                let target = tendiesDir.appendingPathComponent(u.lastPathComponent)
                if u.path != target.path && !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.copyItem(at: u, to: target)
                }
                foundURLs.append(target)
            }
        }
        if let storedItems = try? FileManager.default.contentsOfDirectory(at: tendiesDir, includingPropertiesForKeys: nil) {
            for u in storedItems where u.pathExtension.lowercased() == "tendies" {
                if !foundURLs.contains(u) {
                    foundURLs.append(u)
                }
            }
        }

        let newURLs = foundURLs.filter { url in
            !tendieItems.contains(where: { $0.fileName == url.lastPathComponent })
        }

        guard !newURLs.isEmpty else { return }

        Task {
            await self.importTendieFiles(urls: newURLs)
        }
    }

    @discardableResult
    func importPairingFile(from sourceURL: URL, originalName: String? = nil) -> Bool {
        let isSecured = sourceURL.startAccessingSecurityScopedResource()
        defer { if isSecured { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else {
            errorMessage = "所选配对文件为空或无法读取。"
            return false
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aircardURL = docs.appendingPathComponent("aircard_pairing.plist")
        let airliftURL = docs.appendingPathComponent("airlift_pairing.plist")

        do {
            try data.write(to: aircardURL, options: .atomic)
            try data.write(to: airliftURL, options: .atomic)

            if let orig = originalName, !orig.isEmpty,
               orig != "aircard_pairing.plist" && orig != "airlift_pairing.plist" {
                let origURL = docs.appendingPathComponent(orig)
                if origURL.path != sourceURL.path {
                    try? data.write(to: origURL, options: .atomic)
                }
            }

            PairingController.customPairingFilePath = aircardURL.path
            refreshPairingFile()
            let display = originalName ?? sourceURL.lastPathComponent
            pairingStatus = "配对文件已载入 ✅（\(display)）"
            log.append("已导入配对文件：\(display)（\(data.count) 字节）")
            return true
        } catch {
            errorMessage = "保存配对文件失败：\(error.localizedDescription)"
            return false
        }
    }

    func selectPairingFile(filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent(filename).path
        let canonical = PairingController.syncCanonicalPairingFile(from: path)
        let exists = FileManager.default.fileExists(atPath: canonical) &&
            ((try? FileManager.default.attributesOfItem(atPath: canonical)[.size] as? Int) ?? 0) > 0
        hasPairingFile = exists
        pairingFileName = exists ? (path as NSString).lastPathComponent : ""
        if exists {
            pairingStatus = "当前使用：\(pairingFileName) ✅"
            log.append("已选择配对文件：\(pairingFileName)")
        }
        scanDocumentsDirectory()
    }

    // MARK: - Pairing File

    func refreshPairingFile() {
        let path = PairingController.pairingFilePath()
        let exists = FileManager.default.fileExists(atPath: path) &&
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) > 0
        hasPairingFile = exists
        pairingFileName = exists ? (path as NSString).lastPathComponent : ""
        scanDocumentsDirectory()
    }


    var pairingFileSizeString: String {
        let path = PairingController.pairingFilePath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func startPairing() {
        pairingPhase = .pairing
        pairingPIN = nil
        pairingStatus = "正在启动本机配对服务…"
        errorMessage = nil
        PairingLiveActivityController.shared.begin()

        let ctrl = PairingController.shared

        // run #155: PIN 直达灵动岛——订阅 PairingController 的
        // pairingPIN，码一发布立刻经 ContentState 送进 Live
        // Activity（展开态大字与锁屏横幅都读这个字段）。原先码只
        // 靠下方 0.2s 轮询顺带转发，送达时机系于轮询节拍；轮询
        // 本身保留（状态文案同步仍走它）。订阅在配对收尾时撤销。
        pairingPINForwarding = ctrl.$pairingPIN
            .sink { pin in
                guard let pin else { return }
                Task { @MainActor in
                    PairingLiveActivityController.shared.pinReady(pin)
                }
            }

        Task {
            do {
                let path = try await ctrl.startAndWait()
                await MainActor.run {
                    self.pairingPhase = .idle
                    self.pairingPINForwarding = nil
                    self.refreshPairingFile()
                    self.pairingStatus = "配对成功！✅"
                    self.log.append("配对完成：\(path)")
                    PairingLiveActivityController.shared.succeeded()
                }
            } catch is CancellationError {
                self.pairingPhase = .idle
                self.pairingPINForwarding = nil
                self.pairingStatus = "已取消。"
                PairingLiveActivityController.shared.failed(message: "配对已取消")
            } catch {
                self.pairingPhase = .idle
                self.pairingPINForwarding = nil
                self.pairingStatus = ""
                self.errorMessage = "配对失败：\(error.localizedDescription)"
                PairingLiveActivityController.shared.failed(message: "配对失败")
            }
        }

        // Poll PairingController status every 0.2s while pairing
        Task {
            while pairingPhase == .pairing {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    guard self.pairingPhase == .pairing else { return }
                    self.pairingStatus = ctrl.pairingStatus
                    self.pairingPIN   = ctrl.pairingPIN
                    if let pin = self.pairingPIN {
                        PairingLiveActivityController.shared.pinReady(pin)
                    }
                }
            }
        }
    }

    func cancelPairing() {
        PairingController.shared.softCancel()
        pairingPhase = .idle
        pairingPINForwarding = nil
        pairingStatus = ""
        PairingLiveActivityController.shared.failed(message: "配对已取消")
    }

    func deletePairingFile() {
        PairingController.deleteStoredPairingCredentials()
        hasPairingFile = false
        pairingFileName = ""
        pairingStatus = "配对文件已删除"
        log.append("已删除当前配对凭据")
        scanDocumentsDirectory()
    }

    // MARK: - Network

    /// 回环开关的用户点按入口（run #166）：壁纸页「内置
    /// 回环」瓷砖与配对页网络卡开关共用这一处，两页行为
    /// 自此恒等。动作与此前两处各自实现逐字一致（已连接
    /// stop、其余 start，随后 refreshNetworkStatus）；连接
    /// 方向额外置位连接成功提醒（见 loopbackToastArmed），
    /// 断开方向清位。只经 LoopbackTunnelManager 既有公开
    /// API，不改其本体。
    func userToggleLoopback() {
        let manager = LoopbackTunnelManager.shared
        if manager.status == .connected {
            loopbackToastArmed = false
            manager.stop()
        } else {
            loopbackToastArmed = true
            manager.start()
        }
        refreshNetworkStatus()
    }

    func refreshNetworkStatus() {
        let ip = deviceIP
        let (vpn, wifi, detail) = NetworkStatus.summarize(deviceIP: ip)
        vpnUp = vpn
        wifiUp = wifi
        networkDetail = detail
        syncTargetHostsToRust()
    }

    /// Synchronizes the active device IP and candidate host addresses to the Rust core
    /// so the RSD tunnel connects over the non-loopback VPN interface rather than 127.0.0.1.
    func syncTargetHostsToRust() {
        let ip = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty {
            ip.withCString { _ = al_set_target_host($0) }
        } else {
            _ = al_set_target_host(nil)
        }

        var candidates: [String] = []
        if !ip.isEmpty {
            candidates.append(ip)
        }
        for cand in NetworkStatus.tunnelHostCandidates() {
            if !candidates.contains(cand) {
                candidates.append(cand)
            }
        }
        let cStrings = candidates.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) }
        ptrs.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                _ = al_set_target_hosts(base, buf.count)
            }
        }
    }

    // MARK: - Poster Slice

    var effectiveKeys: [String: UIImage] {
        sliceMode == .posterSlice ? slicedKeys : customKeys
    }

    func setPosterImage(_ img: UIImage) {
        posterImage = img
        posterZoom = 1.0
        posterOffset = .zero
        updatePosterSlicing()
    }

    func updatePosterSlicing() {
        guard let img = posterImage else { slicedKeys = [:]; return }
        slicedKeys = ImageEngine.slicePoster(
            image: img,
            zoom: posterZoom,
            offset: posterOffset,
            maskToCircles: maskToCircles
        )
    }

    func setIndividualKey(digit: String, image: UIImage) {
        rawIndividualImages[digit] = image
        individualOffsets[digit] = .zero
        individualZooms[digit] = 1.0
        selectedKeyDigit = digit
        updateIndividualKey(digit: digit)
    }

    func updateIndividualKey(digit: String) {
        guard let raw = rawIndividualImages[digit] else { return }
        let offset = individualOffsets[digit] ?? .zero
        let zoom   = individualZooms[digit] ?? 1.0
        if let cropped = ImageEngine.cropToCircle(
            image: raw,
            targetSize: CGSize(width: 225, height: 225),
            circleDiameter: 222.0,
            zoom: zoom,
            offset: offset
        ) {
            customKeys[digit] = cropped
        }
    }

    func clearIndividualKey(digit: String) {
        customKeys.removeValue(forKey: digit)
        rawIndividualImages.removeValue(forKey: digit)
        individualOffsets.removeValue(forKey: digit)
        individualZooms.removeValue(forKey: digit)
        if selectedKeyDigit == digit { selectedKeyDigit = nil }
    }

    func clearAllCreator() {
        posterImage = nil
        posterZoom = 1.0
        posterOffset = .zero
        slicedKeys.removeAll()
        customKeys.removeAll()
        rawIndividualImages.removeAll()
        individualOffsets.removeAll()
        individualZooms.removeAll()
        selectedKeyDigit = nil
    }

    // MARK: - Passthm Load

    func loadPassthm(url: URL) {
        Task.detached {
            let result = PasscodeThemeReader.inspect(url: url)
            await MainActor.run {
                if let (keys, rawData, count) = result {
                    self.loadedTheme = PasscodeThemeInfo(
                        name: url.deletingPathExtension().lastPathComponent,
                        filePath: url.path,
                        fileCount: count,
                        keysPreview: keys,
                        rawKeyData: rawData
                    )
                } else {
                    self.errorMessage = "读取 .passthm 失败——格式无效或不受支持。"
                }
            }
        }
    }

    func loadPassthmFromDocuments(filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(filename)
        loadPassthm(url: url)
    }

    func clearLoadedTheme() {
        loadedTheme = nil
        passthmFlashPhase = .idle
        passthmFlashProgress = 0
        passthmFlashLog.removeAll()
    }

    // MARK: - Passthm Flash

    var canFlashPassthm: Bool {
        guard hasPairingFile && passthmFlashPhase != .running else { return false }
        switch passcodeMode {
        case .applyTheme:
            return loadedTheme != nil && !(loadedTheme?.keysPreview.isEmpty ?? true)
        case .themeCreator:
            return !effectiveKeys.isEmpty
        }
    }

    func flashPassthm() {
        guard canFlashPassthm else { return }

        let isCreator = (passcodeMode == .themeCreator)
        let keys: [String: UIImage]
        let rawKeys: [String: Data]

        if isCreator {
            keys = effectiveKeys
            rawKeys = [:] // CRITICAL: Never use rawKeyData from previously loaded zip in creator mode!
        } else if let theme = loadedTheme {
            keys = theme.keysPreview
            rawKeys = theme.rawKeyData
        } else {
            return
        }

        guard !keys.isEmpty else {
            errorMessage = "没有已载入的按键图片。"
            return
        }

        // Run #160: resource-integrity gate (see SPEC #160).
        // Synchronous: flashing only starts after verification
        // has concluded; failure stops the flash here.
        guard ResourceIntegrity.verifyBundleResources() else {
            errorMessage = "资源完整性校验未通过，已停止刷入"
            return
        }

        passthmFlashPhase    = .running
        passthmFlashProgress = 0
        passthmFlashLog.removeAll()
        errorMessage = nil
        syncTargetHostsToRust()

        if !vpnUp {
            passthmFlashLog.append("⚠️ 提示：强烈建议先连接回环 VPN（LocalDevVPN 或 SideStore WireGuard）再进行设备操作。")
        }

        let pairingPath = PairingController.pairingFilePath()
        let targetVer = targetTelephonyVersion
        let targetLang = passcodeLanguageTarget
        let targetBold = passcodeBoldTarget
        let detected = AppViewModel.detectedDeviceLanguage.code

        Task.detached { [weak self] in
            guard let self = self else { return }

            let stageThemeDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("airlift_passthm_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: stageThemeDir, withIntermediateDirectories: true)

            let langs: [String]
            if targetLang == .all {
                langs = KeypadLocales.all
            } else {
                var l = [targetLang.code]
                if targetLang.code != "other" {
                    l.append("other")
                }
                if targetLang.code != detected && detected != "other" && !l.contains(detected) {
                    l.append(detected)
                }
                langs = l
            }
            let boldSuffixes: [String]
            switch targetBold {
            case .both: boldSuffixes = ["", "-bold"]
            case .boldOnly: boldSuffixes = ["-bold"]
            case .regularOnly: boldSuffixes = [""]
            }

            // Stage keypad images with all configured language & weight variants
            for (digit, image) in keys {
                let imgData: Data
                if let raw = rawKeys[digit] {
                    imgData = raw
                } else if let png = image.pngData() {
                    imgData = png
                } else {
                    continue
                }
                let stdSubtext = KeypadLayout.subtexts[digit] ?? ""

                for lang in langs {
                    for bld in boldSuffixes {
                        if digit == "0" {
                            // Blank variant: lang-0---white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-0---white\(bld).png"))
                            // Plus variant: lang-0-+--white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-0-+--white\(bld).png"))
                        } else if digit == "1" {
                            // Blank variant: lang-1---white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-1---white\(bld).png"))
                        } else {
                            // 1. Blank subtext
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)---white\(bld).png"))

                            // 2. Standard Latin subtext
                            if !stdSubtext.isEmpty {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(stdSubtext)--white\(bld).png"))
                                let noSpace = stdSubtext.replacingOccurrences(of: " ", with: "")
                                if noSpace != stdSubtext {
                                    try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(noSpace)--white\(bld).png"))
                                }
                            }

                            // 3. Cyrillic subtexts
                            if (lang == "ru" || targetLang == .all), let ruSub = KeypadLocales.cyrillicRU[digit] {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(ruSub)--white\(bld).png"))
                            }
                            if (lang == "uk" || targetLang == .all), let ukSub = KeypadLocales.cyrillicUK[digit] {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(ukSub)--white\(bld).png"))
                            }
                        }
                    }
                }
            }

            // iOS TelephonyUI @3x high-res indicator marker
            try? Data().write(to: stageThemeDir.appendingPathComponent("_big"))

            await MainActor.run {
                self.passthmFlashLog.append("⚡ 主题素材已暂存（\(targetVer) · \(langs.joined(separator: ", ").uppercased()) · \(targetBold.code)）。正在注入 iOS 缓存…")
                self.passthmFlashProgress = 0.2
            }

            let targetDirs: [String]
            if targetVer == "all" {
                targetDirs = [
                    "/var/mobile/Library/Caches/TelephonyUI-10",
                    "/var/mobile/Library/Caches/TelephonyUI-9",
                    "/var/mobile/Library/Caches/TelephonyUI-8"
                ]
            } else {
                targetDirs = [
                    "/var/mobile/Library/Caches/\(targetVer)"
                ]
            }

            var allOk = true
            var lastErr: String? = nil

            for (idx, targetPath) in targetDirs.enumerated() {
                let targetName = (targetPath as NSString).lastPathComponent
                await MainActor.run {
                    self.passthmFlashLog.append("  正在写入 \(targetName)…")
                }

                var stepOk = false
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var outError: UnsafeMutablePointer<CChar>? = nil
                        let rc = pairingPath.withCString { pairC in
                            stageThemeDir.path.withCString { srcC in
                                targetPath.withCString { tgtC in
                                    al_exploit_write_dir(pairC, srcC, tgtC, { _, msg in
                                        guard let msg = msg else { return }
                                        let line = String(cString: msg)
                                        DispatchQueue.main.async { AppViewModel.shared?.appendPasscodeDetail(line) }
                                    }, nil, &outError)
                                }
                            }
                        }
                        if let p = outError {
                            lastErr = String(validatingUTF8: p)
                            al_string_free(p)
                        }
                        stepOk = (rc == 0)
                        cont.resume()
                    }
                }

                if !stepOk {
                    allOk = false
                    await MainActor.run {
                        self.passthmFlashLog.append("  ⚠️ 写入 \(targetName) 失败：\(lastErr ?? "error")")
                    }
                } else {
                    await MainActor.run {
                        self.passthmFlashLog.append("  ✅ 已注入 \(targetName)")
                    }
                }

                await MainActor.run {
                    self.passthmFlashProgress = 0.2 + Double(idx + 1) * 0.25
                }
            }

            try? FileManager.default.removeItem(at: stageThemeDir)

            await MainActor.run {
                if allOk {
                    self.passthmFlashProgress = 1.0
                    self.passthmFlashPhase = .done(ok: true)
                    self.passthmFlashLog.append("🎉 密码盘主题已应用！锁定 iPhone 即可看到效果。")
                    self.successAlertMessage = "密码盘主题应用成功！\n\n锁定 iPhone（或重启）即可看到新的密码键盘。"
                    self.showSuccessAlert = true
                } else {
                    self.passthmFlashPhase = .done(ok: false)
                    self.passthmFlashLog.append("❌ 有一个或多个主题注入失败。")
                }
            }
        }
    }

    func exportPassthm() -> URL? {
        let keys = effectiveKeys
        guard !keys.isEmpty else {
            errorMessage = "导出前请至少设置一个按键。"
            return nil
        }
        do {
            let zipData = try PasscodeThemePackager.buildPassthm(
                keys: keys,
                telephonyVersion: targetTelephonyVersion,
                language: passcodeLanguageTarget,
                bold: passcodeBoldTarget
            )
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CocoWall_Custom_\(Int(Date().timeIntervalSince1970)).passthm")
            try zipData.write(to: tempURL)
            self.exportedThemeURL = tempURL
            self.showShareSheet = true
            return tempURL
        } catch {
            errorMessage = "导出主题失败：\(error.localizedDescription)"
            return nil
        }
    }

    func resetPosterPosition() {
        posterZoom = 1.0
        posterOffset = .zero
        updatePosterSlicing()
    }

    func adoptThemeIntoCreator() {
        guard let theme = loadedTheme else { return }
        for (digit, img) in theme.keysPreview {
            customKeys[digit] = img
            rawIndividualImages[digit] = img
            individualOffsets[digit] = .zero
            individualZooms[digit] = 1.0
        }
        selectedKeyDigit = nil
        sliceMode = .individualKeys
        passcodeMode = .themeCreator
    }

    func appendLog(_ line: String) {
        log.append(line)
    }

    /// run #159：引擎/助手明细行的统一收集入口（发布日志
    /// 总闸 CWLogGate）：TendiesEngine / PosterStoreHelper /
    /// PosterRefreshHelper 的 log 闭包一律经此入列，总闸
    /// 关闭时明细行（阶段明细 + [计时]）直接丢弃、不产
    /// 生。注意清理进度（run #148）由 PosterStoreHelper
    /// 内部先行观察同一批行再外转发，不经此入口、不受
    /// 总闸影响；用户级结果行（🎉/✅/❌）由各流程直接
    /// append，不走这里。
    func appendEngineDetail(_ line: String) {
        if CWLogGate.detailedLogsEnabled {
            tendiesFlashLog.append(line)
        }
    }

    /// run #159：密码盘 FFI 写盘回调的明细行收集入口
    /// （发布日志总闸，同 appendEngineDetail 口径）。
    func appendPasscodeDetail(_ line: String) {
        if CWLogGate.detailedLogsEnabled {
            passthmFlashLog.append("    " + line)
        }
    }

    // MARK: - Tendies / Wallpapers

    func loadSavedTendies() {
        if let data = UserDefaults.standard.data(forKey: "aircard.saved_tendies"),
           let items = try? JSONDecoder().decode([TendieItem].self, from: data) {
            // 选择状态不跨启动保留：每次载入都回到未选中，由用户手动勾选。
            self.tendieItems = items
                .filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
                .map { item in
                    var item = item
                    item.isSelected = false
                    return item
                }
            // 载入即按当前排序键成序（run #148 第五件）：
            // 展开页与轮播进页第一帧就是排序后的统一顺序。
            applyTendieSort()
        }
    }

    func saveTendieItems() {
        if let data = try? JSONEncoder().encode(tendieItems) {
            UserDefaults.standard.set(data, forKey: "aircard.saved_tendies")
        }
    }

    // MARK: - 壁纸库排序（run #148 第五件）

    /// 按当前排序键把 tendieItems 原地重排（展开页与轮播
    /// 共用这同一份数组顺序）。只在数据变化（载入/导入
    /// 完成）与排序设置变化时调用，视图 body 内不做任何
    /// 排序计算。比较器是全序：主键 → 文件名自然序 →
    /// id，保证结果确定、方向反转即严格逆序。
    func applyTendieSort() {
        guard tendieItems.count > 1 else { return }
        // 文件大小键才需要逐个 stat 已存包（实际字节数）；
        // 其余键不碰文件系统。
        var sizes: [UUID: Int] = [:]
        if tendieSortOrder == .size {
            for item in tendieItems {
                let attrs = try? FileManager.default.attributesOfItem(atPath: item.fileURL.path)
                sizes[item.id] = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            }
        }
        let order = tendieSortOrder
        let reversed = tendieSortReversed
        func baseLess(_ a: TendieItem, _ b: TendieItem) -> Bool {
            switch order {
            case .name:
                let c = a.fileName.localizedStandardCompare(b.fileName)
                if c != .orderedSame { return c == .orderedAscending }
            case .imported:
                if a.dateImported != b.dateImported { return a.dateImported > b.dateImported }
            case .size:
                let sa = sizes[a.id] ?? 0, sb = sizes[b.id] ?? 0
                if sa != sb { return sa > sb }
            }
            let c = a.fileName.localizedStandardCompare(b.fileName)
            if c != .orderedSame { return c == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
        tendieItems.sort { a, b in
            reversed ? baseLess(b, a) : baseLess(a, b)
        }
    }

    // MARK: - Tendies 预览再生

    /// 条目展示时若已存预览缺失或解码失败，从其 .tendies 包内重新提取并回写。
    /// 导入时的提取只在导入当下跑一次、失败静默置空，结果又随条目持久化，
    /// 展示侧原本只读已存数据、从不重试，所以在这里补一层展示时再生。
    /// 另对存量条目做一次性 V2 升级：无标记时即使已有可用预览，也用新策略
    /// （按最大图选）重提一次，提到了就覆盖，提不到保留旧预览；跑完无论
    /// 成败都置标记（UserDefaults 键 cocowall.previewV2.<条目 id>），避免
    /// 每次展示重复解压。有标记时回到原行为：仅缺失或解码失败才再生。
    func regenerateTendiePreview(itemID: UUID) {
        guard tendieItems.contains(where: { $0.id == itemID }) else { return }
        guard !previewRegenInFlight.contains(itemID),
              !previewRegenQueue.contains(itemID) else { return }
        // run #148：只入队，不在这里做任何解码校验（原版
        // 在调用方线程上 UIImage(data:) 全量解码验旧预览，
        // 展开页每格出现都付一遍）；校验与提取统一在泵出
        // 的后台任务里、并发封顶。
        previewRegenQueue.append(itemID)
        pumpPreviewRegenQueue()
    }

    /// 预览再生泵（run #148）：在飞任务不超过上限时逐个
    /// 取出队列头部执行；任务收尾回填、置 V2 标记（口径
    /// 同原实现）后继续泵。跳过条件与原实现一致：V2 已
    /// 升级且已存预览可解码 —— 只是改在后台线程判定。
    private func pumpPreviewRegenQueue() {
        while previewRegenInFlight.count < Self.previewRegenMaxConcurrent,
              !previewRegenQueue.isEmpty {
            let itemID = previewRegenQueue.removeFirst()
            guard let idx = tendieItems.firstIndex(where: { $0.id == itemID }) else { continue }
            let item = tendieItems[idx]
            previewRegenInFlight.insert(itemID)
            let v2Key = "cocowall.previewV2.\(itemID.uuidString)"
            let v2Done = UserDefaults.standard.bool(forKey: v2Key)
            let existingData = item.previewImageData
            let packageURL = item.fileURL
            Task {
                let extracted = await Task.detached(priority: .utility) { () -> Data? in
                    if v2Done, let existingData, UIImage(data: existingData) != nil {
                        return nil
                    }
                    return AppViewModel.extractPreviewData(from: packageURL)
                }.value
                previewRegenInFlight.remove(itemID)
                if !v2Done { UserDefaults.standard.set(true, forKey: v2Key) }
                if let extracted,
                   let current = tendieItems.firstIndex(where: { $0.id == itemID }) {
                    tendieItems[current].previewImageData = extracted
                    saveTendieItems()
                }
                pumpPreviewRegenQueue()
            }
        }
    }

    /// 从 .tendies 包提取预览图：图片扩展名候选先按像素总数从大到小选
    /// （像素相同再比导入时同一套关键词分数）——拼图层式包里人物本体
    /// 往往是最大的那张，关键词打分会把它们全压到最低分、选出碎片图。
    /// 候选全灭时放宽到包内第一张可解码的位图资产（按内容嗅探，不看扩展名）。
    /// 返回下采样后的 JPEG 数据，规格与导入时一致（最长边 600、质量 0.85）。
    nonisolated static func extractPreviewData(from packageURL: URL) -> Data? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendie_preview_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rc = packageURL.path.withCString { arcC in
            tempDir.path.withCString { dstC in
                al_zip_extract_all(arcC, dstC)
            }
        }
        guard rc == 0 else { return nil }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var allFiles: [URL] = []
        var candidates: [(url: URL, pixels: Int, score: Int)] = []
        while let url = enumerator.nextObject() as? URL {
            let pathLower = url.path.lowercased()
            let nameLower = url.lastPathComponent.lowercased()
            if pathLower.contains("__macosx") || nameLower == ".ds_store" { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            allFiles.append(url)

            let ext = url.pathExtension.lowercased()
            if ["heic", "png", "jpg", "jpeg"].contains(ext) {
                var score = 10
                if pathLower.contains("proxy") || pathLower.contains("adjusted") {
                    score += 90
                } else if pathLower.contains("background") || pathLower.contains("settling") {
                    score += 70
                } else if pathLower.contains("preview") || pathLower.contains("thumb") {
                    score += 50
                } else if pathLower.contains("asset.resource") {
                    score += 40
                }
                candidates.append((url, pixelCount(ofFile: url), score))
            }
        }

        candidates.sort {
            if $0.pixels != $1.pixels { return $0.pixels > $1.pixels }
            return $0.score > $1.score
        }
        for candidate in candidates {
            if let data = jpegThumbnail(fromFile: candidate.url) { return data }
        }

        let skipExts: Set<String> = ["plist", "json", "txt", "strings", "ca", "car", "zip", "mlmodel", "bin"]
        for url in allFiles {
            if skipExts.contains(url.pathExtension.lowercased()) { continue }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 40_000_000 { continue }
            if let data = jpegThumbnail(fromFile: url) { return data }
        }
        return nil
    }

    /// 只读图片的像素总数（CGImageSource 读元数据，不做全量解码）；读不到返回 0。
    nonisolated static func pixelCount(ofFile url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return 0 }
        return width * height
    }

    /// 读图、下采样、转 JPEG（与导入时的预览生成规格一致）。
    nonisolated static func jpegThumbnail(fromFile url: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let size = image.size
        let maxSide = max(size.width, size.height)
        var thumb = image
        if maxSide > 600 {
            let scale = 600 / maxSide
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        return thumb.jpegData(compressionQuality: 0.85)
    }

    func importTendieFiles(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var importedCount = 0
        var lastImportedName = ""
        for url in urls {
            do {
                var item = try await TendiesEngine.shared.importTendie(from: url)
                // 导入后默认不勾选（引擎构造时为选中，这里在导入赋值处改回未选中）。
                item.isSelected = false
                await MainActor.run {
                    self.tendieItems.removeAll(where: { $0.fileName == item.fileName })
                    self.tendieItems.append(item)
                    self.saveTendieItems()
                    importedCount += 1
                    lastImportedName = item.name
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "导入 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
                }
            }
        }
        // 导入收尾（run #148）：新条目并入当前排序顺序；
        // 至少一张落盘入库成功才弹「导入成功」toast——
        // 全失败时只有上面的错误通道，不冒充成功。
        if importedCount > 0 {
            await MainActor.run {
                self.applyTendieSort()
                self.showToast("导入成功")
            }
        }
    }

    func deleteTendie(item: TendieItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        tendieItems.removeAll(where: { $0.id == item.id })
        saveTendieItems()
    }

    func autoDetectPosterBoardContainer(silent: Bool = false) async {
        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            if !silent {
                await MainActor.run {
                    self.errorMessage = "没有生效的配对文件。请先在「配对」页配对设备。"
                }
            }
            return
        }

        await MainActor.run { self.isDetectingContainer = true }
        defer {
            Task { @MainActor in self.isDetectingContainer = false }
        }

        do {
            let container = try await TendiesEngine.shared.detectPosterBoardContainer(pairingPath: pairingPath)
            await MainActor.run {
                self.posterBoardContainer = container
                UserDefaults.standard.set(container, forKey: "aircard.posterboard_container")
            }
        } catch {
            if !silent {
                await MainActor.run {
                    self.recordDiagnostics(step: "查找 PosterBoard 容器", error: error)
                    self.errorMessage = "自动检测失败：\(error.localizedDescription)\n请确认 LocalDevVPN 已连接且设备已解锁。"
                }
            }
        }
    }

    func flashSelectedTendies() async {
        let selected = tendieItems.filter { $0.isSelected }
        guard !selected.isEmpty else {
            errorMessage = "没有选中要刷入的壁纸。"
            return
        }

        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            // run #163：未配对点刷入的提示文案改 Sage 定稿
            // （壁纸页横幅与弹窗同读 errorMessage、一处生效）；
            // 其余错误文案不动。
            errorMessage = "请先到软件内部设置-设备配对中进行配对"
            return
        }

        // Run #160: resource-integrity gate (see SPEC #160).
        // Synchronous: flashing only starts after verification
        // has concluded; failure stops the flash here.
        guard ResourceIntegrity.verifyBundleResources() else {
            errorMessage = "资源完整性校验未通过，已停止刷入"
            return
        }

        // Run #146: round stage timing (see SPEC #146). The container
        // detection only runs when no container is cached; its line is
        // appended after the log reset below so it survives.
        let roundStart = DispatchTime.now()
        var containerDetectMS: Int? = nil
        var container = posterBoardContainer.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.isEmpty {
            do {
                let detectStart = DispatchTime.now()
                container = try await TendiesEngine.shared.detectPosterBoardContainer(pairingPath: pairingPath)
                containerDetectMS = cwStageMS(detectStart, DispatchTime.now())
                self.posterBoardContainer = container
                UserDefaults.standard.set(container, forKey: "aircard.posterboard_container")
            } catch {
                // run #169：失败的真正原因记进诊断日志（作者页头像
                // 三击复制、设置页「问题反馈」附带），界面仍只显示
                // 通用提示，不把底层错误直接推给所有用户。
                recordDiagnostics(step: "查找 PosterBoard 容器", error: error)
                errorMessage = "无法自动找到 PosterBoard 容器。请确认 LocalDevVPN 已连接且 iPhone 已解锁。"
                return
            }
        }

        tendiesFlashPhase = .running
        tendiesFlashProgress = 0
        tendiesFlashLog = []
        if CWLogGate.detailedLogsEnabled, let containerDetectMS {
            tendiesFlashLog.append("[计时] 刷入·容器检测 \(cwStageText(containerDetectMS)) ms")
        }

        do {
            try await TendiesEngine.shared.flashTendies(
                items: selected,
                containerPath: container,
                resetProtections: resetPBProtections,
                pairingPath: pairingPath,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.appendEngineDetail(line)
                    }
                },
                progress: { [weak self] p in
                    DispatchQueue.main.async {
                        self?.tendiesFlashProgress = p
                    }
                },
                onDescriptorInstalled: { [weak self] item, ext, storeUUID in
                    // Run #124: the engine invokes this from its own
                    // execution context per landed descriptor; hop to
                    // the main queue like the log/progress closures
                    // above and record the flash-registry row.
                    DispatchQueue.main.async {
                        self?.registerFlashedDescriptor(item: item, extensionID: ext, storeUUID: storeUUID)
                    }
                }
            )
            // Run #146: round total; poster_refresh reports its own
            // [计时] line when it finishes (it runs async from here).
            if CWLogGate.detailedLogsEnabled {
                tendiesFlashLog.append("[计时] 刷入·整轮总计 \(cwStageText(cwStageMS(roundStart, DispatchTime.now()))) ms（不含 poster_refresh）")
            }
            tendiesFlashPhase = .done(ok: true)
            tendiesFlashProgress = 1.0
            tendiesFlashLog.append("🎉 壁纸应用成功！")
            tendiesFlashLog.append("正在刷新系统壁纸…")

            // 先试免注销刷新（只重启 PosterBoard 守护进程）；本版不自动注销兜底：
            // 未确认时只如实提示，用户可自行点「注销（NeoSpring）」手动注销。
            PosterRefreshHelper.attemptRefresh(
                pairingPath: pairingPath,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.appendEngineDetail(line)
                    }
                }
            ) { [weak self] confirmed, _ in
                guard let self else { return }
                if confirmed {
                    self.tendiesFlashLog.append("✅ 系统壁纸已刷新，免注销生效。")
                    // run #148：刷入全程成功（事务成功 + 刷新
                    // 已确认）才弹「刷入成功」toast；刷新未确认
                    // 只留下面的如实提示，不弹成功。
                    self.showToast("刷入成功")
                } else {
                    self.tendiesFlashLog.append("⚠️ 壁纸已写入，自动刷新未确认（本版不自动注销；如未生效可手动点注销）。")
                }
            }
        } catch {
            if CWLogGate.detailedLogsEnabled {
                tendiesFlashLog.append("[计时] 刷入·整轮总计 \(cwStageText(cwStageMS(roundStart, DispatchTime.now()))) ms（中途失败）")
            }
            tendiesFlashLog.append("❌ 错误：\(error.localizedDescription)")
            tendiesFlashPhase = .done(ok: false)
        }
    }

    func respringDevice() {
        tendiesFlashLog.append("⚡ 正在触发 NeoSpring 注销…")
        isNeoSpringing = true
        RespringHelper.triggerNeoSpring()
    }

    // MARK: - Flash registry (run #124)

    private static let flashRegistryDefaultsKey = "cocowall.flash_registry"

    /// Loads the persisted flash registry (store id -> entry).
    /// Absent or corrupt data reads as an empty registry. All
    /// registry reads/writes go through JSON codable with `try?`,
    /// so no throwing call can escape into the flash/cleanup flows.
    static func loadFlashRegistry() -> [String: FlashRegistryEntry] {
        guard let data = UserDefaults.standard.data(forKey: flashRegistryDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: FlashRegistryEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    static func saveFlashRegistry(_ registry: [String: FlashRegistryEntry]) {
        guard let data = try? JSONEncoder().encode(registry) else { return }
        UserDefaults.standard.set(data, forKey: flashRegistryDefaultsKey)
    }

    /// Records one successfully landed descriptor against the
    /// library item it was flashed from. Invoked once per descriptor
    /// from the flash flow's success branch (a multi-descriptor
    /// package registers each of its descriptors).
    func registerFlashedDescriptor(item: TendieItem, extensionID: String, storeUUID: String) {
        var registry = Self.loadFlashRegistry()
        registry["\(extensionID)/\(storeUUID)"] = FlashRegistryEntry(
            itemID: item.id.uuidString,
            itemName: item.name,
            relativePath: item.relativePath
        )
        Self.saveFlashRegistry(registry)
    }

    /// Drops registry rows for descriptors the cleanup flow has
    /// actually deleted (per-item `ok` results only), so the
    /// registry never points at a store id that no longer exists.
    static func removeFlashRegistryEntries(deletedResults: [PosterStoreHelper.DeleteResponse.ItemResult]) {
        let gone = deletedResults.filter { $0.ok }
        guard !gone.isEmpty else { return }
        var registry = loadFlashRegistry()
        let before = registry.count
        for res in gone {
            registry.removeValue(forKey: "\(res.extension)/\(res.uuid)")
        }
        if registry.count != before { saveFlashRegistry(registry) }
    }

    /// Support verdict for a system version string (run #124,
    /// wallpaper-page status area): this tool needs iOS 17.0+;
    /// the AirTraffic injection channel is patched from iOS 27.2
    /// (beta 3 onward), so 27.2+ is a risk, not a hard block.
    /// Pure function of the version string — no device access.
    nonisolated static func systemSupportLevel(version: String) -> SystemSupportLevel {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        if major < 17 { return .tooOld }
        if major > 27 || (major == 27 && minor >= 2) { return .patchedRisk }
        return .supported
    }

    /// Fallback match key (run #124): lowercased, ".wallpaper"
    /// suffix trimmed, and a leading purely-numeric base segment
    /// ("1572." — exactly the part run #122's identifier rewrite
    /// randomizes per flash) stripped. Pure string surgery — no
    /// regex, no throwing calls. Names whose first segment is not
    /// purely numeric keep it ("v6x.…", "3d.…").
    nonisolated static func packageFallbackKey(_ s: String) -> String {
        var t = s.lowercased()
        if t.hasSuffix(".wallpaper") { t = String(t.dropLast(".wallpaper".count)) }
        if let dot = t.firstIndex(of: ".") {
            let head = t[..<dot]
            if !head.isEmpty, head.allSatisfy({ $0.isNumber }) {
                t = String(t[t.index(after: dot)...])
            }
        }
        return t
    }

    // MARK: - Device PosterBoard store detection / cleanup

    /// PRBPosterExtensionDataStore layout version: 61 on iOS 17+, 59 below
    /// (same split the flash path uses).
    private var posterStoreStructVersion: Int {
        let major = Int(UIDevice.current.systemVersion.split(separator: ".").first ?? "0") ?? 0
        return major >= 17 ? 61 : 59
    }

    /// Shared preamble for the device-store operations: pairing file must
    /// exist, and the PosterBoard container must be known (auto-detect and
    /// persist it exactly like the flash flow does). Returns nil after
    /// recording the reason in devicePosterStatus.
    private func posterStoreContext() async -> (pairingPath: String, container: String)? {
        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            devicePosterStatus = "没有生效的配对文件。请先配对设备。"
            return nil
        }
        var container = posterBoardContainer.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.isEmpty {
            do {
                container = try await TendiesEngine.shared.detectPosterBoardContainer(pairingPath: pairingPath)
                self.posterBoardContainer = container
                UserDefaults.standard.set(container, forKey: "aircard.posterboard_container")
            } catch {
                devicePosterStatus = "无法自动找到 PosterBoard 容器：\(error.localizedDescription)"
                return nil
            }
        }
        return (pairingPath, container)
    }

    /// 检测本机已导入的壁纸： enumerates the descriptors actually present in
    /// the device's PosterBoard data store (device-side truth; never the
    /// local library list).
    func detectDevicePosters(clearStatus: Bool = true) async {
        guard !isScanningDevicePosters else { return }
        if clearStatus { devicePosterStatus = "" }
        guard let ctx = await posterStoreContext() else { return }

        isScanningDevicePosters = true
        devicePosters = []
        devicePosterSelection = []
        devicePosterThumbs = [:]
        devicePosterDisplayNames = [:]
        let version = posterStoreStructVersion
        let result: Result<[DevicePosterItem], PosterStoreError> = await withCheckedContinuation { cont in
            PosterStoreHelper.listImported(
                pairingPath: ctx.pairingPath,
                containerPath: ctx.container,
                structVersion: version,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.appendEngineDetail(line)
                    }
                }
            ) { result in
                cont.resume(returning: result)
            }
        }
        isScanningDevicePosters = false
        switch result {
        case .success(let items):
            devicePosters = items
            if items.isEmpty && devicePosterStatus.isEmpty {
                devicePosterStatus = "设备数据仓里没有检测到已导入的壁纸。"
            }
            prepareDevicePosterThumbnails()
        case .failure(let err):
            devicePosterStatus = "检测失败：\(err.localizedDescription)"
        }
    }

    /// Resolves cleanup-list thumbnails — and, where the source
    /// library entry is known, its display name — for device-store
    /// descriptors, in three layers (run #124; the run #122
    /// package-name-only matching is kept as layer 2):
    ///   1. Flash registry: store id ("<ext>/<uuid>") -> the library
    ///      item the descriptor was flashed from, recorded at flash
    ///      time. Authoritative: yields both the thumbnail and the
    ///      local display name.
    ///   2. Exact package-name match: the store-reported inner
    ///      `<name>.wallpaper` directory name against the same name
    ///      as a path component inside the local .tendies zips
    ///      (central directory, no extraction). Right for packages
    ///      flashed before the identifier rewrite existed.
    ///   3. Base-stripped fallback (thumbnails only), for packages
    ///      flashed before the registry existed but after run #122:
    ///      that rewrite renames the packaged numeric base inside
    ///      the store (7400.… came back as 1572.… / 4845.… / … —
    ///      Sage's 2026-11-01 device list) while the local library
    ///      keeps the original name, so layer 2 can never hit for
    ///      them. Both sides are keyed by packageFallbackKey
    ///      (numeric base stripped, suffix after it must agree).
    ///      NOTE: the stripped key collides for packages that
    ///      differ ONLY in their numeric base （同名异包） — the
    ///      first library item wins; that residual ambiguity is
    ///      accepted for this legacy layer, and layer 1 exists
    ///      precisely so new flashes never depend on it.
    /// The descriptor's `identifier` field would be another key but
    /// the DVT listing cannot read it (left empty by design, run
    /// #114). Unmatched descriptors keep the placeholder.
    func prepareDevicePosterThumbnails() {
        let posters = devicePosters
        guard !posters.isEmpty else {
            devicePosterThumbs = [:]
            devicePosterDisplayNames = [:]
            return
        }
        let library = tendieItems
        let registry = Self.loadFlashRegistry()
        Task.detached(priority: .utility) {
            var thumbs: [String: Data] = [:]
            var names: [String: String] = [:]

            // Layer 1: flash registry, by store id.
            var pending: [DevicePosterItem] = []
            for poster in posters {
                guard let entry = registry[poster.id] else {
                    pending.append(poster)
                    continue
                }
                // Live entry (by id, falling back to its file path)
                // supplies the thumbnail and the current name; the
                // recorded name still applies if the entry is gone.
                let item = library.first { $0.id.uuidString == entry.itemID }
                    ?? library.first { $0.relativePath == entry.relativePath }
                names[poster.id] = item?.name ?? entry.itemName
                if let data = item?.previewImageData {
                    thumbs[poster.id] = data
                }
            }

            // Layers 2+3: package-name matching for the rest.
            if !pending.isEmpty, !library.isEmpty {
                var exact: [String: Data] = [:]
                var exactItemName: [String: String] = [:]
                var stripped: [String: Data] = [:]
                for item in library {
                    guard let data = item.previewImageData else { continue }
                    for pkg in Self.wallpaperPackageNames(inZipAt: item.fileURL) {
                        if exact[pkg] == nil {
                            exact[pkg] = data
                            exactItemName[pkg] = item.name
                        }
                        let key = Self.packageFallbackKey(pkg)
                        if stripped[key] == nil { stripped[key] = data }
                    }
                }
                for poster in pending where !poster.packageName.isEmpty {
                    if let d = exact[poster.packageName] {
                        thumbs[poster.id] = d
                        if let n = exactItemName[poster.packageName] {
                            names[poster.id] = n
                        }
                    } else if let d = stripped[Self.packageFallbackKey(poster.packageName)] {
                        thumbs[poster.id] = d
                    }
                }
            }

            await MainActor.run { [weak self] in
                // Apply only if the list hasn't been replaced since.
                guard let self, self.devicePosters == posters else { return }
                self.devicePosterThumbs = thumbs
                self.devicePosterDisplayNames = names
            }
        }
    }

    /// Names of the `.wallpaper` bundle directories inside a
    /// .tendies zip (the package names the device store reports).
    nonisolated static func wallpaperPackageNames(inZipAt url: URL) -> [String] {
        guard let names = zipCentralDirectoryNames(at: url) else { return [] }
        var out = Set<String>()
        for name in names {
            for comp in name.split(separator: "/") {
                // Skip __MACOSX AppleDouble shadow entries ("._…").
                if comp.hasPrefix("._") { continue }
                if comp.lowercased().hasSuffix(".wallpaper") {
                    out.insert(String(comp))
                }
            }
        }
        return Array(out)
    }

    /// Entry names from a zip's central directory. Returns nil when
    /// the archive can't be parsed (including zip64) — callers then
    /// simply show placeholders.
    nonisolated static func zipCentralDirectoryNames(at url: URL) -> [String]? {
        let fh = FileHandle(forReadingAtPath: url.path)
        guard let fh else { return nil }
        defer { fh.closeFile() }
        let end = fh.seekToEndOfFile()
        guard end > 22 else { return nil }
        let tailLen = min(UInt64(65_557), end)
        do { try fh.seek(toOffset: end - tailLen) } catch { return nil }
        let tail = fh.readData(ofLength: Int(tailLen))
        guard tail.count >= 22 else { return nil }
        let bytes = [UInt8](tail)
        var eocd: Int? = nil
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard let e = eocd else { return nil }
        func u16(_ a: [UInt8], _ o: Int) -> Int { Int(a[o]) | (Int(a[o + 1]) << 8) }
        func u32(_ a: [UInt8], _ o: Int) -> UInt64 {
            UInt64(a[o]) | (UInt64(a[o + 1]) << 8) | (UInt64(a[o + 2]) << 16) | (UInt64(a[o + 3]) << 24)
        }
        var remaining = u16(bytes, e + 10)
        var cursor = u32(bytes, e + 16)
        if remaining == 0xFFFF || cursor == 0xFFFF_FFFF { return nil }
        var names: [String] = []
        while remaining > 0 {
            do { try fh.seek(toOffset: cursor) } catch { return nil }
            let head = fh.readData(ofLength: 46)
            guard head.count == 46 else { return nil }
            let h = [UInt8](head)
            guard h[0] == 0x50, h[1] == 0x4B, h[2] == 0x01, h[3] == 0x02 else { return nil }
            let nameLen = u16(h, 28)
            let extraLen = u16(h, 30)
            let commentLen = u16(h, 32)
            if nameLen > 0 {
                let nameData = fh.readData(ofLength: nameLen)
                guard nameData.count == nameLen else { return nil }
                if let name = String(data: nameData, encoding: .utf8), !name.isEmpty {
                    names.append(name)
                }
            }
            cursor += UInt64(46 + nameLen + extraLen + commentLen)
            remaining -= 1
        }
        return names
    }

    /// 清理所选： deletes the selected descriptors from the device data
    /// store, refreshes the list, then tries the no-respring PosterBoard
    /// refresh so the removal takes effect.
    func cleanupSelectedDevicePosters() async {
        guard !isCleaningDevicePosters else { return }
        let targets = devicePosters.filter { devicePosterSelection.contains($0.id) }
        guard !targets.isEmpty else { return }
        // Run #146: round stage timing (see SPEC #146).
        let roundStart = DispatchTime.now()
        guard let ctx = await posterStoreContext() else { return }

        isCleaningDevicePosters = true
        // run #148：进度从检测段起位；删除段的逐目标计数由
        // PosterStoreHelper 的进度回调（rust 标记映射）推进，
        // 删除流程本身不因进度改动。
        cleanupProgress = CleanupProgressState(phase: .detecting, completed: 0, total: targets.count)
        let version = posterStoreStructVersion
        let result: Result<PosterStoreHelper.DeleteResponse, PosterStoreError> = await withCheckedContinuation { cont in
            PosterStoreHelper.deleteImported(
                pairingPath: ctx.pairingPath,
                containerPath: ctx.container,
                structVersion: version,
                targets: targets,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.appendEngineDetail(line)
                    }
                },
                progress: { [weak self] p in
                    DispatchQueue.main.async {
                        guard let self, self.isCleaningDevicePosters else { return }
                        switch p.phase {
                        case .detecting:
                            self.cleanupProgress = CleanupProgressState(phase: .detecting, completed: 0, total: p.total)
                        case .deleting:
                            self.cleanupProgress = CleanupProgressState(phase: .deleting, completed: p.completed, total: p.total)
                        case .reviewing:
                            self.cleanupProgress = CleanupProgressState(phase: .reviewing, completed: p.total, total: p.total)
                        }
                    }
                }
            ) { result in
                cont.resume(returning: result)
            }
        }

        switch result {
        case .success(let r):
            // Run #124: drop flash-registry rows for the descriptors
            // that were actually deleted, so the registry never maps
            // a store id that no longer exists.
            Self.removeFlashRegistryEntries(deletedResults: r.results)
            var message = "清理完成：成功 \(r.deleted) 条"
            if r.failed > 0 { message += "，失败 \(r.failed) 条" }
            message += "。"
            // run #148：删后段（重检测 + PosterBoard 刷新）
            // 进度置「刷新中」，收尾在刷新回调里清进度并
            // 弹「已清理 N 张」toast。
            cleanupProgress = CleanupProgressState(phase: .refreshing, completed: targets.count, total: targets.count)
            let deletedCount = r.deleted
            await detectDevicePosters(clearStatus: false)
            // Run #146: round total （删除 + 删后重检测）; poster_refresh
            // reports its own [计时] line when it finishes.
            if CWLogGate.detailedLogsEnabled {
                tendiesFlashLog.append("[计时] 清理·整轮总计 \(cwStageText(cwStageMS(roundStart, DispatchTime.now()))) ms（不含 poster_refresh）")
            }
            devicePosterStatus = message
            isCleaningDevicePosters = false
            // Removal only takes effect once PosterBoard re-reads its
            // store — try the免注销 refresh; on failure just report it
            // (this版不自动注销, same rule as the flash flow).
            PosterRefreshHelper.attemptRefresh(
                pairingPath: ctx.pairingPath,
                log: { [weak self] line in
                    DispatchQueue.main.async {
                        self?.appendEngineDetail(line)
                    }
                }
            ) { [weak self] confirmed, _ in
                guard let self else { return }
                // run #148：一轮清理到此收尾——清进度，删
                // 除本身已成功即弹「已清理 N 张」toast（刷
                // 新是否确认只影响下面状态文案的措辞，删
                // 除事实不变，不因此扣住成功提示）。
                self.cleanupProgress = nil
                self.showToast("已清理 \(deletedCount) 张")
                if confirmed {
                    self.devicePosterStatus += "已刷新 PosterBoard，删除已生效。"
                } else {
                    self.devicePosterStatus += "自动刷新未确认，如列表未更新可手动点注销生效。"
                }
            }
        case .failure(let err):
            if CWLogGate.detailedLogsEnabled {
                tendiesFlashLog.append("[计时] 清理·整轮总计 \(cwStageText(cwStageMS(roundStart, DispatchTime.now()))) ms（失败）")
            }
            isCleaningDevicePosters = false
            cleanupProgress = nil
            devicePosterStatus = "清理失败：\(err.localizedDescription)"
        }
    }

    func reset() {
        passthmFlashPhase = .idle
        passthmFlashProgress = 0
        tendiesFlashPhase = .idle
        tendiesFlashProgress = 0
        errorMessage = nil
    }
}

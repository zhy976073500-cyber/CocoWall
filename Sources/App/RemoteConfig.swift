import Foundation
import Combine
import CryptoKit

// MARK: - 编码常量（run #159 字符串收口）
//
// 发布防盗方案第三节「字符串收口」：配置端点、公钥之外的
// 默认链接、渠道水印等敏感常量不以明文躺在二进制里，统一
// 以 base64 编码存放、运行时解码。挡的是「解压 IPA 改字
// 换皮」一级的抄法，不承诺对抗有心逆向（方案第 0 节共识）。
// 覆盖清单登记在 SPEC run #159 第三节。

enum CWEncoded {
    static func decode(_ encoded: String) -> String {
        guard let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }
}

/// 发布渠道水印（run #159 第五节）：标识分发渠道/批次，
/// 不进任何 UI。存放方式与其它敏感常量同法（编码存放、
/// 运行时解码），由 RemoteConfigService 持有并写入配置
/// 缓存的元数据，发现盗版时可凭它溯源到流出批次。
enum CWChannel {
    static var tag: String { CWEncoded.decode("Y29jb3dhbGwtb2ZmaWNpYWwtMS4wLjA=") }
}

// MARK: - 远程配置模型（结构以 remote-config.json v3 为准）

struct RemoteConfig: Equatable {
    struct Announcement: Equatable {
        var id: Int = 0
        var title: String = ""
        var body: String = ""
        var link: String = ""
    }

    struct AppInfo: Equatable {
        var latestVersion: String = ""
        var forceUpdate: Bool = false
        var downloadUrl: String = ""
        var updateNote: String = ""
        /// 匿名使用计数上报地址（run #166）：可选字段，
        /// 缺失/为空即不上报；现行已发布的 B 版配置没有此
        /// 字段，解析行为与此前逐字一致。激活方式=日后在
        /// 配置里填入统计函数 URL 并重签发布，客户端零改动。
        var statsUrl: String = ""
    }

    /// 壁纸目录条目（run #159 本轮只解析存模型，不接 UI）。
    struct WallpaperEntry: Equatable {
        var no: Int = 0
        var title: String = ""
        var preview: String = ""
        var driveUrl: String = ""
    }

    var announcement = Announcement()
    var app = AppInfo()
    var feishuUrl: String = ""
    var pairingTutorialUrl: String = ""
    var wallpapers: [WallpaperEntry] = []

    /// 内置默认：从未成功加载任何验签配置时的生效值。
    /// 两个链接与 run #158 之前写死在 UI 里的值逐字一致，
    /// 保证「配置从未加载成功 ⇒ 全部功能照常」（零误伤红线）。
    static var defaults: RemoteConfig {
        var config = RemoteConfig()
        config.feishuUrl = CWEncoded.decode("aHR0cHM6Ly9teS5mZWlzaHUuY24vd2lraS9PaTZwd3JScDlpOHdkMmtCbDBMYzRibjluVGI=")
        config.pairingTutorialUrl = CWEncoded.decode("aHR0cHM6Ly9kcml2ZS51Yy5jbi9zLzJmNjM2MzQ2NjdhNDQ/cHVibGljPTE=")
        return config
    }
}

// 容错解码：任一字段缺失/类型不符都落默认值，绝不让一份
// 字段不全的配置整份解码失败（验签通过的配置最大限度生效）。
extension RemoteConfig: Decodable {
    private enum CodingKeys: String, CodingKey {
        case announcement, app, feishuUrl, pairingTutorialUrl, wallpapers
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        if let box = try? root.decodeIfPresent(AnnouncementBox.self, forKey: .announcement) {
            announcement = box.value
        }
        if let box = try? root.decodeIfPresent(AppInfoBox.self, forKey: .app) {
            app = box.value
        }
        feishuUrl = (try? root.decodeIfPresent(String.self, forKey: .feishuUrl)) ?? ""
        pairingTutorialUrl = (try? root.decodeIfPresent(String.self, forKey: .pairingTutorialUrl)) ?? ""
        if let boxes = try? root.decodeIfPresent([WallpaperBox].self, forKey: .wallpapers) {
            wallpapers = boxes.map(\.value)
        }
    }

    private struct AnnouncementBox: Decodable {
        var value: RemoteConfig.Announcement
        private enum K: String, CodingKey { case id, title, body, link }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            var a = RemoteConfig.Announcement()
            a.id = (try? c.decodeIfPresent(Int.self, forKey: .id)) ?? 0
            a.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            a.body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
            a.link = (try? c.decodeIfPresent(String.self, forKey: .link)) ?? ""
            value = a
        }
    }

    private struct AppInfoBox: Decodable {
        var value: RemoteConfig.AppInfo
        private enum K: String, CodingKey { case latestVersion, forceUpdate, downloadUrl, updateNote, statsUrl }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            var a = RemoteConfig.AppInfo()
            a.latestVersion = (try? c.decodeIfPresent(String.self, forKey: .latestVersion)) ?? ""
            a.forceUpdate = (try? c.decodeIfPresent(Bool.self, forKey: .forceUpdate)) ?? false
            a.downloadUrl = (try? c.decodeIfPresent(String.self, forKey: .downloadUrl)) ?? ""
            a.updateNote = (try? c.decodeIfPresent(String.self, forKey: .updateNote)) ?? ""
            a.statsUrl = (try? c.decodeIfPresent(String.self, forKey: .statsUrl)) ?? ""
            value = a
        }
    }

    private struct WallpaperBox: Decodable {
        var value: RemoteConfig.WallpaperEntry
        private enum K: String, CodingKey { case no, title, preview, driveUrl }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            var w = RemoteConfig.WallpaperEntry()
            w.no = (try? c.decodeIfPresent(Int.self, forKey: .no)) ?? 0
            w.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            w.preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? ""
            w.driveUrl = (try? c.decodeIfPresent(String.self, forKey: .driveUrl)) ?? ""
            value = w
        }
    }
}

// MARK: - 远程配置服务（run #159 第一节）
//
// 由刷入链路所在的 AppViewModel 持有并在 init 里 start()
// （适度耦合点之一；验签状态还并入壁纸页状态胶囊的内部
// 状态计算，见 TendiesView）。链路：启动同步读上次验签
// 通过的缓存（连原始字节存、读出后复验）→ 异步拉主端点
// → 验不过/拉不到换兜底端点 → 都不行就保持缓存/内置
// 默认。全程不阻塞任何功能、失败静默。

@MainActor
final class RemoteConfigService: ObservableObject {

    enum VerificationState: Equatable {
        /// 本次启动尚未有任何一份配置通过验签。
        case unverified
        /// 已有配置（缓存或刚拉到的）通过 Ed25519 验签。
        case verified
        /// 端点有响应但签名全部验不过（且本次启动尚无验签
        /// 通过的配置）——配置整份丢弃，只记状态不打扰用户。
        case rejected
    }

    enum Prompt: Equatable {
        case announcement(RemoteConfig.Announcement)
        case update(RemoteConfig.AppInfo)

        var announcementValue: RemoteConfig.Announcement? {
            if case .announcement(let a) = self { return a }
            return nil
        }
        var updateValue: RemoteConfig.AppInfo? {
            if case .update(let a) = self { return a }
            return nil
        }
    }

    @Published private(set) var verificationState: VerificationState = .unverified
    @Published private(set) var effectiveConfig: RemoteConfig = .defaults
    @Published private(set) var prompt: Prompt? = nil

    /// 渠道水印（见 CWChannel）：随配置缓存元数据落盘。
    let channelTag = CWChannel.tag

    private var started = false
    private var refreshTask: Task<Void, Never>? = nil

    private enum Keys {
        static let lastReadAnnouncementID = "cw.remoteConfig.lastReadAnnouncementID"
        static let lastPromptedVersion = "cw.remoteConfig.lastPromptedVersion"
    }

    init() {
        loadVerifiedCache()
    }

    /// AppViewModel.init 调用一次：先按缓存/默认评估一次
    /// 弹窗，再异步刷新网络配置。
    func start() {
        guard !started else { return }
        started = true
        evaluatePrompts()
        refreshTask = Task { [weak self] in
            await self?.refreshFromNetwork()
        }
    }

    // MARK: 生效值（字段为空时回落内置默认，入口永不失效）

    var feishuURLString: String {
        effectiveConfig.feishuUrl.isEmpty ? RemoteConfig.defaults.feishuUrl : effectiveConfig.feishuUrl
    }

    var pairingTutorialURLString: String {
        effectiveConfig.pairingTutorialUrl.isEmpty
            ? RemoteConfig.defaults.pairingTutorialUrl
            : effectiveConfig.pairingTutorialUrl
    }

    // MARK: 弹窗（公告 / 版本提醒）

    /// 弹窗被关闭（或主按钮已处理跳转）后调用：按类型记账，
    /// 然后链式评估下一个待弹项。强更不记账——下次启动还会
    /// 再弹，直到用户更新到 latestVersion 为止。
    func dismissPrompt() {
        switch prompt {
        case .announcement(let a):
            UserDefaults.standard.set(a.id, forKey: Keys.lastReadAnnouncementID)
        case .update(let info):
            if !info.forceUpdate {
                UserDefaults.standard.set(info.latestVersion, forKey: Keys.lastPromptedVersion)
            }
        case nil:
            return
        }
        prompt = nil
        evaluatePrompts()
    }

    /// 优先级：强更 > 公告 > 普通版本提醒。同一时刻最多一个。
    private func evaluatePrompts() {
        guard prompt == nil else { return }
        let config = effectiveConfig
        let current = Self.currentAppVersion

        // 版本提醒：latestVersion 高于当前且 downloadUrl 非空。
        let info = config.app
        if !info.latestVersion.isEmpty, !info.downloadUrl.isEmpty,
           Self.version(info.latestVersion, isNewerThan: current) {
            if info.forceUpdate {
                prompt = .update(info)
                return
            }
            let prompted = UserDefaults.standard.string(forKey: Keys.lastPromptedVersion)
            if prompted != info.latestVersion {
                // 普通提醒排在公告之后：先看公告，公告关掉后
                // dismissPrompt 的链式评估会再轮到它。
                if pendingAnnouncement(in: config) == nil {
                    prompt = .update(info)
                    return
                }
            }
        }
        if let a = pendingAnnouncement(in: config) {
            prompt = .announcement(a)
        }
    }

    private func pendingAnnouncement(in config: RemoteConfig) -> RemoteConfig.Announcement? {
        let a = config.announcement
        guard a.id > 0, !a.title.isEmpty || !a.body.isEmpty else { return nil }
        let lastRead = UserDefaults.standard.integer(forKey: Keys.lastReadAnnouncementID)
        return a.id > lastRead ? a : nil
    }

    static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// 点分版本比较：数值段逐段比，不足补 0。
    static func version(_ candidate: String, isNewerThan current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        var a = parts(candidate)
        var b = parts(current)
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count)
        b += Array(repeating: 0, count: n - b.count)
        for i in 0..<n where a[i] != b[i] {
            return a[i] > b[i]
        }
        return false
    }

    // MARK: 拉取与验签

    private static var endpointURLs: [URL] {
        [
            CWEncoded.decode("aHR0cHM6Ly9jb2Nvd2FsbC1jb25maWcub3NzLWNuLWJlaWppbmcuYWxpeXVuY3MuY29tL2NvbmZpZy5qc29u"),
            CWEncoded.decode("aHR0cHM6Ly9jZG4uanNkZWxpdnIubmV0L2doL3poeTk3NjA3MzUwMC1jeWJlci9jb2Nvd2FsbC1jb25maWdAbWFpbi9jb25maWcuanNvbg=="),
        ].compactMap { URL(string: $0) }
    }

    private static func signatureURL(for configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent("config.sig")
    }

    private func refreshFromNetwork() async {
        var sawInvalidSignature = false
        for endpoint in Self.endpointURLs {
            guard let (configData, sigText) = await fetchPair(configURL: endpoint) else {
                continue // 拉不到（断网/404/超时）：静默换下一个端点
            }
            guard Self.verify(configData: configData, signatureText: sigText) else {
                sawInvalidSignature = true
                continue // 验不过：整份丢弃，换兜底端点
            }
            guard let decoded = try? JSONDecoder().decode(RemoteConfig.self, from: configData) else {
                continue
            }
            effectiveConfig = decoded
            verificationState = .verified
            persistCache(configData: configData, signatureText: sigText)
            evaluatePrompts()
            // 匿名使用计数（run #166）：验签通过的新配置生效
            // 后顺带触发一次（内部自带「今日已成功上报则跳
            // 过」与「statsUrl 为空则无-op」两道门；缓存/内置
            // 默认没有 statsUrl，走不到实际上报）。完全异步、
            // 失败静默，见 UsageStats。
            UsageStats.reportIfNeeded(statsUrl: decoded.app.statsUrl)
            return
        }
        if sawInvalidSignature, verificationState != .verified {
            verificationState = .rejected
        }
    }

    private func fetchPair(configURL: URL) async -> (Data, String)? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        do {
            let (configData, configResponse) = try await session.data(from: configURL)
            guard (configResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let (sigData, sigResponse) = try await session.data(from: Self.signatureURL(for: configURL))
            guard (sigResponse as? HTTPURLResponse)?.statusCode == 200,
                  let sigText = String(data: sigData, encoding: .utf8) else { return nil }
            return (configData, sigText)
        } catch {
            return nil
        }
    }

    /// Ed25519 验签：公钥为原始 32 字节的 base64；签名文件
    /// 内容是「config.json 原始字节的签名」的 base64（可能
    /// 带结尾空白，先 trim 再解码）。验不过一律整份丢弃。
    /// 本函数是纯函数，run #160 资源完整性校验复用同一入口
    /// 验清单签名（同一把公钥的唯一常量来源），故标
    /// nonisolated 供同步上下文调用。
    nonisolated static func verify(configData: Data, signatureText: String) -> Bool {
        let trimmed = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: trimmed), signature.count == 64,
              let keyData = Data(base64Encoded: "zYU8LDldMafck0ya4KumaNpVJbYeERGJSXVPYarRqaw="),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return publicKey.isValidSignature(signature, for: configData)
    }

    // MARK: 缓存（Application Support，连原始字节存）

    private static var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("RemoteConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persistCache(configData: Data, signatureText: String) {
        guard let dir = Self.cacheDirectory else { return }
        try? configData.write(to: dir.appendingPathComponent("config.json"), options: .atomic)
        try? Data(signatureText.utf8).write(to: dir.appendingPathComponent("config.sig"), options: .atomic)
        // 元数据：渠道水印 + 落盘时间，盗版溯源与自查用，不进 UI。
        let meta = "{\"channel\":\"\(channelTag)\",\"savedAt\":\(Int(Date().timeIntervalSince1970))}"
        try? Data(meta.utf8).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// 启动同步读缓存：读出后先复验，验过才解码生效——
    /// 缓存被篡改同样整份丢弃，回落内置默认。
    private func loadVerifiedCache() {
        guard let dir = Self.cacheDirectory,
              let configData = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let sigData = try? Data(contentsOf: dir.appendingPathComponent("config.sig")),
              let sigText = String(data: sigData, encoding: .utf8),
              Self.verify(configData: configData, signatureText: sigText),
              let decoded = try? JSONDecoder().decode(RemoteConfig.self, from: configData)
        else { return }
        effectiveConfig = decoded
        verificationState = .verified
    }
}

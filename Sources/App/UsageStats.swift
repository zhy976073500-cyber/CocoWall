import Foundation

// MARK: - 匿名使用计数（run #166）
//
// 目的：让作者能看到「今天有多少台设备在用」这一量级，
// 不做任何用户画像。客户端只在远程配置（验签通过的那
// 份）里带了 app.statsUrl 时才工作——现行已发布配置没
// 有此字段，服务整体无-op；日后把统计函数 URL 填进配置
// 重签发布即激活，客户端零改动、用户无感、无设置开关。
//
// 上报口径（一台设备每天至多成功上报一次）：
// - 载荷只有三项：安装随机 UUID（首次生成、持久化于
//   UserDefaults，卸载重装即换新）、App 版本、当天日期
//   （本地时区 yyyy-MM-dd）。不带设备型号、不带系统版
//   本、不带任何其它标识；IP 只在服务端连接层天然可见，
//   客户端不采集、不发送。
// - 触发点：RemoteConfigService 一份网络配置验签通过并
//   生效后顺带调用（见 RemoteConfig.refreshFromNetwork）。
//   缓存/内置默认没有 statsUrl，走不到实际上报。
// - 失败全静默：不重试、不弹窗、不写用户可见日志；发布
//   版不打印 id 与 URL（run #159 发布版无详细日志口径）。
//   当天没报成，下次启动再试。
enum UsageStats {

    private enum Keys {
        static let installID = "cw.usageStats.installID"
        static let lastReportDate = "cw.usageStats.lastReportDate"
    }

    /// 上报超时（秒）：统计通道绝不许拖住任何功能。
    private static let timeout: TimeInterval = 5

    /// 远程配置生效后调用。statsUrl 为空/非法、或今日已
    /// 成功上报过 → 立即返回；否则 detached 后台发一次。
    static func reportIfNeeded(statsUrl: String) {
        let trimmed = statsUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }

        let defaults = UserDefaults.standard
        let today = Self.dayString(for: Date())
        guard defaults.string(forKey: Keys.lastReportDate) != today else { return }

        // 安装 ID：生成一次后持久化，此后恒定。
        let installID: String
        if let existing = defaults.string(forKey: Keys.installID), !existing.isEmpty {
            installID = existing
        } else {
            installID = UUID().uuidString
            defaults.set(installID, forKey: Keys.installID)
        }

        let payload: [String: String] = [
            "id": installID,
            "v": RemoteConfigService.currentAppVersion,
            "d": today,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)

        // 发射后不管：独立会话、独立任务，不挂任何 UI 与
        // 业务链路；只有收到 2xx 才记「今日已上报」。
        Task.detached {
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    UserDefaults.standard.set(today, forKey: Keys.lastReportDate)
                }
            } catch {
                // 静默：下次启动再试。
            }
        }
    }

    /// 本地时区日期串（yyyy-MM-dd）：与「当天至多一次」
    /// 的记账口径共用同一格式。
    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

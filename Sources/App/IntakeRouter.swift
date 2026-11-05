//
//  IntakeRouter.swift
//  CocoWall
//
//  统一智能接收（run #165）：所有进入 App 的文件——系统
//  「打开方式」（onOpenURL）与 App 内两个导入选择器（壁纸
//  导入、配对文件导入）——都先经过这里按内容分类，再分发
//  到既有导入路径。不看后缀看内容，优先级固定为：
//    1. 真实壁纸包：ZIP 魔数开头（结构校验由
//       TendiesEngine.importTendie 本体执行，不另写校验器）
//    2. Base64 编码包：全文严格 Base64 解码后命中 1
//    3. 配对文件：可解析为字典根的 plist（应用走既有
//       importPairingFile，其自有校验与状态反馈不变）
//  三类全不命中 → errorMessage「无法识别这个文件」，不改
//  任何状态。分类函数对任意输入全定义、防御式：坏 Base64、
//  截断 zip、杂 plist、空文件都干净落到「无法识别」。
//

import Foundation

extension AppViewModel {

    /// 智能接收的分类结果。tendiesPack 携带要交给引擎的
    /// 字节（1 = 原始字节，2 = 解码后字节）。
    enum IntakeClassification {
        case tendiesPack(Data)
        case pairingFile(Data)
        case unrecognized
    }

    // MARK: - 分类（纯函数，无副作用）

    static func classifyIntake(data: Data) -> IntakeClassification {
        guard !data.isEmpty else { return .unrecognized }

        // 1. 真实结构：ZIP 魔数 PK\x03\x04。
        if hasZIPMagic(data) {
            return .tendiesPack(data)
        }

        // 2. 解码结构：全文严格 Base64 → 解码产物命中 1。
        if let decoded = strictBase64Decode(data), hasZIPMagic(decoded) {
            return .tendiesPack(decoded)
        }

        // 3. 配对 plist：可解析且根为字典（配对记录的格式
        // 门；键级校验仍由既有配对应用路径在用时把关，本
        // 处不另立平行校验器）。既有配对导入自有校验=
        // 可读且非空，已由入口保证。
        if let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           root is [String: Any] {
            return .pairingFile(data)
        }

        return .unrecognized
    }

    private static func hasZIPMagic(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
    }

    /// 严格 Base64 解码：去掉全部空白后，剩余字符必须全部
    /// 落在 Base64 字母表内、`=` 只能作为末尾至多两个的
    /// 填充、总长为 4 的倍数；解码后再编码须与原文逐字
    /// 一致（排除非规范尾位）。任一不符返回 nil。不使用
    /// ignoreUnknownCharacters 之类宽容选项。
    static func strictBase64Decode(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let stripped = text.filter { !$0.isWhitespace }
        guard !stripped.isEmpty else { return nil }

        var padding = 0
        var bodyCount = 0
        for ch in stripped {
            if ch == "=" {
                padding += 1
                continue
            }
            guard padding == 0 else { return nil }
            guard ch.isASCII, let v = ch.asciiValue,
                  (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 43 || v == 47
            else { return nil }
            bodyCount += 1
        }
        guard padding <= 2, (bodyCount + padding) % 4 == 0 else { return nil }

        guard let decoded = Data(base64Encoded: stripped) else { return nil }
        guard decoded.base64EncodedString() == stripped else { return nil }
        return decoded
    }

    // MARK: - 入口（URL → 同步读入 → 分发）

    /// 统一接收入口：系统「打开方式」与两个 App 内选择器
    /// 共用。读入在调用线程同步完成（与既有配对导入在选
    /// 择器回调内同步读取的行为一致，也保证 security-
    /// scoped 资源在回调收尾前读完）。
    /// switchTabOnSuccess 仅系统「打开方式」传 true：成功
    /// 后切到对应分区（壁纸 / 设置）；选择器入口用户已在
    /// 对应页面，不切。
    func intakeFile(at url: URL, switchTabOnSuccess: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }

        guard let data, !data.isEmpty else {
            errorMessage = "无法识别这个文件"
            return
        }
        intake(data: data, originalName: url.lastPathComponent, switchTabOnSuccess: switchTabOnSuccess)
    }

    /// 系统「打开方式」专用入口（AirCardApp 的 onOpenURL）。
    func handleOpenInURL(_ url: URL) {
        // run #167：LocalDevVPN 回调（`localdevvpn://enable?
        // scheme=cocowall`，1 秒后 LocalDevVPN 打开 `cocowall://`
        // 跳回本 App）——只刷新网络状态（外部回环已连上即点亮
        // vpnUp），不走文件接收，否则会误报「无法识别这个文件」。
        if url.scheme?.lowercased() == "cocowall" {
            refreshNetworkStatus()
            return
        }
        intakeFile(at: url, switchTabOnSuccess: true)
    }

    private func intake(data: Data, originalName: String, switchTabOnSuccess: Bool) {
        switch Self.classifyIntake(data: data) {
        case .tendiesPack(let bytes):
            let name = Self.tendiesFileName(forOriginal: originalName)
            guard let staged = Self.stageIntakeData(bytes, fileName: name) else {
                errorMessage = "无法识别这个文件"
                return
            }
            Task { await self.importTendieViaIntake(stagedURL: staged, switchTab: switchTabOnSuccess) }

        case .pairingFile:
            guard let staged = Self.stageIntakeData(data, fileName: originalName) else {
                errorMessage = "无法识别这个文件"
                return
            }
            // 既有配对应用路径：写入规范副本、置自定义路径、
            // 刷新状态与 pairingStatus 反馈，一字未改。
            let ok = importPairingFile(from: staged, originalName: originalName)
            try? FileManager.default.removeItem(at: staged)
            if ok, switchTabOnSuccess {
                selectedTab = .settings
            }

        case .unrecognized:
            errorMessage = "无法识别这个文件"
        }
    }

    // MARK: - 分发实现

    /// 壁纸包分发：结构校验与导入同体——调用既有
    /// TendiesEngine.importTendie（与 importTendieFiles
    /// 同一个引擎入口）；成功后的登记（取消默认勾选、
    /// 同名替换、落盘保存、并入排序、「导入成功」toast）
    /// 与 importTendieFiles 逐项一致。引擎抛错 = 结构校
    /// 验未过 = 不属任何一类 → 统一报「无法识别这个文件」，
    /// 并清掉引擎校验前留在 Tendies 存储里的半成品副本，
    /// 保证无半导入。
    private func importTendieViaIntake(stagedURL: URL, switchTab: Bool) async {
        let storedCopy = TendiesEngine.tendiesStorageDirectory
            .appendingPathComponent(stagedURL.lastPathComponent)
        do {
            var item = try await TendiesEngine.shared.importTendie(from: stagedURL)
            try? FileManager.default.removeItem(at: stagedURL)
            item.isSelected = false
            tendieItems.removeAll(where: { $0.fileName == item.fileName })
            tendieItems.append(item)
            saveTendieItems()
            applyTendieSort()
            showToast("导入成功")
            if switchTab {
                selectedTab = .wallpapers
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            if stagedURL.standardizedFileURL.path != storedCopy.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: storedCopy)
            }
            errorMessage = "无法识别这个文件"
        }
    }

    /// 引擎按源文件名落盘存储，故暂存文件名必须先定稿为
    /// .tendies 名：原名已是 .tendies 则原样，否则换后缀
    /// （如 1-pack.txt → 1-pack.tendies）；基名为空时用
    /// 固定名兜底。
    private static func tendiesFileName(forOriginal originalName: String) -> String {
        if originalName.lowercased().hasSuffix(".tendies") {
            return originalName
        }
        let base = (originalName as NSString).deletingPathExtension
        return (base.isEmpty ? "导入壁纸" : base) + ".tendies"
    }

    /// 把待导入字节暂存到临时目录（引擎从 URL 导入、配对
    /// 导入从 URL 读入，都需要一个真实文件）。写失败返回
    /// nil，由调用方统一报「无法识别这个文件」。
    private static func stageIntakeData(_ data: Data, fileName: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Intake", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

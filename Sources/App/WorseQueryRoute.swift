//
//  WorseQueryRoute.swift
//  CocoWall
//
//  worse_query 接入（run #176，行为重写版）：App Group 容器发现、
//  版本与能力探测、逃逸触发接口、路径解析、PosterBoard 容器定位、
//  失败回退与结构化诊断。对应手册 §5 的模块 1–5、8。
//
//  许可硬线：worse_query 为 GPL-3.0，CocoWall 闭源。本文件为自研
//  Swift 实现，只按公开行为规格（README、FAQ、手册 §5 的行为清单）
//  写成；不得包含、链接、复制 worse_query / Erosion / Pocket Poster /
//  Placard 的任何源码，不得沿用下游给 bad_query 封装起的名字。
//  出包前许可部分须经熟悉开源许可的第三方复核（手册 §4）。
//
//  本版状态（run #176，验证版优先）：模块 1（App Group 探测）为
//  完整可测实现，是手册验证 1 的生死门；模块 3（逃逸触发）只有接口
//  与未实现桩——其内部参数未公开，不得编造，待真机联调时实测填。
//  在逃逸触发落地之前，26.0–27.1 走现有路线，27.2 如实提示暂不
//  支持，不宣称支持、不静默假装。
//

import Foundation
import UIKit

// MARK: - 模块 1：App Group 容器发现

/// App Group 容器发现（手册 §4–§5 模块 1）。
///
/// Group id 与包名是两回事：包名仍是 `com.coco.cocowall`，不改；
/// Group id 建议 `group.com.coco.cocowall.shared`，最终以开发者
/// 后台注册为准。运行时解析顺序（不要 hardcode）：
///   1. Info.plist 的 `ALTAppGroups`——AltStore 重签后写入的实际
///      授予 id，形式为 `group.<原id>.<TEAMID>`；
///   2. Info.plist 的编译期常量 `CWAppGroupIdentifier`；
///   3. 字面量兜底 `fallbackGroupIdentifier`。
enum WorseQueryAppGroup {

    /// 建议的 Group id（以开发者后台注册为准）。
    static let fallbackGroupIdentifier = "group.com.coco.cocowall.shared"

    /// AltStore / SideStore 重签后写入 Info.plist 的实际授予 id 列表。
    /// 为空表示未经过这类重签，或重签工具未授予 App Groups。
    static var altAppGroups: [String] {
        Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    }

    /// 编译期常量（Info.plist 的 `CWAppGroupIdentifier`）。
    static var compiledGroupIdentifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "CWAppGroupIdentifier") as? String,
              !id.isEmpty else { return nil }
        return id
    }

    /// 按上述顺序解析出的实际 Group id。
    static var resolvedGroupIdentifier: String {
        // AltStore 改写后的 id 含原 id 作为子串（group.<原id>.<TEAMID>），
        // 优先取含本包标识的那一条；都没有时取第一条。
        if let granted = altAppGroups.first(where: { $0.contains("com.coco.cocowall") })
            ?? altAppGroups.first {
            return granted
        }
        if let compiled = compiledGroupIdentifier { return compiled }
        return fallbackGroupIdentifier
    }

    /// 探测状态。`granted` 即手册验证 1 的通过标准：
    /// `containerURL` 非 nil，且能在该目录内创建并读回探针文件；
    /// `ALTAppGroups`（如存在）含预期 group id。
    enum Status: Equatable {
        case notChecked
        case checking
        case granted(groupID: String, containerPath: String, altGroups: [String])
        case denied(groupID: String, reason: String, altGroups: [String])

        /// 诊断日志 / 设置页共用的单行摘要。
        var summaryText: String {
            switch self {
            case .notChecked:
                return "未检测"
            case .checking:
                return "检测中…"
            case .granted(let groupID, let path, _):
                return "已放行（\(groupID)，\(path)）"
            case .denied(let groupID, let reason, _):
                return "未放行（\(groupID)：\(reason)）"
            }
        }
    }

    /// 同步探测：在解析出的 Group id 上调
    /// `containerURL(forSecurityApplicationGroupIdentifier:)`，
    /// 成功则写探针文件并读回校验。调用方应在后台队列执行，
    /// 不要阻塞主线程。探针文件用后即删，不留垃圾。
    static func probe() -> Status {
        let groupID = resolvedGroupIdentifier
        let altGroups = altAppGroups
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            return .denied(
                groupID: groupID,
                reason: "containerURL 返回 nil：未授予 App Group（免费账号可能被侧载工具剥离，见手册 §4）",
                altGroups: altGroups
            )
        }
        let probeURL = containerURL.appendingPathComponent(
            "cocowall-worse-query-probe-\(UUID().uuidString).txt"
        )
        let probeText = "cocowall worse_query probe \(Date().timeIntervalSince1970)"
        do {
            try probeText.write(to: probeURL, atomically: true, encoding: .utf8)
            let readBack = try String(contentsOf: probeURL, encoding: .utf8)
            try? FileManager.default.removeItem(at: probeURL)
            guard readBack == probeText else {
                return .denied(groupID: groupID, reason: "探针文件读回内容不一致", altGroups: altGroups)
            }
            return .granted(groupID: groupID, containerPath: containerURL.path, altGroups: altGroups)
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            return .denied(groupID: groupID, reason: "探针文件写/读失败：\(error.localizedDescription)", altGroups: altGroups)
        }
    }
}

// MARK: - 模块 2：版本与能力探测（路由）

/// 路由判定结果。`route` 是本轮启动的决策；`reason` 是写进诊断
/// 日志与界面的人话原因。探测优先：26.0–27.1 的回退以本次启动的
/// App Group 探测结果为准，不只按版本号硬编码。
struct WorseQueryRouting: Equatable {
    enum Route: Equatable {
        /// 走现有路线（回环 + 配对 + AFC + Books 注入）。
        case legacy
        /// 优先 worse_query，失败回退现有路线（26.0–26.7.2 / 27.0–27.1）。
        case worseQuery
        /// 只走 worse_query，无回退（27.2）。
        case worseQueryOnly
        /// 27.2 但新路线不可用（App Group 未放行，或逃逸触发未实现）：
        /// 界面如实提示暂不支持，不绕进配对流程空转。
        case worseQueryBlocked
        /// 低于 17.0，或 27.3 正式版以后：默认不支持，待评估。
        case unsupported
        /// 27.3 beta：实验性，灰度开关默认关，本版按不支持处理。
        case experimental27_3
    }

    let route: Route
    let reason: String

    /// 是否因新路线不可用而回退到现有路线（26.0–27.1 的
    /// App Group 未放行 / 逃逸未实现两档）。调用方据此在
    /// 刷入日志首行明示回退原因；平时为 false。
    var fellBackFromWorseQuery: Bool = false

    /// 是否要走 worse_query 通道（逃逸触发成功后才真正进入）。
    var usesWorseQuery: Bool { route == .worseQuery || route == .worseQueryOnly }

    /// 界面文案：当前系统走哪条路线、为什么。
    var userMessage: String {
        switch route {
        case .legacy:
            return "当前走现有路线（回环 + 配对刷入）。\(reason)"
        case .worseQuery:
            return "当前走新路线（worse_query）刷入，失败时回退现有路线。"
        case .worseQueryOnly:
            return "当前走新路线（worse_query）刷入（iOS 27.2 仅此通道）。"
        case .worseQueryBlocked:
            return "iOS 27.2 暂不支持刷入：\(reason)"
        case .unsupported:
            return "当前系统暂不支持刷入：\(reason)"
        case .experimental27_3:
            return "iOS 27.3 实验性支持未开启：\(reason)"
        }
    }
}

/// 版本分流（手册 §7）。输入：系统版本字符串 + 本次启动的
/// App Group 探测结果。输出：路由决策。版本范围取自 worse_query
/// README 公开的支持范围（26.0–26.7.2 / 27.2），其余按手册 §7 表。
enum WorseQueryRouter {

    static func route(
        for version: String,
        appGroup: WorseQueryAppGroup.Status,
        escapeImplemented: Bool = WorseQueryEscape.isImplemented
    ) -> WorseQueryRouting {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        let appGroupOK: Bool
        if case .granted = appGroup { appGroupOK = true } else { appGroupOK = false }

        if major < 17 {
            return WorseQueryRouting(route: .unsupported, reason: "低于 iOS 17.0。")
        }
        if major <= 25 {
            return WorseQueryRouting(route: .legacy, reason: "iOS 17.0–25.x 走现有路线。")
        }
        if major == 26 {
            if minor > 7 || (minor == 7 && patch > 2) {
                return WorseQueryRouting(route: .unsupported, reason: "超出已公开支持范围（26.7.2）。")
            }
            return preferredOrLegacy(
                appGroupOK: appGroupOK,
                escapeImplemented: escapeImplemented,
                rangeLabel: "iOS 26.0–26.7.2"
            )
        }
        if major == 27 {
            switch minor {
            case 0, 1:
                return preferredOrLegacy(
                    appGroupOK: appGroupOK,
                    escapeImplemented: escapeImplemented,
                    rangeLabel: "iOS 27.0–27.1"
                )
            case 2:
                guard appGroupOK else {
                    return WorseQueryRouting(
                        route: .worseQueryBlocked,
                        reason: "App Group 未放行（\(appGroup.summaryText)），新路线无可用通道。"
                    )
                }
                guard escapeImplemented else {
                    return WorseQueryRouting(
                        route: .worseQueryBlocked,
                        reason: "逃逸触发未实现（待真机联调），新路线暂不可用。"
                    )
                }
                return WorseQueryRouting(route: .worseQueryOnly, reason: "iOS 27.2 仅走新路线。")
            case 3:
                return WorseQueryRouting(
                    route: .experimental27_3,
                    reason: "27.3 beta 实验性支持灰度默认关，未验证前不开启。"
                )
            default:
                return WorseQueryRouting(route: .unsupported, reason: "iOS 27.3 正式版以后默认不支持，待评估。")
            }
        }
        return WorseQueryRouting(route: .unsupported, reason: "高于 iOS 27 的系统未验证。")
    }

    /// 26.0–26.7.2 / 27.0–27.1 的共用分支：App Group 未放行或逃逸
    /// 未实现时回退现有路线（有回退可走，不判死刑）。
    private static func preferredOrLegacy(
        appGroupOK: Bool,
        escapeImplemented: Bool,
        rangeLabel: String
    ) -> WorseQueryRouting {
        guard appGroupOK else {
            return WorseQueryRouting(
                route: .legacy,
                reason: "\(rangeLabel)：App Group 未放行，回退现有路线。",
                fellBackFromWorseQuery: true
            )
        }
        guard escapeImplemented else {
            return WorseQueryRouting(
                route: .legacy,
                reason: "\(rangeLabel)：逃逸触发未实现，回退现有路线。",
                fellBackFromWorseQuery: true
            )
        }
        return WorseQueryRouting(route: .worseQuery, reason: "\(rangeLabel)：优先新路线。")
    }
}

// MARK: - 模块 3：逃逸触发（自研核心，接口已定、实现待实测）

/// 逃逸触发的结构化错误。三类分开，禁止静默继续写文件：
/// 超时 / 被拒绝 / 无扩展；另加未实现一档。
enum WorseQueryEscapeError: LocalizedError, Equatable {
    /// 实现尚未落地（run #176 现状）：不尝试任何系统调用，直接失败。
    case notImplemented
    case timedOut(seconds: Int)
    case denied(detail: String)
    case noExtension(targetPath: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "逃逸触发未实现（待真机联调填入实测参数）"
        case .timedOut(let seconds):
            return "逃逸触发超时（\(seconds) 秒无响应）"
        case .denied(let detail):
            return "逃逸触发被拒绝：\(detail)"
        case .noExtension(let targetPath):
            return "未拿到目标路径的沙盒扩展：\(targetPath)"
        }
    }
}

/// 逃逸触发：行为目标是向系统容器管理服务发起容器查询，拿到
/// 目标路径的沙盒扩展，使普通文件 API 能访问该路径。
///
/// 未公开、待真机联调实测填（不得编造）：
/// 以下问题在公开行为规格（README、FAQ、手册 §5）里均无答案，
/// 实现者须在真机上逐项实测后才能填，填之前本桩一律返回
/// `.notImplemented`，调用方按失败回退处理：
///   1. 目标服务是哪个（服务名、取用方式）；
///   2. 容器查询的参数长什么样（目标如何描述、分区如何取值）；
///   3. 拿到扩展后如何持有、有效期多久、是否要逐路径申请；
///   4. 超时、重试与失败的实测表现。
/// 实现者隔离：只按本文件与手册 §5 的行为清单写，不要打开
/// 上游源码目录去抄，不要沿用下游给 bad_query 封装起的名字。
enum WorseQueryEscape {

    /// 逃逸触发是否已实现。false 时一切 worse_query 刷入尝试
    /// 都在触发前即失败，不触碰任何系统服务。
    static let isImplemented = false

    /// 触发一次逃逸，目标为待写入的容器路径（如 PosterBoard
    /// 数据容器）。成功后普通文件 API 即可访问该路径。
    /// 本版未实现：直接返回 `.notImplemented`。
    static func trigger(targetPath: String) async -> Result<Void, WorseQueryEscapeError> {
        // run #176：桩。上面列出的四个问题实测清楚之前，
        // 这里不编任何服务名、参数或数值。
        return .failure(.notImplemented)
    }
}

// MARK: - 模块 4 + 5：路径解析与 PosterBoard 容器定位

/// PosterBoard 容器定位（手册 §5 模块 4、5）。
///
/// 目标 App：PosterBoard，bundle id `com.apple.PosterBoard`，
/// 恢复域 `AppDomain-com.apple.PosterBoard`。容器内写入点：
/// `Library/Application Support/PRBPosterExtensionDataStore/61/`
/// `Extensions/<扩展id>/descriptors/`（iOS 17+ 结构版本为 61）。
///
/// 定位顺序：① 复用现有路线已缓存的容器路径（UserDefaults
/// `aircard.posterboard_container`，即 legacy 路线自动检测的结果），
/// 校验存在且为目录即用；② 在逃逸已授予访问权的前提下，枚举
/// `/var/mobile/Containers/Data/Application/*`，读各容器的
/// `.com.apple.mobile_container_manager.metadata.plist`，以
/// `MCMMetadataIdentifier` 匹配 bundle id。定位不到就报错，
/// 不拼猜测路径硬试。首次定位允许慢（参照量级约 30 秒），
/// 调用方应给界面进度提示并缓存结果。
enum WorseQueryPosterBoardLocator {

    static let posterBoardBundleID = "com.apple.PosterBoard"

    /// iOS 应用数据容器根目录（worse_query 公开的可达路径之一）。
    static let applicationContainersRoot = "/var/mobile/Containers/Data/Application"

    /// 容器元数据 plist 的文件名（iOS 容器布局的公开事实）。
    static let containerMetadataFileName = ".com.apple.mobile_container_manager.metadata.plist"

    enum LocateError: LocalizedError, Equatable {
        case cachedPathInvalid(String)
        case rootNotAccessible(String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .cachedPathInvalid(let path):
                return "已缓存的 PosterBoard 容器路径无效：\(path)"
            case .rootNotAccessible(let path):
                return "应用容器根目录不可访问（逃逸未授予访问权？）：\(path)"
            case .notFound:
                return "未找到 PosterBoard 数据容器（com.apple.PosterBoard）"
            }
        }
    }

    /// 定位 PosterBoard 数据容器，返回其根路径。
    /// 调用前必须已触发逃逸（模块 3）；否则枚举必然失败。
    static func locate(cachedContainer: String?) -> Result<String, LocateError> {
        let fm = FileManager.default
        // ① 已缓存路径：存在且为目录即用。
        if let cached = cachedContainer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: cached, isDirectory: &isDir), isDir.boolValue {
                return .success(cached)
            }
            // 缓存失效不直接判死刑，继续走枚举；枚举也失败时
            // 返回 notFound，由调用方记诊断。
        }
        // ② 枚举应用数据容器，按元数据匹配 bundle id。
        guard let entries = try? fm.contentsOfDirectory(atPath: applicationContainersRoot) else {
            return .failure(.rootNotAccessible(applicationContainersRoot))
        }
        for entry in entries {
            let containerPath = (applicationContainersRoot as NSString).appendingPathComponent(entry)
            let metadataPath = (containerPath as NSString).appendingPathComponent(containerMetadataFileName)
            guard let plist = NSDictionary(contentsOfFile: metadataPath),
                  let identifier = plist["MCMMetadataIdentifier"] as? String,
                  identifier == posterBoardBundleID else { continue }
            return .success(containerPath)
        }
        return .failure(.notFound)
    }

    /// 描述符目录：`…/PRBPosterExtensionDataStore/<版本>/Extensions/<扩展id>/descriptors/`。
    /// 结构版本与现有路线一致：iOS 17+ 为 61，16 为 59。
    static func descriptorsDirectory(
        containerPath: String,
        structVersion: Int,
        extensionID: String
    ) -> String {
        "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(structVersion)/Extensions/\(extensionID)/descriptors"
    }
}

// MARK: - 模块 8：失败回退与结构化诊断（本文件的部分）

/// worse_query 路线的诊断行：拼进 AppViewModel 现有的诊断日志
///（`recordDiagnostics` / `currentDiagnosticsSnapshot`），与
/// 回环、配对状态同款格式。任一环节失败都先记一笔再回退。
enum WorseQueryDiagnostics {

    /// 两行摘要：App Group 状态 + 路由决策。
    static func summaryLines(
        appGroupStatus: WorseQueryAppGroup.Status,
        routing: WorseQueryRouting
    ) -> [String] {
        [
            "App Group：\(appGroupStatus.summaryText)",
            "新路线：\(routing.userMessage)",
        ]
    }
}

//
//  ClownfishRewriter.swift
//  CocoWall
//
//  iOS 27 旧包 Clownfish 重写（run #175；设计合约见
//  ~/workspace/cocowall-release/contract-clownfish-rewrite.md）。
//
//  参考行为：GoldenNugget 的 legacy-convert（导入旧 .tendies 时，
//  iOS 27+ 上把包重写成现代 Clownfish 布局，好让景深效果出来）。
//  许可硬线：GoldenNugget 是 AGPL-3.0，代码不能搬进闭源 CocoWall——
//  本文件是按行为描述用 Swift 重新实现的（clean-room），只复用
//  PosterKit 格式本身的事实（两个深度配置 plist 的固定结构、
//  平面角色与命名规则），不抄任何 GoldenNugget 代码。
//  两个深度配置 plist 是固定内容（depthEffectDisabled = false），
//  以 base64 常量内嵌，直接写出，不经过 NSKeyedArchiver。
//
//  行为总览（与合约 §3 一致）：
//  · 判定：描述符有壁纸平面、但没有任何一个平面的 index.xml 含
//    publishedObjectNames → 旧包；Mercury 包直接跳过；已现代的包不动。
//  · 转换（每描述符）：发布各平面根图层（id 改角色名、targetId 跟指、
//    像素画布 fit 缩放）→ 删外部 <scriptObject> → 危险 CAML（LKState
//    增删元素 / CAMeshTransform）拍平成静态图 → 缺 Foreground 补空
//    平面 → 纯色背景补实图 → Wallpaper.plist 改 family=Clownfish 并
//    补深度键 → 写两个深度配置 plist → index.xml 按现代模板重写 →
//    包与平面改名成 stock Clownfish 形状。
//  · 已现代的包也过一遍安全处理：只删脚本 / 拍平危险 CAML，不改
//    family 与发布状态。
//  · 纯文件 I/O，不碰网络、不改注入机制；调用方（刷入流程）在
//    解压后、标识重写（rewriteDescriptorIdentifiers）之前调用——
//    转换先用原 assetId 改名，标识重写再把整套名字换成新 base，
//    两步衔接、最终一致。
//

import Foundation
import UIKit

public enum ClownfishRewriter {

    // MARK: - 常量

    public static let clownfishFamily = "Clownfish"
    public static let mercuryProvider = "com.apple.MercuryPoster"
    public static let mercuryFamily = "Mercury"

    /// 两个深度配置 plist 的文件名（PosterKit 读它们决定是否允许景深）。
    public static let configurableOptionsName = ".com.apple.posterkit.provider.contents.configurableOptions.plist"
    public static let renderingConfigurationName = "com.apple.posterkit.provider.instance.renderingConfiguration.plist"

    public static let modernContentVersion = 1.01
    public static let defaultMaxAdaptiveTimeMultiplier = 2.0

    /// 深度开启的 PRPosterConfigurableOptions（NSKeyedArchiver 二进制 plist，
    /// 912 字节）。固定内容：preferredRenderingConfiguration 的
    /// depthEffectDisabled / motionEffectsDisabled 均为 false，role 为
    /// PRPosterRoleLockScreen。
    private static let configurableOptionsB64 =
        "YnBsaXN0MDDUAQIDBAUGP0JZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tl" +
        "eWVkQXJjaGl2ZXKsBwgbHCAmJxMxNDk8VSRudWxs2QkKCwwNDg8QERITFBUWFxgZGlYkY2xhc3Nf" +
        "EBphbWJpZW50U3VwcG9ydGVkRGF0YUxheW91dF8QGmRpc3BsYXlOYW1lTG9jYWxpemF0aW9uS2V5" +
        "WWx1bWluYW5jZV8QIHByZWZlcnJlZEhvbWVTY3JlZW5Db25maWd1cmF0aW9uXxAfcHJlZmVycmVk" +
        "UmVuZGVyaW5nQ29uZmlndXJhdGlvbl8QH3ByZWZlcnJlZFRpbWVGb250Q29uZmlndXJhdGlvbnNf" +
        "EBRwcmVmZXJyZWRUaXRsZUNvbG9yc1Ryb2xlgAsQAIAAgAWABoAJgAOAA4ACXxAWUFJQb3N0ZXJS" +
        "b2xlTG9ja1NjcmVlbtIJHR4fWk5TLm9iamVjdHOABKDSISIjJFgkY2xhc3Nlc1okY2xhc3NuYW1l" +
        "oiQlV05TQXJyYXlYTlNPYmplY3QjP+AAAAAAAADVCSgpKissLS4vMF8QHWFsbG93c01vZGlmeWlu" +
        "Z0xlZ2liaWxpdHlCbHVyXxAXcHJlZmVycmVkR3JhZGllbnRDb2xvcnNfEBRwcmVmZXJyZWRTb2xp" +
        "ZENvbG9yc15wcmVmZXJyZWRTdHlsZYAICYAAgACAB9IhIjIzojMlXxApUFJQb3N0ZXJEZXNjcmlw" +
        "dG9ySG9tZVNjcmVlbkNvbmZpZ3VyYXRpb27TCTU2Nzg4XxATZGVwdGhFZmZlY3REaXNhYmxlZF8Q" +
        "FW1vdGlvbkVmZmVjdHNEaXNhYmxlZIAKCNIhIjo7ojslXxAeUFJQb3N0ZXJSZW5kZXJpbmdDb25m" +
        "aWd1cmF0aW9u0iEiPT6iPiVfEBtQUlBvc3RlckNvbmZpZ3VyYWJsZU9wdGlvbnPRQEFUcm9vdIAB" +
        "EgABhqAACAARABsAJAApADIARABRAFcAagBxAI4AqwC1ANgA+gEcATMBOAE6ATwBPgFAAUIBRAFG" +
        "AUgBSgFjAWgBcwF1AXYBewGEAY8BkgGaAaMBrAG3AdcB8QIIAhcCGQIaAhwCHgIgAiUCKAJUAlsC" +
        "cQKJAosCjAKRApQCtQK6Ar0C2wLeAuMC5QAAAAAAAAIBAAAAAAAAAEMAAAAAAAAAAAAAAAAAAALq"

    /// 深度开启的 PRPosterRenderingConfiguration（NSKeyedArchiver 二进制 plist，
    /// 282 字节）。固定内容：depthEffectDisabled / motionEffectsDisabled 均为 false。
    private static let renderingConfigurationB64 =
        "YnBsaXN0MDDUAQIDBAUGFBdZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tl" +
        "eWVkQXJjaGl2ZXKjBwgOVSRudWxs0wkKCwwNDVYkY2xhc3NfEBNkZXB0aEVmZmVjdERpc2FibGVk" +
        "XxAVbW90aW9uRWZmZWN0c0Rpc2FibGVkgAII0g8QERJYJGNsYXNzZXNaJGNsYXNzbmFtZaISE18Q" +
        "HlBSUG9zdGVyUmVuZGVyaW5nQ29uZmlndXJhdGlvblhOU09iamVjdNEVFlRyb290gAESAAGGoAgR" +
        "GyQpMkRITlVccoqMjZKbpqnK09bb3QAAAAAAAAEBAAAAAAAAABgAAAAAAAAAAAAAAAAAAADi"

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]

    // MARK: - 结果

    public struct ConversionSummary {
        public let descriptor: String
        public let wallpaper: String
        public let screen: String
        public let planes: [String]
        public let flattened: Bool
        public let failed: String?
    }

    public struct RenameSummary {
        public let descriptor: String
        public let wallpaper: String
        public let planes: [String]
    }

    public enum ClownfishError: Error {
        case noWallpaperFolder(String)
        case noMainCaml(String)
        case noRootLayer(String)
        case unreadablePlist(String)
    }

    // MARK: - 判定（公开，供导入时检测与刷入时复核）

    /// 树里全部旧包的 family（去重、按包排序）。直接读解压后的树，
    /// 不读 zip。旧包 = 有壁纸平面、但没有任何一个平面已发布
    /// （index.xml 含 publishedObjectNames）。
    public static func legacyFamilies(in rootURL: URL) -> [String] {
        var families: [String] = []
        for descriptor in iterDescriptorDirs(at: rootURL) {
            // Mercury 包布局完全不同，绝不能重写成 Clownfish 形状，
            // 也不应触发转换提示。
            guard !isMercuryDescriptor(at: descriptor) else { continue }
            guard isLegacyDescriptor(at: descriptor) else { continue }
            let family = wallpaperFamily(of: descriptor) ?? ""
            families.append(family.isEmpty ? descriptor.lastPathComponent : family)
        }
        return families
    }

    /// 描述符是否旧包：有壁纸平面、但没有任何一个平面已发布。
    public static func isLegacyDescriptor(at descriptorURL: URL) -> Bool {
        guard let wallpaperDir = findWallpaperDir(in: descriptorURL) else { return false }
        let planes = planeDirs(in: wallpaperDir)
        guard !planes.isEmpty else { return false }
        return !planes.contains(where: { isModernPlane(at: $0) })
    }

    /// 是否 Mercury（空间照片）包：路径含 Mercury provider 或 family 为 Mercury。
    /// 布局完全不同，绝不能重写成 Clownfish 形状。
    public static func isMercuryDescriptor(at descriptorURL: URL) -> Bool {
        if descriptorURL.path.contains(mercuryProvider) { return true }
        guard let family = wallpaperFamily(of: descriptorURL) else { return false }
        return family.lowercased() == mercuryFamily.lowercased()
    }

    /// 已现代的描述符是否仍需安全处理（带危险 CAML 状态操作或外部脚本）。
    public static func descriptorNeedsSanitize(at descriptorURL: URL) -> Bool {
        guard let wallpaperDir = findWallpaperDir(in: descriptorURL) else { return false }
        return planeDirs(in: wallpaperDir).contains { plane in
            guard planeRole(folderName: plane.lastPathComponent) != nil else { return false }
            return planeHasUnsupportedCaml(at: plane) || planeHasExternalScript(at: plane)
        }
    }

    /// 目标 iOS 版本是否支持重写（仅 iOS 27+）。
    public static func isConversionSupported(majorVersion: Int) -> Bool {
        majorVersion >= 27
    }

    // MARK: - 转换入口

    /// 转换树下全部旧描述符（原地改）；已现代但带危险 CAML/脚本的
    /// 描述符只做安全处理（删脚本 / 拍平危险平面）。每个描述符独立
    /// 记结果，单个失败不中断其余描述符。
    public static func convertTree(
        at rootURL: URL,
        screen: (width: Double, height: Double, scale: Int)? = nil
    ) -> [ConversionSummary] {
        var results: [ConversionSummary] = []
        for descriptor in iterDescriptorDirs(at: rootURL) {
            // Mercury 包绝不重写（布局完全不同，重写会毁掉它）。
            guard !isMercuryDescriptor(at: descriptor) else { continue }
            if !isLegacyDescriptor(at: descriptor) {
                guard descriptorNeedsSanitize(at: descriptor) else { continue }
                let written = flattenUnsupportedPlanes(in: descriptor)
                if !written.isEmpty {
                    results.append(ConversionSummary(
                        descriptor: descriptor.lastPathComponent,
                        wallpaper: findWallpaperDir(in: descriptor)?.lastPathComponent ?? "",
                        screen: "",
                        planes: written.map { $0.deletingLastPathComponent().lastPathComponent },
                        flattened: true,
                        failed: nil
                    ))
                }
                continue
            }
            do {
                let summary = try convertDescriptor(at: descriptor, screen: screen)
                results.append(summary)
            } catch {
                results.append(ConversionSummary(
                    descriptor: descriptor.lastPathComponent,
                    wallpaper: findWallpaperDir(in: descriptor)?.lastPathComponent ?? "",
                    screen: "",
                    planes: [],
                    flattened: false,
                    failed: error.localizedDescription
                ))
            }
        }
        return results
    }

    /// 把树下全部已是 Clownfish family 的包按 stock 形状改名
    /// （<assetId>.Clownfish-<逻辑屏类>.wallpaper 与
    /// <assetId>.Clownfish_<角色>-<逻辑屏类>.ca）。必须在 convertTree
    /// 之后跑（名字从改完的 Wallpaper.plist 里取）。
    public static func renameDescriptorsToSkeleton(at rootURL: URL) -> [RenameSummary] {
        var results: [RenameSummary] = []
        for descriptor in iterDescriptorDirs(at: rootURL) {
            guard let wallpaperDir = findWallpaperDir(in: descriptor) else { continue }
            guard let data = readPlist(at: wallpaperDir.appendingPathComponent("Wallpaper.plist")),
                  let family = data["family"] as? String,
                  family.lowercased() == clownfishFamily.lowercased() else { continue }
            let (newDir, _) = renameToSkeletonShape(wallpaperDir: wallpaperDir, data: data)
            results.append(RenameSummary(
                descriptor: descriptor.lastPathComponent,
                wallpaper: newDir.lastPathComponent,
                planes: planeDirs(in: newDir).compactMap { planeRole(folderName: $0.lastPathComponent) }
            ))
        }
        return results
    }

    // MARK: - 单个描述符转换

    static func convertDescriptor(
        at descriptorURL: URL,
        screen: (width: Double, height: Double, scale: Int)? = nil
    ) throws -> ConversionSummary {
        guard let wallpaperDir = findWallpaperDir(in: descriptorURL) else {
            throw ClownfishError.noWallpaperFolder(descriptorURL.path)
        }
        guard let plistData = readPlist(at: wallpaperDir.appendingPathComponent("Wallpaper.plist")) else {
            throw ClownfishError.unreadablePlist(wallpaperDir.appendingPathComponent("Wallpaper.plist").path)
        }
        let docWidth: Double
        let docHeight: Double
        let pixelScale: Int
        if let screen = screen {
            (docWidth, docHeight, pixelScale) = screen
        } else if let parsed = parseLogicalScreenClass(plistData["logicalScreenClass"] as? String) {
            (docWidth, docHeight, pixelScale) = parsed
        } else {
            (docWidth, docHeight, pixelScale) = (390, 844, 3)
        }

        var convertedPlanes: [String] = []
        for planeDir in planeDirs(in: wallpaperDir) {
            guard let role = planeRole(folderName: planeDir.lastPathComponent) else { continue }
            try modernizePlane(at: planeDir, role: role, docWidth: docWidth, docHeight: docHeight,
                               logicalWidth: Int(docWidth), pixelScale: pixelScale)
            convertedPlanes.append(role)
        }

        // 先合成前景平面（缺时新建），再看 foreground.ca 是否存在——
        // 与参考实现同序：合成后才把 Foreground 记进已转平面。
        synthesizeForegroundPlane(in: wallpaperDir, docWidth: docWidth, docHeight: docHeight, pixelScale: pixelScale)
        if !convertedPlanes.contains("Foreground"),
           FileManager.default.fileExists(atPath: wallpaperDir.appendingPathComponent("foreground.ca").path) {
            convertedPlanes.append("Foreground")
        }

        try modernizeWallpaperPlist(at: wallpaperDir)
        try writeDepthConfigs(wallpaperDir: wallpaperDir)

        return ConversionSummary(
            descriptor: descriptorURL.lastPathComponent,
            wallpaper: wallpaperDir.lastPathComponent,
            screen: "\(Int(docWidth))x\(Int(docHeight))@\(pixelScale)x",
            planes: convertedPlanes,
            flattened: false,
            failed: nil
        )
    }

    // MARK: - 平面

    /// 文件夹名 → 角色（Background / Floating / Foreground）。
    static func planeRole(folderName: String) -> String? {
        var name = folderName.lowercased()
        if name.hasSuffix(".ca") { name = String(name.dropLast(3)) }
        let tokens = name.split { !$0.isLetter }.map(String.init)
        if tokens.contains("foreground") || tokens.contains("fg") { return "Foreground" }
        if tokens.contains("floating") || tokens.contains("fl") { return "Floating" }
        if tokens.contains("background") || tokens.contains("bg") { return "Background" }
        return nil
    }

    /// `"390w-844h@3x~iphone"` → (390, 844, 3)，解析失败返回 nil。
    static func parseLogicalScreenClass(_ value: String?) -> (Double, Double, Int)? {
        guard let value = value else { return nil }
        guard let match = firstMatch(pattern: #"^(\d+)w-(\d+)h@(\d+)x"#, in: value),
              match.count == 4,
              let w = Double(match[1]), let h = Double(match[2]), let s = Int(match[3]) else { return nil }
        return (w, h, s)
    }

    static func isModernPlane(at planeDir: URL) -> Bool {
        guard let index = readPlist(at: planeDir.appendingPathComponent("index.xml")) else { return false }
        return index["publishedObjectNames"] != nil
    }

    static func wallpaperFamily(of descriptorURL: URL) -> String? {
        guard let wallpaperDir = findWallpaperDir(in: descriptorURL),
              let data = readPlist(at: wallpaperDir.appendingPathComponent("Wallpaper.plist")),
              let family = data["family"] as? String else { return nil }
        return family
    }

    static func planeHasUnsupportedCaml(at planeDir: URL) -> Bool {
        guard let text = readText(at: planeDir.appendingPathComponent("main.caml")) else { return false }
        return hasUnsupportedCaml(text)
    }

    static func planeHasExternalScript(at planeDir: URL) -> Bool {
        guard let text = readText(at: planeDir.appendingPathComponent("main.caml")) else { return false }
        return hasExternalScript(text)
    }

    /// 每个平面：去脚本 → 危险 CAML 拍平 / 否则发布根图层 → 纯色背景
    /// 补实图 → index.xml 按现代模板重写 → 缺 assetManifest 补空的。
    static func modernizePlane(
        at planeDir: URL,
        role: String,
        docWidth: Double,
        docHeight: Double,
        logicalWidth: Int,
        pixelScale: Int
    ) throws {
        let index = readPlist(at: planeDir.appendingPathComponent("index.xml")) ?? [:]
        let unitsInPixels = planeUnits(index: index, logicalWidth: logicalWidth)
        let mainCamlURL = planeDir.appendingPathComponent("main.caml")
        guard FileManager.default.fileExists(atPath: mainCamlURL.path) else {
            throw ClownfishError.noMainCaml(planeDir.path)
        }
        var text = stripScripts(readText(at: mainCamlURL) ?? "")
        if hasUnsupportedCaml(text) {
            text = flattenPlane(role: role, planeDir: planeDir, width: docWidth, height: docHeight)
        } else {
            text = try modernizeMainCaml(text, role: role, docWidth: docWidth, docHeight: docHeight,
                                          unitsInPixels: unitsInPixels, pixelScale: pixelScale)
        }
        try writeText(text, to: mainCamlURL)
        ensureBackgroundImage(at: planeDir, role: role, docWidth: docWidth, docHeight: docHeight)
        try writeText(modernIndexXML(docWidth: docWidth, docHeight: docHeight, role: role),
                      to: planeDir.appendingPathComponent("index.xml"))
        let manifestURL = planeDir.appendingPathComponent("assetManifest.caml")
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            try writeText(emptyMicaAssetManifest, to: manifestURL)
        }
    }

    /// 已现代描述符的安全处理：每个平面去脚本、危险 CAML 拍平。
    /// 返回被重写的 main.caml 路径（空 = 包本来就安全）。
    static func flattenUnsupportedPlanes(in descriptorURL: URL) -> [URL] {
        guard let wallpaperDir = findWallpaperDir(in: descriptorURL) else { return [] }
        let parsed = parseLogicalScreenClass(
            (readPlist(at: wallpaperDir.appendingPathComponent("Wallpaper.plist")) ?? [:])["logicalScreenClass"] as? String)
        let (width, height, _) = parsed ?? (393, 852, 3)
        var written: [URL] = []
        for planeDir in planeDirs(in: wallpaperDir) {
            guard let role = planeRole(folderName: planeDir.lastPathComponent) else { continue }
            let mainCamlURL = planeDir.appendingPathComponent("main.caml")
            guard FileManager.default.fileExists(atPath: mainCamlURL.path),
                  let original = readText(at: mainCamlURL) else { continue }
            let stripped = stripScripts(original)
            if hasUnsupportedCaml(stripped) {
                let flat = flattenPlane(role: role, planeDir: planeDir, width: width, height: height)
                try? writeText(flat, to: mainCamlURL)
                written.append(mainCamlURL)
            } else if stripped != original {
                try? writeText(stripped, to: mainCamlURL)
                written.append(mainCamlURL)
            }
        }
        return written
    }

    /// 平面是否像素画布：index.xml 的 unitsInPixelsInPlayer 为准；
    /// 缺省时 documentWidth 明显大于逻辑宽即像素画布，否则按点算。
    /// （点画布误判成像素画布会把图放大 3 倍，见合约。）
    static func planeUnits(index: [String: Any], logicalWidth: Int) -> Bool {
        if let value = index["unitsInPixelsInPlayer"] as? Bool { return value }
        if let docWidth = (index["documentWidth"] as? NSNumber)?.doubleValue, logicalWidth > 0 {
            return docWidth > Double(logicalWidth) + 1.0
        }
        return false
    }

    /// 发布平面根图层：根 CALayer 的 id 改成角色名，内部 targetId 跟指，
    /// name 与 position 不动；像素画布才加 fit 缩放。
    static func modernizeMainCaml(
        _ text: String,
        role: String,
        docWidth: Double,
        docHeight: Double,
        unitsInPixels: Bool,
        pixelScale: Int
    ) throws -> String {
        guard let tagRange = firstTagRange(pattern: #"<CALayer\b[^>]*>"#, in: text) else {
            throw ClownfishError.noRootLayer("main.caml has no root CALayer")
        }
        var tag = String(text[tagRange])
        let oldId = xmlAttr(tag, name: "id")
        tag = setXmlAttr(tag, name: "id", value: role)
        tag = addScale(tag, scale: fitScale(tag: tag, docWidth: docWidth, docHeight: docHeight,
                                            unitsInPixels: unitsInPixels, pixelScale: pixelScale))
        var out = text.replacingCharacters(in: tagRange, with: tag)
        if let oldId = oldId, oldId != role {
            out = out.replacingOccurrences(of: "targetId=\"\(oldId)\"", with: "targetId=\"\(role)\"")
        }
        return out
    }

    static func fitScale(tag: String, docWidth: Double, docHeight: Double,
                         unitsInPixels: Bool, pixelScale: Int) -> Double {
        guard unitsInPixels else { return 1.0 }
        var oldWidth = docWidth
        var oldHeight = docHeight
        if let bounds = xmlAttr(tag, name: "bounds") {
            let parts = bounds.split(separator: " ")
            if parts.count >= 4 {
                oldWidth = Double(parts[2]) ?? docWidth
                oldHeight = Double(parts[3]) ?? docHeight
            }
        }
        let divisor = pixelScale > 0 ? Double(pixelScale) : 1.0
        let pointWidth = oldWidth / divisor
        let pointHeight = oldHeight / divisor
        guard pointWidth > 0, pointHeight > 0 else { return 1.0 }
        return max(docWidth / pointWidth, docHeight / pointHeight)
    }

    static func addScale(_ tag: String, scale: Double) -> String {
        guard abs(scale - 1.0) > 1e-6 else { return tag }
        let oldTransform = (xmlAttr(tag, name: "transform") ?? "").trimmingCharacters(in: .whitespaces)
        let prefix = oldTransform.isEmpty ? "" : oldTransform + " "
        let newTransform = prefix + String(format: "scale(%.6f, %.6f, 1)",
                                            locale: Locale(identifier: "en_US_POSIX"), scale, scale)
        return setXmlAttr(tag, name: "transform", value: newTransform)
    }

    /// 危险 CAML 的平面拍平成单张静态图（取平面 assets 里最大的图；
    /// 没图则为空平面）。
    static func flattenPlane(role: String, planeDir: URL, width: Double, height: Double) -> String {
        if let image = pickPlaneImage(in: planeDir) {
            return flatPlaneCaml(role: role, image: image, width: width, height: height)
        }
        return emptyPlaneCaml(role: role, width: width, height: height)
    }

    static func pickPlaneImage(in planeDir: URL) -> String? {
        let assets = planeDir.appendingPathComponent("assets")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: assets.path) else { return nil }
        var best: (size: Int, name: String)? = nil
        for name in names {
            guard imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let url = assets.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            if best == nil || size > best!.size { best = (size, name) }
        }
        return best?.name
    }

    /// 纯色平面补实图：纯色填的平面没有 <contents> 图片，深度渲染器
    /// 会强制解包背景图而崩溃；把纯色渲染成 PNG 塞进 assets 并注入。
    static func ensureBackgroundImage(at planeDir: URL, role: String, docWidth: Double, docHeight: Double) {
        let mainCamlURL = planeDir.appendingPathComponent("main.caml")
        guard FileManager.default.fileExists(atPath: mainCamlURL.path),
              let text = readText(at: mainCamlURL),
              !text.contains("<contents"),
              let color = solidBackgroundColor(text) else { return }
        let image = "solid_\(role.lowercased()).png"
        let assets = planeDir.appendingPathComponent("assets")
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let size = CGSize(width: max(1, Int(docWidth.rounded())), height: max(1, Int(docHeight.rounded())))
        let renderer = UIGraphicsImageRenderer(size: size)
        let png = renderer.pngData { ctx in
            ctx.cgContext.setFillColor(UIColor(red: CGFloat(color.0) / 255.0,
                                               green: CGFloat(color.1) / 255.0,
                                               blue: CGFloat(color.2) / 255.0, alpha: 1.0).cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))
        }
        try? png.write(to: assets.appendingPathComponent(image))
        guard let injected = injectContents(text, image: image), injected != text else { return }
        try? writeText(injected, to: mainCamlURL)
    }

    /// 平面 CAML 里最上层的不透明纯色（子层 backgroundColor 属性优先
    /// 于根的 <backgroundColor> 元素；文档顺序靠后的在视觉上层）。
    static func solidBackgroundColor(_ text: String) -> (Int, Int, Int)? {
        var last: (Int, Int, Int)? = nil
        for m in allMatches(pattern: #"backgroundColor="([^"]+)""#, in: text) where m.count == 2 {
            if let rgb = rgbFromComponents(m[1]) { last = rgb }
        }
        for m in allMatches(pattern: #"<backgroundColor\b[^>]*\bvalue="([^"]+)""#, in: text) where m.count == 2 {
            if let rgb = rgbFromComponents(m[1]) { last = rgb }
        }
        return last
    }

    static func rgbFromComponents(_ value: String) -> (Int, Int, Int)? {
        let parts = value.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        var channels: [Int] = []
        for part in parts.prefix(3) {
            guard let v = Double(part) else { return nil }
            channels.append(Int((max(0.0, min(1.0, v)) * 255.0).rounded()))
        }
        return (channels[0], channels[1], channels[2])
    }

    /// 给最后一个自闭合 <CALayer/> 注入实图 contents，CAML 其余部分不动。
    static func injectContents(_ text: String, image: String) -> String? {
        guard let range = lastTagRange(pattern: #"<CALayer\b[^>]*/>"#, in: text) else { return nil }
        let tag = String(text[range])
        let head = String(tag.dropLast(2))
        let injected = head + "><contents type=\"CGImage\" src=\"assets/\(xmlEscape(image))\"/></CALayer>"
        return text.replacingCharacters(in: range, with: injected)
    }

    // MARK: - Wallpaper.plist 与深度配置

    /// Wallpaper.plist 改现代键：family 改 Clownfish；contentVersion /
    /// disableAdaptiveTime / maximumAdaptiveTimeMultiplier 只在缺失时补；
    /// assets.lockAndHome.default.type 缺失时补 LayeredAnimation；平面
    /// 文件名键指向真实平面文件夹。name 不动。
    static func modernizeWallpaperPlist(at wallpaperDir: URL) throws {
        let path = wallpaperDir.appendingPathComponent("Wallpaper.plist")
        guard var data = readPlist(at: path) else {
            throw ClownfishError.unreadablePlist(path.path)
        }
        data["family"] = clownfishFamily
        if data["contentVersion"] == nil { data["contentVersion"] = modernContentVersion }
        if data["disableAdaptiveTime"] == nil { data["disableAdaptiveTime"] = true }
        if data["maximumAdaptiveTimeMultiplier"] == nil {
            data["maximumAdaptiveTimeMultiplier"] = defaultMaxAdaptiveTimeMultiplier
        }

        var assets = (data["assets"] as? [String: Any]) ?? [:]
        var lockAndHome = (assets["lockAndHome"] as? [String: Any]) ?? [:]
        var def = (lockAndHome["default"] as? [String: Any]) ?? [:]
        if def["type"] == nil { def["type"] = "LayeredAnimation" }

        var planes: [String: String] = [:]
        for planeDir in planeDirs(in: wallpaperDir) {
            if let role = planeRole(folderName: planeDir.lastPathComponent) {
                planes[role] = planeDir.lastPathComponent
            }
        }
        let keys: [String: (primary: String, alternate: String)] = [
            "Background": ("backgroundAnimationFileName", "backgroundAnimationFileNameKey"),
            "Floating": ("floatingAnimationFileNameKey", "floatingAnimationFileName"),
            "Foreground": ("foregroundAnimationFileName", "foregroundAnimationFileNameKey"),
        ]
        for (role, pair) in keys {
            if let folder = planes[role] {
                def[pair.primary] = folder
                let altValue = def[pair.alternate]
                if altValue == nil || (altValue as? String) == "" {
                    def.removeValue(forKey: pair.alternate)
                }
            } else {
                def.removeValue(forKey: pair.primary)
                def.removeValue(forKey: pair.alternate)
            }
        }
        lockAndHome["default"] = def
        assets["lockAndHome"] = lockAndHome
        data["assets"] = assets

        let out = try PropertyListSerialization.data(fromPropertyList: data, format: .binary, options: 0)
        try out.write(to: path)
    }

    /// 写两个 PosterKit 深度配置 plist（固定内容，base64 常量解出直接写）。
    /// configurableOptions 在版本 contents 文件夹里，renderingConfiguration
    /// 在版本文件夹里；两者 depthEffectDisabled 均为 false。
    static func writeDepthConfigs(wallpaperDir: URL) throws {
        let contentsDir = wallpaperDir.deletingLastPathComponent()
        let versionDir = contentsDir.deletingLastPathComponent()
        guard let optionsData = Data(base64Encoded: configurableOptionsB64),
              let renderingData = Data(base64Encoded: renderingConfigurationB64) else { return }
        try optionsData.write(to: contentsDir.appendingPathComponent(configurableOptionsName))
        try renderingData.write(to: versionDir.appendingPathComponent(renderingConfigurationName))
    }

    /// 缺 Foreground 平面时合成一个空透明已发布平面。Clownfish 深度
    /// 渲染器会建第三个平面；只有 Background+Floating 的包被标成
    /// Clownfish 后，渲染器拿不到前景视图会崩溃。
    static func synthesizeForegroundPlane(in wallpaperDir: URL, docWidth: Double, docHeight: Double, pixelScale: Int) {
        let planes = planeDirs(in: wallpaperDir)
        if planes.contains(where: { planeRole(folderName: $0.lastPathComponent) == "Foreground" }) { return }
        let dest = wallpaperDir.appendingPathComponent("foreground.ca")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try? writeText(emptyPlaneCaml(role: "Foreground", width: docWidth, height: docHeight),
                       to: dest.appendingPathComponent("main.caml"))
        try? writeText(modernIndexXML(docWidth: docWidth, docHeight: docHeight, role: "Foreground"),
                       to: dest.appendingPathComponent("index.xml"))
        try? writeText(emptyMicaAssetManifest, to: dest.appendingPathComponent("assetManifest.caml"))
    }

    // MARK: - 改名成 stock Clownfish 形状

    /// 包与平面按 stock 命名：<assetId>.Clownfish-<逻辑屏类>.wallpaper 与
    /// <assetId>.Clownfish_<角色>-<逻辑屏类>.ca。WallpaperKit 也靠磁盘名
    /// 认平面，原名留着会建不出锁屏视图而崩溃。assetId 取
    /// assets.lockAndHome.<variant>.identifier（优先 default），没有则取
    /// 顶层 identifier；取不到或 logicalScreenClass 为空则原样不动。
    static func skeletonNames(data: [String: Any]) -> (bundle: String, planes: [String: String])? {
        let assets = (data["assets"] as? [String: Any])?["lockAndHome"] as? [String: Any] ?? [:]
        let variant = (assets["default"] as? [String: Any])
            ?? assets.values.compactMap({ $0 as? [String: Any] }).first ?? [:]
        var assetId: String? = nil
        if let n = variant["identifier"] as? NSNumber { assetId = "\(n.intValue)" }
        else if let s = variant["identifier"] as? String { assetId = s }
        if assetId == nil {
            if let n = data["identifier"] as? NSNumber { assetId = "\(n.intValue)" }
            else if let s = data["identifier"] as? String { assetId = s }
        }
        let logicalClass = (data["logicalScreenClass"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let assetId = assetId, !logicalClass.isEmpty else { return nil }
        let bundle = "\(assetId).\(clownfishFamily)-\(logicalClass).wallpaper"
        var planes: [String: String] = [:]
        for role in ["Background", "Floating", "Foreground"] {
            planes[role] = "\(assetId).\(clownfishFamily)_\(role)-\(logicalClass).ca"
        }
        return (bundle, planes)
    }

    static func renameToSkeletonShape(wallpaperDir: URL, data: [String: Any]) -> (URL, [String: String]) {
        guard let names = skeletonNames(data: data) else { return (wallpaperDir, [:]) }
        var wallpaperDir = wallpaperDir
        for planeDir in planeDirs(in: wallpaperDir) {
            guard let role = planeRole(folderName: planeDir.lastPathComponent),
                  let targetName = names.planes[role] else { continue }
            let target = wallpaperDir.appendingPathComponent(targetName)
            if target.standardizedFileURL.path != planeDir.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.moveItem(at: planeDir, to: target)
            }
        }
        let contentsDir = wallpaperDir.deletingLastPathComponent()
        let newDir = contentsDir.appendingPathComponent(names.bundle)
        if newDir.standardizedFileURL.path != wallpaperDir.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: newDir)
            try? FileManager.default.moveItem(at: wallpaperDir, to: newDir)
            wallpaperDir = newDir
        }

        let planeKeys: [String: String] = [
            "backgroundAnimationFileName": "Background",
            "backgroundAnimationFileNameKey": "Background",
            "foregroundAnimationFileName": "Foreground",
            "foregroundAnimationFileNameKey": "Foreground",
            "floatingAnimationFileName": "Floating",
            "floatingAnimationFileNameKey": "Floating",
        ]
        let wpPath = wallpaperDir.appendingPathComponent("Wallpaper.plist")
        if var wp = readPlist(at: wpPath) {
            var changed = false
            if var assets = wp["assets"] as? [String: Any] {
                for (groupKey, groupValue) in assets {
                    guard var group = groupValue as? [String: Any] else { continue }
                    for (variantKey, variantValue) in group {
                        guard var variant = variantValue as? [String: Any] else { continue }
                        for (key, role) in planeKeys {
                            if let targetName = names.planes[role],
                               let current = variant[key] as? String, current != targetName {
                                variant[key] = targetName
                                changed = true
                            }
                        }
                        group[variantKey] = variant
                    }
                    assets[groupKey] = group
                }
                wp["assets"] = assets
            }
            if changed,
               let out = try? PropertyListSerialization.data(fromPropertyList: wp, format: .binary, options: 0) {
                try? out.write(to: wpPath)
            }
        }

        let userInfoURL = contentsDir.appendingPathComponent("com.apple.posterkit.provider.contents.userInfo")
        if var ui = readPlist(at: userInfoURL) {
            ui["wallpaperRepresentingFileName"] = names.bundle
            if let out = try? PropertyListSerialization.data(fromPropertyList: ui, format: .binary, options: 0) {
                try? out.write(to: userInfoURL)
            }
        }
        return (wallpaperDir, names.planes)
    }

    // MARK: - 树遍历

    /// 树下全部“像描述符”的文件夹：含 versions 目录、且 versions 下
    /// 能找到 .wallpaper 包。__MACOSX 镜像树跳过（里面是 AppleDouble
    /// 占位，没有 main.caml）。
    static func iterDescriptorDirs(at rootURL: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return results
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "versions",
                  let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir.boolValue else { continue }
            let descriptorDir = url.deletingLastPathComponent()
            if findWallpaperDir(in: descriptorDir) != nil {
                results.append(descriptorDir)
            }
            enumerator.skipDescendants()
        }
        return results.sorted { $0.path < $1.path }
    }

    static func findWallpaperDir(in descriptorURL: URL) -> URL? {
        let versions = descriptorURL.appendingPathComponent("versions")
        guard let versionNames = try? FileManager.default.contentsOfDirectory(atPath: versions.path) else { return nil }
        for version in versionNames.sorted() {
            let contents = versions.appendingPathComponent(version).appendingPathComponent("contents")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: contents.path) else { continue }
            for name in names.sorted() {
                if name.hasSuffix(".wallpaper") {
                    let candidate = contents.appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    static func planeDirs(in wallpaperDir: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: wallpaperDir.path) else { return [] }
        return names.sorted().compactMap { name -> URL? in
            guard name.hasSuffix(".ca") else { return nil }
            let url = wallpaperDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return url
        }
    }

    // MARK: - CAML 文本手术

    /// 删外部 <scriptObject src=...> 节点。外挂脚本会让 WallpaperKit
    /// 的 WKPlatformPackageView 一渲染就 trap，触发 CollectionsPoster
    /// 崩溃冷却，连累所有壁纸没快照没景深。
    static func stripScripts(_ text: String) -> String {
        replaceMatches(pattern: #"<scriptObject\b[^>]*?/\s*>|<scriptObject\b[^>]*?>.*?</scriptObject>"#,
                       in: text, with: "", dotMatchesLineSeparators: true)
    }

    static func hasExternalScript(_ text: String) -> Bool {
        firstMatch(pattern: #"<scriptObject\b[^>]*?/\s*>|<scriptObject\b[^>]*?>.*?</scriptObject>"#,
                   in: text, dotMatchesLineSeparators: true) != nil
    }

    /// 深度渲染器会 trap 的 CAML 状态操作：LKState 增删元素、CAMeshTransform。
    static func hasUnsupportedCaml(_ text: String) -> Bool {
        firstMatch(pattern: #"<LKStateAddElement\b|<LKStateRemoveElement\b|\bCAMeshTransform\b|(?:^|[\s"])meshTransform\s*="#,
                   in: text) != nil
    }

    // MARK: - 模板

    static func modernIndexXML(docWidth: Double, docHeight: Double, role: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>assetManifest</key>
        \t<string>assetManifest.caml</string>
        \t<key>documentHeight</key>
        \t<real>\(fmtNum(docHeight))</real>
        \t<key>documentResizesToView</key>
        \t<false/>
        \t<key>documentWidth</key>
        \t<real>\(fmtNum(docWidth))</real>
        \t<key>dynamicGuidesEnabled</key>
        \t<true/>
        \t<key>geometryFlipped</key>
        \t<false/>
        \t<key>guidesEnabled</key>
        \t<true/>
        \t<key>interactiveMouseEventsEnabled</key>
        \t<true/>
        \t<key>interactiveShowsCursor</key>
        \t<true/>
        \t<key>interactiveTouchEventsEnabled</key>
        \t<false/>
        \t<key>loopEnd</key>
        \t<real>+infinity</real>
        \t<key>loopStart</key>
        \t<real>0.0</real>
        \t<key>loopingEnabled</key>
        \t<true/>
        \t<key>multitouchDisablesMouse</key>
        \t<false/>
        \t<key>multitouchEnabled</key>
        \t<false/>
        \t<key>plugins</key>
        \t<array/>
        \t<key>presentationMouseEventsEnabled</key>
        \t<true/>
        \t<key>presentationShowsCursor</key>
        \t<true/>
        \t<key>presentationTouchEventsEnabled</key>
        \t<false/>
        \t<key>publishedObjectNames</key>
        \t<array>
        \t\t<string>\(role)</string>
        \t</array>
        \t<key>rootDocument</key>
        \t<string>main.caml</string>
        \t<key>savesWindowFrame</key>
        \t<false/>
        \t<key>scalesToFitInPlayer</key>
        \t<true/>
        \t<key>showsTouches</key>
        \t<true/>
        \t<key>snappingEnabled</key>
        \t<true/>
        \t<key>timelineMarkers</key>
        \t<string>[(null)]</string>
        \t<key>touchesColor</key>
        \t<string>1 1 0 0.8</string>
        \t<key>unitsInPixelsInPlayer</key>
        \t<false/>
        </dict>
        </plist>
        """
    }

    static let emptyMicaAssetManifest = """
        <?xml version="1.0" encoding="UTF-8"?>

        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <MicaAssetManifest>
            <modules type="NSArray"/>
          </MicaAssetManifest>
        </caml>
        """

    static func flatPlaneCaml(role: String, image: String, width: Double, height: Double) -> String {
        let cx = width / 2.0
        let cy = height / 2.0
        return """
            <?xml version="1.0" encoding="UTF-8"?>

            <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
              <CALayer id="\(role)" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(fmtNum(width)) \(fmtNum(height))" contentsFormat="RGBA8" cornerCurve="circular" geometryFlipped="1" hidden="0" name="Root Layer" position="\(fmtNum(cx)) \(fmtNum(cy))">
                <sublayers>
                  <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(fmtNum(width)) \(fmtNum(height))" contentsFormat="RGBA8" cornerCurve="circular" name="\(xmlEscape(image))" position="\(fmtNum(cx)) \(fmtNum(cy))">
                    <contents type="CGImage" src="assets/\(xmlEscape(image))"/>
                  </CALayer>
                </sublayers>
              </CALayer>
            </caml>
            """
    }

    static func emptyPlaneCaml(role: String, width: Double, height: Double) -> String {
        let cx = width / 2.0
        let cy = height / 2.0
        return """
            <?xml version="1.0" encoding="UTF-8"?>

            <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
              <CALayer id="\(role)" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(fmtNum(width)) \(fmtNum(height))" contentsFormat="RGBA8" cornerCurve="circular" geometryFlipped="0" hidden="0" name="\(role)" position="\(fmtNum(cx)) \(fmtNum(cy))"/>
            </caml>
            """
    }

    /// Python 的 `{value:g}` 格式：整数不带小数点，其余按需。
    static func fmtNum(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return "\(Int(value))"
        }
        var s = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while s.hasSuffix("0") { s = String(s.dropLast()) }
        if s.hasSuffix(".") { s = String(s.dropLast()) }
        return s
    }

    // MARK: - 正则与 XML 属性小工具

    static func regex(_ pattern: String, dotMatchesLineSeparators: Bool = false) -> NSRegularExpression? {
        var options: NSRegularExpression.Options = []
        if dotMatchesLineSeparators { options.insert(.dotMatchesLineSeparators) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// 返回第一处匹配的全部捕获组（[0] 为整段）。无匹配返回 nil。
    static func firstMatch(pattern: String, in text: String,
                           dotMatchesLineSeparators: Bool = false) -> [String]? {
        guard let re = regex(pattern, dotMatchesLineSeparators: dotMatchesLineSeparators) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location == NSNotFound { groups.append("") }
            else if let swiftRange = Range(r, in: text) { groups.append(String(text[swiftRange])) }
            else { groups.append("") }
        }
        return groups
    }

    static func allMatches(pattern: String, in text: String) -> [[String]] {
        guard let re = regex(pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, options: [], range: range).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                if r.location == NSNotFound { return "" }
                guard let swiftRange = Range(r, in: text) else { return "" }
                return String(text[swiftRange])
            }
        }
    }

    static func replaceMatches(pattern: String, in text: String, with replacement: String,
                               dotMatchesLineSeparators: Bool = false) -> String {
        guard let re = regex(pattern, dotMatchesLineSeparators: dotMatchesLineSeparators) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    /// 第一个匹配标签的 Swift Range。
    static func firstTagRange(pattern: String, in text: String) -> Range<String.Index>? {
        guard let re = regex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(m.range, in: text) else { return nil }
        return swiftRange
    }

    /// 最后一个匹配标签的 Swift Range。
    static func lastTagRange(pattern: String, in text: String) -> Range<String.Index>? {
        guard let re = regex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.matches(in: text, options: [], range: range).last,
              let swiftRange = Range(m.range, in: text) else { return nil }
        return swiftRange
    }

    static func xmlAttr(_ tag: String, name: String) -> String? {
        firstMatch(pattern: #"\b"# + name + #"="([^"]*)""#, in: tag).flatMap { $0.count == 2 ? $0[1] : nil }
    }

    static func setXmlAttr(_ tag: String, name: String, value: String) -> String {
        let pattern = #"\b"# + name + #"="[^"]*""#
        if let range = firstTagRange(pattern: pattern, in: tag) {
            return tag.replacingCharacters(in: range, with: "\(name)=\"\(value)\"")
        }
        guard let end = tag.lastIndex(of: ">") else { return tag }
        var out = tag
        out.insert(contentsOf: " \(name)=\"\(value)\"", at: end)
        return out
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - 文件 I/O

    static func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = root as? [String: Any] else { return nil }
        return dict
    }

    static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

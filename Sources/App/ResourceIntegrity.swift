import Foundation
import CryptoKit

// MARK: - 资源完整性校验（run #160，发布方案「资源完整性校验」）
//
// 每次刷入开始前，由 AppViewModel 的两个刷入入口同步调用：
// 先验清单签名，再逐个比对清单内文件的 SHA-256，全部通过
// 才放行；任一环节失败即拦截刷入。校验在本函数内同步得出
// 结论，没有异步绕过路径。
//
// 清单不进仓库：发布打包时由主线对最终 IPA 现场生成
// integrity-manifest.json（格式 {"version":1,"files":
// {相对路径: sha256 十六进制}}），用配置签名私钥 Ed25519
// 离线签名，签名文件 integrity-manifest.sig（内容为签名
// base64，与 config.sig 同约定）与清单一同注入 .app 根
// 目录。本文件只负责验，不负责生成。
//
// 验签复用 run #159 的同一验签入口（RemoteConfigService
// .verify）——同一把发布公钥、唯一常量来源，不另抄一份。
//
// 预期行为（SPEC run #160 登记）：CI 产物本身不含清单，
// 直接装 CI 包刷入会被拦截；正式分发包由主线在打包环节
// 注入清单+签名后才完整。

enum ResourceIntegrity {

    private struct Manifest: Decodable {
        var version: Int
        var files: [String: String]
    }

    /// 同步校验：清单签名有效且清单内每个文件存在、哈希
    /// 一致，才返回 true。
    static func verifyBundleResources() -> Bool {
        let root = Bundle.main.bundleURL
        let manifestURL = root.appendingPathComponent("integrity-manifest.json")
        let signatureURL = root.appendingPathComponent("integrity-manifest.sig")

        // ① 清单或签名缺失、验签失败、清单解析失败 → 拦截。
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let signatureData = try? Data(contentsOf: signatureURL),
              let signatureText = String(data: signatureData, encoding: .utf8),
              RemoteConfigService.verify(configData: manifestData, signatureText: signatureText),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.version == 1,
              !manifest.files.isEmpty
        else { return false }

        // ② 逐个按相对路径读文件、算 SHA-256 比对：任一
        // 缺失或不一致 → 拦截。清单已经过验签，这里的路径
        // 形态检查只是纵深防御。
        for (relativePath, expectedHex) in manifest.files {
            guard !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..")
            else { return false }
            let fileURL = root.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: fileURL) else { return false }
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex == expectedHex.lowercased() else { return false }
        }

        // ③ 全部通过 → 放行（静默）。
        return true
    }
}

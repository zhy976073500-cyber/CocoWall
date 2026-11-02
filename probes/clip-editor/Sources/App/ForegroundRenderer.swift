import Foundation
import SwiftUI
import UIKit

// MARK: - 前景组渲染（文字 / 扫光 → PNG）
//
// 前景组（Foreground.ca）只收位图：文字与扫光在导出时用
// UIGraphicsImageRenderer 以 3x 渲染成 PNG，与样本包
// 「.ca 里只有 CGImage」形态一致。预览侧文字直接用 SwiftUI Text
// 显示（同字号/颜色），扫光用渐变矩形近似；两者尺寸口径共用
// textSize / 图层 size，保证所见与导出大致对齐。
enum ForegroundRenderer {

    static let renderScale: CGFloat = 3

    // MARK: 文字

    static func font(ofSize size: Double) -> UIFont {
        UIFont.boldSystemFont(ofSize: CGFloat(size))
    }

    /// 文字图层的逻辑尺寸（pt）：单行文本的紧排尺寸 + 少量内边距。
    static func textSize(string: String, fontSize: Double) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font(ofSize: fontSize)]
        let measured = (string as NSString).size(withAttributes: attrs)
        return CGSize(width: ceil(measured.width) + 16, height: ceil(measured.height) + 10)
    }

    static func renderTextPNG(string: String, fontSize: Double, colorHex: String) -> Data? {
        let ptSize = textSize(string: string, fontSize: fontSize)
        let pxSize = CGSize(width: ptSize.width * renderScale, height: ptSize.height * renderScale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: pxSize, format: format)
        let image = renderer.image { _ in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font(ofSize: fontSize * Double(renderScale)),
                .foregroundColor: UIColor(hex: colorHex) ?? .white,
            ]
            let ns = string as NSString
            let measured = ns.size(withAttributes: attrs)
            let origin = CGPoint(x: (pxSize.width - measured.width) / 2,
                                 y: (pxSize.height - measured.height) / 2)
            ns.draw(at: origin, withAttributes: attrs)
        }
        return image.pngData()
    }

    // MARK: 扫光

    /// 半透明斜向渐变条（透明底）。斜扫的运动在导出时写成
    /// transform.translation.x 关键帧动画（见 ClipExporter），
    /// 图本身是静止的斜条。
    static func renderSweepPNG(sizePt: CGSize) -> Data? {
        let pxSize = CGSize(width: sizePt.width * renderScale, height: sizePt.height * renderScale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: pxSize, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: pxSize.width / 2, y: pxSize.height / 2)
            cg.rotate(by: -0.42)
            let bandWidth = pxSize.width * 0.55
            let bandHeight = pxSize.height * 1.8
            let rect = CGRect(x: -bandWidth / 2, y: -bandHeight / 2,
                              width: bandWidth, height: bandHeight)
            let colors = [
                UIColor.white.withAlphaComponent(0).cgColor,
                UIColor.white.withAlphaComponent(0.55).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 0.5, 1]) {
                cg.saveGState()
                cg.clip(to: rect)
                cg.drawLinearGradient(gradient,
                                      start: CGPoint(x: rect.minX, y: 0),
                                      end: CGPoint(x: rect.maxX, y: 0),
                                      options: [])
                cg.restoreGState()
            }
        }
        return image.pngData()
    }
}

// MARK: - 颜色工具

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex) ?? .white)
    }
}

// MARK: - 图片数据格式识别（导出时给素材文件挑扩展名）

enum ImageDataFormat {
    static func fileExtension(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "png"
    }
}

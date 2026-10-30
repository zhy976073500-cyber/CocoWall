import SwiftUI

/// 壁纸库的占位数据。
///
/// 封面图、名称、价格、移动云盘链接、打赏码都还没有定稿，
/// 所以全部集中在这一个文件里：日后拿到真实素材，只改这里，
/// 页面代码（LibraryView.swift）不用动。
struct LibraryItem: Identifiable {
    /// 编号，界面上显示为「No.100」起。
    let number: Int
    let name: String
    /// 封面图资源名（Assets.xcassets 里的 imageset）；为 nil 时用渐变占位。
    let coverAsset: String?
    /// 详情页大图资源名；为 nil 时详情页也用渐变占位。
    let previewAsset: String?
    let gradientTop: Color
    let gradientBottom: Color
    /// 是否进「主播推荐」横排。
    let recommended: Bool

    var id: Int { number }
    var numberText: String { "No.\(number)" }
}

/// 详情页的三个变体。切换时预览的色调要真的变：
/// 暖调压一层橙、提饱和；冷调压一层蓝、降饱和。
enum LibraryVariant: String, CaseIterable, Identifiable {
    case original = "原图"
    case warm = "暖调"
    case cool = "冷调"

    var id: String { rawValue }

    var overlayColor: Color {
        switch self {
        case .original: return .clear
        case .warm: return .orange
        case .cool: return .blue
        }
    }

    var overlayOpacity: Double {
        switch self {
        case .original: return 0
        case .warm: return 0.16
        case .cool: return 0.14
        }
    }

    var saturation: Double {
        switch self {
        case .original: return 1.0
        case .warm: return 1.15
        case .cool: return 0.85
        }
    }
}

enum LibraryCatalog {
    static let items: [LibraryItem] = [
        LibraryItem(number: 100, name: "星星人",
                    coverAsset: "LibraryStar", previewAsset: "LibraryHero",
                    gradientTop: Color(red: 1.00, green: 0.62, blue: 0.35),
                    gradientBottom: Color(red: 0.98, green: 0.35, blue: 0.45),
                    recommended: true),
        LibraryItem(number: 101, name: "史迪仔花瓶",
                    coverAsset: "LibraryStitch", previewAsset: "LibraryStitch",
                    gradientTop: Color(red: 0.35, green: 0.65, blue: 0.95),
                    gradientBottom: Color(red: 0.20, green: 0.45, blue: 0.80),
                    recommended: true),
        LibraryItem(number: 102, name: "极光夜空",
                    coverAsset: nil, previewAsset: nil,
                    gradientTop: Color(red: 0.30, green: 0.25, blue: 0.65),
                    gradientBottom: Color(red: 0.10, green: 0.55, blue: 0.55),
                    recommended: true),
        LibraryItem(number: 103, name: "霓虹都市",
                    coverAsset: nil, previewAsset: nil,
                    gradientTop: Color(red: 0.95, green: 0.35, blue: 0.65),
                    gradientBottom: Color(red: 0.45, green: 0.25, blue: 0.85),
                    recommended: false),
        LibraryItem(number: 104, name: "深海",
                    coverAsset: nil, previewAsset: nil,
                    gradientTop: Color(red: 0.15, green: 0.45, blue: 0.75),
                    gradientBottom: Color(red: 0.05, green: 0.20, blue: 0.45),
                    recommended: false),
        LibraryItem(number: 105, name: "落日余晖",
                    coverAsset: nil, previewAsset: nil,
                    gradientTop: Color(red: 1.00, green: 0.55, blue: 0.25),
                    gradientBottom: Color(red: 0.85, green: 0.25, blue: 0.30),
                    recommended: false),
        LibraryItem(number: 106, name: "几何线条",
                    coverAsset: nil, previewAsset: nil,
                    gradientTop: Color(red: 0.55, green: 0.60, blue: 0.70),
                    gradientBottom: Color(red: 0.25, green: 0.30, blue: 0.45),
                    recommended: false),
        LibraryItem(number: 107, name: "云朵之上",
                    coverAsset: nil, previewAsset: nil,
                    gradientTop: Color(red: 0.55, green: 0.80, blue: 1.00),
                    gradientBottom: Color(red: 0.85, green: 0.92, blue: 1.00),
                    recommended: false),
    ]

    static var recommended: [LibraryItem] { items.filter(\.recommended) }

    /// 移动云盘与打赏都还没接，按钮点了给占位提示，文案集中放这里。
    static let cloudDriveNote = "移动云盘链接待更新，暂时还不能下载。"
    static let tipNote = "打赏通道待更新，谢谢支持。"
}

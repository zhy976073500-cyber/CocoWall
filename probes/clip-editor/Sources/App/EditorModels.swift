import Foundation
import CoreGraphics

// MARK: - 剪辑式制作器数据模型（探针 v1）
//
// 定案口径（2026-11-02 Sage 拍板，见工程 README）：
//  · 部分（状态）3 个：开屏 Locked / 主屏 Unlock / 熄屏 Sleep。
//    编辑器只编开屏、主屏两套摆位；熄屏导出时自动生成（= 开屏摆位，
//    透明度 ×0.5 压暗），没有熄屏画布。
//  · 图层分 3 组对应 3 个 .ca：背景 Background（1 张底图）/
//    浮动 Floating（多图层，不设上限）/ 前景 Foreground（文字、扫光，
//    渲染成 PNG）。组固定，用户只能往组里加图层。
//  · 帧口径 60fps：循环一圈默认 240 帧（可选 180/240/360）；
//    状态过渡默认 48 帧（可调 24–60）。
//  · 动画分工不抢属性：位置/大小/透明度归状态（每图层在开屏、主屏
//    各存一套值，过渡靠弹簧插值）；持续动作归模板，只碰 transform。
//  · 每图层最多 2 个模板：动作槽 + 缩放旋转槽，各带幅度/速度。
//  · 时间轴上每图层一条 clip，拖两头 = 淡入/淡出帧数（图层在整个
//    循环里一直在，不是生死）。
//
// 坐标：编辑器画布 390×844pt，原点左上、y 向下；图层 position 均为
// 「中心点」。导出 CAML 时统一换算为左下原点 (x, 844 − y)
// （2026-11-01 真机验证定案，见 ClipExporter.camlPoint）。

// MARK: 分组与状态页签

enum LayerGroup: String, CaseIterable {
    case background
    case floating
    case foreground

    var displayName: String {
        switch self {
        case .background: return "背景"
        case .floating: return "浮动"
        case .foreground: return "前景"
        }
    }
}

/// 编辑器可编的两个部分页签（熄屏不可编，故不在此列）。
enum PartTab: String, CaseIterable, Identifiable {
    case locked
    case unlock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .locked: return "开屏"
        case .unlock: return "主屏"
        }
    }
}

// MARK: 单状态摆位（位置/大小/透明度归状态管）

struct LayerLayout: Equatable {
    /// 中心点（编辑器画布坐标）。
    var center: CGPoint
    /// 显示尺寸（pt）。
    var size: CGSize
    var opacity: Double = 1

    static func centered(size: CGSize) -> LayerLayout {
        LayerLayout(center: CGPoint(x: 195, y: 422), size: size, opacity: 1)
    }
}

// MARK: 模板（持续动作，只碰 transform）

enum MotionKind: String, CaseIterable, Identifiable {
    // 动作槽
    case float      // 漂浮：translation.y 上下
    case sway       // 摇摆：rotation.z
    case kenburns   // 慢放大平移：scale + translation（仅背景）
    // 缩放旋转槽
    case breathe    // 呼吸缩放：scale
    case spinSway   // 旋转摇摆：rotation.z
    // 特效专用（不可手动选，扫光图层自带）
    case sweep      // 斜扫：translation.x 一次扫过

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .float: return "漂浮"
        case .sway: return "摇摆"
        case .kenburns: return "慢放大平移"
        case .breathe: return "呼吸缩放"
        case .spinSway: return "旋转摇摆"
        case .sweep: return "斜扫"
        }
    }

    /// 写入 CAML 的 keyPath 列表（预览求值与此一一对应）。
    var keyPaths: [String] {
        switch self {
        case .float: return ["transform.translation.y"]
        case .sway, .spinSway: return ["transform.rotation.z"]
        case .kenburns: return ["transform.scale", "transform.translation.x", "transform.translation.y"]
        case .breathe: return ["transform.scale"]
        case .sweep: return ["transform.translation.x"]
        }
    }

    /// 动作槽可选项（kenburns 仅背景可选，调用方按组过滤）。
    static var actionSlotKinds: [MotionKind] { [.float, .sway, .kenburns] }
    /// 缩放旋转槽可选项。
    static var transformSlotKinds: [MotionKind] { [.breathe, .spinSway] }
}

struct MotionSetting: Equatable {
    var kind: MotionKind
    /// 幅度 0…1（映射到各 kind 的物理量，见 MotionMath）。
    var amplitude: Double = 0.5
    /// 速度 0.5…2（1 = 模板一圈正好等于循环时长）。
    var speed: Double = 1
}

// MARK: 图层

enum LayerContent: Equatable {
    case photo(data: Data, pixelSize: CGSize)
    case text(string: String, fontSize: Double, colorHex: String)
    case sweep
}

struct EditorLayer: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var group: LayerGroup
    var content: LayerContent
    var lockedLayout: LayerLayout
    var unlockLayout: LayerLayout
    /// clip 两头拖出的淡入/淡出帧数（0 = 不淡）。v1 仅编辑器预览
    /// 生效，导出暂不写入（见 ClipExporter 注释与 README 已知限制）。
    var fadeInFrames: Int = 0
    var fadeOutFrames: Int = 0
    /// 动作槽（漂浮/摇摆/慢放大平移）。
    var actionMotion: MotionSetting?
    /// 缩放旋转槽（呼吸缩放/旋转摇摆）。
    var transformMotion: MotionSetting?

    func layout(for tab: PartTab) -> LayerLayout {
        tab == .locked ? lockedLayout : unlockLayout
    }

    mutating func setLayout(_ layout: LayerLayout, for tab: PartTab) {
        if tab == .locked { lockedLayout = layout } else { unlockLayout = layout }
    }

    var isText: Bool {
        if case .text = content { return true }
        return false
    }

    var isSweep: Bool { content == .sweep }
}

// MARK: 弹簧预设（过渡）

/// 三档弹簧预设：跟手 = 样本包 7400 原值（stiffness 300 / damping 50 /
/// mass 2，duration 0.8）；柔和、带弹为同量级派生。写进 CAML 的
/// CASpringAnimation，预览开锁用同一组参数求曲线（SpringCurve）。
struct SpringSpec: Equatable, Hashable, Identifiable {
    var name: String
    var stiffness: Double
    var damping: Double
    var mass: Double

    var id: String { name }

    static let responsive = SpringSpec(name: "跟手", stiffness: 300, damping: 50, mass: 2)
    static let gentle = SpringSpec(name: "柔和", stiffness: 180, damping: 38, mass: 2)
    static let bouncy = SpringSpec(name: "带弹", stiffness: 260, damping: 22, mass: 2)
    static let all: [SpringSpec] = [.responsive, .gentle, .bouncy]
}

/// 解析弹簧曲线：给定弹簧参数与时间 t（秒），返回 0→1 的进度
/// （带弹档会过冲 >1，与 CASpringAnimation 的物理行为同构）。
/// 预览开锁专用；导出只写参数，曲线由 PosterBoard 自己算。
enum SpringCurve {
    static func value(spec: SpringSpec, t: Double) -> Double {
        if t <= 0 { return 0 }
        let k = spec.stiffness, c = spec.damping, m = spec.mass
        let omega0 = sqrt(k / m)
        let zeta = c / (2 * sqrt(k * m))
        if zeta < 1 {
            let wd = omega0 * sqrt(1 - zeta * zeta)
            let env = exp(-zeta * omega0 * t)
            return 1 - env * (cos(wd * t) + (zeta * omega0 / wd) * sin(wd * t))
        } else {
            // 过阻尼/临界：双指数解（ζ=1 时两根重合，公式退化为临界式）。
            let s = sqrt(max(zeta * zeta - 1, 0))
            let r1 = -omega0 * (zeta - s)
            let r2 = -omega0 * (zeta + s)
            if abs(r1 - r2) < 1e-9 {
                return 1 - exp(-omega0 * t) * (1 + omega0 * t)
            }
            let a = r2 / (r2 - r1)
            let b = -r1 / (r2 - r1)
            return 1 - (a * exp(r1 * t) + b * exp(r2 * t))
        }
    }
}

// MARK: 模板求值（预览与导出共用语义）

/// 模板动画在任意时刻的 transform 偏移。预览（SwiftUI）与导出
/// （CAKeyframeAnimation 的 values）必须同源：导出写的是
/// [起点, 终点] + autoreverses，预览按同一三角波回放。
/// 返回值均为 CAML/CA 语义：translation.y 正 = 上，rotation 弧度，
/// scale 为倍率。预览层负责把 translation.y 取负换成屏幕方向。
struct MotionOffset: Equatable {
    var scale: Double = 1
    var rotationZ: Double = 0
    var translationX: Double = 0
    var translationY: Double = 0

    static let identity = MotionOffset()

    mutating func absorb(_ other: MotionOffset) {
        scale *= other.scale
        rotationZ += other.rotationZ
        translationX += other.translationX
        translationY += other.translationY
    }
}

enum MotionMath {
    /// 模板一圈（去+回）时长（秒）= 循环时长 / speed。
    /// 导出的 CAML 写法：duration = 循环时长、speed = 2×speed，
    /// 单程 = duration/speed = 循环/(2×speed)，一圈正好同上。
    static func cycleDuration(loopSeconds: Double, speed: Double) -> Double {
        loopSeconds / max(speed, 0.01)
    }

    /// 三角波：phase 0→1 对应一个完整来回（0→1→0）。
    static func triangle(phase: Double) -> Double {
        let p = phase - floor(phase)
        return p < 0.5 ? p * 2 : 2 - p * 2
    }

    /// 单个模板在给定循环相位（0…1）下的偏移。
    static func offset(of motion: MotionSetting, loopPhase: Double) -> MotionOffset {
        let a = motion.amplitude
        switch motion.kind {
        case .float:
            // 漂浮：-A → +A 三角波（与导出 values [-A, A] + autoreverses 同构）。
            let tri = triangle(phase: loopPhase * max(motion.speed, 0.01))
            let amp = 4 + 26 * a
            return MotionOffset(translationY: -amp + 2 * amp * tri)
        case .sway:
            let tri = triangle(phase: loopPhase * max(motion.speed, 0.01))
            let from = -(0.03 + 0.12 * a), to = 0.03 + 0.12 * a
            return MotionOffset(rotationZ: from + (to - from) * tri)
        case .spinSway:
            let tri = triangle(phase: loopPhase * max(motion.speed, 0.01))
            let from = -(0.08 + 0.22 * a), to = 0.08 + 0.22 * a
            return MotionOffset(rotationZ: from + (to - from) * tri)
        case .breathe:
            let tri = triangle(phase: loopPhase * max(motion.speed, 0.01))
            return MotionOffset(scale: 1 + (0.02 + 0.08 * a) * tri)
        case .kenburns:
            let tri = triangle(phase: loopPhase * max(motion.speed, 0.01))
            return MotionOffset(scale: 1 + 0.07 * a * tri,
                                translationX: -14 * a * tri,
                                translationY: 8 * a * tri)
        case .sweep:
            // 斜扫：不回来，-320 → +320 一次扫过（两端都在画布外）。
            let p = loopPhase - floor(loopPhase)
            return MotionOffset(translationX: -320 + 640 * p)
        }
    }

    /// 图层两个槽叠加后的总偏移（同 keyPath 时缩放旋转槽优先：
    /// absorb 顺序为动作槽先、缩放旋转槽后，scale 取乘积、
    /// rotation 取和——两槽同写 rotation 时实际是叠加，与导出时
    /// 两条动画并存的 CA 行为一致）。
    static func combinedOffset(action: MotionSetting?, transform: MotionSetting?,
                               loopPhase: Double) -> MotionOffset {
        var result = MotionOffset.identity
        if let action { result.absorb(offset(of: action, loopPhase: loopPhase)) }
        if let transform { result.absorb(offset(of: transform, loopPhase: loopPhase)) }
        return result
    }
}

// MARK: 工程

struct ClipProject: Equatable {
    static let canvasSize = CGSize(width: 390, height: 844)
    static let fps: Double = 60

    var name: String = "未命名壁纸"
    /// 循环长度（帧）：180 / 240 / 360。
    var loopFrames: Int = 240
    /// 状态过渡时长（帧）：24…60，默认 48。
    var transitionFrames: Int = 48
    var spring: SpringSpec = .responsive

    var background: EditorLayer?
    var floating: [EditorLayer] = []
    var foreground: [EditorLayer] = []

    var loopSeconds: Double { Double(loopFrames) / Self.fps }
    var transitionSeconds: Double { Double(transitionFrames) / Self.fps }

    func layers(in group: LayerGroup) -> [EditorLayer] {
        switch group {
        case .background: return background.map { [$0] } ?? []
        case .floating: return floating
        case .foreground: return foreground
        }
    }

    /// 渲染顺序（底→顶）：背景、浮动（数组序）、前景（数组序）。
    var allLayersBottomToTop: [EditorLayer] {
        layers(in: .background) + floating + foreground
    }

    func layer(id: UUID) -> EditorLayer? {
        allLayersBottomToTop.first { $0.id == id }
    }

    mutating func updateLayer(_ layer: EditorLayer) {
        switch layer.group {
        case .background:
            if background?.id == layer.id { background = layer }
        case .floating:
            if let i = floating.firstIndex(where: { $0.id == layer.id }) { floating[i] = layer }
        case .foreground:
            if let i = foreground.firstIndex(where: { $0.id == layer.id }) { foreground[i] = layer }
        }
    }

    mutating func removeLayer(id: UUID) {
        if background?.id == id { background = nil }
        floating.removeAll { $0.id == id }
        foreground.removeAll { $0.id == id }
    }
}

// MARK: 时间码

/// mm:ss:ff（60fps 口径），时间轴播放头上方的时间码。
func timecode(frame: Double) -> String {
    let total = max(0, Int(frame.rounded()))
    let f = total % 60
    let s = (total / 60) % 60
    let m = total / 3600
    return String(format: "%02d:%02d:%02d", m, s, f)
}

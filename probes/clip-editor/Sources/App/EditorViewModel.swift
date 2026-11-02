import Foundation
import SwiftUI
import PhotosUI
import UIKit

// MARK: - 编辑器状态与播放引擎
//
// 播放：30Hz 计时器推进 currentFrame（帧，60fps 口径），循环回绕。
// 模板偏移由 MotionMath 按 loopPhase 求值，画布与时间轴共用。
// 预览开锁：以工程的弹簧参数（SpringSpec）+ 过渡帧数驱动，在
// 开屏/主屏两套摆位之间插值——弹簧规范时长按样本的 0.8s 映射到
// 选定的过渡时长（见 transitionCurveValue），与导出写进 CAML 的
// CASpringAnimation 参数同源（曲线本体由 PosterBoard 计算，
// 这里是同参数的解析近似）。
@MainActor
final class EditorViewModel: ObservableObject {

    @Published var project = ClipProject()
    @Published var currentTab: PartTab = .locked
    @Published var selectedLayerID: UUID?
    @Published var currentFrame: Double = 0
    @Published var isPlaying = true
    @Published var isScrubbing = false

    /// 导出结果（成功给文件 URL，失败给原因），ContentView 据此弹面板。
    @Published var exportOutcome: ExportOutcome?

    enum ExportOutcome: Identifiable {
        case success(URL)
        case failure(String)
        var id: String {
            switch self {
            case .success(let url): return "ok-" + url.lastPathComponent
            case .failure(let msg): return "err-" + msg
            }
        }
    }

    // MARK: 过渡预览状态
    //
    // 开始预览时把当次过渡的设置快照下来（类型/弹簧/时长），中途改
    // 设置不影响正在播的这一段。开屏预览（previewWake）是特殊的
    // 同页签过渡：from == to == .locked，来源摆位取熄屏压暗态
    // （开屏摆位、透明度 ×0.5），用入场设置。

    private var transitionFrom: PartTab?
    private var transitionTo: PartTab?
    private var transitionElapsed: Double = 0
    private var transitionIsWake = false
    private var activeSpring: SpringSpec = .responsive
    private var activeDuration: Double = 0.8
    private var activeAnimatesOpacity = true
    private var activeAnimatesLayout = false
    @Published private(set) var isTransitioning = false

    private var timer: Timer?
    private var lastTick: Date?

    init() {
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    deinit { timer?.invalidate() }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick ?? now), 0.1)
        lastTick = now

        if isTransitioning {
            transitionElapsed += dt
            if transitionElapsed >= activeDuration * 1.15 {
                finishTransition()
            }
        } else if isPlaying && !isScrubbing {
            let next = currentFrame + dt * ClipProject.fps
            currentFrame = next.truncatingRemainder(dividingBy: Double(project.loopFrames))
        }
    }

    // MARK: 过渡预览

    /// 当前过渡曲线进度（无过渡时为 nil）。弹簧规范时长 0.8s
    /// （样本原值）线性映射到当次过渡的选定时长。
    var transitionProgress: Double? {
        guard isTransitioning else { return nil }
        let t = transitionElapsed * (0.8 / max(activeDuration, 0.01))
        return SpringCurve.value(spec: activeSpring, t: t)
    }

    var transitionSourceTab: PartTab? { transitionFrom }

    private func beginTransition(from: PartTab, to: PartTab, isWake: Bool,
                                 spring: SpringSpec, seconds: Double,
                                 animatesOpacity: Bool, animatesLayout: Bool) {
        transitionFrom = from
        transitionTo = to
        transitionIsWake = isWake
        activeSpring = spring
        activeDuration = seconds
        activeAnimatesOpacity = animatesOpacity
        activeAnimatesLayout = animatesLayout
        transitionElapsed = 0
        isTransitioning = true
    }

    /// 预览开锁/回锁：用「解锁过渡」的类型、帧数与弹簧。
    func previewUnlock() {
        guard !isTransitioning else { return }
        beginTransition(from: .locked, to: .unlock, isWake: false,
                        spring: project.spring, seconds: project.transitionSeconds,
                        animatesOpacity: project.transitionKind.animatesOpacity,
                        animatesLayout: project.transitionKind.animatesLayout)
    }

    func previewLock() {
        guard !isTransitioning else { return }
        beginTransition(from: .unlock, to: .locked, isWake: false,
                        spring: project.spring, seconds: project.transitionSeconds,
                        animatesOpacity: project.transitionKind.animatesOpacity,
                        animatesLayout: project.transitionKind.animatesLayout)
    }

    /// 预览开屏：从熄屏压暗态进入开屏画面，用「开屏入场」设置。
    /// 入场类型为「无」时以极短时长直接切入（示意无动画）。
    func previewWake() {
        guard !isTransitioning, currentTab == .locked else { return }
        let entrance = project.entrance
        if entrance.kind == .none {
            beginTransition(from: .locked, to: .locked, isWake: true,
                            spring: entrance.spring, seconds: 0.05,
                            animatesOpacity: true, animatesLayout: false)
        } else {
            beginTransition(from: .locked, to: .locked, isWake: true,
                            spring: entrance.spring, seconds: entrance.seconds,
                            animatesOpacity: true, animatesLayout: false)
        }
    }

    private func finishTransition() {
        if let to = transitionTo { currentTab = to }
        transitionFrom = nil
        transitionTo = nil
        transitionIsWake = false
        transitionElapsed = 0
        isTransitioning = false
    }

    // MARK: 当前帧下图层的有效摆位/透明度（画布用）

    /// 某部分下图层应呈现的摆位（不含过渡插值）。背景特殊：两张
    /// 都设时，每张只在自己那一部分可见（另一部分透明度 0，摆位
    /// 取自己那套）；只设一张时共用，按各部分自己的摆位（老行为）。
    func displayLayout(of layer: EditorLayer, for tab: PartTab) -> LayerLayout {
        if let slot = project.backgroundSlot(of: layer), project.hasBothBackgrounds {
            var layout = layer.layout(for: slot)
            if tab != slot { layout.opacity = 0 }
            return layout
        }
        return layer.layout(for: tab)
    }

    /// 背景图层在当前页签是否完全不可见（两张都设、且不是它自己
    /// 的部分、且不在过渡中）——画布据此禁手势，免得拖到看不见的层。
    func backgroundHiddenInCurrentTab(_ layer: EditorLayer) -> Bool {
        guard !isTransitioning,
              let slot = project.backgroundSlot(of: layer),
              project.hasBothBackgrounds else { return false }
        return slot != currentTab
    }

    /// 有效摆位：过渡中按当次过渡类型在两部分之间插值——挂了弹簧
    /// 的属性（渐变→透明度、摆位弹簧→位置/大小）按弹簧进度走，
    /// 没挂的直接取目标值（位置直接切换 / 透明度直接到位）。
    /// 开屏预览时来源是熄屏压暗态（开屏摆位、透明度 ×0.5）。
    func effectiveLayout(of layer: EditorLayer) -> LayerLayout {
        if let progress = transitionProgress, let from = transitionFrom, let to = transitionTo {
            var a = displayLayout(of: layer, for: from)
            let b = displayLayout(of: layer, for: to)
            if transitionIsWake { a.opacity *= 0.5 }
            return LayerLayout(
                center: activeAnimatesLayout
                    ? CGPoint(x: a.center.x + (b.center.x - a.center.x) * progress,
                              y: a.center.y + (b.center.y - a.center.y) * progress)
                    : b.center,
                size: activeAnimatesLayout
                    ? CGSize(width: a.size.width + (b.size.width - a.size.width) * progress,
                             height: a.size.height + (b.size.height - a.size.height) * progress)
                    : b.size,
                opacity: activeAnimatesOpacity
                    ? a.opacity + (b.opacity - a.opacity) * progress
                    : b.opacity)
        }
        return displayLayout(of: layer, for: currentTab)
    }

    /// 面板与画布拖动应写入哪一部分的摆位：两张背景都设时，背景
    /// 图层只编自己那一部分；其余情况编当前页签。
    func editingTab(for layer: EditorLayer) -> PartTab {
        if let slot = project.backgroundSlot(of: layer), project.hasBothBackgrounds {
            return slot
        }
        return currentTab
    }

    func loopPhase(frame: Double? = nil) -> Double {
        (frame ?? currentFrame) / Double(project.loopFrames)
    }

    /// 淡入淡出在当前帧的乘子（clip 两头拖出的帧数）。
    func fadeMultiplier(of layer: EditorLayer) -> Double {
        var m = 1.0
        let f = currentFrame
        if layer.fadeInFrames > 0 && f < Double(layer.fadeInFrames) {
            m = min(m, f / Double(layer.fadeInFrames))
        }
        let remain = Double(project.loopFrames) - f
        if layer.fadeOutFrames > 0 && remain < Double(layer.fadeOutFrames) {
            m = min(m, remain / Double(layer.fadeOutFrames))
        }
        return max(0, min(1, m))
    }

    func effectiveOpacity(of layer: EditorLayer) -> Double {
        effectiveLayout(of: layer).opacity * fadeMultiplier(of: layer)
    }

    /// 模板总偏移（预览用；扫光自带于 actionMotion）。
    func motionOffset(of layer: EditorLayer) -> MotionOffset {
        MotionMath.combinedOffset(action: layer.actionMotion,
                                  transform: layer.transformMotion,
                                  loopPhase: loopPhase())
    }

    // MARK: 选中

    var selectedLayer: EditorLayer? {
        selectedLayerID.flatMap { project.layer(id: $0) }
    }

    func select(_ id: UUID?) { selectedLayerID = id }

    func updateSelected(_ mutate: (inout EditorLayer) -> Void) {
        guard var layer = selectedLayer else { return }
        mutate(&layer)
        project.updateLayer(layer)
    }

    // MARK: 导入素材（PhotosPicker）

    /// 导入背景图到指定部分（开屏/主屏各一张，互不覆盖）。
    func importBackground(item: PhotosPickerItem?, into part: PartTab) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        let size = Self.coverSize(pixelSize: image.size)
        let layout = LayerLayout.centered(size: size)
        let layer = EditorLayer(name: part == .locked ? "开屏背景" : "主屏背景",
                                group: .background,
                                content: .photo(data: data, pixelSize: image.size),
                                lockedLayout: layout, unlockLayout: layout)
        if part == .locked {
            project.backgroundLocked = layer
        } else {
            project.backgroundUnlock = layer
        }
        selectedLayerID = layer.id
        currentTab = part
    }

    func importFloating(items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            addPhotoLayer(data: data, pixelSize: image.size)
        }
    }

    func addPhotoLayer(data: Data, pixelSize: CGSize) {
        let idx = project.floating.count
        let w = min(220.0, max(60.0, pixelSize.width / 3))
        let h = w * pixelSize.height / max(pixelSize.width, 1)
        let size = CGSize(width: w, height: min(h, 460))
        let offset = CGFloat(idx % 5) * 14
        let layout = LayerLayout(center: CGPoint(x: 195 + offset - 28, y: 422 + offset - 28),
                                 size: size, opacity: 1)
        let layer = EditorLayer(name: "图层 \(idx + 1)", group: .floating,
                                content: .photo(data: data, pixelSize: pixelSize),
                                lockedLayout: layout, unlockLayout: layout)
        project.floating.append(layer)
        selectedLayerID = layer.id
    }

    /// 背景默认摆位：等比放大到盖满 390×844 画布。
    static func coverSize(pixelSize: CGSize) -> CGSize {
        let canvas = ClipProject.canvasSize
        let scale = max(canvas.width / max(pixelSize.width, 1),
                        canvas.height / max(pixelSize.height, 1))
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    // MARK: 文字 / 特效图层

    struct TextColorOption: Identifiable {
        var name: String
        var hex: String
        var id: String { hex }
    }

    static let textColors: [TextColorOption] = [
        TextColorOption(name: "白", hex: "#FFFFFF"),
        TextColorOption(name: "黑", hex: "#111111"),
        TextColorOption(name: "蓝", hex: "#0071E3"),
        TextColorOption(name: "黄", hex: "#FFD60A"),
        TextColorOption(name: "粉", hex: "#FF6482"),
        TextColorOption(name: "绿", hex: "#30D158"),
    ]

    func addTextLayer(string: String, fontSize: Double, colorHex: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let size = ForegroundRenderer.textSize(string: trimmed, fontSize: fontSize)
        let layout = LayerLayout.centered(size: size)
        let layer = EditorLayer(name: "文字：\(trimmed)", group: .foreground,
                                content: .text(string: trimmed, fontSize: fontSize, colorHex: colorHex),
                                lockedLayout: layout, unlockLayout: layout)
        project.foreground.append(layer)
        selectedLayerID = layer.id
    }

    func addSweepLayer() {
        let layout = LayerLayout.centered(size: CGSize(width: 180, height: 360))
        let layer = EditorLayer(name: "扫光", group: .foreground, content: .sweep,
                                lockedLayout: layout, unlockLayout: layout,
                                actionMotion: MotionSetting(kind: .sweep, amplitude: 1, speed: 1))
        project.foreground.append(layer)
        selectedLayerID = layer.id
    }

    // MARK: 图层管理（列表页用）

    func deleteLayer(id: UUID) {
        project.removeLayer(id: id)
        if selectedLayerID == id { selectedLayerID = nil }
    }

    func renameLayer(id: UUID, to name: String) {
        guard var layer = project.layer(id: id) else { return }
        layer.name = name
        project.updateLayer(layer)
    }

    func moveFloating(from source: IndexSet, to destination: Int) {
        project.floating.move(fromOffsets: source, toOffset: destination)
    }

    func moveForeground(from source: IndexSet, to destination: Int) {
        project.foreground.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: 导出

    func exportPackage() {
        guard project.hasAnyBackground else {
            exportOutcome = .failure("先选一张背景图（开屏或主屏任意一张），再导出。")
            return
        }
        do {
            let identifier = String(Int.random(in: 8000...8999))
            let descriptorUUID = UUID().uuidString.uppercased()
            let output = try ClipExporter.build(project: project,
                                                identifier: identifier,
                                                descriptorUUID: descriptorUUID)
            let safeName = project.name
                .replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespaces)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent((safeName.isEmpty ? "wallpaper" : safeName) + ".tendies")
            try output.data.write(to: url, options: .atomic)
            exportOutcome = .success(url)
        } catch {
            exportOutcome = .failure("导出失败：\(error.localizedDescription)")
        }
    }
}

import Foundation
import SwiftUI
import PhotosUI
import UIKit

// MARK: - 编辑器状态与播放引擎（v3 四段式）
//
// 时间线是一条线四段：开屏动画｜开屏｜解锁动画｜主屏。ViewModel
// 用 segment + segmentProgress（动画段）/ currentFrame（循环段）
// 定位播放头；画布按当前段求值：
//  · 动画段：图层姿态 = 关键帧轨迹插值（PoseMath，smoothstep）；
//    用户在画布/面板上的编辑先落到 workingPose（操作姿态），
//    点「打关键帧」才记成该时刻的关键帧。
//  · 循环段：状态摆位（displayLayout）+ 模板偏移，与 v2 相同。
// 数据一致性（定案）：开屏动画段最后一帧的姿态 == 开屏摆位
// （lockedLayout），双向同步、同一份数据；解锁动画段起点 = 开屏
// 摆位、终点 = 主屏摆位（端点不另存，直接由两套 layout 充当）。
// 「预览开屏/预览开锁」= 播放头跳到对应动画段从头播放。
@MainActor
final class EditorViewModel: ObservableObject {

    @Published var project = ClipProject()
    @Published var currentTab: PartTab = .locked
    @Published var selectedLayerID: UUID?
    @Published var currentFrame: Double = 0
    @Published var isPlaying = true
    @Published var isScrubbing = false

    /// 当前时间线段与动画段内的归一化进度（0…1）。
    @Published var segment: TimelineSegment = .lockedLoop
    @Published var segmentProgress: Double = 0
    /// 轨道上选中的关键帧标记（点菱形选中，可删）。
    @Published var selectedKeyframe: KeyframeSelection?

    struct KeyframeSelection: Equatable {
        var layerID: UUID
        var segment: TimelineSegment
        var keyframeID: UUID
    }

    /// 动画段内的操作姿态（未打帧的编辑草稿）：画布拖动与面板滑杆
    /// 先改它，画布即时按它渲染；打帧后成为正式关键帧。上下文
    /// （图层+段）不匹配时自动失效、按轨迹插值现算。@Published
    /// 是为了让草稿改动即时触发画布/面板重绘。
    struct WorkingPoseContext: Equatable {
        var layerID: UUID
        var segment: TimelineSegment
        var pose: LayerPose
    }

    @Published private(set) var workingPoseContext: WorkingPoseContext?

    /// 导出结果（成功给文件 URL，失败给原因），ContentView 据此弹面板。
    @Published var exportOutcome: ExportOutcome?
    /// 导出完成提示文案（时长重算口径，导出那一刻按当时帧数生成）。
    @Published var exportNote: String = ""

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
        guard isPlaying && !isScrubbing else { return }
        switch segment {
        case .entrance, .unlockAnim:
            let dur = max(project.segmentDuration(segment), 0.01)
            segmentProgress += dt / dur
            if segmentProgress >= 1 {
                segmentProgress = segmentProgress.truncatingRemainder(dividingBy: 1)
            }
            clearWorkingPose()
        case .lockedLoop, .unlockLoop:
            let next = currentFrame + dt * ClipProject.fps
            currentFrame = next.truncatingRemainder(dividingBy: Double(project.loopFrames))
        }
    }

    // MARK: 播放头定位（四段统一坐标，单位：编辑秒）

    var playheadSeconds: Double {
        let start = project.segmentStart(segment)
        switch segment {
        case .entrance: return start + segmentProgress * project.entranceRulerSeconds
        case .unlockAnim: return start + segmentProgress * project.unlockRulerSeconds
        case .lockedLoop, .unlockLoop: return start + currentFrame / ClipProject.fps
        }
    }

    /// 段内本地帧数（时间码显示用）：动画段 = 进度 × 编辑尺帧数，
    /// 循环段 = currentFrame。
    var segmentLocalFrame: Double {
        switch segment {
        case .entrance: return segmentProgress * project.entranceRulerSeconds * ClipProject.fps
        case .unlockAnim: return segmentProgress * project.unlockRulerSeconds * ClipProject.fps
        case .lockedLoop, .unlockLoop: return currentFrame
        }
    }

    func setPlayhead(seconds: Double) {
        let clamped = min(max(seconds, 0), max(project.timelineTotalSeconds - 0.0001, 0))
        let seg = project.segment(at: clamped)
        segment = seg
        let local = clamped - project.segmentStart(seg)
        switch seg {
        case .entrance: segmentProgress = local / max(project.entranceRulerSeconds, 0.01)
        case .unlockAnim: segmentProgress = local / max(project.unlockRulerSeconds, 0.01)
        case .lockedLoop, .unlockLoop: currentFrame = local * ClipProject.fps
        }
        currentTab = seg.tab
        clearWorkingPose()
    }

    /// 跳到某段开头并播放（页签、段头、预览按钮共用）。
    func jumpToSegment(_ seg: TimelineSegment) {
        segment = seg
        segmentProgress = 0
        if !seg.isAnimation { currentFrame = 0 }
        currentTab = seg.tab
        clearWorkingPose()
        isPlaying = true
    }

    /// 回到当前段开头。
    func restartSegment() {
        segmentProgress = 0
        currentFrame = 0
        clearWorkingPose()
    }

    // MARK: 预览（= 跳到对应动画段播放）

    func previewWake() { jumpToSegment(.entrance) }
    func previewUnlock() { jumpToSegment(.unlockAnim) }
    func previewLock() { jumpToSegment(.unlockAnim) }

    // MARK: 姿态求值（画布用）

    /// 某图层在指定动画段、指定进度下的轨迹姿态。
    func trajectoryPose(of layer: EditorLayer, segment seg: TimelineSegment,
                        progress: Double) -> LayerPose {
        switch seg {
        case .entrance:
            if let pose = PoseMath.evaluate(keyframes: layer.entranceKeyframes, progress: progress) {
                return pose
            }
            return LayerPose(layout: displayLayout(of: layer, for: .locked))
        case .unlockAnim:
            let start = LayerPose(layout: displayLayout(of: layer, for: .locked))
            let end = LayerPose(layout: displayLayout(of: layer, for: .unlock))
            let all = [LayerKeyframe(progress: 0, pose: start)]
                + layer.unlockKeyframes
                + [LayerKeyframe(progress: 1, pose: end)]
            return PoseMath.evaluate(keyframes: all, progress: progress) ?? start
        case .lockedLoop, .unlockLoop:
            return LayerPose(layout: displayLayout(of: layer, for: seg.tab))
        }
    }

    /// 画布当前应渲染的姿态：动画段优先操作姿态（正在编的那层），
    /// 其余走轨迹插值；循环段 = 状态摆位。
    func canvasPose(of layer: EditorLayer) -> LayerPose {
        if segment.isAnimation {
            if let ctx = workingPoseContext, ctx.layerID == layer.id, ctx.segment == segment {
                return ctx.pose
            }
            return trajectoryPose(of: layer, segment: segment, progress: segmentProgress)
        }
        return LayerPose(layout: displayLayout(of: layer, for: currentTab))
    }

    /// 画布渲染顺序：动画段按姿态层级（zIndex）稳定排序，循环段
    /// 保持工程原始顺序（状态不带层级）。
    func canvasLayersOrdered() -> [EditorLayer] {
        let base = project.allLayersBottomToTop
        guard segment.isAnimation else { return base }
        return base.enumerated()
            .sorted { a, b in
                let za = canvasPose(of: a.element).zIndex
                let zb = canvasPose(of: b.element).zIndex
                return za != zb ? za < zb : a.offset < b.offset
            }
            .map { $0.element }
    }

    /// 图层在当前上下文是否完全不可见（双背景时另一部分的那张）：
    /// 画布据此禁手势，免得拖到看不见的层。解锁动画段两张都参与
    /// 轨迹，不禁。
    func isLayerHiddenInCurrentContext(_ layer: EditorLayer) -> Bool {
        guard let slot = project.backgroundSlot(of: layer),
              project.hasBothBackgrounds else { return false }
        switch segment {
        case .entrance, .lockedLoop: return slot == .unlock
        case .unlockLoop: return slot == .locked
        case .unlockAnim: return false
        }
    }

    // MARK: 操作姿态（动画段编辑草稿）

    func clearWorkingPose() {
        workingPoseContext = nil
    }

    /// 当前操作姿态：有草稿用草稿，没有就按轨迹在当前进度现算。
    func workingPose(for layer: EditorLayer) -> LayerPose {
        if let ctx = workingPoseContext, ctx.layerID == layer.id, ctx.segment == segment {
            return ctx.pose
        }
        return trajectoryPose(of: layer, segment: segment, progress: segmentProgress)
    }

    func updateWorkingPose(for layer: EditorLayer, _ mutate: (inout LayerPose) -> Void) {
        var pose = workingPose(for: layer)
        mutate(&pose)
        workingPoseContext = WorkingPoseContext(layerID: layer.id, segment: segment, pose: pose)
    }

    // MARK: 关键帧打帧 / 删除 / 同步

    /// 同进度重复打帧视为覆盖的容差。
    private let keyframeEpsilon = 0.004

    /// 把选中图层的操作姿态记为当前进度处的关键帧。开屏动画段：
    /// 存帧后同步末帧 → 开屏摆位。解锁动画段：进度在两端时直接
    /// 改对应摆位（端点共用数据），中间才存中间帧。
    func stampKeyframe() {
        guard segment.isAnimation, let layer = selectedLayer else { return }
        let pose = workingPose(for: layer)
        let progress = segmentProgress
        switch segment {
        case .entrance:
            updateSelected { l in
                l.entranceKeyframes.removeAll { abs($0.progress - progress) < keyframeEpsilon }
                l.entranceKeyframes.append(LayerKeyframe(progress: progress, pose: pose))
                l.entranceKeyframes.sort { $0.progress < $1.progress }
                Self.syncLockedLayoutToEntranceEnd(&l)
            }
        case .unlockAnim:
            if progress <= keyframeEpsilon {
                updateSelected { l in
                    l.lockedLayout = pose.asLayout
                    Self.syncEntranceEndToLayout(&l)
                }
            } else if progress >= 1 - keyframeEpsilon {
                updateSelected { l in l.unlockLayout = pose.asLayout }
            } else {
                updateSelected { l in
                    l.unlockKeyframes.removeAll { abs($0.progress - progress) < keyframeEpsilon }
                    l.unlockKeyframes.append(LayerKeyframe(progress: progress, pose: pose))
                    l.unlockKeyframes.sort { $0.progress < $1.progress }
                }
            }
        case .lockedLoop, .unlockLoop:
            break
        }
        if let updated = selectedLayer {
            workingPoseContext = WorkingPoseContext(
                layerID: updated.id, segment: segment, pose: workingPose(for: updated))
        }
    }

    /// 删除轨道上选中的关键帧（开屏段删后末帧同步回摆位）。
    func deleteSelectedKeyframe() {
        guard let sel = selectedKeyframe,
              var layer = project.layer(id: sel.layerID) else { return }
        switch sel.segment {
        case .entrance:
            layer.entranceKeyframes.removeAll { $0.id == sel.keyframeID }
            Self.syncLockedLayoutToEntranceEnd(&layer)
        case .unlockAnim:
            layer.unlockKeyframes.removeAll { $0.id == sel.keyframeID }
        case .lockedLoop, .unlockLoop:
            break
        }
        project.updateLayer(layer)
        selectedKeyframe = nil
        clearWorkingPose()
    }

    /// 当前进度附近（±1%）是否已有该图层的关键帧（面板删除入口）。
    func keyframeNearPlayhead(of layer: EditorLayer) -> LayerKeyframe? {
        guard segment.isAnimation else { return nil }
        let list = segment == .entrance ? layer.entranceKeyframes : layer.unlockKeyframes
        return list.first { abs($0.progress - segmentProgress) < 0.01 }
    }

    func deleteKeyframeNearPlayhead() {
        guard let layer = selectedLayer,
              let kf = keyframeNearPlayhead(of: layer) else { return }
        selectedKeyframe = KeyframeSelection(layerID: layer.id, segment: segment, keyframeID: kf.id)
        deleteSelectedKeyframe()
    }

    /// 末帧 → 开屏摆位（开屏动画段终点与开屏摆位同一份数据）。
    static func syncLockedLayoutToEntranceEnd(_ layer: inout EditorLayer) {
        guard let last = layer.entranceKeyframes.max(by: { $0.progress < $1.progress }) else { return }
        layer.lockedLayout = last.pose.asLayout
    }

    /// 开屏摆位 → 末帧（在循环段改了开屏摆位，末帧跟上；保留末帧
    /// 自己的旋转/层级）。
    static func syncEntranceEndToLayout(_ layer: inout EditorLayer) {
        guard let idx = layer.entranceKeyframes.indices
            .max(by: { layer.entranceKeyframes[$0].progress < layer.entranceKeyframes[$1].progress })
        else { return }
        var pose = layer.entranceKeyframes[idx].pose
        pose.center = layer.lockedLayout.center
        pose.size = layer.lockedLayout.size
        pose.opacity = layer.lockedLayout.opacity
        layer.entranceKeyframes[idx].pose = pose
    }

    /// 导出时该图层的层级端点值：开屏轨迹末帧优先，其次解锁轨迹
    /// 末个中间帧，都没有 = 0（ClipExporter 写 CALayer zPosition）。
    static func exportZIndex(of layer: EditorLayer) -> Int {
        if let last = layer.entranceKeyframes.max(by: { $0.progress < $1.progress }) {
            return last.pose.zIndex
        }
        if let last = layer.unlockKeyframes.max(by: { $0.progress < $1.progress }) {
            return last.pose.zIndex
        }
        return 0
    }

    // MARK: 状态摆位（循环段与轨迹端点共用）

    /// 某部分下图层应呈现的摆位。背景特殊：两张都设时，每张只在
    /// 自己那一部分可见（另一部分透明度 0，摆位取自己那套）；
    /// 只设一张时共用，按各部分自己的摆位（老行为）。
    func displayLayout(of layer: EditorLayer, for tab: PartTab) -> LayerLayout {
        if let slot = project.backgroundSlot(of: layer), project.hasBothBackgrounds {
            var layout = layer.layout(for: slot)
            if tab != slot { layout.opacity = 0 }
            return layout
        }
        return layer.layout(for: tab)
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

    /// 淡入淡出在当前帧的乘子（clip 两头拖出的帧数；仅循环段，
    /// 动画段的透明度由轨迹管）。
    func fadeMultiplier(of layer: EditorLayer) -> Double {
        guard !segment.isAnimation else { return 1 }
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
        canvasPose(of: layer).opacity * fadeMultiplier(of: layer)
    }

    /// 模板总偏移（预览用；仅循环段——动画段画面由轨迹驱动，
    /// 模板不叠加，免得两套动画抢同一属性）。
    func motionOffset(of layer: EditorLayer) -> MotionOffset {
        guard !segment.isAnimation else { return .identity }
        return MotionMath.combinedOffset(action: layer.actionMotion,
                                         transform: layer.transformMotion,
                                         loopPhase: loopPhase())
    }

    // MARK: 选中

    var selectedLayer: EditorLayer? {
        selectedLayerID.flatMap { project.layer(id: $0) }
    }

    func select(_ id: UUID?) {
        selectedLayerID = id
        if id != workingPoseContext?.layerID { clearWorkingPose() }
    }

    func updateSelected(_ mutate: (inout EditorLayer) -> Void) {
        guard var layer = selectedLayer else { return }
        let beforeLocked = layer.lockedLayout
        mutate(&layer)
        // 在循环段改了开屏摆位 → 开屏动画段末帧跟上（同一份数据）。
        if layer.lockedLayout != beforeLocked {
            Self.syncEntranceEndToLayout(&layer)
        }
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
        segment = part == .locked ? .lockedLoop : .unlockLoop
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
        if selectedKeyframe?.layerID == id { selectedKeyframe = nil }
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
            exportNote = "动画时长按过渡速度重算（开屏入场 \(project.entrance.frames) 帧 / 解锁 \(project.transitionFrames) 帧）；解锁动画的中间关键帧暂只在预览生效。"
            exportOutcome = .success(url)
        } catch {
            exportOutcome = .failure("导出失败：\(error.localizedDescription)")
        }
    }
}

import SwiftUI
import UIKit

// MARK: - 时间轴（v3 四段式：一条线从左到右）
//
// 结构：段头行（开屏动画｜开屏｜解锁动画｜主屏，动画段用暖色
// 区分，点段头 = 播放头跳到该段）/ 刻度尺 / 背景轨 / 每浮动图层
// 一行 / 前景行 / 「+ 添加图层」灰行。播放头固定正中，整条线横移
// scrub（统一坐标 = 编辑秒：动画段按编辑尺长度、循环段按循环
// 时长）。动画段是实实在在的段：段内在图层行上以菱形标关键帧，
// 点菱形选中该帧（可删），点背景轨的动画段块打开该段设置
// （开屏动画段 → 开屏入场设置、解锁动画段 → 解锁过渡设置）。
// 淡入/淡出手柄保留：淡入在「开屏」段左缘、淡出在「主屏」段右缘。
struct ClipTimelineView: View {
    @ObservedObject var vm: EditorViewModel
    var onAddLayer: () -> Void
    var onOpenLayers: () -> Void
    var onOpenTransition: () -> Void
    var onOpenEntrance: () -> Void

    private let labelWidth: CGFloat = 38
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 4
    private let headerHeight: CGFloat = 20
    private let rulerHeight: CGFloat = 16
    private let maxFloatingRows = 5
    private let accent = Color(red: 0, green: 0.44, blue: 0.89)
    /// 动画段底色（暖色，与循环段区分）。
    private let animFill = Color(red: 1, green: 0.85, blue: 0.62)
    private let animFillSelected = Color(red: 1, green: 0.72, blue: 0.38)

    @State private var scrubStartSeconds: Double?
    @State private var fadeDragLayerID: UUID?
    @State private var fadeDragIsIn = true
    @State private var fadeDragStart = 0
    @State private var lockedThumb: UIImage?
    @State private var unlockThumb: UIImage?

    static func height(floatingCount: Int, foregroundCount: Int) -> CGFloat {
        let rows = 1 + min(floatingCount, 5) + foregroundCount + 1 // 背景 + 浮动 + 前景 + 添加
        return 20 + 16 + CGFloat(rows) * 30 + 10
    }

    private var visibleFloating: ArraySlice<EditorLayer> {
        vm.project.floating.prefix(maxFloatingRows)
    }

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width - labelWidth
            // 整条线约 1.7 倍轨宽，段内有排帧的余地。
            let ppf = trackWidth * 1.7 / CGFloat(max(vm.project.timelineTotalSeconds, 0.01))
            let centerX = labelWidth + trackWidth / 2

            ZStack(alignment: .topLeading) {
                VStack(spacing: rowSpacing) {
                    segmentHeader(trackWidth: trackWidth, ppf: ppf)
                    ruler(trackWidth: trackWidth, ppf: ppf)
                    backgroundRow(trackWidth: trackWidth, ppf: ppf)
                    ForEach(Array(visibleFloating)) { layer in
                        layerRow(layer: layer, trackWidth: trackWidth, ppf: ppf)
                    }
                    if vm.project.floating.count > maxFloatingRows {
                        Button(action: onOpenLayers) {
                            Text("还有 \(vm.project.floating.count - maxFloatingRows) 个图层，在「图层」页看全部")
                                .font(.system(size: 11))
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: 16)
                    }
                    ForEach(vm.project.foreground) { layer in
                        layerRow(layer: layer, trackWidth: trackWidth, ppf: ppf)
                    }
                    if vm.project.foreground.isEmpty {
                        HStack(spacing: 0) {
                            rowLabel("前景")
                            Text("（空）文字、扫光放这里")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.62))
                                .frame(width: trackWidth, height: rowHeight, alignment: .leading)
                        }
                    }
                    addRow
                }
                .padding(.horizontal, 2)

                // 固定播放头 + 时间码（段内本地时间）
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 2)
                    .offset(x: centerX - 1)
                    .allowsHitTesting(false)
                Text(timecode(frame: vm.segmentLocalFrame))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
                    .position(x: centerX, y: 9)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(ppf: ppf))
        }
        .onAppear { refreshThumbs() }
        .onChange(of: vm.project.backgroundLocked?.id) { _ in refreshThumbs() }
        .onChange(of: vm.project.backgroundUnlock?.id) { _ in refreshThumbs() }
    }

    // MARK: 几何（绝对编辑秒 → 轨内 x）

    private func blockX(_ seg: TimelineSegment, ppf: CGFloat) -> CGFloat {
        CGFloat(vm.project.segmentStart(seg)) * ppf - CGFloat(vm.playheadSeconds) * ppf
    }

    private func blockW(_ seg: TimelineSegment, ppf: CGFloat) -> CGFloat {
        CGFloat(vm.project.segmentDuration(seg)) * ppf
    }

    /// 一段的块面（在行 ZStack 内绝对定位，两侧各留 1.5pt 缝）。
    @ViewBuilder
    private func segmentBlock<Content: View>(_ seg: TimelineSegment, ppf: CGFloat,
                                             height: CGFloat? = nil,
                                             @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: max(blockW(seg, ppf: ppf) - 3, 8), height: height ?? (rowHeight - 4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .offset(x: blockX(seg, ppf: ppf) + 1.5)
    }

    // MARK: scrub

    private func scrubGesture(ppf: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if scrubStartSeconds == nil {
                    scrubStartSeconds = vm.playheadSeconds
                    vm.isScrubbing = true
                }
                let delta = Double(value.translation.width / ppf)
                vm.setPlayhead(seconds: (scrubStartSeconds ?? 0) - delta)
            }
            .onEnded { _ in
                scrubStartSeconds = nil
                vm.isScrubbing = false
            }
    }

    // MARK: 段头行（点段头跳段；动画段暖色）

    private func segmentHeader(trackWidth: CGFloat, ppf: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: labelWidth)
            ZStack(alignment: .leading) {
                ForEach(TimelineSegment.allCases) { seg in
                    let current = vm.segment == seg
                    segmentBlock(seg, ppf: ppf, height: headerHeight - 2) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(seg.isAnimation
                                      ? animFill.opacity(current ? 0.95 : 0.55)
                                      : Color(white: current ? 0.86 : 0.94))
                            Text(seg.displayName)
                                .font(.system(size: 10.5, weight: current ? .bold : .medium))
                                .foregroundStyle(current ? Color(white: 0.1) : Color(white: 0.45))
                                .lineLimit(1)
                        }
                    }
                    .onTapGesture { vm.jumpToSegment(seg) }
                }
            }
            .frame(width: trackWidth, height: headerHeight)
            .clipped()
        }
        .frame(height: headerHeight)
    }

    // MARK: 刻度尺（整条线，1 秒一格）

    private func ruler(trackWidth: CGFloat, ppf: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: labelWidth)
            Canvas { context, size in
                let total = vm.project.timelineTotalSeconds
                var sec = 0
                while Double(sec) <= total {
                    let x = CGFloat(sec) * ppf - CGFloat(vm.playheadSeconds) * ppf
                    if x >= -20 && x <= size.width + 20 {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height - 5))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                        let label = Text("\(sec)s")
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                        context.draw(context.resolve(label),
                                     at: CGPoint(x: x, y: 4), anchor: .center)
                    }
                    sec += 1
                }
            }
            .frame(width: trackWidth, height: rulerHeight)
        }
        .frame(height: rulerHeight)
    }

    // MARK: 背景行（四段各一块）

    private func backgroundRow(trackWidth: CGFloat, ppf: CGFloat) -> some View {
        HStack(spacing: 0) {
            rowLabel("背景")
            ZStack(alignment: .leading) {
                // 开屏动画段：开屏背景缩略，点开 = 开屏入场设置
                segmentBlock(.entrance, ppf: ppf) {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 6).fill(animFill.opacity(0.5))
                        if let thumb = lockedThumb {
                            Image(uiImage: thumb).resizable().scaledToFill().opacity(0.75)
                        }
                        Text("开屏入场设置 ▸")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(white: 0.25))
                            .padding(.leading, 5).padding(.bottom, 2.5)
                    }
                }
                .onTapGesture { onOpenEntrance() }

                // 开屏循环段：开屏背景
                segmentBlock(.lockedLoop, ppf: ppf) {
                    backgroundThumbContent(part: .locked)
                }
                .onTapGesture { selectBackground(part: .locked) }

                // 解锁动画段：过渡标记，点开 = 解锁过渡设置
                segmentBlock(.unlockAnim, ppf: ppf) {
                    ZStack {
                        LinearGradient(
                            colors: [Color(red: 0.98, green: 0.75, blue: 0.45),
                                     Color(red: 0, green: 0.44, blue: 0.89)],
                            startPoint: .leading, endPoint: .trailing)
                        Text("\(vm.project.transitionKind.displayName) \(vm.project.transitionFrames)帧")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .onTapGesture { onOpenTransition() }

                // 主屏循环段：主屏背景
                segmentBlock(.unlockLoop, ppf: ppf) {
                    backgroundThumbContent(part: .unlock)
                }
                .onTapGesture { selectBackground(part: .unlock) }

                // 背景层的关键帧菱形（两张背景共用这一行）
                ForEach(vm.project.layers(in: .background)) { layer in
                    ForEach(layer.entranceKeyframes) { kf in
                        keyframeDiamond(layer: layer, seg: .entrance, kf: kf, ppf: ppf)
                    }
                    ForEach(layer.unlockKeyframes) { kf in
                        keyframeDiamond(layer: layer, seg: .unlockAnim, kf: kf, ppf: ppf)
                    }
                }
            }
            .frame(width: trackWidth, height: rowHeight)
            .clipped()
        }
    }

    /// 一侧背景的缩略内容（自己设的优先，没设则共用另一侧并标注）。
    private func backgroundThumbContent(part: PartTab) -> some View {
        let own = part == .locked ? vm.project.backgroundLocked : vm.project.backgroundUnlock
        let other = part == .locked ? vm.project.backgroundUnlock : vm.project.backgroundLocked
        let shown = own ?? other
        let shared = own == nil && other != nil
        let thumb = part == .locked ? lockedThumb : unlockThumb
        let selected = shown != nil && vm.selectedLayerID == shown?.id
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.94))
            if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .opacity(shared ? 0.45 : 1)
            }
            Text(segmentCaption(part: part, shared: shared, hasImage: shown != nil))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(shown != nil ? .white : Color(white: 0.55))
                .shadow(color: shown != nil ? .black.opacity(0.45) : .clear, radius: 2, y: 1)
                .lineLimit(1)
                .padding(.leading, 5)
                .padding(.bottom, 2.5)
            if selected {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(accent, lineWidth: 1.4)
            }
        }
    }

    private func selectBackground(part: PartTab) {
        let own = part == .locked ? vm.project.backgroundLocked : vm.project.backgroundUnlock
        let other = part == .locked ? vm.project.backgroundUnlock : vm.project.backgroundLocked
        if let shown = own ?? other { vm.select(shown.id) }
    }

    private func segmentCaption(part: PartTab, shared: Bool, hasImage: Bool) -> String {
        if !hasImage { return part == .locked ? "开屏背景 · 未设" : "主屏背景 · 未设" }
        if shared { return part == .locked ? "与主屏共用" : "与开屏共用" }
        return part == .locked ? "开屏背景" : "主屏背景"
    }

    private func refreshThumbs() {
        lockedThumb = Self.thumb(of: vm.project.backgroundLocked ?? vm.project.backgroundUnlock)
        unlockThumb = Self.thumb(of: vm.project.backgroundUnlock ?? vm.project.backgroundLocked)
    }

    private static func thumb(of layer: EditorLayer?) -> UIImage? {
        guard let layer, case .photo(let data, _) = layer.content else { return nil }
        return UIImage(data: data)
    }

    // MARK: 图层行（浮动 / 前景共用：四段块 + 关键帧菱形 + 淡入淡出手柄）

    private func layerRow(layer: EditorLayer, trackWidth: CGFloat, ppf: CGFloat) -> some View {
        let selected = vm.selectedLayerID == layer.id
        return HStack(spacing: 0) {
            rowLabel(layer.name)
            ZStack(alignment: .leading) {
                // 开屏动画段块（暖色）
                segmentBlock(.entrance, ppf: ppf) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? animFillSelected.opacity(0.75) : animFill.opacity(0.45))
                }
                // 开屏循环段块（clip 本体 + 名称 + 淡入楔形）
                segmentBlock(.lockedLoop, ppf: ppf) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color(red: 0.85, green: 0.91, blue: 1) : Color(white: 0.93))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(selected ? accent : .clear, lineWidth: 1.4))
                        if layer.fadeInFrames > 0 {
                            LinearGradient(colors: [.black.opacity(0.22), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: CGFloat(layer.fadeInFrames) / 60 * ppf)
                        }
                        Text(layer.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(white: 0.25))
                            .lineLimit(1)
                            .padding(.leading, 8)
                    }
                }
                .onTapGesture { vm.select(layer.id) }
                // 解锁动画段块（暖→蓝渐变示意交接）
                segmentBlock(.unlockAnim, ppf: ppf) {
                    LinearGradient(
                        colors: [animFill.opacity(selected ? 0.95 : 0.6),
                                 Color(red: 0.62, green: 0.74, blue: 0.92).opacity(selected ? 0.95 : 0.6)],
                        startPoint: .leading, endPoint: .trailing)
                }
                // 主屏循环段块（+ 淡出楔形）
                segmentBlock(.unlockLoop, ppf: ppf) {
                    ZStack(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color(red: 0.85, green: 0.91, blue: 1) : Color(white: 0.93))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(selected ? accent : .clear, lineWidth: 1.4))
                        if layer.fadeOutFrames > 0 {
                            LinearGradient(colors: [.clear, .black.opacity(0.22)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: CGFloat(layer.fadeOutFrames) / 60 * ppf)
                        }
                    }
                }
                .onTapGesture { vm.select(layer.id) }

                // 关键帧菱形（两个动画段）
                ForEach(layer.entranceKeyframes) { kf in
                    keyframeDiamond(layer: layer, seg: .entrance, kf: kf, ppf: ppf)
                }
                ForEach(layer.unlockKeyframes) { kf in
                    keyframeDiamond(layer: layer, seg: .unlockAnim, kf: kf, ppf: ppf)
                }

                // 淡入手柄（开屏段左缘）/ 淡出手柄（主屏段右缘）
                fadeHandle(layer: layer, isIn: true, ppf: ppf)
                    .offset(x: blockX(.lockedLoop, ppf: ppf) - 2)
                fadeHandle(layer: layer, isIn: false, ppf: ppf)
                    .offset(x: blockX(.unlockLoop, ppf: ppf) + blockW(.unlockLoop, ppf: ppf) - 16)
            }
            .frame(width: trackWidth, height: rowHeight)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { vm.select(layer.id) }
        }
    }

    private func keyframeDiamond(layer: EditorLayer, seg: TimelineSegment,
                                 kf: LayerKeyframe, ppf: CGFloat) -> some View {
        let x = blockX(seg, ppf: ppf) + CGFloat(kf.progress) * blockW(seg, ppf: ppf)
        let isSelected = vm.selectedKeyframe?.keyframeID == kf.id
        return Rectangle()
            .fill(isSelected ? accent : Color(white: 0.3))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(45))
            .overlay(
                Rectangle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(45)))
            .position(x: x, y: rowHeight / 2)
            .onTapGesture {
                vm.setPlayhead(seconds: vm.project.segmentStart(seg)
                               + kf.progress * vm.project.segmentDuration(seg))
                vm.select(layer.id)
                vm.selectedKeyframe = EditorViewModel.KeyframeSelection(
                    layerID: layer.id, segment: seg, keyframeID: kf.id)
                vm.isPlaying = false
            }
    }

    private func fadeHandle(layer: EditorLayer, isIn: Bool, ppf: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 18, height: rowHeight - 4)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 3.5, height: 12))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if fadeDragLayerID != layer.id {
                            fadeDragLayerID = layer.id
                            fadeDragIsIn = isIn
                            fadeDragStart = isIn ? layer.fadeInFrames : layer.fadeOutFrames
                            vm.select(layer.id)
                        }
                        // ppf 是 pt/秒，1 帧 = ppf/60 pt
                        let deltaFrames = Int((value.translation.width * 60 / ppf).rounded())
                        let delta = fadeDragIsIn ? deltaFrames : -deltaFrames
                        let newValue = min(max(fadeDragStart + delta, 0), 120)
                        vm.updateSelected { l in
                            if fadeDragIsIn { l.fadeInFrames = newValue } else { l.fadeOutFrames = newValue }
                        }
                    }
                    .onEnded { _ in fadeDragLayerID = nil })
    }

    // MARK: 添加行 / 行标签

    private var addRow: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: labelWidth)
            Button(action: onAddLayer) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("添加图层")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.55))
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight - 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(white: 0.82), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Color(white: 0.5))
            .lineLimit(1)
            .frame(width: labelWidth, alignment: .center)
    }
}

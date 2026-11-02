import SwiftUI
import UIKit

// MARK: - 时间轴（Blurrr 式：播放头固定正中，拖轨道 scrub）
//
// 结构自上而下：刻度尺（秒）/ 背景轨 / 每浮动图层一行 clip /
// 前景行 / 「+ 添加图层」灰行。浮动 clip 按当前帧横向偏移，循环
// 拷贝 ×3（前/当/后）保证拖过回环点不露白。clip 恒跨整个循环
// （图层一直在），两头手柄拖动 = 淡入/淡出帧数。
// 背景轨 v2 改三段横排（不随 scrub 滚动，是状态示意）：
// [开屏背景 clip][过渡段][主屏背景 clip]，过渡段宽度按过渡帧数
// 占循环的比例示意，点它打开「解锁过渡」编辑。
// 刻度与时间码按 60fps 口径：mm:ss:ff。
struct ClipTimelineView: View {
    @ObservedObject var vm: EditorViewModel
    var onAddLayer: () -> Void
    var onOpenLayers: () -> Void
    var onOpenTransition: () -> Void

    private let labelWidth: CGFloat = 38
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 4
    private let rulerHeight: CGFloat = 22
    private let maxFloatingRows = 5

    @State private var scrubStartFrame: Double?
    @State private var fadeDragLayerID: UUID?
    @State private var fadeDragIsIn = true
    @State private var fadeDragStart = 0
    @State private var lockedThumb: UIImage?
    @State private var unlockThumb: UIImage?

    static func height(floatingCount: Int) -> CGFloat {
        let rows = 1 + min(floatingCount, 5) + 1 + 1 // 背景 + 浮动 + 前景 + 添加
        return 22 + CGFloat(rows) * 30 + 8
    }

    private var visibleFloating: ArraySlice<EditorLayer> {
        vm.project.floating.prefix(maxFloatingRows)
    }

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width - labelWidth
            let ppf = trackWidth / CGFloat(vm.project.loopFrames)
            let centerX = labelWidth + trackWidth / 2

            ZStack(alignment: .topLeading) {
                VStack(spacing: rowSpacing) {
                    ruler(trackWidth: trackWidth, ppf: ppf)
                    backgroundRow(trackWidth: trackWidth)
                    ForEach(Array(visibleFloating)) { layer in
                        clipRow(layer: layer, trackWidth: trackWidth, ppf: ppf)
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
                    foregroundRow(trackWidth: trackWidth)
                    addRow
                }
                .padding(.horizontal, 2)

                // 固定播放头 + 时间码
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 2)
                    .offset(x: centerX - 1)
                    .allowsHitTesting(false)
                Text(timecode(frame: vm.currentFrame))
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

    // MARK: scrub

    private func scrubGesture(ppf: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if scrubStartFrame == nil {
                    scrubStartFrame = vm.currentFrame
                    vm.isScrubbing = true
                }
                let delta = Double(value.translation.width / ppf)
                var f = (scrubStartFrame ?? 0) - delta
                let lf = Double(vm.project.loopFrames)
                f = f.truncatingRemainder(dividingBy: lf)
                if f < 0 { f += lf }
                vm.currentFrame = f
            }
            .onEnded { _ in
                scrubStartFrame = nil
                vm.isScrubbing = false
            }
    }

    // MARK: 刻度尺

    private func ruler(trackWidth: CGFloat, ppf: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: labelWidth)
            Canvas { context, size in
                let lf = Double(vm.project.loopFrames)
                let center = size.width / 2
                for copy in -1...1 {
                    var sec = 0
                    while Double(sec) * 60 <= lf {
                        let frame = Double(copy) * lf + Double(sec) * 60
                        let x = center + (frame - vm.currentFrame) * Double(ppf)
                        if x >= -20 && x <= size.width + 20 {
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: size.height - 6))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                            let label = Text("\(sec)s")
                                .font(.system(size: 9))
                                .foregroundColor(.gray)
                            context.draw(context.resolve(label),
                                         at: CGPoint(x: x, y: 5), anchor: .center)
                        }
                        sec += 1
                    }
                }
            }
            .frame(width: trackWidth, height: rulerHeight)
        }
        .frame(height: rulerHeight)
    }

    // MARK: 背景行（三段：开屏 clip + 过渡段 + 主屏 clip）

    private func backgroundRow(trackWidth: CGFloat) -> some View {
        // 过渡段宽度按过渡帧数占循环时长的比例示意（夹在 58pt 与
        // 整轨 42% 之间，保证标注文字放得下）。
        let proportion = CGFloat(vm.project.transitionFrames) / CGFloat(vm.project.loopFrames)
        let transitionW = min(max(trackWidth * proportion, 58), trackWidth * 0.42)
        let sideW = max((trackWidth - transitionW - 6) / 2, 10)
        return HStack(spacing: 0) {
            rowLabel("背景")
            HStack(spacing: 3) {
                backgroundSegment(part: .locked, width: sideW)
                transitionSegment(width: transitionW)
                backgroundSegment(part: .unlock, width: sideW)
            }
            .frame(width: trackWidth, height: rowHeight)
        }
    }

    /// 一侧背景 clip：显示该部分实际生效的背景（自己设的优先，
    /// 没设则共用另一侧那张并标注）。点按选中对应图层。
    private func backgroundSegment(part: PartTab, width: CGFloat) -> some View {
        let own = part == .locked ? vm.project.backgroundLocked : vm.project.backgroundUnlock
        let other = part == .locked ? vm.project.backgroundUnlock : vm.project.backgroundLocked
        let shown = own ?? other
        let shared = own == nil && other != nil
        let thumb = part == .locked ? lockedThumb : unlockThumb
        let selected = shown != nil && vm.selectedLayerID == shown?.id
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.94))
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
        }
        .frame(width: width, height: rowHeight - 4)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color(red: 0, green: 0.44, blue: 0.89) : .clear, lineWidth: 1.4))
        .contentShape(Rectangle())
        .onTapGesture {
            if let shown { vm.select(shown.id) }
        }
    }

    private func segmentCaption(part: PartTab, shared: Bool, hasImage: Bool) -> String {
        if !hasImage { return part == .locked ? "开屏背景 · 未设" : "主屏背景 · 未设" }
        if shared { return part == .locked ? "与主屏共用" : "与开屏共用" }
        return part == .locked ? "开屏背景" : "主屏背景"
    }

    /// 中间过渡段：渐变条 + 「类型 N帧」标注，点按打开过渡编辑。
    private func transitionSegment(width: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.62, green: 0.74, blue: 0.92),
                         Color(red: 0, green: 0.44, blue: 0.89)],
                startPoint: .leading, endPoint: .trailing)
            Text("\(vm.project.transitionKind.displayName) \(vm.project.transitionFrames)帧")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(width: width, height: rowHeight - 4)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onOpenTransition() }
    }

    private func refreshThumbs() {
        lockedThumb = Self.thumb(of: vm.project.backgroundLocked ?? vm.project.backgroundUnlock)
        unlockThumb = Self.thumb(of: vm.project.backgroundUnlock ?? vm.project.backgroundLocked)
    }

    private static func thumb(of layer: EditorLayer?) -> UIImage? {
        guard let layer, case .photo(let data, _) = layer.content else { return nil }
        return UIImage(data: data)
    }

    // MARK: 浮动图层 clip 行

    private func clipRow(layer: EditorLayer, trackWidth: CGFloat, ppf: CGFloat) -> some View {
        let selected = vm.selectedLayerID == layer.id
        return HStack(spacing: 0) {
            rowLabel(layer.name)
            ZStack(alignment: .leading) {
                ForEach(-1...1, id: \.self) { copy in
                    clipBar(layer: layer, selected: selected, trackWidth: trackWidth, ppf: ppf)
                        .offset(x: (CGFloat(copy) * CGFloat(vm.project.loopFrames) - CGFloat(vm.currentFrame)) * ppf)
                }
            }
            .frame(width: trackWidth, height: rowHeight)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { vm.select(layer.id) }
        }
    }

    private func clipBar(layer: EditorLayer, selected: Bool, trackWidth: CGFloat, ppf: CGFloat) -> some View {
        let fadeInW = CGFloat(layer.fadeInFrames) * ppf
        let fadeOutW = CGFloat(layer.fadeOutFrames) * ppf
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color(red: 0.85, green: 0.91, blue: 1) : Color(white: 0.93))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Color(red: 0, green: 0.44, blue: 0.89) : .clear, lineWidth: 1.4))

            // 淡入淡出楔形（深色斜块示意）
            if layer.fadeInFrames > 0 {
                LinearGradient(colors: [.black.opacity(0.22), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeInW)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if layer.fadeOutFrames > 0 {
                HStack {
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.22)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: fadeOutW)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Text(layer.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(white: 0.25))
                .lineLimit(1)
                .padding(.leading, max(fadeInW + 6, 8))

            // 两头手柄（命中区 ≥16pt，拖动改淡入/淡出帧数）
            HStack {
                fadeHandle(layer: layer, isIn: true, ppf: ppf)
                Spacer()
                fadeHandle(layer: layer, isIn: false, ppf: ppf)
            }
        }
        .frame(width: trackWidth, height: rowHeight - 4)
    }

    private func fadeHandle(layer: EditorLayer, isIn: Bool, ppf: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 18, height: rowHeight - 4)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 3.5, height: 12)
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if fadeDragLayerID != layer.id {
                            fadeDragLayerID = layer.id
                            fadeDragIsIn = isIn
                            fadeDragStart = isIn ? layer.fadeInFrames : layer.fadeOutFrames
                            vm.select(layer.id)
                        }
                        let deltaFrames = Int((value.translation.width / ppf).rounded())
                        let delta = fadeDragIsIn ? deltaFrames : -deltaFrames
                        let newValue = min(max(fadeDragStart + delta, 0), 120)
                        vm.updateSelected { l in
                            if fadeDragIsIn { l.fadeInFrames = newValue } else { l.fadeOutFrames = newValue }
                        }
                    }
                    .onEnded { _ in fadeDragLayerID = nil }
            )
    }

    // MARK: 前景行（全部前景图层并排成段）

    private func foregroundRow(trackWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            rowLabel("前景")
            if vm.project.foreground.isEmpty {
                Text("（空）文字、扫光放这里")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.62))
                    .frame(width: trackWidth, height: rowHeight, alignment: .leading)
            } else {
                HStack(spacing: 3) {
                    ForEach(vm.project.foreground) { layer in
                        let selected = vm.selectedLayerID == layer.id
                        Text(layer.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(Color(white: 0.25))
                            .frame(maxWidth: .infinity)
                            .frame(height: rowHeight - 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? Color(red: 0.85, green: 0.91, blue: 1) : Color(white: 0.93))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(selected ? Color(red: 0, green: 0.44, blue: 0.89) : .clear, lineWidth: 1.4)))
                            .onTapGesture { vm.select(layer.id) }
                    }
                }
                .frame(width: trackWidth, height: rowHeight)
            }
        }
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

import SwiftUI
import UIKit

// MARK: - 锁屏手机框预览画布
//
// 画布逻辑尺寸恒为 390×844（与导出 1:1），按 scale 缩小显示；
// 所有子视图位置/尺寸手动乘 scale，拖动手势的 translation 是
// 屏幕点，除以 scale 还原成画布点写回模型（不使用 scaleEffect，
// 避免手势坐标空间随版本变化）。
// 循环段：图层按状态摆位 + MotionMath 模板偏移播放；动画段：
// 图层按关键帧轨迹姿态渲染（EditorViewModel.canvasPose），拖动
// 改操作姿态、打帧后成为关键帧。
// 锁屏系统占位（时间/日期同行同基线 + 时钟下三组件行）画在最上层、
// 不可交互——沿用 Sage 的锁屏规格：日期与时间同行同基线、
// 左电量条 82%、中圆环 51%、右 Q 版人物、冰蓝白半透明。
struct CanvasView: View {
    @ObservedObject var vm: EditorViewModel
    /// 显示高度（pt）；scale = 高度 / 844。
    var displayHeight: CGFloat = 308

    private var scale: CGFloat { displayHeight / 844 }
    private var displayWidth: CGFloat { 390 * scale }

    @State private var dragLayerID: UUID?
    @State private var dragStartCenter: CGPoint = .zero
    @State private var dragStartPose: LayerPose?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 画布底（无背景图时的占位）
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.82)],
                                     startPoint: .top, endPoint: .bottom))
            if !vm.project.hasAnyBackground {
                Text("点底部「素材」选背景图")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .frame(width: displayWidth, height: displayHeight)
            }

            // 壁纸图层（底→顶；动画段按姿态层级排序）
            ForEach(vm.canvasLayersOrdered()) { layer in
                layerView(layer)
            }

            // 锁屏系统占位（最上层，不拦截手势）
            lockScreenChrome
                .allowsHitTesting(false)
        }
        .frame(width: displayWidth, height: displayHeight)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { vm.select(nil) }
    }

    // MARK: 单图层

    @ViewBuilder
    private func layerView(_ layer: EditorLayer) -> some View {
        let pose = vm.canvasPose(of: layer)
        let offset = vm.motionOffset(of: layer)
        let s = scale
        // CAML translation.y 正 = 上 → 屏幕 y 取负；rotation.z 同理取负
        // （姿态旋转与模板旋转同为 CAML 语义，相加后一起取负）。
        let cx = (pose.center.x + CGFloat(offset.translationX)) * s
        let cy = (pose.center.y - CGFloat(offset.translationY)) * s
        let w = pose.size.width * CGFloat(offset.scale) * s
        let h = pose.size.height * CGFloat(offset.scale) * s
        let selected = vm.selectedLayerID == layer.id
        // 双背景时另一部分的那张在当前上下文不可见，禁手势防误拖。
        let hidden = vm.isLayerHiddenInCurrentContext(layer)
        let editTab = vm.editingTab(for: layer)
        let inAnimation = vm.segment.isAnimation

        layerContent(layer)
            .frame(width: max(w, 1), height: max(h, 1))
            .rotationEffect(.radians(-(offset.rotationZ + pose.rotation)))
            .opacity(vm.effectiveOpacity(of: layer))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color(red: 0, green: 0.44, blue: 0.89) : .clear,
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            .position(x: cx, y: cy)
            .allowsHitTesting(!hidden)
            .onTapGesture { vm.select(layer.id) }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragLayerID != layer.id {
                            dragLayerID = layer.id
                            vm.select(layer.id)
                            if inAnimation {
                                dragStartPose = vm.workingPose(for: layer)
                            } else {
                                dragStartCenter = vm.project.layer(id: layer.id)?
                                    .layout(for: editTab).center ?? pose.center
                            }
                        }
                        let dx = value.translation.width / s
                        let dy = value.translation.height / s
                        if inAnimation {
                            // 动画段：拖动改操作姿态（打帧后才成为关键帧）
                            let start = dragStartPose ?? pose
                            vm.updateWorkingPose(for: layer) { p in
                                p.center = CGPoint(
                                    x: min(max(start.center.x + dx, -100), 490),
                                    y: min(max(start.center.y + dy, -100), 944))
                            }
                        } else {
                            vm.updateSelected { l in
                                var target = l.layout(for: editTab)
                                target.center = CGPoint(
                                    x: min(max(dragStartCenter.x + dx, -100), 490),
                                    y: min(max(dragStartCenter.y + dy, -100), 944))
                                l.setLayout(target, for: editTab)
                            }
                        }
                    }
                    .onEnded { _ in
                        dragLayerID = nil
                        dragStartPose = nil
                    }
            )
    }

    @ViewBuilder
    private func layerContent(_ layer: EditorLayer) -> some View {
        switch layer.content {
        case .photo(let data, _):
            if let ui = Self.cachedImage(id: layer.id, data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        case .text(let string, let fontSize, let colorHex):
            Text(string)
                .font(.system(size: CGFloat(fontSize) * scale, weight: .bold))
                .foregroundStyle(Color(hex: colorHex))
                .lineLimit(1)
        case .sweep:
            Rectangle()
                .fill(LinearGradient(
                    colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                    startPoint: .leading, endPoint: .trailing))
                .rotationEffect(.degrees(-24))
                .blendMode(.screen)
        }
    }

    // MARK: 锁屏系统占位

    private var lockScreenChrome: some View {
        let s = scale
        return ZStack(alignment: .topLeading) {
            // 时间 + 日期：同行同基线
            HStack(alignment: .lastTextBaseline, spacing: 8 * s) {
                Text("5月20日周五")
                    .font(.system(size: 30 * s, weight: .semibold))
                Text("13:14")
                    .font(.system(size: 66 * s, weight: .bold))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            .position(x: 195 * s, y: 96 * s)

            // 时钟下三组件行：左电量条 82% / 中圆环 51% / 右 Q 版人物
            HStack(spacing: 26 * s) {
                // 电量条
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.35))
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: 96 * s * 0.82)
                }
                .frame(width: 96 * s, height: 17 * s)

                // 圆环 51%（内含小地球）
                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.51)
                        .stroke(Color.white.opacity(0.9),
                                style: StrokeStyle(lineWidth: 6.5 * s, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "globe")
                        .font(.system(size: 15 * s))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 37 * s, height: 37 * s)

                // Q 版人物占位
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 38 * s))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .position(x: 195 * s, y: 152 * s)

            // Home 指示条
            Capsule()
                .fill(Color.white.opacity(0.85))
                .frame(width: 134 * s, height: 5 * s)
                .position(x: 195 * s, y: 830 * s)
        }
        .frame(width: displayWidth, height: displayHeight)
    }

    // MARK: 图片解码缓存（30Hz 重绘时避免反复解码原图）

    private static let imageCache = NSCache<NSString, UIImage>()

    private static func cachedImage(id: UUID, data: Data) -> UIImage? {
        let key = "\(id.uuidString)-\(data.count)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }
}

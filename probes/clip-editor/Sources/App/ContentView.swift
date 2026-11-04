import SwiftUI
import PhotosUI

// MARK: - 主界面（布局参考 Blurrr 剪辑页）
//
// 自上而下：顶栏胶囊按钮（✕ / ? / 循环选择 / 蓝色导出钮）→
// 状态页签（开屏 / 主屏 + 预览过渡）→ 居中锁屏手机框预览 →
// 播放控制行 → 时间轴（播放头固定正中）→ 选中图层面板 →
// 底部大圆角卡片工具坞（素材/图层/动作/文字/特效/状态）。
// 白底、平面色块，不用液态玻璃；唯一强调色 #0071E3。
struct ContentView: View {
    @StateObject private var vm = EditorViewModel()

    @State private var showLockedBgPicker = false
    @State private var showUnlockBgPicker = false
    @State private var showFloatingPicker = false
    @State private var lockedBgSelection: PhotosPickerItem?
    @State private var unlockBgSelection: PhotosPickerItem?
    @State private var floatingSelection: [PhotosPickerItem] = []

    @State private var showMaterialMenu = false
    @State private var showLayerList = false
    @State private var showStateSettings = false
    @State private var showAddText = false
    @State private var showTransitionEditor = false
    @State private var showEntranceEditor = false
    @State private var showResetConfirm = false
    @State private var showAbout = false
    @State private var showPickLayerHint = false

    private let accent = Color(red: 0, green: 0.44, blue: 0.89) // #0071E3
    private let capsuleFill = Color(white: 0.949) // #F2F2F5

    var body: some View {
        VStack(spacing: 0) {
            topBar
            tabBar
            CanvasView(vm: vm, displayHeight: 300)
                .padding(.vertical, 8)
            controlsRow
            ClipTimelineView(vm: vm,
                             onAddLayer: { showMaterialMenu = true },
                             onOpenLayers: { showLayerList = true },
                             onOpenTransition: { showTransitionEditor = true },
                             onOpenEntrance: { showEntranceEditor = true })
                .frame(height: timelineHeight)
                .padding(.top, 4)
            SelectionPanelView(vm: vm)
                .padding(.top, 6)
            Spacer(minLength: 4)
            dock
        }
        .background(Color.white)
        // 素材导入
        .photosPicker(isPresented: $showLockedBgPicker, selection: $lockedBgSelection, matching: .images)
        .photosPicker(isPresented: $showUnlockBgPicker, selection: $unlockBgSelection, matching: .images)
        .photosPicker(isPresented: $showFloatingPicker, selection: $floatingSelection, matching: .images)
        .onChange(of: lockedBgSelection) { item in
            Task { await vm.importBackground(item: item, into: .locked); lockedBgSelection = nil }
        }
        .onChange(of: unlockBgSelection) { item in
            Task { await vm.importBackground(item: item, into: .unlock); unlockBgSelection = nil }
        }
        .onChange(of: floatingSelection) { items in
            Task { await vm.importFloating(items: items); floatingSelection = [] }
        }
        // 弹层
        .sheet(isPresented: $showLayerList) { LayerListView(vm: vm) }
        .sheet(isPresented: $showStateSettings) { StateSettingsView(vm: vm) }
        .sheet(isPresented: $showAddText) { AddTextView(vm: vm) }
        .sheet(isPresented: $showTransitionEditor) { TransitionEditorView(vm: vm) }
        .sheet(isPresented: $showEntranceEditor) { EntranceEditorView(vm: vm) }
        .sheet(item: $vm.exportOutcome) { outcome in exportSheet(outcome) }
        .confirmationDialog("添加素材", isPresented: $showMaterialMenu, titleVisibility: .visible) {
            Button("设为开屏背景") { showLockedBgPicker = true }
            Button("设为主屏背景") { showUnlockBgPicker = true }
            Button("添加浮动图（可多选）") { showFloatingPicker = true }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("清空当前工程重做？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("清空重做", role: .destructive) {
                vm.project = ClipProject()
                vm.select(nil)
                vm.currentFrame = 0
                vm.jumpToSegment(.lockedLoop)
                vm.isPlaying = true
            }
            Button("取消", role: .cancel) {}
        }
        .alert("剪辑制作探针", isPresented: $showAbout) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("把 .tendies 制作改成剪辑手感的探针：时间线一条线四段——开屏动画｜开屏｜解锁动画｜主屏。动画段里给图层打关键帧排运动轨迹（位置/缩放/旋转/透明度/层级），关键帧只定轨迹，导出时长按过渡速度重算；循环段摆位置挂模板。开屏/主屏各一张背景。导出按真包结构生成三状态 .tendies，去 CocoWall 刷入验证。熄屏部分导出时自动生成。")
        }
        .alert("先选一个图层", isPresented: $showPickLayerHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("在画布上或时间轴上点选一个图层，下面就会出现它的动作模板。")
        }
    }

    private var timelineHeight: CGFloat {
        ClipTimelineView.height(floatingCount: vm.project.floating.count,
                                foregroundCount: vm.project.foreground.count)
            + (vm.project.floating.count > 5 ? 20 : 0)
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            capsuleButton(icon: "xmark") { showResetConfirm = true }
            capsuleButton(icon: "questionmark") { showAbout = true }
            Spacer()
            Menu {
                Button("3s · 180 帧") { vm.project.loopFrames = 180 }
                Button("4s · 240 帧") { vm.project.loopFrames = 240 }
                Button("6s · 360 帧") { vm.project.loopFrames = 360 }
            } label: {
                HStack(spacing: 4) {
                    Text("循环 \(Int(vm.project.loopSeconds))s")
                        .font(.system(size: 13.5, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color(white: 0.15))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 12).fill(capsuleFill))
            }
            Button { vm.exportPackage() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .bold))
                    Text("生成 .tendies")
                        .font(.system(size: 13.5, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 12).fill(accent))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func capsuleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(white: 0.15))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 12).fill(capsuleFill))
        }
    }

    // MARK: 状态页签 + 过渡预览

    private var tabBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(PartTab.allCases) { tab in
                    Button {
                        // 页签 = 快捷跳转：跳到对应循环段并切画布
                        vm.jumpToSegment(tab == .locked ? .lockedLoop : .unlockLoop)
                    } label: {
                        Text(tab.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(vm.currentTab == tab ? accent : Color(white: 0.45))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6.5)
                            .background(
                                Capsule().fill(vm.currentTab == tab ? Color.white : Color.clear)
                                    .shadow(color: .black.opacity(vm.currentTab == tab ? 0.1 : 0), radius: 3, y: 1))
                    }
                }
            }
            .padding(3)
            .background(Capsule().fill(capsuleFill))

            Spacer()

            if vm.currentTab == .locked {
                previewButton(icon: "sun.max", title: "预览开屏", action: { vm.previewWake() })
            }
            Button {
                vm.previewUnlock()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: vm.currentTab == .locked ? "lock.open" : "lock")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(vm.currentTab == .locked ? "预览开锁" : "预览回锁")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color(red: 0.91, green: 0.95, blue: 1)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
    }

    private func previewButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(red: 0.91, green: 0.95, blue: 1)))
        }
    }

    // MARK: 播放控制行

    private var controlsRow: some View {
        HStack {
            Button { vm.restartSegment() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(white: 0.2))
            }
            Spacer()
            Button { vm.isPlaying.toggle() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(white: 0.08)))
            }
            Spacer()
            Text("\(vm.segment.displayName) \(timecode(frame: vm.segmentLocalFrame))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 2)
    }

    // MARK: 底部工具坞

    private var dock: some View {
        HStack(spacing: 8) {
            dockCard(icon: "photo.on.rectangle.angled", label: "素材") { showMaterialMenu = true }
            dockCard(icon: "square.3.layers.3d", label: "图层") { showLayerList = true }
            dockCard(icon: "sparkles", label: "动作") {
                if vm.selectedLayer == nil { showPickLayerHint = true }
            }
            dockCard(icon: "textformat", label: "文字") { showAddText = true }
            dockCard(icon: "wand.and.stars", label: "特效") { vm.addSweepLayer() }
            dockCard(icon: "slider.horizontal.3", label: "状态") { showStateSettings = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func dockCard(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Color(white: 0.3))
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 15).fill(Color(white: 0.957)))
        }
    }

    // MARK: 导出结果面板

    @ViewBuilder
    private func exportSheet(_ outcome: EditorViewModel.ExportOutcome) -> some View {
        switch outcome {
        case .success(let url):
            ExportSuccessView(url: url, note: vm.exportNote)
        case .failure(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 14.5))
                    .multilineTextAlignment(.center)
                Button("知道了") { vm.exportOutcome = nil }
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(28)
            .presentationDetents([.height(240)])
        }
    }
}

// MARK: - 导出成功面板（分享走系统面板，存到文件后去 CocoWall 导入）

private struct ExportSuccessView: View {
    let url: URL
    var note: String = ""
    @Environment(\.dismiss) private var dismiss

    private var fileSizeText: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return nil }
        return String(format: "%.1f MB", Double(size) / 1_000_000)
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.green)
            Text(url.lastPathComponent)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let sizeText = fileSizeText {
                Text("\(sizeText) · 点下面分享，存到「文件」后去 CocoWall 导入刷入试效果")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
            }
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
            }
            ShareLink(item: url) {
                Text("分享 / 存储 .tendies")
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0, green: 0.44, blue: 0.89)))
            }
            Button("完成") { dismiss() }
                .font(.system(size: 14.5))
        }
        .padding(24)
        .presentationDetents([.height(410)])
    }
}

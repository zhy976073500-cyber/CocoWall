//
//  TendiesView.swift
//  AirCard-iOS
//
//  Dedicated UI for importing, previewing, and flashing PosterBoard .tendies wallpapers.
//  Unified Form design matching the Passcode Theme tab.
//

import SwiftUI
import UniformTypeIdentifiers
import NetworkExtension

// MARK: - 液态玻璃（run #128 起全 App standing 要求）
//
// 新建 / 重排的 UI 表面一律走这组辅助：iOS 26 用原生
// glassEffect / GlassEffectContainer 与 glass / glassProminent
// 按钮样式；部署目标仍含 iOS 17–25，旧系统回退
// .ultraThinMaterial 等价外观，功能与布局不因回退而变。
// 玻璃 API 只存在于新 SDK：编译期以 #if compiler(>=6.2)
// 分流（旧 SDK 根本不编译玻璃分支），运行时再以
// #available(iOS 26, *) 把关。
// 例外（run #131）：壁纸页底部 sheet 区经 Sage 定不用液态
// 玻璃，保持纯色平面（见 SPEC #131 登记）。

extension View {
    /// 玻璃表面：26+ 原生玻璃（可带 tint / 可 interactive），
    /// 旧系统 = ultraThinMaterial + 同色淡 tint 叠色 + 发丝描边。
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let baseGlass = Glass.regular
            let tintedGlass = tint.map { baseGlass.tint($0) } ?? baseGlass
            self.glassEffect(interactive ? tintedGlass.interactive() : tintedGlass, in: shape)
        } else {
            glassMaterialFallback(shape, tint: tint)
        }
        #else
        glassMaterialFallback(shape, tint: tint)
        #endif
    }

    @ViewBuilder
    fileprivate func glassMaterialFallback<S: Shape>(_ shape: S, tint: Color?) -> some View {
        self.background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                if let tint {
                    shape.fill(tint)
                }
            }
        }
        .overlay {
            shape.stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        }
    }
}

/// 玻璃收拢容器：26+ 用 GlassEffectContainer 让同组玻璃元素
/// 共享采样与融合；旧系统直通（各表面各自走材质回退）。
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

extension View {
    /// 主行动按钮双路（run #129 补入共用辅助）：iOS 26 用系统
    /// glassProminent 样式，旧系统保持 borderedProminent；
    /// 只换按钮表面，标签、布局与行为不变。tint 为 nil 时
    /// 与不加 tint 等价（系统强调色）。
    @ViewBuilder
    func glassProminentButton(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(tint)
        } else {
            self.buttonStyle(.borderedProminent).tint(tint)
        }
        #else
        self.buttonStyle(.borderedProminent).tint(tint)
        #endif
    }

    /// 次级按钮双路（run #129）：iOS 26 用系统 glass 样式，
    /// 旧系统保持 bordered；同上只换表面。
    @ViewBuilder
    func glassButton(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).tint(tint)
        } else {
            self.buttonStyle(.bordered).tint(tint)
        }
        #else
        self.buttonStyle(.bordered).tint(tint)
        #endif
    }
}

// MARK: - 状态区回环呈现（run #127，纯逻辑，可离线断言）

/// 内置回环隧道状态的纯枚举镜像，与 NEVPNStatus 一一对应。
/// 下面的映射逻辑只依赖这个镜像（不依赖 NetworkExtension），
/// 因此可原文抽出、在离线 harness 里跑断言。
enum LoopbackPhase {
    case connected
    case connecting
    case disconnecting
    case reasserting
    case disconnected
    case invalid
    case unknown
}

/// 壁纸页状态区回环按钮与「回环连接」状态行的呈现结果。
/// 可发现性纪律（run #127，Sage 2026-11-02 真机反馈：设置页的
/// 内置回环开关他根本没找到）：壁纸页这一处就是唯一入口的心智
/// 模型——按钮标题在任何状态下都必须写明「内置回环」，不许只
/// 写含糊的「连接」二字让人分不清连的是内是外；连接状态紧贴
/// 按钮下方一行显示（见状态区排版）。
struct LoopbackPresentation {
    let buttonTitle: String
    let buttonSubtitle: String
    let buttonEnabled: Bool
    let lineValue: String
    let lineOK: Bool
    let lineWarn: Bool
}

/// 纯映射（run #127）：隧道相位 + 保存配置忙碌位 + 外部回环探活
/// → 按钮标题/副文案/可用性与状态行文案。
///
/// 「回环连接」一行的口径：以内置隧道状态为主——内置已连接 /
/// 连接中 / 断开中都据实显示；内置不在场（未连接 / 未配置）时，
/// 外部 LocalDevVPN 在跑（externalUp = vm.vpnUp 的接口扫描结果）
/// 仍显示「已连接」，因为刷入照样走得通。isBusy 表示 start() 正
/// 在保存 VPN 配置（NEVPNStatus 尚未翻到 connecting），此时按
/// 连接中呈现，避免按钮在授权弹窗前后闪回可点状态。
func loopbackPresentation(phase: LoopbackPhase,
                          isBusy: Bool,
                          externalUp: Bool) -> LoopbackPresentation {
    let effective: LoopbackPhase =
        (isBusy && (phase == .disconnected || phase == .invalid || phase == .unknown))
        ? .connecting : phase
    switch effective {
    case .connected:
        return LoopbackPresentation(
            buttonTitle: "断开内置回环",
            buttonSubtitle: "内置回环已连接，点击断开",
            buttonEnabled: true,
            lineValue: "已连接（内置回环）",
            lineOK: true, lineWarn: false)
    case .connecting, .reasserting:
        return LoopbackPresentation(
            buttonTitle: "内置回环连接中…",
            buttonSubtitle: "正在建立内置回环…",
            buttonEnabled: false,
            lineValue: "连接中…",
            lineOK: false, lineWarn: true)
    case .disconnecting:
        return LoopbackPresentation(
            buttonTitle: "内置回环断开中…",
            buttonSubtitle: "正在断开内置回环…",
            buttonEnabled: false,
            lineValue: "断开中…",
            lineOK: false, lineWarn: true)
    case .disconnected, .invalid, .unknown:
        return LoopbackPresentation(
            buttonTitle: "连接内置回环",
            buttonSubtitle: phase == .invalid
                ? "CocoWall 自带回环；首次连接会弹出系统提示，允许添加 VPN 配置"
                : "CocoWall 自带回环，点按直接连接，无需其他 App",
            buttonEnabled: true,
            lineValue: externalUp ? "已连接" : "未连接",
            lineOK: externalUp, lineWarn: false)
    }
}

struct TendiesView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showFilePicker = false
    @State private var selectedDetailItem: TendieItem? = nil
    @State private var isNeoSpringing = false
    @State private var showImportedPage = false
    /// 扇形卡长按菜单的目标项（run #130）：非 nil 时扇形滚动
    /// 冻结、页面根部弹 confirmationDialog 呈现「详情/删除」。
    @State private var fanMenuTarget: TendieItem? = nil

    private var selectedCount: Int {
        vm.tendieItems.filter { $0.isSelected }.count
    }

    private var selectedItems: [TendieItem] {
        vm.tendieItems.filter { $0.isSelected }
    }

    // MARK: - 状态条（run #128 改版：底部 sheet 顶部胶囊状态条）

    /// 与设置页 VPNStatusRow 共用同一 LoopbackTunnelManager 共享
    /// 实例（run #127 收敛）：同一份 VPN 配置档案、同一状态源，
    /// 两处启停互通、状态一致。
    @ObservedObject private var loopback = LoopbackTunnelManager.shared

    private var loopbackPhase: LoopbackPhase {
        switch loopback.status {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case .reasserting: return .reasserting
        case .disconnected: return .disconnected
        case .invalid: return .invalid
        @unknown default: return .unknown
        }
    }

    private var loopbackUI: LoopbackPresentation {
        loopbackPresentation(phase: loopbackPhase,
                             isBusy: loopback.isBusy,
                             externalUp: vm.vpnUp)
    }

    private var systemStatusLevel: SystemSupportLevel {
        AppViewModel.systemSupportLevel(version: UIDevice.current.systemVersion)
    }

    /// 状态条「系统」段的值（run #128 紧凑口径）：iOS 版本 + 支持
    /// 等级短文案；等级判定仍走 AppViewModel.systemSupportLevel。
    private var systemSegmentText: String {
        let v = UIDevice.current.systemVersion
        switch systemStatusLevel {
        case .supported:
            return "iOS \(v) · 支持"
        case .patchedRisk:
            return "iOS \(v) · 风险提示"
        case .tooOld:
            return "iOS \(v) · 不支持"
        }
    }

    private var systemSegmentColor: Color {
        switch systemStatusLevel {
        case .supported: return .green
        case .patchedRisk: return .orange
        case .tooOld: return .red
        }
    }

    /// 状态条「回环」段的值与语义色（run #128）：以内置隧道状态为
    /// 主口径（与 run #127 loopbackPresentation 同一判定），内置不
    /// 在场时外部回环在跑（vm.vpnUp）仍算已连接。
    private var loopbackSegment: (value: String, color: Color) {
        switch loopbackPhase {
        case .connected:
            return ("已连接", .green)
        case .connecting, .reasserting:
            return ("连接中…", .orange)
        case .disconnecting:
            return ("断开中…", .orange)
        case .disconnected, .invalid, .unknown:
            if loopback.isBusy { return ("连接中…", .orange) }
            return vm.vpnUp ? ("已连接", .green) : ("未连接", .red)
        }
    }

    private func toggleSelection(itemID: UUID) {
        if let idx = vm.tendieItems.firstIndex(where: { $0.id == itemID }) {
            vm.tendieItems[idx].isSelected.toggle()
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 错误横幅（沿用旧版文案与关闭行为）
                    if let err = vm.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                            Spacer()
                            Button {
                                vm.errorMessage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                        // run #131：错误横幅改实色浅红面，不用液态玻璃。
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    }

                    headerRow
                    fanZone
                    if !vm.tendieItems.isEmpty {
                        selectedLine
                    }
                    bottomSheet
                }
                .padding(.bottom, 66)
            }
            .background(Color(UIColor.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showImportedPage) {
                ImportedWallpapersView()
            }
            .sheet(isPresented: $showFilePicker) {
                TendiesDocumentPickerView { urls in
                    Task {
                        await vm.importTendieFiles(urls: urls)
                    }
                }
            }
            .sheet(item: $selectedDetailItem) { item in
                TendieDetailSheet(item: item)
            }
            // 扇形长按菜单（run #130）：不用 contextMenu——它挂在
            // rotationEffect 后的卡片上、且横滑 ScrollView 惯性不被
            // 打断，真机录屏里菜单浮空脱锚、卡片滑走。改长按手势
            // 设 fanMenuTarget（扇形随之 scrollDisabled 冻结）后，
            // 在此以 confirmationDialog 稳定呈现同一组动作。
            .confirmationDialog(
                fanMenuTarget?.name ?? "",
                isPresented: Binding(
                    get: { fanMenuTarget != nil },
                    set: { if !$0 { fanMenuTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: fanMenuTarget
            ) { item in
                Button("详情") {
                    selectedDetailItem = item
                }
                Button("删除", role: .destructive) {
                    vm.deleteTendie(item: item)
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $vm.showDevicePosterSheet) {
                DevicePosterCleanupView()
            }
            .onAppear {
                vm.isNeoSpringing = false
                isNeoSpringing = false
                vm.showSuccessAlert = false
                vm.successAlertMessage = ""
                vm.scanDocumentsForTendies()
                // 状态条（沿用 run #124/#127 触发）：进页面查一次
                // 配对文件与回环探活状态（均为现成只读轻量检查）。
                vm.refreshPairingFile()
                vm.refreshNetworkStatus()
                // 内置回环的已保存配置与状态只读对齐（共享实例）。
                Task { await loopback.reload() }
            }
            .task {
                if vm.posterBoardContainer.isEmpty {
                    await vm.autoDetectPosterBoardContainer(silent: true)
                }
            }
            .overlay {
                if isNeoSpringing || vm.isNeoSpringing {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        NeoSpringView()
                            .brightness(-1.0)
                            .ignoresSafeArea()
                    }
                }
            }
        }
    }

    // MARK: - 页头（标题 + 展开按钮）

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text("我的壁纸")
                .font(.largeTitle.bold())
            Spacer()
            Button {
                showImportedPage = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .glassSurface(Circle(), tint: Color.blue.opacity(0.12), interactive: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: - 扇形壁纸区

    private var fanZone: some View {
        Group {
            if vm.tendieItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("还没有载入 .tendies 壁纸")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("点下方「导入壁纸」从文件选择 .tendies，或把壁纸拷到 我的 iPhone › CocoWall。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 30)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    // 交叠量（run #132）：-62 → -34，150pt 宽卡每张
                    // 露出约 116pt（三分之二强），画面与卡名不再
                    // 被邻卡大面积盖住。
                    HStack(spacing: -34) {
                        ForEach(Array(vm.tendieItems.enumerated()), id: \.element.id) { idx, item in
                            fanCard(item: item, index: idx, count: vm.tendieItems.count)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .scrollTargetLayout()
                }
                // 停下时弹簧式吸附到整卡（run #130，苹果信息式 Q 弹）。
                .scrollTargetBehavior(.viewAligned)
                // 长按菜单呈现期间冻结扇形（run #130），惯性不再
                // 带着卡片在菜单背后滑走。
                .scrollDisabled(fanMenuTarget != nil)
            }
        }
    }

    private func fanCard(item: TendieItem, index: Int, count: Int) -> some View {
        // zIndex 仍按与列表中点的距离排（近中点在上）；旋转、
        // 缩放、上浮已改由滚动相位驱动（run #133-B，见下方
        // scrollTransition），不再有 index 循环的静态角度。
        let center = Double(count - 1) / 2.0
        return ZStack(alignment: .bottomLeading) {
            TendieThumbnailView(item: item)
                .frame(width: 150, height: 200)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.38)],
                           startPoint: .center, endPoint: .bottom)
            // 卡名防压（run #132）：最大宽收进每张卡的可见条
            // （约 110pt），尾部截断，不再伸进被邻卡盖住的区域。
            Text(item.name)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 110, alignment: .leading)
                .padding(.leading, 10)
                .padding(.bottom, 9)
                .padding(.trailing, item.isSelected ? 34 : 10)
            if item.isSelected {
                ZStack {
                    Circle().fill(Color.blue)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 21, height: 21)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: 150, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if item.isSelected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.blue, lineWidth: 3)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // 选中态弹簧缩放回弹（run #130）。
        .scaleEffect(item.isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: item.isSelected)
        // 点按选中（run #130：手势实现取代原 Button+contextMenu，
        // 附一次轻触觉，沿用 App 内 UIImpactFeedbackGenerator 口径）。
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            toggleSelection(itemID: item.id)
        }
        // 长按出菜单（run #130）：只设目标项；菜单由页面根部的
        // confirmationDialog 呈现，扇形同时冻结，不再脱锚。
        .onLongPressGesture(minimumDuration: 0.45) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            fanMenuTarget = item
        }
        .zIndex(-abs(Double(index) - center))
        // 扇形几何（run #133-B 二次校正，取代 #130/#132 的
        // 「index 静态 base 角度 + 回正抵消」）：旧实现保留了
        // ±8/±4 的 index 循环角度阶梯，角度不由卡片在屏幕上
        // 的位置决定，停稳时邻卡倾斜看运气，达不到定稿图
        // （底部支点、邻卡明显张开约 ±11°、中心卡主导）的
        // 对称扇开。现旋转/缩放/上浮全部改由 scrollTransition
        // 相位驱动，卡片静止角度一律 0：角度 =
        // 13°×clamp(phase.value, -1, 1)，中心卡回正、越往
        // 两侧倾斜越大封顶 13°（停稳时邻卡 |phase|≈0.77
        // 对应约 ±10°，与定稿图一致），绕底部支点
        // anchor(0.5, 1.15)（run #132 定）上张下收；缩放
        // 1+0.06×(1-|phase|)、上浮 -6×(1-|phase|) 同源
        // 驱动，中心卡放大上浮主导，滚动时连续扇动。
        .scrollTransition(.interactive) { content, phase in
            let v = min(1.0, max(-1.0, phase.value))
            let a = abs(v)
            return content
                .scaleEffect(1 + 0.06 * (1 - a))
                .offset(y: -6 * (1 - a))
                .rotationEffect(.degrees(13 * v), anchor: UnitPoint(x: 0.5, y: 1.15))
        }
        .task {
            // 已存预览缺失或解码失败时，从包内重新提取（与旧列表行同口径）。
            vm.regenerateTendiePreview(itemID: item.id)
        }
    }

    // MARK: - 已选行

    private var selectedLine: some View {
        HStack(spacing: 6) {
            if selectedItems.isEmpty {
                Text("还没选择要刷入的壁纸")
                    .foregroundStyle(.secondary)
            } else {
                Text("已选")
                    .foregroundStyle(.secondary)
                Text(selectedItems.map(\.name).joined(separator: "、"))
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text("共 \(vm.tendieItems.count) 张")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    // MARK: - 底部 sheet 区
    //
    // run #131：本区经 Sage 定不用液态玻璃——回到 #128 设计稿
    // （wallpaper-page-v5）的纯色平面：sheet 底 #F7F7FA 实色、
    // 内部瓷砖/宽条纯白面 + 轻柔阴影、状态条白色实色胶囊、
    // 刷入主按钮纯蓝实色胶囊。布局/文案/行为与 #128/#130 一致。

    /// sheet 面板底色（设计稿 #F7F7FA）。
    private static let sheetBackground = Color(red: 247.0 / 255, green: 247.0 / 255, blue: 250.0 / 255)
    /// 刷入主按钮蓝（设计稿 #0071E3）。
    private static let flashBlue = Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255)

    private var bottomSheet: some View {
        VStack(spacing: 12) {
            statusCapsule

            // run #127 纪律沿用：启停失败原文红字显示在状态条下方。
            if let loopbackError = loopback.lastError {
                Text(loopbackError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            flashButton
            importTile
            microcopy

            HStack(spacing: 10) {
                moreWallpapersTile
                loopbackTile
            }

            cleanupTile

            if !vm.devicePosterStatus.isEmpty {
                Text(vm.devicePosterStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Self.sheetBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 15, x: 0, y: -4)
        .padding(.horizontal, 12)
    }

    // MARK: 状态条

    private var statusCapsule: some View {
        HStack(spacing: 8) {
            statusSegment(label: "回环",
                          value: loopbackSegment.value,
                          color: loopbackSegment.color)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 1, height: 14)
            statusSegment(label: "配对文件",
                          value: vm.hasPairingFile ? "已识别" : "未识别",
                          color: vm.hasPairingFile ? .green : .red)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 1, height: 14)
            statusSegment(label: "系统",
                          value: systemSegmentText,
                          color: systemSegmentColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.white, in: Capsule())
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }

    private func statusSegment(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    // MARK: 刷入主按钮

    @ViewBuilder
    private var flashButton: some View {
        if case .running = vm.tendiesFlashPhase {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在刷入壁纸…").font(.subheadline.bold())
                    ProgressView(value: vm.tendiesFlashProgress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        } else {
            flashActionButton
        }
    }

    /// 刷入主按钮（run #131 起不用液态玻璃）：纯蓝（#0071E3）
    /// 实色胶囊，文案 / 禁用口径 / 行为与 #128 一致；原
    /// glassProminent 双路与自绘回退就此合并为这一份实现。
    private var flashActionButton: some View {
        Button {
            Task {
                await vm.flashSelectedTendies()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("刷入 \(selectedCount) 张壁纸")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(selectedCount == 0 ? Self.flashBlue.opacity(0.45) : Self.flashBlue, in: Capsule())
            .shadow(color: Self.flashBlue.opacity(0.28), radius: 11, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(selectedCount == 0)
    }

    // MARK: 导入壁纸（原页头 + 号搬家，fileImporter 行为不变）

    private var importTile: some View {
        Button {
            showFilePicker = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.10))
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("导入壁纸")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("从文件导入 .tendies 壁纸包")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 微文案

    private var microcopy: some View {
        VStack(spacing: 2) {
            if vm.posterBoardContainer.isEmpty {
                Text("刷入时将自动检测 PosterBoard 容器。")
            } else {
                Text("目标：已检测到 PosterBoard 容器 ✓ · 刷入后先尝试免注销刷新")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    // MARK: 双列瓷砖

    private func sheetTile(icon: String,
                            tint: Color,
                            title: String,
                            subtitle: String,
                            subtitleColor: Color,
                            enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle().fill(tint.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(tint)
                }
                .frame(width: 34, height: 34)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 8)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var moreWallpapersTile: some View {
        sheetTile(icon: "photo.on.rectangle.angled",
                  tint: .blue,
                  title: "获取更多壁纸",
                  subtitle: "飞书合集，持续更新",
                  subtitleColor: .secondary) {
            if let url = URL(string: "https://my.feishu.cn/wiki/Oi6pwrRp9i8wd2kBl0Lc4bn9nTb") {
                UIApplication.shared.open(url)
            }
        }
    }

    private var loopbackTile: some View {
        let connected = loopbackPhase == .connected
        let busy = !loopbackUI.buttonEnabled
        let subtitle: String
        let subtitleColor: Color
        if connected {
            subtitle = "已连接 · 点击断开"
            subtitleColor = .green
        } else if busy {
            subtitle = loopbackUI.lineValue
            subtitleColor = .orange
        } else {
            subtitle = "未连接 · 点击连接"
            subtitleColor = .secondary
        }
        return sheetTile(icon: "globe",
                         tint: .green,
                         title: "内置回环",
                         subtitle: subtitle,
                         subtitleColor: subtitleColor,
                         enabled: !busy) {
            // run #127 接线沿用：点按直接启停内置隧道（共享实例），
            // 任何状态下都不跳转外部 App。
            if loopbackPhase == .connected {
                loopback.stop()
            } else {
                loopback.start()
            }
            vm.refreshNetworkStatus()
        }
    }

    // MARK: 清除壁纸（进现有清理页）

    private var cleanupTile: some View {
        Button {
            vm.showDevicePosterSheet = true
            Task { await vm.detectDevicePosters() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.10))
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("清除壁纸")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("检测并清除本机已导入的壁纸")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tendie Thumbnail（扇形卡与全屏选择页共用）

struct TendieThumbnailView: View {
    let item: TendieItem

    var body: some View {
        if let imgData = item.previewImageData, let uiImg = UIImage(data: imgData) {
            Image(uiImage: uiImg)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(UIColor.tertiarySystemFill)
                Image(systemName: item.posterType.systemIcon)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Tendie Row View

struct TendieRowView: View {
    @EnvironmentObject var vm: AppViewModel
    @Binding var item: TendieItem
    let onInspect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $item.isSelected)
                .labelsHidden()

            if let imgData = item.previewImageData, let uiImg = UIImage(data: imgData) {
                Image(uiImage: uiImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 60)
                    .cornerRadius(6)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: 44, height: 60)
                    .overlay {
                        Image(systemName: item.posterType.systemIcon)
                            .foregroundColor(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.posterType.rawValue)
                        .font(.caption2.bold())
                        .foregroundColor(item.posterType.badgeColor)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("\(item.descriptorCount) 个描述符")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                onInspect()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .task {
            // 已存预览缺失或解码失败时，从包内重新提取（导入时只提取一次且不重试）。
            vm.regenerateTendiePreview(itemID: item.id)
        }
    }
}

// MARK: - Tendie Detail Sheet

struct TendieDetailSheet: View {
    let item: TendieItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let imgData = item.previewImageData, let uiImg = UIImage(data: imgData) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 300)
                            .cornerRadius(12)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                            .listRowBackground(Color.clear)
                    }
                }

                Section("信息") {
                    detailRow(title: "名称", value: item.name)
                    detailRow(title: "文件名", value: item.fileName)
                    detailRow(title: "类型", value: item.posterType.rawValue)
                    detailRow(title: "描述符", value: "\(item.descriptorCount)")
                    detailRow(title: "目标扩展", value: item.posterType.extensionBundleId)
                    detailRow(title: "格式", value: item.isContainer ? "App 容器" : "描述符包")
                    if item.unsafeContainer {
                        detailRow(title: "警告", value: "包含 SQLite 数据库")
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Tendies Document Picker

struct TendiesDocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var contentTypes: [UTType] = []
        if let customType = UTType("com.aircard.tendies") {
            contentTypes.append(customType)
        }
        if let extType = UTType(filenameExtension: "tendies") {
            contentTypes.append(extType)
        }
        contentTypes.append(contentsOf: [.archive, .zip, .data, .item])

        // asCopy: true ensures iOS safely copies documents into app sandbox tmp directory
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: TendiesDocumentPickerView

        init(_ parent: TendiesDocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            parent.onPick(urls)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Device Poster Cleanup Sheet

/// Lists the descriptors actually present in the device's PosterBoard
/// data store (via PosterStoreHelper), lets the user tick items, and —
/// after an explicit confirmation — deletes the selected ones from the
/// device, then shows the refreshed list and the cleanup result.
struct DevicePosterCleanupView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCleanupConfirm = false

    private var selectedItems: [DevicePosterItem] {
        vm.devicePosters.filter { vm.devicePosterSelection.contains($0.id) }
    }

    private var allSelected: Bool {
        !vm.devicePosters.isEmpty && vm.devicePosterSelection.count == vm.devicePosters.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isScanningDevicePosters {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在检测设备数据仓…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if vm.devicePosters.isEmpty {
                            Section {
                                VStack(spacing: 10) {
                                    Image(systemName: "photo.stack")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.secondary)
                                    Text(vm.devicePosterStatus.isEmpty ? "设备数据仓里没有检测到已导入的壁纸。" : vm.devicePosterStatus)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 24)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .listRowSeparator(.hidden)
                            }
                        }
                        if !vm.devicePosters.isEmpty {
                        Section {
                            ForEach(vm.devicePosters) { item in
                                Button {
                                    if vm.devicePosterSelection.contains(item.id) {
                                        vm.devicePosterSelection.remove(item.id)
                                    } else {
                                        vm.devicePosterSelection.insert(item.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: vm.devicePosterSelection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(vm.devicePosterSelection.contains(item.id) ? Color.accentColor : Color.secondary)
                                        // Runs #122/#124: thumbnail borrowed
                                        // from the matching local library
                                        // entry (flash registry first, then
                                        // package-name matching in
                                        // AppViewModel), so a row can be
                                        // recognised by its picture.
                                        if let thumbData = vm.devicePosterThumbs[item.id],
                                           let thumb = UIImage(data: thumbData) {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 34, height: 46)
                                                .cornerRadius(6)
                                                .clipped()
                                                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                                        } else {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color(UIColor.tertiarySystemFill))
                                                .frame(width: 34, height: 46)
                                                .overlay {
                                                    Image(systemName: "photo")
                                                        .foregroundStyle(.secondary)
                                                }
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            // Run #124: prefer the local
                                            // library display name when the
                                            // row's source entry is known —
                                            // the store-reported name carries
                                            // the rewritten packaged base
                                            // (e.g. "1572.WWDC_2022-…"), which
                                            // identifies nothing.
                                            Text(vm.devicePosterDisplayNames[item.id] ?? item.name)
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("\(item.extensionId) · \(String(item.uuid.prefix(8)))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text("设备数据仓中共 \(vm.devicePosters.count) 张")
                                Spacer()
                                Button(allSelected ? "取消全选" : "全选") {
                                    if allSelected {
                                        vm.devicePosterSelection = []
                                    } else {
                                        vm.devicePosterSelection = Set(vm.devicePosters.map { $0.id })
                                    }
                                }
                                .font(.caption)
                                .textCase(nil)
                            }
                        }
                        }
                    }
                }
            }
            .onChange(of: vm.tendieItems) { _, _ in
                // A library preview regenerated after the cleanup
                // list was built can fill in a row thumbnail that
                // was missing (run #122).
                vm.prepareDevicePosterThumbnails()
            }
            .navigationTitle("本机已导入的壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            await vm.detectDevicePosters()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isScanningDevicePosters || vm.isCleaningDevicePosters)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !vm.devicePosters.isEmpty {
                    // run #129：底栏与清理按钮玻璃化（清理逻辑不变）——
                    // 栏面走 glassSurface、主按钮走 glassProminent 双路。
                    GlassGroup {
                        VStack(spacing: 8) {
                            if !vm.devicePosterStatus.isEmpty {
                                Text(vm.devicePosterStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            Button(role: .destructive) {
                                showCleanupConfirm = true
                            } label: {
                                HStack(spacing: 8) {
                                    Spacer()
                                    if vm.isCleaningDevicePosters {
                                        ProgressView()
                                        Text("正在清理…")
                                    } else {
                                        Image(systemName: "trash")
                                        Text("清理所选（\(selectedItems.count)）")
                                    }
                                    Spacer()
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                            }
                            .glassProminentButton(tint: .red)
                            .disabled(selectedItems.isEmpty || vm.isCleaningDevicePosters || vm.isScanningDevicePosters)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassSurface(Rectangle())
                    }
                }
            }
            .confirmationDialog(
                "清理所选壁纸？",
                isPresented: $showCleanupConfirm,
                titleVisibility: .visible
            ) {
                Button("清理 \(selectedItems.count) 张", role: .destructive) {
                    Task { await vm.cleanupSelectedDevicePosters() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所选 \(selectedItems.count) 张壁纸将从设备 PosterBoard 数据仓中移除。")
            }
        }
    }
}

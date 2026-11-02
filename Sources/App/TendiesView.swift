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

/// 轮播单卡（run #136 独立子视图、#138 换底盘沿用）：
/// 延迟轮盘式轮播的卡片子视图。#138 起父视图持连续
/// 主位置 p（手势直驱），本视图自持弹簧化位置 p̃、以
/// 「离焦点越远响应越慢」的弹簧追赶 p；显示距离
/// d̃ = index − p̃ 同时决定本卡的布局横移（父以 ZStack
/// 把卡心放在视口中心，本视图以 offset x = d̃×96
/// 平移）与全部变换——滑动时近卡先行、远卡按距离
/// 递增拖后，卡间距在运动中真实伸缩（级联核心）；
/// 静止时 p̃ 与 p 精确一致、布局不漂移。选中集与
/// 长按菜单仍归父视图管，经回调回传；长按按压态经
/// onPressingChange 回报父视图，用于在长按识别期间
/// 门控容器拖动。两侧卡保持正脸（无 3D 转侧），只
/// 倾斜/下沉/变暗/轻微虚化，缩略图另带轻去色（#137）。
private struct FanCardView: View {
    @EnvironmentObject var vm: AppViewModel
    let item: TendieItem
    /// 本卡在带内的序号。
    let index: Int
    /// 父视图的连续主位置 p（index 单位浮点；p 等于
    /// 本卡序号时本卡居中）。
    let position: Double
    /// 扫光触发 token：本卡为停稳聚焦卡时等于父视图的
    /// 递增计数、非聚焦卡为 0；跳到新的正值时播一次扫光。
    let sweepToken: Int
    let onTap: () -> Void
    let onLongPress: () -> Void
    /// 长按按压态变化（按下未达识别时长即先报）：父
    /// 视图据此在长按识别期间禁用容器拖动（见 TendiesView
    /// 的 fanPressActive 与手势掩码）。
    let onPressingChange: (Bool) -> Void

    /// 弹簧化位置 p̃：布局与全部变换的唯一驱动量来源。
    @State private var pTilde: Double
    /// 扫光光带当前 x 偏移（pt）：停在 −155（旋转光带
    /// 完全出卡左界、被卡面裁掉不可见），触发时先瞬时
    /// 归位 −155、再动画扫到 +155。
    @State private var sweepX: CGFloat = -155

    init(item: TendieItem, index: Int, position: Double, sweepToken: Int,
         onTap: @escaping () -> Void,
         onLongPress: @escaping () -> Void,
         onPressingChange: @escaping (Bool) -> Void) {
        self.item = item
        self.index = index
        self.position = position
        self.sweepToken = sweepToken
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.onPressingChange = onPressingChange
        // 首帧即以真实 p 呈现，不从别处弹入。
        _pTilde = State(initialValue: position)
    }

    /// 显示距离 d̃（正值在本卡位于视口中心右侧）。
    private var shownD: Double { Double(index) - pTilde }

    var body: some View {
        // 延迟轮盘变换量（曲线 #136 立、#137 修分层、
        // #138 倾斜/下沉/缩放按原视频实测签名更新，
        // 全部由 d̃ 推导）：绕底部锚点向外倾斜 9°×
        // clamp(d̃, ±2.2)（实测约 9–10°/格、最远约
        // 20°）；沿弧下沉 17×clamp(d̃, ±2)²（实测弧
        // 陡，|d|=2 约卡高 1/3）；整卡压暗 −0.28×
        // min(|d̃|/1.8, 1)（#137，深度主要靠变暗）；
        // 模糊只留轻微虚化——正中 ±0.55 内为 0、其后
        // 线性升至 1.6pt 封顶（#137）；缩略图另加轻
        // 去色 0.30 封顶（#137，只挂缩略图本体）；
        // 缩放 1.08 起、随 |d̃| 收到 0.94（#138 实测
        // 口径）。布局横移即链尾 offset x = d̃×96
        // 本身——#136 的 lagX 换算项退役：滞后现在就是
        // 位置本身的滞后，不再二次换算。
        let s = shownD
        let asd = abs(s)
        let sClamped = min(2.2, max(-2.2, s))
        let dropClamped = min(2, max(-2, s))
        let lagTilt = 9 * sClamped
        let lagDropY = CGFloat(17 * dropClamped * dropClamped)
        let lagScale = 1.08 - 0.07 * min(asd, 2)
        let lagBrightness = -0.28 * min(asd / 1.8, 1)
        let lagBlur = CGFloat(1.6 * min(max(asd - 0.55, 0) / 1.45, 1))
        let lagSaturation = 1 - 0.30 * min(asd / 1.8, 1)
        let lagZIndex = 100 - (asd * 10).rounded()
        // 阴影沿 #135 的 |d| 衰减口径，改由 shownD 驱动：
        // 近中心投影大而软、远端收紧。
        let lagNear = 1 - min(asd, 1)
        let lagShadowRadius = CGFloat(6 + 14 * lagNear)
        let lagShadowY = CGFloat(4 + 6 * lagNear)
        return ZStack(alignment: .bottomLeading) {
            // 模糊组（缩略图 + 底部渐变 + 卡名）：模糊只
            // 作用于此组，勾选徽章在其外保持锐利。
            ZStack(alignment: .bottomLeading) {
                TendieThumbnailView(item: item)
                    .frame(width: 150, height: 200)
                    .clipped()
                    // 轻去色只挂缩略图本体（run #137）：
                    // 同组的卡名与组外的徽章都不去色。
                    .saturation(lagSaturation)
                LinearGradient(colors: [.clear, .black.opacity(0.38)],
                               startPoint: .center, endPoint: .bottom)
                // 卡名防压（run #132）：最大宽收进每张卡的
                // 可见条（约 110pt），尾部截断。
                Text(item.name)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.bottom, 9)
                    .padding(.trailing, item.isSelected ? 34 : 10)
            }
            .blur(radius: lagBlur)
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
        // 变暗作用于整卡（含卡名与勾选徽章）：#137 起
        // 深度主要靠压暗承担，模糊只留轻微虚化、缩略图
        // 另带一点去色（见上 lagSaturation）。
        .brightness(lagBrightness)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if item.isSelected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.blue, lineWidth: 3)
            }
        }
        // 扫光（run #136）：白色线性渐变光带（宽约卡宽
        // 45%、峰值 alpha 0.35、倾斜约 20°），在自身
        // 容器内裁到卡圆角，不影响选中描边；光带旋转
        // 后横向半幅约 76pt，故行程取 ±155（略大于
        // 半卡宽 75 + 76）保证两端完全出卡。
        .overlay {
            ZStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: 68, height: 260)
                    .rotationEffect(.degrees(20))
                    .offset(x: sweepX)
            }
            .frame(width: 150, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: lagShadowRadius, x: 0, y: lagShadowY)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // 点按选中 / 长按出菜单（run #130 手势口径沿用、
        // #138 加按压态回报）：只回调父视图，触觉与状态
        // 变更在父侧；pressing 在识别时长到达前即先报
        // 按下，父视图据此门控容器拖动（拖动 minimumDistance
        // 4 的阈值也让轻触点按先于拖动成立）。
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.45,
                            pressing: { onPressingChange($0) },
                            perform: { onLongPress() })
        // 延迟轮盘几何（run #138）：倾斜绕底部锚点
        // (0.5, 0.92) 向外倒；offset x = d̃×96 即卡的
        // 布局横移本身（父以 ZStack 把卡心放在视口
        // 中心），y 为沿弧下沉 lagDropY；选中回弹 1.04
        // 并入缩放（弹簧 .animation(value: isSelected)
        // 沿用 #130，只在选中态变化时触发，不干扰 p̃
        // 弹簧的逐帧追赶）。hit 区按未倾斜卡框判定
        // （contentShape），倾斜最大约 19.8°、错位有限，
        // 见 SPEC #138 未验证项。
        .rotationEffect(.degrees(lagTilt), anchor: UnitPoint(x: 0.5, y: 0.92))
        .offset(x: CGFloat(s) * 96, y: lagDropY)
        .scaleEffect(lagScale * (item.isSelected ? 1.04 : 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: item.isSelected)
        .zIndex(lagZIndex)
        // 位置弹簧追赶（run #138 级联核心）：p 每变一次
        // 就以 response 0.55 + 0.10×min(|index − p|, 2.5)、
        // 阻尼 0.92 的弹簧重新瞄准 p̃——离焦点越远响应
        // 越慢，整带滑动时近卡先行、远卡拖后，间距在
        // 运动中伸缩；阻尼近临界，落位慢软、无可见
        // 弹跳（约 0.8s 停稳主要由父视图的松手吸附
        // 弹簧主导，本弹簧管逐卡跟随）。
        .onChange(of: position) { _, newP in
            withAnimation(.spring(response: 0.55 + 0.10 * min(abs(Double(index) - newP), 2.5),
                                  dampingFraction: 0.92)) {
                pTilde = newP
            }
        }
        // 扫光触发：token 跳到新正值（本卡刚成为停稳
        // 聚焦卡）时播一次——光带先瞬时归位左外，
        // 再 0.7s easeInOut 扫到右外。
        .onChange(of: sweepToken) { _, newToken in
            guard newToken > 0 else { return }
            sweepX = -155
            withAnimation(.easeInOut(duration: 0.7)) {
                sweepX = 155
            }
        }
        .task {
            // 已存预览缺失或解码失败时，从包内重新提取（与旧列表行同口径）。
            vm.regenerateTendiePreview(itemID: item.id)
        }
    }
}

struct TendiesView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showFilePicker = false
    @State private var selectedDetailItem: TendieItem? = nil
    @State private var isNeoSpringing = false
    @State private var showImportedPage = false
    /// 扇形卡长按菜单的目标项（run #130）：非 nil 时轮播
    /// 拖动门控禁用（run #138 手势掩码）、页面根部弹
    /// confirmationDialog 呈现「详情/删除」。
    @State private var fanMenuTarget: TendieItem? = nil
    /// 轮播主位置 p（run #138 换底盘）：连续浮点、index
    /// 单位，p = k 表示第 k 卡居中；由容器拖动手势直驱
    /// （见 fanDragGesture），松手弹簧吸附到整格。各卡
    /// 自持弹簧化位置 p̃ 追赶 p（见 FanCardView），其
    /// 布局与变换全由 d̃ = index − p̃ 决定。初始 0
    /// （首卡居中）；有限长条不绕圈（同 #135 起口径）。
    @State private var fanPosition: Double = 0
    /// 拖动起点的主位置：非 nil 表示拖动进行中；吸附
    /// 投影与单次滑动格数上限都以它为基准。
    @State private var fanDragStart: Double? = nil
    /// 任一卡长按按压中（尚未达识别时长）：为真时容器
    /// 拖动经手势掩码禁用（只留子手势），避免按压被
    /// 拖动抢走；菜单打开期间另由 fanMenuTarget 门控。
    @State private var fanPressActive: Bool = false
    /// 停稳聚焦 index 与扫光触发（run #136 立、#138 换
    /// 信号源）：p 静止 300ms 后取 round(p) 为聚焦格
    /// （见 scheduleFanFocusSettle）；聚焦真正换人（非
    /// 首次出现）时 fanSweepToken 递增，只传给聚焦卡，
    /// 触发它播一次扫光。
    @State private var fanFocusedIndex: Int? = nil
    @State private var fanSweepToken: Int = 0
    @State private var fanSettleTask: Task<Void, Never>? = nil

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
            // rotationEffect 后的卡片上、且轮播滑动不被打断，真机
            // 录屏里菜单浮空脱锚、卡片滑走。改长按手势设
            // fanMenuTarget（run #138 起轮播拖动随之门控冻结；
            // #136 时为 ScrollView 的 scrollDisabled）后，在此以
            // confirmationDialog 稳定呈现同一组动作。
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

    // MARK: - 轮播壁纸区（run #138 换底盘：手势直驱 + 每卡位置弹簧，撤 ScrollView；内部符号仍沿用 fan 前缀）

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
                // 布局口径（run #138）：ZStack 把每卡的布局
                // 中心放在带中心，卡的实际横向位置由其内部
                // offset（d̃×96）决定。带高 256：卡心纵坐标
                // 128 = 顶留 28（中心卡放大 1.08 的上沿
                // 外溢）+ 半卡高 100；其下再垫 52，凑回
                // #136 的总高 308（= 28 + 200 + 底留 80）：
                // 下沉最大值 17×2² = 68，卡底 228 + 68 =
                // 296，距带底 308 留约 12——下沉的卡不被
                // 裁掉、也不压到下方已选行（本区不裁剪，
                // 尺寸核算只为防视觉重叠）。pitch 保持
                // #136 的 96、卡 150×200。
                ZStack {
                    ForEach(Array(vm.tendieItems.enumerated()), id: \.element.id) { idx, item in
                        // 渲染剔除：目标 |d| > 3.4 的卡必然在
                        // 屏外（视口半宽约 215pt + 半卡宽 75
                        // = 290 < 3.4×96 = 326），不进视图树，
                        // 省 blur/阴影的逐帧开销；再入场时
                        // p̃ 以当前 p 初始化（见 FanCardView），
                        // 以正确变换直接出现在边缘、无弹入。
                        if abs(Double(idx) - fanPosition) <= 3.4 {
                            FanCardView(item: item,
                                        index: idx,
                                        position: fanPosition,
                                        sweepToken: idx == fanFocusedIndex ? fanSweepToken : 0,
                                        onTap: {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            toggleSelection(itemID: item.id)
                                        },
                                        onLongPress: {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            fanMenuTarget = item
                                        },
                                        onPressingChange: { pressing in
                                            fanPressActive = pressing
                                        })
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 256)
                .padding(.bottom, 52)
                // 整带（含下垫）都是拖动命中区：卡间空隙与
                // 卡下方留白也能起拖。
                .contentShape(Rectangle())
                // 手势门控：长按按压中或菜单打开期间，掩码
                // 只留子手势——容器拖动禁用、卡的点按/长按
                // 照常；其余时候拖动与子手势全开。
                .gesture(fanDragGesture,
                         including: (fanMenuTarget == nil && !fanPressActive) ? .all : .subviews)
                // p 一变就重排停稳判定（run #138）：静止满
                // 300ms 才更新聚焦格（扫光信号源由 #136 的
                // 滚动偏移换成 p；手势共存与仲裁见 SPEC
                // #138 未验证项）。
                .onChange(of: fanPosition) { _, _ in
                    scheduleFanFocusSettle()
                }
                // 导入/删除使卡数变化：主位置钳回新范围、
                // 聚焦 index 越界失效，并重排停稳判定，
                // 避免聚焦停在已删或错位的位置。
                .onChange(of: vm.tendieItems.count) { _, newCount in
                    let maxP = Double(max(newCount - 1, 0))
                    if fanPosition > maxP { fanPosition = maxP }
                    if let f = fanFocusedIndex, f >= newCount { fanFocusedIndex = nil }
                    scheduleFanFocusSettle()
                }
                // 自空态切回时 onChange 不补发，进场先钳位
                // 并排一次停稳判定（首次定聚焦不扫光）。
                .onAppear {
                    let maxP = Double(max(vm.tendieItems.count - 1, 0))
                    if fanPosition > maxP { fanPosition = maxP }
                    scheduleFanFocusSettle()
                }
            }
        }
    }

    /// 容器拖动（run #138）：DragGesture(minimumDistance: 4)
    /// ——未达阈值的轻触仍走子卡点按。拖动中 p 实时跟手
    /// （p = 起点 p − translation.width/96：向左拖 p 增大、
    /// 带向左走，与 #136 的 ScrollView 滑动方向一致），
    /// 超出 [0, n−1] 的部分由 fanRubberBanded 按 0.35
    /// 橡皮筋。松手以 predictedEndTranslation 投影落点、
    /// 四舍五入到整格（相对起点取整最多 ±4 格——单次
    /// 滑动上限，可调旋钮，见 SPEC #138），再钳到
    /// [0, n−1]，以 response 0.8 / 阻尼 0.95 的弹簧把
    /// p 动画过去——慢软落位对齐实测约 0.8s 停稳、无
    /// 可见弹跳。
    private var fanDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if fanDragStart == nil { fanDragStart = fanPosition }
                let start = fanDragStart ?? fanPosition
                let raw = start - Double(value.translation.width) / 96
                fanPosition = fanRubberBanded(raw)
            }
            .onEnded { value in
                let start = fanDragStart ?? fanPosition
                fanDragStart = nil
                let count = vm.tendieItems.count
                guard count > 0 else { return }
                let projected = start - Double(value.predictedEndTranslation.width) / 96
                var target = projected.rounded()
                let startRounded = start.rounded()
                target = min(max(target, startRounded - 4), startRounded + 4)
                target = min(max(target, 0), Double(count - 1))
                withAnimation(.spring(response: 0.8, dampingFraction: 0.95)) {
                    fanPosition = target
                }
                scheduleFanFocusSettle()
            }
    }

    /// 橡皮筋（run #138）：[0, n−1] 内 1:1 跟手，超出
    /// 部分只走 35%。
    private func fanRubberBanded(_ p: Double) -> Double {
        let maxP = Double(max(vm.tendieItems.count - 1, 0))
        if p < 0 { return p * 0.35 }
        if p > maxP { return maxP + (p - maxP) * 0.35 }
        return p
    }

    /// 停稳聚焦推导（run #136 立、#138 换信号源）：p 或
    /// 卡数一变就取消上一轮判定、重排一个 300ms 的静默
    /// 计时；满 300ms 无新变化视为停稳，聚焦格 =
    /// round(p)（钳到有效范围）。聚焦相对上一次真正
    /// 换人（且非首次出现）时递增 fanSweepToken——token
    /// 只传给聚焦卡，触发其扫光；首次定聚焦不递增、
    /// 不扫光。
    private func scheduleFanFocusSettle() {
        fanSettleTask?.cancel()
        fanSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let count = vm.tendieItems.count
            guard count > 0 else { return }
            let best = min(max(Int(fanPosition.rounded()), 0), count - 1)
            if let prev = fanFocusedIndex, prev != best {
                fanSweepToken += 1
            }
            fanFocusedIndex = best
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

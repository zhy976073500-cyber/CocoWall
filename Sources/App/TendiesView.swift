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
import ImageIO

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

/// 轮播外圈静态简版卡（run #144）：安装窗口外圈
/// （3.4 < |d| ≤ 4.5）专用——只有缩略图 + 渐变 +
/// 卡名，变换公式与 FanCardView 在该距离段的取值逐
/// 项同口径（倾斜 9°×clamp(d, ±2.2)、下沉 17×
/// clamp(d, ±2)²、scale 1.08 − 0.07×min(|d|, 2)、
/// brightness −0.28、缩略图去色 0.30、zIndex 同公
/// 式），但无 blur、无阴影、无手势、无 .task：先
/// 以近乎零成本在树里占位，卡滑进 3.4 升为全卡时
/// 视图构建与解码不再卡在高速滑动路径上。
/// 位置源（run #149 订正）：#144–#148 本视图读目标
/// 距离 d（index − fanPosition）、全卡读弹簧距离 d̃
/// （index − p̃），双源并存是快滑重影的真凶——高速
/// 时弹簧追赶滞后 (p − p̃) 达 1–2 格以上，卡在
/// 3.4 边界由简版升全卡的瞬间按整段滞后量（约
/// 100–230pt）瞬移，与邻卡每帧约 8–16pt 的位移完
/// 全脱节，眼睛即读成同一张卡的双像（定因全账见
/// SPEC #149）。本轮起与全卡同源：父以 index − p̃
/// 传入（积分器按全 index 积分，run #150 迁入
/// FanPhysicsIntegrator），变换公式逐项不变（对任意 |d| 均有
/// 定义、钳制段外仅 offset 线性延伸，与全卡同），
/// 边界两侧位置连续、升/降级不再瞬移。
private struct FanCardGhostView: View {
    let item: TendieItem
    /// 显示距离 d̃（run #149 起与 FanCardView 同源：父
    /// 视图物理循环积分出的本卡弹簧化位置 p̃ 换算的
    /// index − p̃，带符号：正值在本卡位于视口中心右侧）。
    let shownD: Double

    var body: some View {
        let d = shownD
        let a = abs(d)
        let dc = min(2, max(-2, d))
        ZStack(alignment: .bottomLeading) {
            TendieThumbnailView(item: item)
                .frame(width: 150, height: 200)
                .clipped()
                // 轻去色只挂缩略图本体（与全卡 #137 口径一致）。
                .saturation(1 - 0.30 * min(a / 1.8, 1))
            LinearGradient(colors: [.clear, .black.opacity(0.38)],
                           startPoint: .center, endPoint: .bottom)
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
        .frame(width: 150, height: 200)
        .brightness(-0.28 * min(a / 1.8, 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .rotationEffect(.degrees(9 * min(2.2, max(-2.2, d))), anchor: UnitPoint(x: 0.5, y: 0.92))
        .offset(x: CGFloat(d) * 96, y: CGFloat(17 * dc * dc))
        .scaleEffect(1.08 - 0.07 * min(a, 2))
        .zIndex(100 - (a * 10).rounded())
        // 纯占位：不接任何手势，触摸穿透到带容器。
        .allowsHitTesting(false)
    }
}

/// 轮播单卡（run #136 独立子视图、#138 换底盘沿用、
/// #145 改无状态）：延迟轮盘式轮播的卡片子视图。
/// #145 起本视图不再自持任何运动状态——父视图以单
/// 一物理循环积分全卡的弹簧化位置 p̃（见 FanStripView
/// 的 FanPhysicsIntegrator），本视图只收显
/// 示距离 d̃ 并据此渲染：d̃ 同时决定本卡的布局横移
/// （父以 ZStack 把卡心放在视口中心，本视图以
/// offset x = d̃×96 平移）与全部变换——滑动时近卡先
/// 行、远卡按距离递增拖后，卡间距在运动中真实伸缩
/// （级联核心）；静止时 p̃ 与目标 p 精确一致、布局
/// 不漂移。选中集与长按菜单仍归父视图管，经回调回
/// 传。两侧卡保持正脸（无 3D 转侧），只倾斜/下沉/
/// 变暗/轻微虚化，缩略图另带轻去色（#137）。
private struct FanCardView: View {
    @EnvironmentObject var vm: AppViewModel
    let item: TendieItem
    /// 本卡在带内的序号。
    let index: Int
    /// 显示距离 d̃（run #145）：父视图物理循环积分出
    /// 的本卡弹簧化位置 p̃ 换算的 index − p̃（带符号：
    /// 正值在本卡位于视口中心右侧）。本卡的布局横移
    /// 与全部变换只由它推导。
    let shownD: Double
    /// 扫光触发 token：本卡为停稳聚焦卡时等于父视图的
    /// 递增计数、非聚焦卡为 0；跳到新的正值时播一次扫光。
    let sweepToken: Int
    /// 阴影静态标记（run #143 立、#144 曾扩展、#145
    /// 回到 #143 口径）：仅拖动进行中为真——拖动期用
    /// 一组静态阴影值（radius 10 / y 6 / opacity
    /// 0.18），避开逐帧离屏重绘；父以 fanDragStart
    /// != nil 传入。#144 曾把它扩到整个运动期（含吸
    /// 附在飞），随高速直跟、blur 冻结在 #145 一并撤
    /// 销：弹簧全程存活后，吸附期阴影随 d̃ 的变化本
    /// 就是观感的一部分，静态只留手指直接驱动的拖
    /// 动期（#143 原口径）。
    let shadowStatic: Bool
    /// 预览补全推迟标记（run #144，保留）：运动未停稳
    /// 时为真，本卡 .task 不跑 regenerateTendiePreview；
    /// 停稳后转假、.task 补跑，解压提取不落在滑动路
    /// 径上。停稳信号 #145 起改由父级物理量判定
    /// （全卡速度与位差均足够小、持续数帧；run #150
    /// 起父以 integrator.isSettled 逐帧直传本标记）。
    let previewsDeferred: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// 扫光光带当前 x 偏移（pt）：停在 −155（旋转光带
    /// 完全出卡左界、被卡面裁掉不可见），触发时先瞬时
    /// 归位 −155、再动画扫到 +155。
    @State private var sweepX: CGFloat = -155

    // 延迟轮盘变换量（run #140 自 body 拆出为独立计算
    // 属性：曲线 #136 立、#137 修分层、#138 倾斜/下沉/
    // 缩放按原视频实测签名更新，全部由 d̃ 推导）：
    // 绕底部锚点向外倾斜 9°×clamp(d̃, ±2.2)（实测约
    // 9–10°/格、最远约 20°）；沿弧下沉 17×clamp(d̃, ±2)²
    // （实测弧陡，|d|=2 约卡高 1/3）；整卡压暗
    // −0.28×min(|d̃|/1.8, 1)（#137，深度主要靠变暗）；
    // 模糊只留轻微虚化——正中 ±0.55 内为 0、其后线性
    // 升至 1.6pt 封顶（#137）；缩略图另加轻去色 0.30
    // 封顶（#137，只挂缩略图本体）；缩放 1.08 起、随
    // |d̃| 收到 0.94（#138 实测口径）。布局横移即链尾
    // offset x = d̃×96 本身——#136 的 lagX 换算项退役：
    // 滞后现在就是位置本身的滞后，不再二次换算。
    /// 倾斜角（度）。
    private var lagTilt: Double { 9 * min(2.2, max(-2.2, shownD)) }
    /// 沿弧下沉量（pt）。
    private var lagDropY: CGFloat {
        let d = min(2, max(-2, shownD))
        return CGFloat(17 * d * d)
    }
    /// 缩放（选中回弹 1.04 在 positionedFace 段另乘）。
    private var lagScale: Double { 1.08 - 0.07 * min(abs(shownD), 2) }
    /// 整卡压暗量。
    private var lagBrightness: Double { -0.28 * min(abs(shownD) / 1.8, 1) }
    /// 模糊组虚化半径（pt）。run #143：半径先量化到
    /// 0.5pt 台阶再施加——逐帧连续变化的半径会让模糊
    /// 每帧换一套光栅化参数、徒增开销；曲线本体（#137
    /// 口径）不变，只是输出取整到最近 0.5。
    private var lagBlur: CGFloat {
        let raw = 1.6 * min(max(abs(shownD) - 0.55, 0) / 1.45, 1)
        return CGFloat((raw * 2).rounded() / 2)
    }
    /// 缩略图去色后的饱和度。
    private var lagSaturation: Double { 1 - 0.30 * min(abs(shownD) / 1.8, 1) }
    /// 层级（近中心压远端）。
    private var lagZIndex: Double { 100 - (abs(shownD) * 10).rounded() }
    // 阴影沿 #135 的 |d| 衰减口径，改由 shownD 驱动：
    // 近中心投影大而软、远端收紧。
    /// 阴影半径（pt）。
    private var lagShadowRadius: CGFloat { CGFloat(6 + 14 * (1 - min(abs(shownD), 1))) }
    /// 阴影纵向偏移（pt）。
    private var lagShadowY: CGFloat { CGFloat(4 + 6 * (1 - min(abs(shownD), 1))) }
    // 拖动期静态阴影（run #143 立）：拖动进行中（父
    // 传入 shadowStatic）改用一组静态值（radius 10 /
    // y 6 / opacity 0.18），避开拖动逐帧的离屏 alpha
    // 轮廓重绘；其余时间恢复上面随 |d̃| 衰减的动态口
    // 径。静态三值与动态公式均未动。#144 曾把静态覆
    // 盖面扩到整个运动期（含吸附），#145 已回到本口
    // 径（见 shadowStatic 注释）。
    /// 当前生效的阴影半径（pt）。
    private var activeShadowRadius: CGFloat { shadowStatic ? 10 : lagShadowRadius }
    /// 当前生效的阴影纵向偏移（pt）。
    private var activeShadowY: CGFloat { shadowStatic ? 6 : lagShadowY }
    /// 当前生效的阴影不透明度。
    private var activeShadowOpacity: Double { shadowStatic ? 0.18 : 0.22 }

    /// 模糊组（run #140 自 body 拆出）：缩略图 + 底部
    /// 渐变 + 卡名——模糊只作用于此组，勾选徽章在其
    /// 外保持锐利。
    private var cardContent: some View {
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
        // run #143：先 compositingGroup 把卡面拍平，
        // 模糊只对拍平结果算一次，不再逐子层重复采样。
        // 半径取 lagBlur 逐帧曲线（#144 的高速冻结已随
        // 直跟旁路在 #145 一并撤销，见 SPEC #145）。
        .compositingGroup()
        .blur(radius: lagBlur)
    }

    /// 选中徽章（run #140 自 body 拆出）：卡面右下角，
    /// 在模糊组之外，不模糊、不去色。
    @ViewBuilder
    private var selectionBadge: some View {
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

    /// 卡面本体（run #140 自 body 拆出）：模糊组 + 选中
    /// 徽章的组合，ZStack 本体只做组合；变换与手势在
    /// 其后的三段链（run #141）里。
    private var cardFace: some View {
        ZStack(alignment: .bottomLeading) {
            cardContent
            selectionBadge
        }
    }

    /// 选中描边（run #140 自 body 拆出）：baseFace 以
    /// overlay 形式叠在卡面之上。
    @ViewBuilder
    private var selectionRing: some View {
        if item.isSelected {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.blue, lineWidth: 3)
        }
    }

    // 扫光（run #136；run #140 自 body 拆出为独立子
    // 表达式，baseFace 以 overlay 形式叠加）：白色线性
    // 渐变光带（宽约卡宽 45%、峰值 alpha 0.35、倾斜
    // 约 20°），在自身容器内裁到卡圆角，不影响选中
    // 描边；光带旋转后横向半幅约 76pt，故行程取
    // ±155（略大于半卡宽 75 + 76）保证两端完全出卡。
    private var sweepOverlay: some View {
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

    // run #141：#140 后 CI 仍红——超时自卡面表达式挪进
    // body 修饰链本身（379 行 .overlay { sweepOverlay }
    // 处报错）。本轮把链按原顺序切成三段带显式返回
    // 类型（some View）的计算属性，每段 ≤6 个修饰符，
    // body 只返回最后一段；闭包式 overlay 改值式。
    // 修饰符顺序与参数与 #140 逐一等价，纯结构拆分：
    // #139 手势接线语义与 #138 全部常数/曲线/吸附/
    // 扫光一字未改。
    // run #145 续：链段三再删两项 onChange（位置弹簧
    // 追赶与高速冻结捕获，运动核心上移父级），三段结
    // 构与剩余修饰符的顺序不变。

    /// 链段一（修饰符 1–6）：卡面 + 尺寸/压暗/裁形/
    /// 描边/扫光/阴影。
    private var baseFace: some View {
        cardFace
            .frame(width: 150, height: 200)
            // 变暗作用于整卡（含卡名与勾选徽章）：#137 起
            // 深度主要靠压暗承担，模糊只留轻微虚化、缩略图
            // 另带一点去色（见上 lagSaturation）。
            .brightness(lagBrightness)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(selectionRing)
            .overlay(sweepOverlay)
            .shadow(color: .black.opacity(activeShadowOpacity), radius: activeShadowRadius, x: 0, y: activeShadowY)
    }

    /// 链段二（修饰符 7–12）：命中形状/点按/长按 +
    /// 倾斜/横移/缩放。
    private var positionedFace: some View {
        baseFace
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // 点按选中 / 长按出菜单（run #130 手势口径沿用）：
            // 只回调父视图，触觉与状态变更在父侧。容器拖动
            // 与本手势同时识别（run #139）：真实拖动位移超过
            // 长按失败距离（10pt）后长按自然失败、不会误出
            // 菜单；菜单打开期间的冻结由父视图在拖动的
            // onChanged/onEnded 开头判定 fanMenuTarget 处理。
            .onTapGesture { onTap() }
            .onLongPressGesture(minimumDuration: 0.45) { onLongPress() }
            // 延迟轮盘几何（run #138）：倾斜绕底部锚点
            // (0.5, 0.92) 向外倒；offset x = d̃×96 即卡的
            // 布局横移本身（父以 ZStack 把卡心放在视口
            // 中心），y 为沿弧下沉 lagDropY；选中回弹 1.04
            // 并入缩放（弹簧 .animation(value: isSelected)
            // 沿用 #130，只在选中态变化时触发，不干扰父
            // 级物理循环的逐帧积分）。hit 区按未倾斜卡框
            // 判定（contentShape），倾斜最大约 19.8°、错
            // 位有限，见 SPEC #138 未验证项。
            .rotationEffect(.degrees(lagTilt), anchor: UnitPoint(x: 0.5, y: 0.92))
            .offset(x: CGFloat(shownD) * 96, y: lagDropY)
            .scaleEffect(lagScale * (item.isSelected ? 1.04 : 1.0))
    }

    /// 链段三（修饰符 13–16）：选中动画/层级 + 扫光
    /// 触发/预览补全推迟。run #145：原链内的位置弹簧
    /// 追赶 onChange（#138 立、#143/#144 先后加过直跟
    /// 分支）与高速态冻结捕获 onChange（#144）随运动
    /// 核心上移父级一并删除——卡的位置改由父级物理
    /// 循环积分、经 shownD 入参直达链段二的 offset，
    /// 本段回到 4 个修饰符。
    private var interactiveFace: some View {
        positionedFace
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: item.isSelected)
            .zIndex(lagZIndex)
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
            // 预览补全（run #144 改推迟口径、保留）：
            // .task(id:) 以 previewsDeferred 为标识——运
            // 动期（deferred = true）任务起来即返回、不
            // 解压不提取；停稳后父传 deferred 转假，
            // 任务标识变化自动重跑、此时
            // 才补全（已存预览缺失或解码失败时从包内重
            // 新提取，与旧列表行同口径）。停稳信号 #145
            // 起为物理量判定（见 FanStripView）。
            .task(id: previewsDeferred) {
                guard !previewsDeferred else { return }
                vm.regenerateTendiePreview(itemID: item.id)
            }
    }

    var body: some View {
        interactiveFace
    }
}

/// 轮播物理积分器（run #150 自 #145 的 FanPhysics 值
/// 结构体 + stepFanPhysics 函数改造）：引用型类，由
/// FanStripView 以 @StateObject 持有——无 @Published
/// 属性，逐 tick 的积分写入不经 SwiftUI 的 @State 失
/// 效通道，物理帧的求值范围因此收在 TimelineView 内
/// 容里（审计 S3）；位置计算就在 TimelineView 内容
/// 求值中一步完成（advance 紧接着渲染，见
/// FanStripView.stripFrame），不再有 #145 的
/// 「onChange 写回状态、旧物理先成一帧、新物理再成
/// 一帧」两遍模式（审计 S1）。积分公式与 #145 逐项
/// 一致：半隐式欧拉，ω = 2π / (0.55 + 0.10×min(|i
/// − p|, 2.5))、k = ω²、c = 2×0.92×ω，dt 取帧间真
/// 实差钳 0.05、> 1/40 分两步；停稳判定同口径（全
/// 卡 |v| 与 |p − p̃| 均 < 0.005 连续 5 帧）。
private final class FanPhysicsIntegrator: ObservableObject {
    /// 每卡弹簧化位置 p̃（index 单位）：卡 i 的显示
    /// 距离 d̃ = i − positions[i]。
    private(set) var positions: [Double] = []
    /// 每卡速度（格/秒），与 positions 同序同长。
    private(set) var velocities: [Double] = []
    /// 全卡同时满足静止阈值的连续帧数：达 5 帧判
    /// 停稳（见 advance 的停稳判定）。
    private(set) var settledFrames: Int = 0
    /// 上一积分帧的时刻：算帧间真实 dt 用；TimelineView
    /// 暂停期间不更新，恢复后首帧的大 dt 由积分内的
    /// 钳制兜底。
    private var lastStepDate: Date? = nil
    /// 每卡安装分区（run #150 S2）：2 全卡 / 1 简版 /
    /// 0 不进树，与 positions 同序同长。分区键改用弹
    /// 簧距离 shownD（#144–#149 按目标距离分区、位置
    /// 按 shownD，高速滞后 1–2 格以上时处理倒置：简
    /// 版锐卡被拉进活跃区、全卡被推到窗外，见审计
    /// S2）；升/降级带 ±0.15 迟滞，防临界卡逐帧换分
    /// 支闪烁（审计 S2 后果 C）。
    private(set) var zones: [Int] = []

    /// 是否停稳（判定与 #145 同口径）。
    var isSettled: Bool { settledFrames >= 5 }

    /// 无迟滞的基础分区（新卡初始分区与数组未同步时
    /// 的回退）：窗口宽度沿 #144——|d̃| ≤ 3.4 全卡、
    /// ≤ 4.5 简版、之外不进树（3.4×96 = 326 > 视口
    /// 半宽约 215 + 半卡宽 75 = 290，全卡区外必然屏
    /// 外；外圈简版先行占位，卡高速滑入时视图构建与
    /// 解码已提前完成、不卡在滑动路径上）。
    static func plainZone(shownD: Double) -> Int {
        let a = abs(shownD)
        if a <= 3.4 { return 2 }
        if a <= 4.5 { return 1 }
        return 0
    }

    /// 第 idx 卡当前分区：数组未同步到该序号时以
    /// shownD 现算基础分区回退。
    func zone(at idx: Int, shownD: Double) -> Int {
        idx < zones.count ? zones[idx] : Self.plainZone(shownD: shownD)
    }

    /// 第 idx 卡的弹簧化位置 p̃：数组未同步到该序号
    /// 时回退目标 p（此时 d̃ = 目标距离，卡以正确位
    /// 置直接出现、无飞入）。
    func tilde(at idx: Int, target: Double) -> Double {
        idx < positions.count ? positions[idx] : target
    }

    /// 物理数组与卡数对齐（run #145 口径沿用）：新增
    /// 序号的 p̃ 以当前目标 p 初始化（以正确位置直接
    /// 出现、无飞入）、速度 0、分区按其 shownD 取基
    /// 础值；既有序号保留各自 p̃、速度与分区。删除
    /// 中间卡时后续序号的条目随 item 滑动对位、位置
    /// 本身不跳——与按 index 的安装窗口口径一致。
    func syncCount(_ count: Int, target: Double) {
        if positions.count > count {
            positions.removeLast(positions.count - count)
            velocities.removeLast(velocities.count - count)
            zones.removeLast(zones.count - count)
        }
        while positions.count < count {
            let idx = positions.count
            positions.append(target)
            velocities.append(0)
            zones.append(Self.plainZone(shownD: Double(idx) - target))
        }
    }

    /// 唤醒（run #145 口径沿用）：目标或卡集变化后清
    /// 零停稳帧数——积分把各卡带回静止后自然重判停稳。
    func wake() {
        settledFrames = 0
    }

    /// 推进一帧（由 FanStripView 的 TimelineView 内容
    /// 求值直接调用，紧接着以新位置渲染本帧）。返回
    /// 本帧是否发生停稳上升沿（未停稳→停稳）：聚焦
    /// 推导与 fanIsSettled 写回都是视图状态、不能在
    /// 求值内做，由调用方在求值外收口（见
    /// FanStripView.stripTimeline）。
    @discardableResult
    func advance(to date: Date, target: Double, count: Int) -> Bool {
        let last = lastStepDate
        lastStepDate = date
        guard count > 0, let last else { return false }
        let rawDt = date.timeIntervalSince(last)
        guard rawDt > 0 else { return false }
        syncCount(count, target: target)
        let dt = min(rawDt, 0.05)
        let steps = dt > 1.0 / 40.0 ? 2 : 1
        let h = dt / Double(steps)
        for _ in 0..<steps {
            for i in 0..<count {
                let dist = abs(Double(i) - target)
                let omega = 2 * Double.pi / (0.55 + 0.10 * min(dist, 2.5))
                let k = omega * omega
                let c = 2 * 0.92 * omega
                let a = k * (target - positions[i]) - c * velocities[i]
                velocities[i] += a * h
                positions[i] += velocities[i] * h
            }
        }
        var allRest = true
        for i in 0..<count {
            if abs(velocities[i]) >= 0.005 || abs(target - positions[i]) >= 0.005 {
                allRest = false
                break
            }
        }
        let wasSettled = isSettled
        settledFrames = allRest ? settledFrames + 1 : 0
        updateZones()
        return !wasSettled && isSettled
    }

    /// 分区迟滞更新（run #150 S2）：按积分后的 shownD
    /// 逐卡迁移分区——升全卡需 |d̃| ≤ 3.4 − 0.15、由
    /// 全卡降简版需 |d̃| > 3.4 + 0.15；简版入树/剔除
    /// 同理走 4.5 ∓ 0.15。跨界直达（全卡一步剔除、
    /// 剔除直升全卡）按同一组阈值一次到位。
    private func updateZones() {
        for i in zones.indices {
            let a = abs(Double(i) - positions[i])
            switch zones[i] {
            case 2:
                if a > 4.5 + 0.15 { zones[i] = 0 }
                else if a > 3.4 + 0.15 { zones[i] = 1 }
            case 1:
                if a <= 3.4 - 0.15 { zones[i] = 2 }
                else if a > 4.5 + 0.15 { zones[i] = 0 }
            default:
                if a <= 3.4 - 0.15 { zones[i] = 2 }
                else if a <= 4.5 - 0.15 { zones[i] = 1 }
            }
        }
    }
}

/// 轮播卡带（run #150 抽独立子视图，审计 S3）：自持
/// 全部轮播状态（目标主位置 p、拖动起点、聚焦与扫
/// 光、停稳标志）与物理积分器——物理 tick 的失效范
/// 围从 TendiesView 整页收进本视图，TendiesView.body
/// 对卡带只剩一次不透明子视图求值。与页面的接口只
/// 有长按菜单目标的 Binding（菜单 confirmationDialog
/// 挂在页面根部，呈现与拖动冻结判定都以它为准，见
/// TendiesView）；条目与选中态经 vm 直达，聚焦变化
/// 不出本视图。
private struct FanStripView: View {
    @EnvironmentObject var vm: AppViewModel
    /// 长按菜单目标（页面根部 confirmationDialog 的呈
    /// 现源）：卡片长按写入，对话框关闭由页面侧
    /// Binding 清零；拖动回调以它非 nil 为冻结判定
    /// （run #139 口径沿用）。
    @Binding var menuTarget: TendieItem?
    /// 物理积分器（run #150）：引用型持有，逐 tick 写
    /// 入不经 SwiftUI 失效通道（见 FanPhysicsIntegrator）。
    @StateObject private var integrator = FanPhysicsIntegrator()
    /// 轮播目标主位置 p（run #138 立、#145 改为纯目
    /// 标）：连续浮点、index 单位，p = k 表示第 k 卡
    /// 的目标居中位；拖动中由手势直给、松手以弹簧动
    /// 画到投影整格（见 fanDragGesture）。它只是目
    /// 标——各卡的实际位置是 integrator 里各自积分出
    /// 的 p̃，永远以弹簧追赶它（run #145 父级物理循
    /// 环、run #150 迁入积分器），带子的弹性全来自这
    /// 层追赶。初始 0（首卡居中）；有限长条不绕圈
    /// （同 #135 起口径）。
    @State private var fanPosition: Double = 0
    /// 拖动起点的主位置：非 nil 表示拖动进行中；吸附
    /// 投影与单次滑动格数上限都以它为基准。
    @State private var fanDragStart: Double? = nil
    /// 停稳聚焦 index 与扫光触发（run #136 立、#138 换
    /// 信号源、#145 改物理停稳触发）：积分判停稳时取
    /// round(p) 为聚焦格（见 deriveFanFocus）；聚焦真
    /// 正换人（非首次出现）时 fanSweepToken 递增，只
    /// 传给聚焦卡，触发它播一次扫光。
    @State private var fanFocusedIndex: Int? = nil
    @State private var fanSweepToken: Int = 0
    /// 停稳标志（run #144 立、#145 换信号源、#150 改
    /// 收口点）：真值由 integrator 的物理量判定，上升
    /// 沿由 advance 在 TimelineView 求值内返回——视图
    /// 状态写回不能在求值里做，故经主队列异步收口置
    /// 真（见 stripTimeline）；清零仍在各唤醒点同步做
    /// （手势松手/卡数变化/进场，均事件语境）。本标志
    /// 只驱动 TimelineView 的 paused 取值；卡的预览推
    /// 迟直接读 integrator.isSettled 逐帧新值、不等本
    /// 标志收口（语义与 #145 的 previewsDeferred 一致）。
    @State private var fanIsSettled: Bool = true

    var body: some View {
        Group {
            if vm.tendieItems.isEmpty {
                emptyPlaceholder
            } else {
                stripTimeline
            }
        }
        // 导入/删除使卡数变化：主位置钳回新范围、聚焦
        // index 越界失效、物理数组对齐新卡数，并唤醒积
        // 分循环重新判定停稳/聚焦，避免聚焦停在已删或
        // 错位的位置。挂在本视图根部、不随空/非空分支
        // 存亡（#148 排序只换序不换数、不触发本条；排
        // 序后回页时物理数组按 index 的对齐语义与排序
        // 前一致，聚焦由下一停稳沿重推）。
        .onChange(of: vm.tendieItems.count) { _, newCount in
            clampPosition(to: newCount)
            if let f = fanFocusedIndex, f >= newCount { fanFocusedIndex = nil }
            integrator.syncCount(newCount, target: fanPosition)
            wakeFanPhysics()
        }
        // 进场先钳位、对齐数组并唤醒一轮积分（首次定聚
        // 焦不扫光，见 deriveFanFocus）。
        .onAppear {
            clampPosition(to: vm.tendieItems.count)
            integrator.syncCount(vm.tendieItems.count, target: fanPosition)
            wakeFanPhysics()
        }
    }

    /// 空态占位（文案与布局自 TendiesView 的 fanZone
    /// 空分支原样迁入 run #150）。
    private var emptyPlaceholder: some View {
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
    }

    /// 卡带时间轴（run #150 S1）：位置计算搬进
    /// TimelineView 内容求值本身——每 tick 先以本帧日
    /// 期推进积分器、紧接着以刚算出的 p̃ 渲染，一次
    /// 求值一帧，消灭 #145 的 onChange 两遍模式；已停
    /// 稳且未拖动时 paused——不再发帧、静止零开销。
    /// 布局口径（run #138）：带高 256：卡心纵坐标
    /// 128 = 顶留 28（中心卡放大 1.08 的上沿外溢）+
    /// 半卡高 100；其下再垫 52，凑回 #136 的总高
    /// 308（= 28 + 200 + 底留 80）：下沉最大值
    /// 17×2² = 68，卡底 228 + 68 = 296，距带底 308
    /// 留约 12——下沉的卡不被裁掉、也不压到下方已选
    /// 行（本区不裁剪，尺寸核算只为防视觉重叠）。
    /// pitch 保持 #136 的 96、卡 150×200。
    private var stripTimeline: some View {
        TimelineView(.animation(paused: fanIsSettled && fanDragStart == nil)) { timeline in
            let settledEdge = integrator.advance(to: timeline.date,
                                                 target: fanPosition,
                                                 count: vm.tendieItems.count)
            if settledEdge {
                // 停稳收口：视图状态不能在 body 求值内
                // 写回，异步到主队列下一轮置真 + 推导聚
                // 焦；收口前若已被唤醒（integrator 已转
                // 未停稳）则放弃本次收口，等下一个上升沿。
                DispatchQueue.main.async {
                    guard integrator.isSettled else { return }
                    fanIsSettled = true
                    deriveFanFocus()
                }
            }
            stripFrame()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 256)
        .padding(.bottom, 52)
        // 整带（含下垫）都是拖动命中区：卡间空隙与
        // 卡下方留白也能起拖。
        .contentShape(Rectangle())
        // 拖动与子卡点按/长按同时识别、常开（run
        // #139）：不再用手势掩码门控——#138 的
        // pressing 掩码在手指一落卡即禁用拖动、整
        // 带滑不动（根因见 SPEC #139）；菜单打开
        // 期间的冻结改由拖动回调开头判定
        // menuTarget 后忽略更新。
        .simultaneousGesture(fanDragGesture)
    }

    /// 轮播卡带本体：ZStack 把每卡的布局中心放在带中
    /// 心，卡的实际横向位置由其内部 offset（d̃×96）决
    /// 定，d̃ 读积分器刚推进出的 p̃（见 tilde）；卡本身
    /// 无状态（run #145）。安装分区（run #150 S2 改
    /// 键）：按弹簧距离 shownD 经 integrator 的迟滞分
    /// 区（全卡 ≤ 3.4、简版 ≤ 4.5、之外不进树，窗口
    /// 宽度沿 #144）——分区与位置同源，高速滞后下不
    /// 再有按目标分区造成的处理倒置，升/降级带 ±0.15
    /// 迟滞不逐帧闪烁。
    private func stripFrame() -> some View {
        ZStack {
            ForEach(Array(vm.tendieItems.enumerated()), id: \.element.id) { idx, item in
                let shownD = Double(idx) - integrator.tilde(at: idx, target: fanPosition)
                let zone = integrator.zone(at: idx, shownD: shownD)
                if zone == 2 {
                    FanCardView(item: item,
                                index: idx,
                                shownD: shownD,
                                sweepToken: idx == fanFocusedIndex ? fanSweepToken : 0,
                                shadowStatic: fanDragStart != nil,
                                previewsDeferred: !integrator.isSettled,
                                onTap: {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    toggleSelection(itemID: item.id)
                                },
                                onLongPress: {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    menuTarget = item
                                })
                } else if zone == 1 {
                    FanCardGhostView(item: item,
                                     shownD: shownD)
                }
            }
        }
    }

    /// 点按选中切换（自 TendiesView 原样迁入 run #150：
    /// 只经 vm 变更选中态，页面已选行读同一 vm）。
    private func toggleSelection(itemID: UUID) {
        if let idx = vm.tendieItems.firstIndex(where: { $0.id == itemID }) {
            vm.tendieItems[idx].isSelected.toggle()
        }
    }

    /// 主位置钳回 [0, n−1] 上界（run #145 起 fanZone
    /// 两处钳位口径的合并：原实现只钳上界——p 的下界
    /// 由橡皮筋与吸附保证不越 0 的持久值）。
    private func clampPosition(to count: Int) {
        let maxP = Double(max(count - 1, 0))
        if fanPosition > maxP { fanPosition = maxP }
    }

    /// 唤醒物理循环（run #145 口径沿用、run #150 迁入
    /// 本视图）：目标或卡集变化后清零积分器停稳帧数
    /// 并置未停稳——TimelineView 随 fanIsSettled 转假
    /// 恢复发帧，积分把各卡带回静止后自然重判停稳并
    /// 推导聚焦（物理量判定，不假设固定时长）。调用
    /// 点全在事件语境（手势松手/卡数变化/进场）。
    private func wakeFanPhysics() {
        integrator.wake()
        fanIsSettled = false
    }

    /// 容器拖动（run #138）：DragGesture(minimumDistance: 4)
    /// ——未达阈值的轻触仍走子卡点按。拖动中目标 p 实时
    /// 跟手（p = 起点 p − translation.width/96：向左拖 p
    /// 增大、带向左走，与 #136 的 ScrollView 滑动方向一
    /// 致），超出 [0, n−1] 的部分由 fanRubberBanded 按
    /// 0.35 橡皮筋。各卡的实际位置不直接跟 p——由积分
    /// 器以各自弹簧追赶（run #145），拖动中带子也始终
    /// 荡在手指之后（参考实现即如此）。松手以
    /// predictedEndTranslation 投影落点、四舍五入到整格
    /// （相对起点取整最多 ±4 格——单次滑动上限，可调旋
    /// 钮，见 SPEC #138），再钳到 [0, n−1]，以
    /// response 0.8 / 阻尼 0.95 的弹簧把目标 p 动画过
    /// 去——主位置的慢软落位保留 SwiftUI 动画，逐卡级
    /// 联由积分弹簧产生。菜单打开期间的冻结（run
    /// #139）：两个回调开头先判 menuTarget——非 nil
    /// 时 onChanged 直接忽略本次更新、onEnded 只清拖动
    /// 起点不做吸附；菜单由长按识别成功后才打开，那时
    /// 手指位移 ≤ 长按失败距离（10pt），此前 p 的漂移
    /// 不足 0.11 格、可忽略，不回滚。
    private var fanDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard menuTarget == nil else { return }
                if fanDragStart == nil {
                    fanDragStart = fanPosition
                }
                let start = fanDragStart ?? fanPosition
                fanPosition = fanRubberBanded(start - Double(value.translation.width) / 96)
            }
            .onEnded { value in
                let start = fanDragStart ?? fanPosition
                fanDragStart = nil
                guard menuTarget == nil else { return }
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
                // 唤醒物理循环（run #145）：目标刚跳变，而
                // 各卡可能恰处静止（慢拖停稳后松手的情
                // 形）——不唤醒的话 TimelineView 还停在暂
                // 停态、积分不跑、带子会冻在原地；唤醒后
                // 积分把各卡带向新目标并重新判定停稳。
                wakeFanPhysics()
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

    /// 停稳聚焦推导（run #136 立、#138 换信号源、#145
    /// 改物理停稳触发）：聚焦格 = round(p)（钳到有效
    /// 范围）；相对上一次真正换人（且非首次出现）时递
    /// 增 fanSweepToken——token 只传给聚焦卡，触发其扫
    /// 光；首次定聚焦不递增、不扫光。
    private func deriveFanFocus() {
        let count = vm.tendieItems.count
        guard count > 0 else { return }
        let best = min(max(Int(fanPosition.rounded()), 0), count - 1)
        if let prev = fanFocusedIndex, prev != best {
            fanSweepToken += 1
        }
        fanFocusedIndex = best
    }
}

struct TendiesView: View {
    @EnvironmentObject var vm: AppViewModel
    /// 深色适配（run #149）：底部 sheet 一套颜色 token
    /// 随此值取双值（见文件内 sheet 色板一节）。
    @Environment(\.colorScheme) private var colorScheme
    @State private var showFilePicker = false
    @State private var selectedDetailItem: TendieItem? = nil
    @State private var isNeoSpringing = false
    @State private var showImportedPage = false
    /// 扇形卡长按菜单的目标项（run #130）：非 nil 时轮播
    /// 拖动冻结（run #139：拖动 onChanged/onEnded 开头
    /// 判定后忽略更新）、页面根部弹 confirmationDialog
    /// 呈现「详情/删除」。
    @State private var fanMenuTarget: TendieItem? = nil
    /// 轮播的其余状态（目标主位置 p、拖动起点、聚焦与
    /// 扫光、停稳标志）与物理积分器已随 run #150 整体
    /// 迁入 FanStripView 自持（见文件前部）：物理 tick
    /// 不再触发本页整页重演；本页与卡带只经上面的
    /// fanMenuTarget 一个 Binding 相连。

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
                        // run #149：底色经 errorBannerBackground 取双值
                        // （深色加深到 18%，浅色 8% 原值不变）。
                        .background(errorBannerBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            // fanMenuTarget（run #139 起轮播拖动在回调内判定
            // 冻结；#138 曾用手势掩码、#136 时为 ScrollView
            // 的 scrollDisabled）后，在此以
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
                // 进页刷新延后（run #148）：页面先用启动时
                // 已载入的持久化库（loadSavedTendies 的上次
                // 扫描结果 + 已存预览）立即出画，Documents
                // 增量扫描推到首帧之后再跑——原实现 onAppear
                // 同步枚举目录、发现新包时当场触发整包导入
                // （解压提取），全压在进页路径上（见 SPEC
                // #148 第四件的定因）。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    vm.scanDocumentsForTendies()
                }
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

    // MARK: - 轮播壁纸区（run #138 换底盘：手势直驱 + 每卡位置弹簧，撤 ScrollView；run #145 运动核心换父级物理循环；run #150 抽独立 FanStripView 自持物理状态，见文件前部——本页对卡带只剩一次不透明子视图求值，接口仅长按菜单目标 Binding）

    private var fanZone: some View {
        FanStripView(menuTarget: $fanMenuTarget)
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

    // sheet 色板（run #149 深色适配）：#128/#131 的浅色
    // 取值逐值保留为 light 分支（#F7F7FA/纯白/#0071E3
    // 原样），dark 分支走苹果系统深色语汇（面板
    // #1C1C1E、瓷砖 #2C2C2E、主按钮 #0A84FF）。此前全
    // 部硬编码浅色：深色模式下页面背景与 tab 栏已变
    // 黑、sheet 仍白，而文字早已是 .primary/.secondary
    // 语义色（深色下自动变白）——白字落白底，状态条标
    // 签与次级文案即糊掉（Sage 录屏实证）。本轮只换背
    // 景侧 token，文字语义色一字不动；仍守 #131 平面
    // 实色口径，深色不上玻璃（Sage 03:20 例外不变）。
    /// sheet 面板底色（light 设计稿 #F7F7FA / dark #1C1C1E）。
    private var sheetBackground: Color {
        colorScheme == .dark
            ? Color(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255)
            : Color(red: 247.0 / 255, green: 247.0 / 255, blue: 250.0 / 255)
    }
    /// sheet 内瓷砖/宽条/状态胶囊底色（light 纯白 / dark #2C2C2E）。
    private var sheetTileBackground: Color {
        colorScheme == .dark
            ? Color(red: 44.0 / 255, green: 44.0 / 255, blue: 46.0 / 255)
            : Color.white
    }
    /// 刷入主按钮蓝（light 设计稿 #0071E3 / dark #0A84FF 系统深色蓝）。
    private var flashBlue: Color {
        colorScheme == .dark
            ? Color(red: 10.0 / 255, green: 132.0 / 255, blue: 255.0 / 255)
            : Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255)
    }
    /// 错误横幅底色（light 红 8% / dark 红 18%：深色下 8% 近乎不可见）。
    private var errorBannerBackground: Color {
        Color.red.opacity(colorScheme == .dark ? 0.18 : 0.08)
    }
    /// 双列瓷砖图标底圆的不透明度（light 现值 0.12 保留 /
    /// dark 略提亮到 0.22：深色下同值发暗）。
    private var tileWellOpacity: Double { colorScheme == .dark ? 0.22 : 0.12 }
    /// 宽条（导入/清除）图标底圆的不透明度（light 现值
    /// 0.10 保留 / dark 0.20，同上理由）。
    private var barWellOpacity: Double { colorScheme == .dark ? 0.20 : 0.10 }

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
        .background(sheetBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
        .background(sheetTileBackground, in: Capsule())
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
            .background(sheetTileBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            .background(selectedCount == 0 ? flashBlue.opacity(0.45) : flashBlue, in: Capsule())
            .shadow(color: flashBlue.opacity(0.28), radius: 11, x: 0, y: 5)
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
                    Circle().fill(Color.blue.opacity(barWellOpacity))
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
            .background(sheetTileBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                    Circle().fill(tint.opacity(tileWellOpacity))
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
            .background(sheetTileBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                    Circle().fill(Color.red.opacity(barWellOpacity))
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
            .background(sheetTileBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        if let uiImg = Self.decodedImage(for: item) {
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

    // 解码缓存（run #144）：原实现每次 body 求值都
    // UIImage(data:) 全量解码一遍预览 JPEG——轮播运动
    // 时每卡每帧 body 重跑，等于主线程逐帧重复解码。
    // 改为：ImageIO 降采样解码（缩略图直出、跳过全尺
    // 寸中间图）+ NSCache 按「条目 id + 数据长度 +
    // 数据哈希」缓存；预览被再生替换时键随数据变、自
    // 动失效。显示上限 600px：卡面显示 150×200pt
    // @3x = 450×600px，且已存预览的规格本就是最长边
    // 600（见 AppViewModel.extractPreviewData），降采
    // 样后画质与原口径一致。NSCache 线程安全、内存压
    // 力时自动回收；countLimit 48 覆盖轮播与展开页同
    // 屏所需。
    //
    // run #148 提额：48 的上限小于真实库规模（Sage 真
    // 机 99 张）——展开页来回滚时先解码的格子必然被逐
    // 出、回来再付一遍同步解码，正是滚动卡顿的一环。
    // 改为 countLimit 160（覆盖整库 + 轮播同屏）并加
    // totalCostLimit 64MB 按解码像素计价封顶，内存压
    // 力下仍由 NSCache 自动回收。
    private static let decodeCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static func decodedImage(for item: TendieItem) -> UIImage? {
        guard let data = item.previewImageData else { return nil }
        let key = "\(item.id.uuidString)|\(data.count)|\(data.hashValue)" as NSString
        if let hit = decodeCache.object(forKey: key) { return hit }
        let image = downsampledImage(from: data, maxPixel: 600)
        if let image {
            let cost = Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
            decodeCache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// ImageIO 降采样解码：建源时不缓存、缩略图立即
    /// 解码（ShouldCacheImmediately），避免首次上屏再
    /// 付一遍解码；任一步失败回退 UIImage(data:) 原
    /// 口径，显示语义与旧实现一致。
    private static func downsampledImage(from data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data)
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
///
/// run #142：版式按清理页设计稿 v2 实装——每行独立成
/// 整行全胶囊玻璃面、行距 8，浮在柔和氛围底上（撤旧版
/// List 大白容器）；顶栏改自绘页头：关闭/刷新做玻璃
/// 圆钮、导航栏隐藏；底部改悬浮玻璃条承载已选计数与
/// 清理钮（0 选灰置、>0 红色强调）。数据来源、勾选/
/// 全选、清理确认与删除流程、刷新/关闭行为一字未动，
/// 只动呈现层（见 SPEC #142）。
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
            ZStack {
                cleanupAmbientBackground
                VStack(spacing: 0) {
                    cleanupHeader
                    // 清理实时进度（run #148）：阶段文案 +
                    // 计数 + 确定型进度条，数据来自
                    // vm.cleanupProgress（PosterStoreHelper
                    // 标记映射 + 删后刷新段衔接）；只呈现，
                    // 不参与删除流程。
                    if let progress = vm.cleanupProgress {
                        VStack(spacing: 6) {
                            HStack {
                                Text(progress.stageText)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if progress.phase == .deleting {
                                    Text("\(progress.completed)/\(progress.total)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ProgressView(value: progress.fraction)
                                .tint(Color.accentColor)
                                .animation(.easeOut(duration: 0.25), value: progress.fraction)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    if vm.isScanningDevicePosters {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在检测设备数据仓…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.devicePosters.isEmpty {
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        cleanupCountRow
                        cleanupRows
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: vm.tendieItems) { _, _ in
                // A library preview regenerated after the cleanup
                // list was built can fill in a row thumbnail that
                // was missing (run #122).
                vm.prepareDevicePosterThumbnails()
            }
            .safeAreaInset(edge: .bottom) {
                if !vm.devicePosters.isEmpty {
                    cleanupBottomBar
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

    /// 氛围底（run #142）：近白底 + 四团大半径模糊的
    /// 柔和彩晕（蓝/绿/桃/紫），参照设计稿 v2 的环境
    /// 光感；纯装饰，不拦截触摸。
    private var cleanupAmbientBackground: some View {
        ZStack {
            Color(red: 0.96, green: 0.96, blue: 0.98)
            Circle()
                .fill(Color.blue.opacity(0.28))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: -160, y: -330)
            Circle()
                .fill(Color.green.opacity(0.26))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: 180, y: -300)
            Circle()
                .fill(Color.orange.opacity(0.22))
                .frame(width: 340, height: 340)
                .blur(radius: 95)
                .offset(x: 200, y: 60)
            Circle()
                .fill(Color.purple.opacity(0.20))
                .frame(width: 360, height: 360)
                .blur(radius: 100)
                .offset(x: -180, y: 330)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 页头（run #142）：关闭 = 玻璃胶囊钮、刷新 = 玻璃
    /// 圆钮（参照液态玻璃概念图的 Edit / compose 钮），
    /// 标题居中加粗；行为沿旧 toolbar——关闭 dismiss、
    /// 刷新重扫、扫描/清理中刷新禁用。
    private var cleanupHeader: some View {
        ZStack {
            Text("本机已导入的壁纸")
                .font(.headline)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .glassSurface(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    Task {
                        await vm.detectDevicePosters()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .glassSurface(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(vm.isScanningDevicePosters || vm.isCleaningDevicePosters)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// 计数行（run #142）：文案与全选/取消全选行为沿用
    /// 旧 Section 头；全选钮改玻璃小胶囊。
    private var cleanupCountRow: some View {
        HStack {
            Text("设备数据仓中共 \(vm.devicePosters.count) 张")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                if allSelected {
                    vm.devicePosterSelection = []
                } else {
                    vm.devicePosterSelection = Set(vm.devicePosters.map { $0.id })
                }
            } label: {
                Text(allSelected ? "取消全选" : "全选")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .glassSurface(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// 壁纸行列（run #142）：撤 List——ScrollView 里
    /// 每行一张独立全胶囊、行距 8，浮在氛围底上。
    private var cleanupRows: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(vm.devicePosters) { item in
                    cleanupRow(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    /// 单行（run #142）：整行全胶囊玻璃面（Capsule 的
    /// 圆角即行高一半）；行内容与点按勾选行为沿用旧行
    /// ——选择圆圈 + 圆角缩略图 + 名称/副行；选中行另
    /// 叠一层淡强调 tint 与描边（参照设计稿选中态）。
    private func cleanupRow(_ item: DevicePosterItem) -> some View {
        let isSelected = vm.devicePosterSelection.contains(item.id)
        return Button {
            if isSelected {
                vm.devicePosterSelection.remove(item.id)
            } else {
                vm.devicePosterSelection.insert(item.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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
                        .cornerRadius(8)
                        .clipped()
                        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 8)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Capsule())
            .glassSurface(Capsule(), tint: isSelected ? Color.accentColor.opacity(0.08) : nil)
            .overlay {
                if isSelected {
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// 底部悬浮玻璃条（run #142）：玻璃胶囊条承载
    /// 「已选 N 张」与清理钮；清理钮走玻璃主按钮双路，
    /// 0 选时灰 tint 禁用、>0 时红色 destructive 强调
    /// （参照设计稿 v2 底栏）。状态文案保留在条上方；
    /// 确认对话与清理行为、禁用条件未动。
    private var cleanupBottomBar: some View {
        VStack(spacing: 8) {
            if !vm.devicePosterStatus.isEmpty {
                Text(vm.devicePosterStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            GlassGroup {
                HStack(spacing: 12) {
                    Text("已选 \(selectedItems.count) 张")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        showCleanupConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            if vm.isCleaningDevicePosters {
                                ProgressView()
                                Text("正在清理…")
                            } else {
                                Image(systemName: "trash")
                                Text("清理所选（\(selectedItems.count)）")
                            }
                        }
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                    }
                    .glassProminentButton(tint: selectedItems.isEmpty ? Color.gray : Color.red)
                    .disabled(selectedItems.isEmpty || vm.isCleaningDevicePosters || vm.isScanningDevicePosters)
                }
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .glassSurface(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

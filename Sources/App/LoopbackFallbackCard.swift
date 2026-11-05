import SwiftUI

/// run #167：签名被挡时的兜底卡片（壁纸页底部 sheet 与配对页
/// VPNStatusRow 共用一份，事实源为 LoopbackTunnelManager.shared
/// 的 signingBlocked / signingBlockedIsEnterprise）。
///
/// 只在内置回环因签名无权限而起不来时渲染（NEConfigurationErrorDomain
/// Code 10）。文案分两档：企业分发描述文件（ProvisionsAllDevices）
/// 用 Sage 逐字定的企业证书版；其余签名（免费个人账号等同样拿不到
/// packet-tunnel-provider）用通用版，不谎称企业证书。
/// “已撤销”本身 App 内无法直接核验——系统只在启动时做吊销校验；
/// 企业版文案里的“已撤销”取自 Sage 对该用户安装渠道的判断（共享
/// 企业证书），见 SPEC #167。
///
/// 外部回环入口（run #167 追加，Sage 定：和之前一样一键跳转；
/// run #168 改 open 完成回调兜底）：
/// LocalDevVPN 的 URL scheme API 为 `localdevvpn://enable?scheme=
/// <回调 scheme>`——打开 LocalDevVPN、自动开始连接，1 秒后打开
/// `<回调 scheme>://` 跳回调用方。CocoWall 在 Info.plist 注册了
/// `cocowall` scheme，故一键动作为：
///   已装 LocalDevVPN → 开 `localdevvpn://enable?scheme=cocowall`
///     （自动连接，1 秒后自动跳回 CocoWall 并刷新网络状态）；
///   未装 → 直接开 App Store 下载页。
/// 检测不用 `canOpenURL` 先探：`canOpenURL` 只查本 App（LiveContainer
/// 内是宿主）的 Info.plist 是否登记了该 scheme，宿主没登记就谎报
/// 未装；`open(_:completionHandler:)` 不受此限，直接开、打不开再
/// 回调里落到 App Store 下载页。
/// LocalDevVPN 已上架 App Store（id 6755608044，
/// Coxson Engineering LLC，免费，需 iOS 14+），但未在中国区上架，
/// 须用外区 Apple ID 登录下载。
///
/// LiveContainer 专项（run #168）：客 App 内置回环从原理上不可用
/// （见 LoopbackTunnelManager.isLiveContainerGuest），故卡片在
/// `signingBlocked || isLiveContainerGuest` 时都渲染；LC 内文案
/// 直说原因与手动切回（`cocowall://` 回调在 LC 内大概率失效，
/// 客 scheme 未注册、LC 内自定义 URL scheme 本就不可靠）。
struct LoopbackSigningBlockedCard: View {
    @ObservedObject var loopback: LoopbackTunnelManager

    /// LocalDevVPN · App Store（美区链接；国区搜不到）。
    static let localDevVPNAppStoreURL = URL(
        string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// 一键外部回环：LocalDevVPN 自动连接后 1 秒跳回本 App。
    /// `scheme=cocowall` 为本 App 在 Info.plist 注册的回调 scheme。
    static let localDevVPNEnableURL = URL(
        string: "localdevvpn://enable?scheme=cocowall")!

    var body: some View {
        // run #168：LiveContainer 内即使尚未报 Code 10 也渲染——
        // 内置回环在客环境从原理上不可用，不必等用户先点一次失败。
        if loopback.signingBlocked || loopback.isLiveContainerGuest {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("内置回环无法使用")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.orange)

                Text(cardMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("LocalDevVPN 未在中国区 App Store 上架，需用外区 Apple ID 登录下载。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("使用外部回环连接") {
                        openExternalLoopback()
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption.bold())

                    Button("前往 App Store 下载 LocalDevVPN") {
                        UIApplication.shared.open(Self.localDevVPNAppStoreURL)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.bold())
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// 三档文案（run #168 补 LiveContainer 档，优先级最高）：
    /// LC 档直说原因 + 手动切回（不承诺自动跳回）；企业档为 Sage
    /// 逐字定稿；其余签名走通用版，不谎称企业证书。
    private var cardMessage: String {
        if loopback.isLiveContainerGuest {
            return "检测到您在 LiveContainer 内运行 CocoWall。LiveContainer 不真正安装 App、不应用客 App 的权限、也不支持 App 扩展，内置回环在此无法使用。请用下方外部回环工具连接：已装 LocalDevVPN 时点按会自动打开并连接，连接后请手动切回 LiveContainer；未装时会跳到 App Store 下载页。"
        }
        if loopback.signingBlockedIsEnterprise {
            return "检测到您使用的是共享已撤销的企业证书，无法获取回环权限，请前往 App Store 登录外区 ID 下载 LocalDevVPN 回环工具进行外部回环连接。"
        }
        return "检测到当前签名未授予回环权限，无法开启内置回环。请用已获得回环权限的签名重装，或用下方外部回环工具连接。"
    }

    /// 一键外部回环（Sage 定：和之前一样；run #168 改完成回调兜底）：
    /// 直接开 `localdevvpn://enable?scheme=cocowall`（LocalDevVPN
    /// 自动打开、自动开始连接，1 秒后自动跳回 CocoWall；回跳由
    /// IntakeRouter.handleOpenInURL 拦截，只刷新网络状态）。
    /// 打开失败（未装 LocalDevVPN）时回调里落到 App Store 下载页。
    /// 不用 canOpenURL 先探——LiveContainer 内查的是宿主的
    /// Info.plist，会谎报未装；open 本身不受登记限制。
    private func openExternalLoopback() {
        UIApplication.shared.open(Self.localDevVPNEnableURL) { success in
            if !success {
                UIApplication.shared.open(Self.localDevVPNAppStoreURL)
            }
        }
    }
}

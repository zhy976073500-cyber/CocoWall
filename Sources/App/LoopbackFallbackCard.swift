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
/// 外部回环入口（run #167 追加，Sage 定：和之前一样一键跳转）：
/// LocalDevVPN 的 URL scheme API 为 `localdevvpn://enable?scheme=
/// <回调 scheme>`——打开 LocalDevVPN、自动开始连接，1 秒后打开
/// `<回调 scheme>://` 跳回调用方。CocoWall 在 Info.plist 注册了
/// `cocowall` scheme，故一键动作为：
///   已装 LocalDevVPN → 开 `localdevvpn://enable?scheme=cocowall`
///     （自动连接，1 秒后自动跳回 CocoWall 并刷新网络状态）；
///   未装 → 直接开 App Store 下载页。
/// LocalDevVPN 已上架 App Store（id 6755608044，
/// Coxson Engineering LLC，免费，需 iOS 14+），但未在中国区上架，
/// 须用外区 Apple ID 登录下载；`localdevvpn://` 已在 Info.plist
/// 的 LSApplicationQueriesSchemes 登记，`canOpenURL` 才能探到。
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
        if loopback.signingBlocked {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("内置回环无法使用")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.orange)

                Text(loopback.signingBlockedIsEnterprise
                     ? "检测到您使用的是共享已撤销的企业证书，无法获取回环权限，请前往 App Store 登录外区 ID 下载 LocalDevVPN 回环工具进行外部回环连接。"
                     : "检测到当前签名未授予回环权限，无法开启内置回环。请用已获得回环权限的签名重装，或用下方外部回环工具连接。")
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

    /// 一键外部回环（Sage 定：和之前一样）：
    /// 已装 LocalDevVPN → `localdevvpn://enable?scheme=cocowall`
    /// （LocalDevVPN 自动打开、自动开始连接，1 秒后自动跳回
    /// CocoWall；回跳由 IntakeRouter.handleOpenInURL 拦截，只
    /// 刷新网络状态）；未装 → 直接跳 App Store 下载页。
    /// `canOpenURL` 能探到才算已装（localdevvpn 已登记查询）。
    private func openExternalLoopback() {
        if UIApplication.shared.canOpenURL(Self.localDevVPNEnableURL) {
            UIApplication.shared.open(Self.localDevVPNEnableURL)
        } else {
            UIApplication.shared.open(Self.localDevVPNAppStoreURL)
        }
    }
}

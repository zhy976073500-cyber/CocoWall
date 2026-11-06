import SwiftUI
import UIKit

/// 作者页的跳转与素材集中定义：真实素材到位后只改这一处。
enum AuthorInfo {
    // run #153：作者名由「Coco果粉营地」改「Coco」（作者页大名
    // 与设置页作者入口行标题共用此一处，两边同时生效）。
    static let displayName = "Coco"
    static let douyinURL = URL(string: "https://v.douyin.com/nioInoa-a18/")!
}

/// 作者头像（run #151 起用真实素材 authorAvatar，沿现有圆形裁切
/// 呈现；结构体名与调用处不变，设置页 40pt 小头像共用同一张图）。
struct AuthorAvatarPlaceholder: View {
    var size: CGFloat = 96

    var body: some View {
        Image("authorAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

/// 公众号二维码（run #151 起用真实素材 officialAccountQR 原图）。
/// run #152：二维码改放白色圆角卡片上呈现（图四周留白作静区）——
/// 深色模式下页面背景转深，卡片保住二维码的扫描对比度；浅色
/// 模式下与页面同为白底，观感与原占位卡一致。
struct AuthorQRPlaceholder: View {
    var body: some View {
        Image("officialAccountQR")
            .resizable()
            .scaledToFit()
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 作者页：大头像 + 名称、抖音直跳按钮、公众号二维码。
struct AuthorView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var vm: AppViewModel

    /// 三击头像复制诊断日志的结果提示（run #169 隐藏按钮）。
    @State private var copyNotice: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // run #169：头像是隐藏按钮——连点三下复制诊断日志。
                // 平时无任何外观变化；有失败日志时复制它，无失败
                // 日志时复制当前状态快照（run #171：没触发过失败
                // 也能拿到一份可发给作者的日志，不再报「暂无」）。
                AuthorAvatarPlaceholder(size: 96)
                    .padding(.top, 28)
                    .contentShape(Circle())
                    .onTapGesture(count: 3) {
                        let log = (vm.lastDiagnosticsLog?.isEmpty == false)
                            ? vm.lastDiagnosticsLog!
                            : vm.currentDiagnosticsSnapshot()
                        UIPasteboard.general.string = log
                        copyNotice = "已复制诊断日志"
                    }

                Text(AuthorInfo.displayName)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)

                Button {
                    openURL(AuthorInfo.douyinURL)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                        Text("抖音主页")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .glassProminentButton()

                VStack(spacing: 10) {
                    AuthorQRPlaceholder()
                    Text("微信扫一扫，关注公众号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        // run #152：背景改系统语义背景（原写死 Color.white，深色
        // 模式下白字白底导致名称与扫码文案不可见）；与 ProView
        // 的 systemBackground 口径一致。
        .background(Color(UIColor.systemBackground))
        .navigationTitle("作者")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(
            get: { copyNotice != nil },
            set: { if !$0 { copyNotice = nil } }
        )) {
            Button("好") { copyNotice = nil }
        } message: {
            Text(copyNotice ?? "")
        }
    }
}

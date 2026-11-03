import SwiftUI

/// 作者页的跳转与素材集中定义：真实素材到位后只改这一处。
enum AuthorInfo {
    static let displayName = "Coco果粉营地"
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

/// 公众号二维码（run #151 起用真实素材 officialAccountQR 原图，
/// 保持原占位卡的 180×180 圆角呈现）。
struct AuthorQRPlaceholder: View {
    var body: some View {
        Image("officialAccountQR")
            .resizable()
            .scaledToFit()
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 作者页：大头像 + 名称、抖音直跳按钮、公众号二维码。
struct AuthorView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                AuthorAvatarPlaceholder(size: 96)
                    .padding(.top, 28)

                Text(AuthorInfo.displayName)
                    .font(.title2.bold())

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
        .background(Color.white)
        .navigationTitle("作者")
        .navigationBarTitleDisplayMode(.inline)
    }
}

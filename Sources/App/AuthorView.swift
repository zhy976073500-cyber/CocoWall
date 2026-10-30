import SwiftUI

/// 作者页的跳转与素材集中定义：真实素材到位后只改这一处。
enum AuthorInfo {
    static let displayName = "Coco果粉营地"
    static let douyinURL = URL(string: "https://v.douyin.com/nioInoa-a18/")!
}

/// 作者头像占位：真实头像到位后把本体换成图片即可，调用处不用动。
struct AuthorAvatarPlaceholder: View {
    var size: CGFloat = 96

    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: [Color.blue.opacity(0.75), Color.purple.opacity(0.75)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.white.opacity(0.9))
            }
    }
}

/// 公众号二维码占位：真实二维码到位后把本体换成图片即可。
struct AuthorQRPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(UIColor.secondarySystemBackground))
            .frame(width: 180, height: 180)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("公众号二维码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
                .buttonStyle(.borderedProminent)

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

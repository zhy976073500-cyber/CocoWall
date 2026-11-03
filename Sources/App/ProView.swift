import SwiftUI

/// 「解锁 Pro」页（run #151）：纯展示，没有任何真实功能门禁——
/// 赞赏码 + 玩笑文案，全 App 功能照常免费。文案由 Sage 定稿
/// （最后一行原文「帮助者」按笔误改「帮助作者」，见 SPEC #151）。
struct ProView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("rewardCode")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.top, 28)

                Text("🎉你已是永久pro会员🎉")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                VStack(spacing: 6) {
                    Text("骗你的")
                    Text("此软件永久免费")
                    Text("个人开发者制作与维护")
                    Text("大家看心情打赏")
                    Text("也可以发抖音帮助作者宣传一下")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("解锁 Pro")
        .navigationBarTitleDisplayMode(.inline)
    }
}

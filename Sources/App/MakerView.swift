import SwiftUI

/// 「制作」页：给以后的壁纸制作工具（.tendies 制作端）提前留的位置。
/// 这一版只占位——介绍即将到来的能力，不实现任何功能，按钮禁用。
struct MakerView: View {
    private struct Capability {
        let icon: String
        let title: String
        let detail: String
    }

    private let capabilities: [Capability] = [
        Capability(icon: "photo.badge.plus",
                   title: "素材导入",
                   detail: "导入背景图与浮动层图片，作为壁纸的素材。"),
        Capability(icon: "square.3.layers.3d",
                   title: "背景与浮动层编排",
                   detail: "排布背景层和浮动层的位置、大小与层级。"),
        Capability(icon: "sparkles",
                   title: "动效模板",
                   detail: "套用现成的动画模板，让壁纸动起来。"),
        Capability(icon: "shippingbox",
                   title: "一键打包 .tendies",
                   detail: "自动生成编号与配置，打包成可导入的 .tendies 文件。"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    capabilityList
                    comingSoonButton
                }
                .padding(20)
            }
            .background(Color.white)
            .navigationTitle("制作")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 24)
            Text("制作壁纸")
                .font(.title.weight(.bold))
            Text("功能开发中，敬请期待")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var capabilityList: some View {
        VStack(spacing: 12) {
            ForEach(capabilities, id: \.title) { capability in
                HStack(spacing: 14) {
                    Image(systemName: capability.icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capability.title)
                            .font(.headline)
                        Text(capability.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
            }
        }
    }

    private var comingSoonButton: some View {
        Button {
            // 占位：功能未落地，按钮保持禁用，不做任何事。
        } label: {
            Text("开始制作（即将推出）")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(true)
    }
}

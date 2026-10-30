import SwiftUI
import UIKit

/// 设置页：沿用我方旧版的卡片版式。顶部是作者入口与配对入口
/// （配对页本体仍是上游 PairingTab，从这里以 sheet 打开），
/// 下面保留 LocalDevVPN 入口卡与核心版本卡。
struct SettingsView: View {
    @State private var showPairingPage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    authorEntry
                    pairingEntry
                    localDevVPNCard
                    coreCard
                }
                .padding(20)
            }
            .background(Color.white)
            .navigationTitle("设置")
            .sheet(isPresented: $showPairingPage) {
                PairingTab()
            }
        }
    }

    // MARK: - 入口行（作者 / 配对）

    /// 与 SettingsCard 同款的白底圆角行：内容 + 右侧箭头。
    private func entryRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
    }

    private var authorEntry: some View {
        NavigationLink {
            AuthorView()
        } label: {
            entryRow {
                AuthorAvatarPlaceholder(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AuthorInfo.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("作者")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var pairingEntry: some View {
        Button {
            showPairingPage = true
        } label: {
            entryRow {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.12))
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.blue)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("设备配对")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("打开配对页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - LocalDevVPN 卡

    private var localDevVPNCard: some View {
        SettingsCard(title: "LocalDevVPN 回环") {
            Text("不想用 App 内的回环时，可以用 LocalDevVPN 一键开启回环隧道，开启后回到本 App 继续配对。")
                .font(.caption).foregroundStyle(.secondary)
            Button("打开 LocalDevVPN") { openLocalDevVPN() }
        }
    }

    /// 跳 LocalDevVPN 开回环（和网页版同一个链接与兜底）：
    /// 装了就直接跳过去开隧道；没装（canOpenURL 为假）就去 App Store 页。
    private func openLocalDevVPN() {
        guard let url = URL(string: "localdevvpn://enable?scheme=cocowall") else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else if let storeURL = URL(string: "https://apps.apple.com/app/id6755608044") {
            UIApplication.shared.open(storeURL, options: [:], completionHandler: nil)
        }
    }

    // MARK: - 核心卡

    private var coreCard: some View {
        SettingsCard(title: "壁纸写入") {
            Text("Rust 核心已链接：airlift-ffi 0.1.0 · AirCard-iOS v1.3.2 · 40640c4")
                .font(.caption).foregroundStyle(.secondary)
            Text("写入核心为 AirCard-iOS 的 AirliftFFI 整库移植（MIT，上游 v1.3.2）：隧道建连、AFC 暂存、AirTraffic 同步、注入与刷新均由原装核心执行，调用顺序与入参与上游 TendiesEngine 一致。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 设置页的一张卡：白底、圆角、轻微阴影，标题在卡内顶部。
private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
    }
}

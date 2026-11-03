import SwiftUI
import UIKit

/// 设置页：沿用我方旧版的卡片版式。只有作者入口与配对入口两行
/// （配对页本体仍是上游 PairingTab，从这里以 sheet 打开）。
struct SettingsView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showPairingPage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassGroup {
                    VStack(spacing: 16) {
                        authorEntry
                        proEntry
                        pairingEntry
                    }
                    .padding(20)
                }
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("设置")
            .sheet(isPresented: $showPairingPage) {
                PairingTab()
            }
        }
    }

    // MARK: - 入口行（作者 / 配对）

    /// 圆角入口行：内容 + 右侧箭头。run #129 起卡面走液态玻璃，
    /// 版式与原来一致。
    /// run #153 点按可靠性修复（根因见 SPEC #153）：① 原先无
    /// contentShape，Button/NavigationLink 的命中区只有 label
    /// 内容的并集——行内 Spacer 中段、元素间空隙、padding 边缘
    /// 全是死区，点在这些位置必然无反应；补 contentShape 让
    /// 整行（含空隙与 padding）都是命中区。② 卡面原用
    /// glassEffect 的 .interactive() 变体，它给 label 内容挂了
    /// 玻璃自己的按压手势处理，与外层 Button/NavigationLink 的
    /// 点按、ScrollView 的触摸仲裁三方抢同一下触摸，出现过
    /// 玻璃有按压反应却不触发导航；改非 interactive 玻璃，外观
    /// 不变，点按只归按钮本身。
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
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    /// 「解锁 Pro」入口（run #151）：纯展示页，无任何功能门禁。
    private var proEntry: some View {
        NavigationLink {
            ProView()
        } label: {
            entryRow {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.12))
                    Image(systemName: "crown.fill")
                        .foregroundStyle(.orange)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("解锁 Pro")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("成为永久会员")
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

}

import SwiftUI
import UIKit

/// 设置页：沿用我方旧版的卡片版式。只有作者入口与配对入口两行
/// （配对页本体仍是上游 PairingTab，从这里以 sheet 打开）。
struct SettingsView: View {
    @State private var showPairingPage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    authorEntry
                    pairingEntry
                }
                .padding(20)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("设置")
            .sheet(isPresented: $showPairingPage) {
                PairingTab()
            }
        }
    }

    // MARK: - 入口行（作者 / 配对）

    /// 圆角入口行：内容 + 右侧箭头。卡面用语义色，跟随系统深浅。
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
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
}

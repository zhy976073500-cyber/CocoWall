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
                        pairingEntry
                        logSection
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

    /// 圆角入口行：内容 + 右侧箭头。run #129 起卡面走液态玻璃
    /// （glassSurface，interactive），版式与原来一致。
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
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
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

    // MARK: - 日志（run #128 从壁纸页搬家到设置页最下面）

    /// 刷入日志 + 活动日志，沿用全 App 统一的 CompactLogView 与
    /// 「非空才显示」口径（与配对页活动日志、密码盘刷入日志一致）。
    @ViewBuilder
    private var logSection: some View {
        if !vm.tendiesFlashLog.isEmpty {
            logCard {
                CompactLogView(
                    title: "刷入日志（\(vm.tendiesFlashLog.count) 行）",
                    lines: vm.tendiesFlashLog,
                    onClear: { vm.tendiesFlashLog.removeAll() }
                )
            }
        }
        if !vm.log.isEmpty {
            logCard {
                CompactLogView(
                    title: "活动日志（\(vm.log.count) 行）",
                    lines: vm.log,
                    onClear: { vm.log.removeAll() }
                )
            }
        }
    }

    /// 与入口行同款玻璃卡面，把日志包成一张卡放在页面最下面。
    private func logCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

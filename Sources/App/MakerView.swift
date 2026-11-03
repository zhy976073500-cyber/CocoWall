import SwiftUI

/// 制作功能发布开关（run #152）：发布版口径——制作页签保留，
/// 点开显示「正在开发中」占位页（MakerComingSoonView），不进
/// 编辑器。编辑器本体（KeyframeEditorView）与 MakerView 的接
/// 线一律不删不改；功能成熟后把此开关改 true 即恢复编辑器。
enum MakerFeatureGate {
    static let MakerFeatureEnabled = false
}

/// 「制作」页：关键帧壁纸编辑器（v1）。
/// 选背景图 + 浮动图，在画布上拖位置、在时间轴上打关键帧，
/// 生成 .tendies 后直接走现有导入通道加入壁纸库。
/// 编辑器本体在 KeyframeEditorView.swift，这里只保留页签壳；
/// run #152 起由 MakerFeatureGate.MakerFeatureEnabled 门控，
/// 关闭时渲染「正在开发中」占位页。
struct MakerView: View {
    var body: some View {
        NavigationStack {
            if MakerFeatureGate.MakerFeatureEnabled {
                KeyframeEditorView()
                    .navigationTitle("制作")
            } else {
                MakerComingSoonView()
                    .navigationTitle("制作")
            }
        }
    }
}

/// 制作功能「正在开发中」占位页（run #152）：简洁空状态——
/// 图标 +「正在开发中」+「敬请期待」小字，背景用系统语义
/// 背景、文案用语义色，深色模式自动适配。
struct MakerComingSoonView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text("正在开发中")
                .font(.title3.bold())
                .foregroundStyle(.primary)

            Text("敬请期待")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }
}

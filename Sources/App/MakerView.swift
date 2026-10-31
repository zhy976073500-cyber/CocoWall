import SwiftUI

/// 「制作」页：关键帧壁纸编辑器（v1）。
/// 选背景图 + 浮动图，在画布上拖位置、在时间轴上打关键帧，
/// 生成 .tendies 后直接走现有导入通道加入壁纸库。
/// 编辑器本体在 KeyframeEditorView.swift，这里只保留页签壳。
struct MakerView: View {
    var body: some View {
        NavigationStack {
            KeyframeEditorView()
                .navigationTitle("制作")
        }
    }
}

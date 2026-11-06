import SwiftUI
import UIKit

/// 问题反馈页（run #169）：设置页入口。
///
/// 用户写下遇到的问题，点「复制反馈内容」即把问题描述 + 诊断日志
/// + 机型信息一并拷到剪贴板，粘贴给作者即可。App 内不直连任何
/// 服务端、不自动上传——反馈去向由用户自己选（抖音、飞书、微信）。
/// 诊断日志优先用最近一次失败记录；没有失败记录时附当前状态快照
/// （run #171），不再只复制问题描述。
struct FeedbackView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var problemText: String = ""
    @State private var copyNotice: String? = nil

    /// 作者 QQ（run #169，Sage 定）：反馈的接收渠道。
    private static let authorQQ = "1138973255"

    private var diagnosticsSection: String {
        if let log = vm.lastDiagnosticsLog, !log.isEmpty {
            return log
        }
        return vm.currentDiagnosticsSnapshot()
    }

    private var feedbackText: String {
        var parts: [String] = []
        let problem = problemText.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("问题描述：\(problem.isEmpty ? "（未填写）" : problem)")
        parts.append("")
        parts.append(diagnosticsSection)
        return parts.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Text("作者 QQ：\(Self.authorQQ)")
                            .font(.subheadline.bold())
                        Spacer()
                        Button("复制 QQ 号") {
                            UIPasteboard.general.string = Self.authorQQ
                            copyNotice = "已复制 QQ 号"
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255))
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("遇到什么问题？")
                        .font(.headline)
                    TextEditor(text: $problemText)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Color(UIColor.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("诊断日志（自动附带）")
                        .font(.headline)
                    Text(diagnosticsSection)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(UIColor.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        UIPasteboard.general.string = feedbackText
                        copyNotice = "已复制，可粘贴发给作者"
                    } label: {
                        Text("复制反馈内容")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Text("复制后加 QQ \(Self.authorQQ) 发给作者即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("问题反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("提示", isPresented: Binding(
                get: { copyNotice != nil },
                set: { if !$0 { copyNotice = nil } }
            )) {
                Button("好") { copyNotice = nil }
            } message: {
                Text(copyNotice ?? "")
            }
        }
    }
}

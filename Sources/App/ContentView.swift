import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Share Sheet for Exporting .passthm

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Crypto Donation Row

struct CryptoDonationRow: View {
    let title: String
    let address: String
    let icon: String
    let iconColor: Color

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.subheadline.bold())
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    UIPasteboard.general.string = address
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation {
                            isCopied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc.fill")
                        Text(isCopied ? "已复制！" : "复制")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(isCopied ? .green : .blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isCopied ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            Text(address)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Donate View

struct DonateView: View {
    var isPopup: Bool = false
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            // Creator Card
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.pink)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Maksym Reva")
                                .font(.headline.bold())
                            Text("🇺🇦")
                                .font(.subheadline)
                        }
                        Text("@mak5er • 主开发者与核心作者")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Social Links (Twitter & GitHub)
                HStack(spacing: 10) {
                    Link(destination: URL(string: "https://x.com/mak5er")!) {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("Twitter / X")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Link(destination: URL(string: "https://github.com/mak5er")!) {
                        HStack(spacing: 5) {
                            Image(systemName: "link")
                            Text("GitHub")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.08))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // Payment Methods
            VStack(alignment: .leading, spacing: 10) {
                Text("捐赠与支持")
                    .font(.caption.bold().uppercaseSmallCaps())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                // PayPal Button
                Link(destination: URL(string: "https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y")!) {
                    HStack(spacing: 10) {
                        Image(systemName: "creditcard.fill")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("用 PayPal 捐赠")
                                .font(.subheadline.bold())
                            Text("收款人：Maksym Reva")
                                .font(.caption2)
                                .opacity(0.85)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.subheadline)
                    }
                    .padding(14)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color(red: 0.05, green: 0.35, blue: 0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // TON
                CryptoDonationRow(
                    title: "💎 TON (The Open Network)",
                    address: "UQBm9KPhtMw-XVVjirUoa09wzrlyWsbeZhKfefl1Uw-qNZ-r",
                    icon: "diamond.fill",
                    iconColor: .cyan
                )

                // USDT TRC20
                CryptoDonationRow(
                    title: "💵 USDT (TRC20)",
                    address: "TDkDMCyjYxgvkWUnQiF5Erk2RyPQMT6G1n",
                    icon: "dollarsign.circle.fill",
                    iconColor: .green
                )

                // BEP20
                CryptoDonationRow(
                    title: "🪙 BEP20 (BNB / USDT)",
                    address: "0x0954dc491c502849d04956ef74634aa5931a08e8",
                    icon: "bitcoinsign.circle.fill",
                    iconColor: .orange
                )
            }

            Text("非常感谢你对 CocoWall 开发的支持！❤️")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(.horizontal)
    }
}

// MARK: - Support Popup Sheet (Startup Welcome)

struct SupportPopupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var dontShowOnLaunch: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Header Brand
                    VStack(spacing: 8) {
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.pink)

                        Text("欢迎使用 CocoWall！")
                            .font(.title2.bold())

                        Text("免费与开源 • 由 @mak5er 开发")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    DonateView(isPopup: true, onDismiss: { dismiss() })

                    VStack(spacing: 12) {
                        Button {
                            dismiss()
                        } label: {
                            Text("继续使用")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Toggle(isOn: $dontShowOnLaunch) {
                            Text("启动时不再显示此弹窗")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)

                        Text("随时可以在「鸣谢 › 捐赠 ❤️」里重新打开捐赠选项")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .padding(.vertical)
            }
            .navigationTitle("支持作者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
}

// MARK: - Credits Sheet

struct CreditsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Int

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分区", selection: $selectedTab) {
                    Text("鸣谢").tag(0)
                    Text("捐赠 ❤️").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Divider()

                ScrollView {
                    if selectedTab == 0 {
                        creditsContent
                    } else {
                        VStack(spacing: 20) {
                            DonateView()
                            Spacer(minLength: 20)
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle(selectedTab == 0 ? "鸣谢" : "捐赠与支持")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var creditsContent: some View {
        VStack(spacing: 20) {
            // Header Brand
            VStack(spacing: 8) {
                Image(systemName: "creditcard.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                Text("CocoWall")
                    .font(.title2.bold())

                Text("密码盘主题与 .tendies 壁纸（iOS 18.0 – 27.2 b2）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 10)

            // Donate banner inside credits
            Button {
                withAnimation {
                    selectedTab = 1
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("支持 @mak5er 的开发")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text("可用 PayPal 与加密货币捐赠")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.pink.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // mak5er (Lead & Core Developer)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("主开发者与核心作者", systemImage: "crown.fill")
                            .font(.caption.bold().uppercaseSmallCaps())
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("主创")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }

                    HStack(spacing: 8) {
                        Text("@mak5er")
                            .font(.headline.bold())

                        Spacer()

                        Link(destination: URL(string: "https://github.com/mak5er")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                Text("GitHub")
                            }
                            .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Link(destination: URL(string: "https://x.com/mak5er")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                Text("Twitter / X")
                            }
                            .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                // merybist (Base IPA Developer)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("基础 IPA 开发者", systemImage: "hammer.fill")
                            .font(.caption.bold().uppercaseSmallCaps())
                            .foregroundStyle(.blue)
                        Spacer()
                        Text("基础")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    HStack(spacing: 8) {
                        Text("@merybist")
                            .font(.headline.bold())

                        Spacer()

                        Link(destination: URL(string: "https://github.com/merybist")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                Text("GitHub")
                            }
                            .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Link(destination: URL(string: "https://x.com/merybist")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                Text("Twitter / X")
                            }
                            .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                // Technology acknowledgments
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.shield.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("核心利用")
                                .font(.subheadline.bold())
                            Text("airlift（AirTraffic 同步沙盒逃逸）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.title3)
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("密码盘主题")
                                .font(.subheadline.bold())
                            Text(".passthm 标准（Cowabunga / Nugget）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill")
                            .font(.title3)
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NeoSpring 与 PosterBoard")
                                .font(.subheadline.bold())
                            Text("SpringBoard 重载与 .tendies 壁纸（@neonmodder123、@skadz108、@rooootdev）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("壁纸刷入框架")
                                .font(.subheadline.bold())
                            Text("基于 AirCard-iOS（作者 Mak5er），遵循 MIT 开源许可")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .background(Color(uiColor: .tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)

            Spacer(minLength: 20)
        }
        .padding(.vertical)
    }
}

// MARK: - Pairing File Guide Sheet

struct PairingGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onImportTapped: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("在哪里找到配对文件")
                            .font(.title2.bold())
                        Text("可以导入由 SideStore、LiveContainer、iLoader 或电脑导出的配对文件。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // SideStore Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "app.badge.checkmark.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            Text("SideStore")
                                .font(.headline.bold())
                            Spacer()
                            Text("推荐")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }

                        Text("SideStore 会在设置过程中自动生成配对文件，可以直接在「文件」App 里选取：")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("在「文件」App 中的路径：")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text("我的 iPhone › SideStore › ALTPairingFile.mobiledevicepairing")
                                .font(.caption.monospaced())
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // LiveContainer Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox.fill")
                                .font(.title3)
                                .foregroundStyle(.purple)
                            Text("LiveContainer（内嵌 SideStore）")
                                .font(.headline.bold())
                        }

                        Text("如果在 LiveContainer 里运行 SideStore，配对文件存放在 LiveContainer 的应用存储里：")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("在「文件」App 中的路径：")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text("我的 iPhone › LiveContainer › SideStore › Documents › ALTPairingFile.mobiledevicepairing")
                                .font(.caption.monospaced())
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // iLoader / Jitterbug / AltStore Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                            Text("iLoader / Jitterbug / AltStore")
                                .font(.headline.bold())
                        }

                        Text("• iLoader：设置 › 导出配对文件 › 存到「文件」。\n• Jitterbug：导出你的 <UDID>.mobiledevicepairing。\n• 电脑（PC/Mac）：运行 jitterbugpair，或从 SideServer / AltServer 导出，再隔空投送到 iPhone。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Direct Placement Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                            Text("手动放进「文件」App")
                                .font(.headline.bold())
                        }

                        Text("也可以把任意 .mobiledevicepairing 或 .plist 文件直接拷到：")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text("「文件」App › 我的 iPhone › CocoWall")
                            .font(.caption.monospaced())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("它会立即出现在应用内「在文稿中发现」列表里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Action Button
                    Button {
                        dismiss()
                        onImportTapped()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("立即导入配对文件")
                            Spacer()
                        }
                        .font(.headline)
                        .frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("配对指南")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }.bold()
                }
            }
        }
    }
}

// MARK: - Native Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView

        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let shouldStop = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStop { url.stopAccessingSecurityScopedResource() }
            }
            parent.onPick(url)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Root Tab View

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @AppStorage("aircard.dont_show_support_on_launch") private var dontShowSupportOnLaunch: Bool = false
    @State private var showSupportPopup: Bool = false

    // 更新弹窗倒计时（run #172）：「以后再说」按钮 10 秒后才可点，
    // 每秒减 1；弹窗每次出现都从 10 重新计。
    @State private var updateDismissCountdown = 10
    // 公告弹窗倒计时（run #173）：「关闭」按钮 10 秒后才可点，
    // 每秒减 1；弹窗每次出现都从 10 重新计。
    @State private var announcementDismissCountdown = 5
    private let updateCountdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // 远程配置弹窗（run #159）：待弹项由 RemoteConfigService
    // 按「强更 > 公告 > 普通版本提醒」排队，同一时刻最多
    // 一个；关闭即由服务记账并链式评估下一个。

    var body: some View {
        TabView(selection: $vm.selectedTab) {
            TendiesView()
                .tabItem { Label("壁纸", systemImage: "photo.stack.fill") }
                .tag(AppTab.wallpapers)

            MakerView()
                .tabItem { Label("制作", systemImage: "wand.and.stars") }
                .tag(AppTab.maker)

            PasscodeThemeTab()
                .tabItem { Label("密码盘", systemImage: "lock.circle.fill") }
                .tag(AppTab.passcodeThemes)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .alert("提示", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("好") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("成功！🎉", isPresented: $vm.showSuccessAlert) {
            Button("好") {}
        } message: {
            Text(vm.successAlertMessage)
        }
        // 公告（run #159 → #173 改自定义卡片）：id 大于本地已读
        // id 才弹一次，关闭即记已读；link 非空时多一个「查看教程」
        // 跳浏览器。系统 .alert 的按钮不支持带倒计时的禁用态，
        // 改 .overlay 居中卡片（与 #172 更新卡片同款）：遮罩 40%
        // 黑、点遮罩不关闭，必须选按钮；「关闭」5 秒倒计时，
        // 倒数完才可点（Sage 2026-11-07 定，10 秒改 5 秒）；「查看教程」
        // 与「加入CocoWall内测群」是正向动作，不等倒计时，点了即
        // 开链接并记已读。groupLink 非空时才显示内测群按钮。
        // run #173：公告每天都提示一次（RemoteConfig 记当天已弹）。
        .overlay {
            if let ann = vm.remotePrompt?.announcementValue {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 16) {
                        Text(ann.title.isEmpty ? "公告" : ann.title)
                            .font(.headline)
                        if !ann.body.isEmpty {
                            Text(ann.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        VStack(spacing: 10) {
                            if !ann.link.isEmpty, let link = URL(string: ann.link) {
                                Button("查看教程") {
                                    UIApplication.shared.open(link)
                                    vm.remoteConfig.dismissPrompt()
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255))
                                .foregroundStyle(.white)
                                .font(.subheadline.weight(.semibold))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            if !ann.groupLink.isEmpty, let groupLink = URL(string: ann.groupLink) {
                                Button("加入CocoWall内测群") {
                                    UIApplication.shared.open(groupLink)
                                    vm.remoteConfig.dismissPrompt()
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.systemBackground))
                                .foregroundStyle(Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255))
                                .font(.subheadline.weight(.semibold))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255), lineWidth: 1.5))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Button(announcementDismissCountdown > 0
                                   ? "关闭（\(announcementDismissCountdown)秒后可关闭）"
                                   : "关闭") {
                                vm.remoteConfig.dismissPrompt()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground))
                            .foregroundStyle(.primary)
                            .font(.subheadline.weight(.semibold))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .disabled(announcementDismissCountdown > 0)
                            .opacity(announcementDismissCountdown > 0 ? 0.5 : 1)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 320)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(radius: 20)
                    .padding(.horizontal, 32)
                    .onAppear { announcementDismissCountdown = 5 }
                }
            }
        }
        // 成功 toast（run #148）：顶部轻量浮层胶囊（对勾 +
        // 文案、液态玻璃面），约 1.6 秒由 AppViewModel 自动
        // 清除；不拦截触摸、不打断当前操作，与上面两个
        // 模态 alert 是两条通道（密码盘成功仍走 alert）。
        .overlay(alignment: .top) {
            if let toast = vm.toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(Capsule())
                .padding(.top, 8)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        // 版本提醒（run #172）：系统 .alert 的按钮不支持带倒计时的
        // 禁用态，改自定义卡片。普通提醒三按钮：去更新 / 明天再提醒
        // （休眠到明天 0 点，明天进 App 再弹一次）/ 以后再说（10 秒
        // 倒计时，倒数完才可点）；强更只有去更新，不可关。遮罩挡住
        // 下层触摸，点遮罩不关闭，必须选按钮。
        .overlay {
            if let info = vm.remotePrompt?.updateValue {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 16) {
                        Text("发现新版本")
                            .font(.headline)
                        Text(info.updateNote.isEmpty
                             ? "CocoWall \(info.latestVersion) 已发布，建议更新到最新版本。"
                             : info.updateNote)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        VStack(spacing: 10) {
                            Button("去更新") {
                                if let url = URL(string: info.downloadUrl) {
                                    UIApplication.shared.open(url)
                                }
                                vm.remoteConfig.dismissPrompt()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255))
                            .foregroundStyle(.white)
                            .font(.subheadline.weight(.semibold))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            if !info.forceUpdate {
                                Button("明天再提醒") {
                                    vm.remoteConfig.snoozeUpdatePromptUntilTomorrow()
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground))
                                .foregroundStyle(.primary)
                                .font(.subheadline.weight(.semibold))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                Button(updateDismissCountdown > 0
                                       ? "以后再说（\(updateDismissCountdown)秒后可关闭）"
                                       : "以后再说") {
                                    vm.remoteConfig.dismissPrompt()
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground))
                                .foregroundStyle(.primary)
                                .font(.subheadline.weight(.semibold))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .disabled(updateDismissCountdown > 0)
                                .opacity(updateDismissCountdown > 0 ? 0.5 : 1)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 320)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(radius: 20)
                    .padding(.horizontal, 32)
                    .onAppear { updateDismissCountdown = 10 }
                }
            }
        }
        .onReceive(updateCountdownTimer) { _ in
            if vm.remotePrompt?.updateValue != nil, updateDismissCountdown > 0 {
                updateDismissCountdown -= 1
            }
            if vm.remotePrompt?.announcementValue != nil, announcementDismissCountdown > 0 {
                announcementDismissCountdown -= 1
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.toastMessage)
        .sheet(isPresented: $vm.showShareSheet) {
            if let url = vm.exportedThemeURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showSupportPopup) {
            SupportPopupSheet(dontShowOnLaunch: $dontShowSupportOnLaunch)
        }
        .onAppear {
            vm.showSuccessAlert = false
            vm.successAlertMessage = ""
        }
    }
}

// MARK: - Pairing Tab

struct PairingTab: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var showFilePicker = false
    @State private var showPairingGuide = false
    // run #155: 导出配对文件的分享面板（临时副本 URL）。
    // run #156: 改单一 item 状态驱动呈现（根因与修法见
    // exportPairingFile 与 SPEC #156 一）。
    @State private var pairingExportItem: PairingExportItem?

    /// 导出分享项（run #156）：sheet(item:) 的载荷——呈现与
    /// 内容同源于这一个可选值，非空才呈现、呈现必有内容。
    private struct PairingExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }
    // run #151: WiFi 监听只在配对页在场时活（onAppear 起、
    // onDisappear 停），驱动页顶横幅。
    @StateObject private var wifiMonitor = WiFiMonitor()
    @Environment(\.colorScheme) private var colorScheme

    /// 配对卡次按钮底色（run #163）：浅蓝填充，浅色
    /// #EAF3FF、深色用蓝 22% 透明（深色下 #EAF3FF 过亮）。
    private var pairingSecondaryFill: Color {
        colorScheme == .dark
            ? Color.blue.opacity(0.22)
            : Color(red: 234.0 / 255, green: 243.0 / 255, blue: 1.0)
    }

    private var isIOS27OrNewer: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    var body: some View {
        NavigationStack {
            Form {
                // WiFi 提示横幅（run #151，页最顶端）：未连 WiFi
                // 时醒目警告，已连时给平静的已连接状态。
                Section {
                    if wifiMonitor.isWiFiConnected {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi")
                                .foregroundStyle(.green)
                            Text("已连接 WiFi")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("请确保设备连接wifi后再进行使用！")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                        }
                    }
                }

                // run #163: 页顶 App 信息卡（应用名/版本徽章/
                // 支持范围说明，含 27.2 已修复提示）整卡按
                // Sage 要求删除，页面直接从「网络」开始；
                // 页顶 WiFi 横幅（#151）不在此卡内、不受影响。

                // Network / VPN Status
                // run #166: 「去系统设置链接回环」整行删除
                // （#151 直达按钮 → #156 改文案 → #163 改点按
                // 弹提示，本轮连提示行与 showLoopbackHint 状态
                // 一并清掉）。网络卡只剩 VPNStatusRow，其内置
                // 回环开关已统一为与壁纸页同一逻辑的单一控件，
                // 不再引导用户去系统设置里手动连接回环工具。
                Section("网络") {
                    VPNStatusRow(vm: vm)
                }

                // 配对（run #163：原「当前配对」「配对文件」「在本机配对」
                // 三段合并为一段。段内顺序：状态行 → 已配对时的导出/删除 →
                // 本机配对块（仅 iOS 27+）→ 导入配对文件次按钮 → iOS 26
                // 教程次按钮 → 帮助链接行 → 支持格式小字 → 文稿中发现列表。
                // 各动作独立成行：原「配对文件」段把导入/指南/教程三个
                // Button 挤在同一 VStack（= 同一列表行）内且未加 borderless
                // 类样式，列表会合并整行命中——点「导入配对文件」连带触发
                // 了同格的指南 Button（Sage 真机实证，run #163 项一 e）；
                // 本轮每钮独立成行 + 整钮 contentShape，结构上消除该问题。
                Section("配对") {
                    HStack(spacing: 10) {
                        if vm.hasPairingFile {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已就绪 ✅")
                                    .font(.subheadline.bold())
                                Text("\(vm.pairingFileName) (\(vm.pairingFileSizeString))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("未配对")
                                    .font(.subheadline.bold())
                                Text(isIOS27OrNewer
                                     ? "在下方直接在本机配对，或导入配对文件。"
                                     : "在下方导入来自 SideStore、iLoader 或电脑的配对文件。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if vm.hasPairingFile {
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    // 导出配对文件（run #155）：仅已配对时出现。
                    // 把 App 已保存的配对文件原样复制为临时副本
                    // CocoWall_pairing.plist 再走系统分享面板——
                    // 字节与原件一致，不做任何改写。
                    if vm.hasPairingFile {
                        Button {
                            exportPairingFile()
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                Text("导出配对文件")
                                Spacer()
                            }
                            .font(.subheadline.bold())
                        }
                    }

                    if vm.hasPairingFile {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "trash.fill")
                                Text("删除配对文件")
                                Spacer()
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                        }
                    }

                    // 本机配对（原「在本机配对」段内容，仅 iOS 27+；
                    // run #163 并入本段，块内逻辑与呈现原样未动）。
                    if isIOS27OrNewer {
                        if vm.pairingPhase == .pairing {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    ProgressView().scaleEffect(0.85)
                                    Text(vm.pairingStatus.isEmpty ? "正在启动本机配对服务…" : Self.localizedPairingStatus(vm.pairingStatus))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                if let pin = vm.pairingPIN {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("在本台 iPhone 上输入这个配对码：")
                                            .font(.caption2.bold().uppercaseSmallCaps())
                                            .foregroundStyle(.secondary)

                                        HStack(alignment: .center, spacing: 0) {
                                            Text(pin)
                                                .font(.system(size: 40, weight: .black, design: .monospaced))
                                                .foregroundStyle(.orange)
                                            Spacer()
                                            Button {
                                                UIPasteboard.general.string = pin
                                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                            } label: {
                                                Label("复制", systemImage: "doc.on.doc")
                                                    .font(.caption.bold())
                                            }
                                            .glassButton(tint: .orange)
                                        }

                                        Text("设置 › 隐私与安全性 › 开发者模式 › 与 CocoWall 配对")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.primary)

                                        Button {
                                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                                UIApplication.shared.open(url)
                                            }
                                        } label: {
                                            Label("立即打开设置 App", systemImage: "arrow.up.forward.app")
                                                .bold()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                        }
                                        .glassProminentButton(tint: .orange)
                                    }
                                    .padding(14)
                                    .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: Color.orange.opacity(0.12))
                                }

                                Button(role: .cancel) {
                                    vm.cancelPairing()
                                } label: {
                                    HStack(spacing: 8) {
                                        Spacer()
                                        Image(systemName: "xmark")
                                        Text("取消配对")
                                        Spacer()
                                    }
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                }
                                .glassButton(tint: .red)
                            }
                        } else {
                            VStack(spacing: 12) {
                                if !vm.pairingStatus.isEmpty && vm.pairingStatus != "idle" {
                                    Text(Self.localizedPairingStatus(vm.pairingStatus))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(
                                            vm.pairingStatus.contains("✅") ? .green :
                                            vm.pairingStatus.contains("❌") || vm.pairingStatus.contains("failed") ? .red :
                                            .secondary
                                        )
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }

                                Button {
                                    vm.startPairing()
                                } label: {
                                    HStack(spacing: 8) {
                                        Spacer()
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.body.weight(.semibold))
                                        Text(vm.hasPairingFile ? "重新配对本机" : "配对本机")
                                            .font(.headline)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    // run #163：整钮命中区显式声明
                                    // （项一 e 的同轮加固）。
                                    .contentShape(Rectangle())
                                }
                                .glassProminentButton()
                            }
                            .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                        }
                    }

                    // 导入配对文件（run #163：由文字行改整宽次按钮——
                    // 浅蓝填充 + 蓝字胶囊；动作与原行一致，拉起配对
                    // 文件选择器 showFilePicker）。
                    Button {
                        showFilePicker = true
                    } label: {
                        Text("导入配对文件")
                            .font(.headline)
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(pairingSecondaryFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))

                    // iOS 26 生成配对文件教程（run #158 建入口；
                    // run #159 起链接改读远程配置 pairingTutorialUrl，
                    // 配置未加载成功时回落内置默认=原写死值）：
                    // run #163 由文字行改与导入同款次按钮，打开方式
                    // 不变（系统浏览器 open）。设置页「支持系统」页内
                    // 的同名按钮不在本段、保持原样。
                    Button {
                        if let url = URL(string: vm.remoteConfig.pairingTutorialURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("iOS 26 生成配对文件教程")
                            .font(.headline)
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(pairingSecondaryFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))

                    // 配对文件在哪（帮助指南 sheet，行为沿旧行；
                    // run #163 改独立行 + 整行 contentShape）。
                    Button {
                        showPairingGuide = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "questionmark.circle")
                            Text("SideStore / LiveContainer 的配对文件在哪？")
                            Spacer()
                        }
                        .font(.footnote)
                        .foregroundStyle(.blue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text("支持从 SideStore、iLoader、AltStore、Jitterbug 或 Mac/PC 导出的 .mobiledevicepairing、.plist、.mobilepair 文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !vm.documentsPlistFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("在文稿中发现：")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            ForEach(vm.documentsPlistFiles, id: \.self) { filename in
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                        .foregroundStyle(.blue)
                                    Text(filename)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button("使用") {
                                        vm.selectPairingFile(filename: filename)
                                    }
                                    .glassButton()
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .confirmationDialog(
                    "删除配对会话？",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("删除配对", role: .destructive) { vm.deletePairingFile() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("当前配对凭据将被移除，之后可以重新配对或导入其他文件。")
                }

            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .navigationTitle("CocoWall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.caption.weight(.semibold))
                            Text("返回")
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPickerView(allowedContentTypes: [
                    UTType(filenameExtension: "mobiledevicepairing") ?? .data,
                    UTType(filenameExtension: "plist") ?? .propertyList,
                    UTType(filenameExtension: "mobilepair") ?? .data,
                    // 统一智能接收（run #165）：可选类型放宽
                    // 为三类并集（壁纸包 / 纯文本 / plist），
                    // 选中后统一走 vm 接路由器按内容分发，配
                    // 对文件仍落回 importPairingFile 原路径。
                    UTType("com.aircard.tendies") ?? .data,
                    .plainText,
                    .propertyList,
                    .data,
                    .item
                ]) { url in
                    vm.intakeFile(at: url, switchTabOnSuccess: false)
                }
            }
            .sheet(isPresented: $showPairingGuide) {
                PairingGuideSheet {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showFilePicker = true
                    }
                }
            }
            // 导出配对文件的系统分享面板（run #155；run #156
            // 改 sheet(item:) 单源驱动，杜绝空内容呈现）。
            .sheet(item: $pairingExportItem) { item in
                ShareSheet(items: [item.url])
            }
            .onAppear {
                vm.refreshNetworkStatus()
                vm.refreshPairingFile()
                wifiMonitor.start()
            }
            .onDisappear {
                wifiMonitor.stop()
            }
            .refreshable {
                vm.refreshNetworkStatus()
                vm.refreshPairingFile()
            }
        }
    }

    // run #163: openSystemVPNSettings（#151 初版、#156 候选链）
    // 已随「去系统设置链接回环」改弹提示而整函数删除——App 内
    // 不再有任何 App-prefs 深链跳转；run #166: 该提示行本身
    // 亦已整行删除，配对页网络卡只剩内置回环开关。

    /// 导出配对文件（run #155）：把存储原件逐字节复制到临时目录
    /// 并命名 CocoWall_pairing.plist，再拉起系统分享面板。
    /// 复制不转码、不重写，导出字节与原件一致。
    ///
    /// run #156 空白面板根因修复：原实现用两个独立 @State
    /// （pairingExportURL + showPairingExport 布尔）配
    /// .sheet(isPresented:) 与 if-let 内容——点按时两份状态
    /// 同回合先后写入，sheet 构建内容时读到的 URL 仍为 nil，
    /// if let 落空，托管控制器以空内容完成呈现；呈现之后内
    /// 容身份再从空视图切换为 ShareSheet，控制器也不会重
    /// 建 → 整片空白（Sage 16:34 截图实证）。文件侧可排除：
    /// pairingFilePath() 自带存在性与非空校验、按钮又以
    /// hasPairingFile 为显隐门，源文件可靠；且复制若抛错，
    /// 旧代码根本不会置呈现位、不会有任何面板——出现的偏
    /// 偏是空面板，症结在呈现竞速不在文件。修法：改
    /// sheet(item:) 单源驱动（呈现与内容同出一个可选值）；
    /// 复制落盘后先核验副本非空再赋值触发呈现；失败则不
    /// 赋值、不呈现，绝不再弹空面板。
    private func exportPairingFile() {
        let source = PairingController.pairingFilePath()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("CocoWall_pairing.plist")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(atPath: source, toPath: dest.path)
            let size = (try? FileManager.default
                .attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
            guard size > 0 else {
                pairingExportItem = nil
                return
            }
            pairingExportItem = PairingExportItem(url: dest)
        } catch {
            pairingExportItem = nil
        }
    }

    /// 配对状态文案中文化（run #155）：`vm.pairingStatus` 的原始串
    /// 来自受保护文件 PairingController（英文引导串写在那边，
    /// 按红线不动），在这里做呈现层映射——已知英文引导/结果串
    /// 换成中文，其余（已是中文、vm 自己写的状态）原样透传。
    /// 颜色判定仍读原始串，不受映射影响。
    static func localizedPairingStatus(_ raw: String) -> String {
        let guide = "请前往 设置 › 隐私与安全 › 开发者模式，选择 CocoWall 进行配对"
        switch raw {
        case "Starting local host…":
            return "正在启动本机配对服务…"
        case "Broadcasting… open Settings to pair",
             "Advertising — open Settings › Privacy & Security › Developer Mode":
            return guide
        case "Cancelled":
            return "已取消"
        default:
            break
        }
        if raw.hasPrefix("Enter PIN ") {
            // "Enter PIN 123456 in Settings › …" — 把码带进中文引导。
            let rest = raw.dropFirst("Enter PIN ".count)
            let pin = rest.split(separator: " ").first.map(String.init) ?? ""
            return pin.isEmpty ? guide : "\(guide)，并输入配对码 \(pin)"
        }
        if raw.hasPrefix("Paired: ") {
            return "配对成功：" + String(raw.dropFirst("Paired: ".count))
        }
        if raw.hasPrefix("Failed: ") {
            return "配对失败：" + String(raw.dropFirst("Failed: ".count))
        }
        return raw
    }
}

// MARK: - VPN Status Row

struct VPNStatusRow: View {
    @ObservedObject var vm: AppViewModel
    // run #127: shared instance — the wallpaper-page status area
    // drives the same manager, so both surfaces share one saved VPN
    // configuration and one status source (wiring only; this row's
    // UI and behavior are unchanged).
    @ObservedObject private var loopback = LoopbackTunnelManager.shared

    /// 隧道相位镜像（run #166）：与壁纸页 TendiesView.loopbackPhase
    /// 同一段映射（NEVPNStatus → LoopbackPhase），喂给下面同一份
    /// 呈现函数——两页自此共用一个状态→文案/可用性的事实源。
    private var loopbackPhase: LoopbackPhase {
        switch loopback.status {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case .reasserting: return .reasserting
        case .disconnected: return .disconnected
        case .invalid: return .invalid
        @unknown default: return .unknown
        }
    }

    /// 与壁纸页 loopbackUI 同一呈现（run #166；run #170 喂入
    /// 外部在场位 vm.vpnUp：内置未连接、外部在场时按钮副文案
    /// 显示「已连接（外部回环）」，与壁纸页胶囊同口径；run
    /// #171：vm.vpnUp 已是窄口径回环路由探活，不再是任意 utun）。
    private var loopbackUI: LoopbackPresentation {
        loopbackPresentation(phase: loopbackPhase, isBusy: loopback.isBusy,
                             externalUp: vm.vpnUp)
    }

    /// 副文案语义色（run #166；run #170：外部已连接也绿）：
    /// 与壁纸页「内置回环」瓷砖同口径——已连接绿、过渡态
    /// （按钮禁用）橙、未连接灰。lineOK 为真即两档已连接
    /// （内置或外部）之一，副文案同绿。
    private var loopbackSubtitleColor: Color {
        if loopbackUI.lineOK { return .green }
        if !loopbackUI.buttonEnabled { return .orange }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: vm.vpnUp
                      ? "checkmark.shield.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(vm.vpnUp ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.vpnUp ? "回环 VPN 已启用" : "未检测到回环 VPN")
                        .font(.subheadline.bold())
                    Text(vm.vpnUp
                         ? "RSD 隧道已就绪——刷入时将自动连接。"
                         // run #169：未连接文案改提两路（内置或外部），
                         // 与下方常驻的外部按钮对应；#163 只引导内置
                         // 的旧口径随外部入口常驻而废止。
                         : "运行刷入前请先开启内置回环，或使用外部回环工具连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // run #166：内置回环开关统一为单一控件（Sage 定：
            // 与壁纸页「内置回环」功能一致）。此前分置两处且
            // 有漏档：未连接时（!vpnUp）是 #163 的整宽主按钮；
            // 内置已连接时（vpnUp 且隧道 .connected）只有一行
            // 小字 + 迷你玻璃钮「关闭内置回环」；而外部 VPN
            // 在场、内置未开时两支都不渲染——本页没有任何
            // 开关（与 #163 删除外部回环引导后留下的死角）。
            // 本轮改为任何状态都渲染同一颗整宽按钮：标题/
            // 副文案/可用性全取壁纸页同一呈现函数
            // loopbackPresentation（连接内置回环 / 断开内置
            // 回环 / 内置回环连接中… / 内置回环断开中…；
            // 副文案如「内置回环已连接，点击断开」「CocoWall
            // 自带回环，点按直接连接，无需其他 App」，首配
            // 置 .invalid 时即「首次连接会弹出系统提示，允许
            // 添加 VPN 配置」，取代 #163 的固定说明小字）；
            // 动作经 vm.userToggleLoopback() 共用入口，与
            // 壁纸页瓷砖恒等（已连接 stop、其余 start、随后
            // 刷新网络状态；连接成功提醒在 VM 内统一触发）；
            // 过渡态按呈现禁用，与壁纸页瓷砖的忙碌禁用同
            // 口径。按钮外观沿用 #163 整宽主蓝（#0071E3、
            // 高 50、圆角 16），全状态同形，只换文案。
            Button {
                vm.userToggleLoopback()
            } label: {
                Text(loopbackUI.buttonTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!loopbackUI.buttonEnabled)

            Text(loopbackUI.buttonSubtitle)
                .font(.caption)
                .foregroundStyle(loopbackSubtitleColor)
                .frame(maxWidth: .infinity, alignment: .center)

            // run #169：配对页常驻外部回环按钮（Sage 定：内置与外部
            // 各留一个）。与兜底卡片同一入口
            // LoopbackSigningBlockedCard.openExternalLoopback：已装
            // LocalDevVPN 时一键自动连接后跳回，未装时跳 App Store
            // 下载页。内置已连接时也能点——系统一次只允许一个 VPN，
            // 点按即切到外部；不与内置按钮共用忙碌禁用（外部无过渡态）。
            // 浅蓝次按钮，与上方主蓝内置按钮区分主次。
            Button {
                LoopbackSigningBlockedCard.openExternalLoopback()
            } label: {
                Text("连接外部回环（LocalDevVPN）")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Color(red: 0, green: 113.0 / 255, blue: 227.0 / 255).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("没有内置回环权限时可用外部工具连接，需外区 Apple ID 下载 LocalDevVPN。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            // run #171：与壁纸页同口径——回环路由已通时不显示
            // 内置的配置读取错误（见 TendiesView 同处注释）。
            if let loopbackError = loopback.lastError, !vm.vpnUp {
                Text(loopbackError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // run #167：签名被挡（Code 10）时才出现兜底卡片——
            // 企业证书版文案 + App Store 下载 LocalDevVPN 入口
            // + 已装时直接打开。平时不渲染（#151 否过常驻的
            // 商店页按钮，本轮只在确诊签名无权限时才给入口）。
            LoopbackSigningBlockedCard(loopback: loopback)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Passcode Theme Tab

struct PasscodeThemeTab: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        NavigationStack {
            Form {
                // Mode picker
                Section {
                    Picker("模式", selection: $vm.passcodeMode) {
                        ForEach(CreatorMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if vm.passcodeMode == .applyTheme {
                    ApplyThemeSection()
                } else {
                    ThemeCreatorSection()
                }

                // 刷入日志窗口已按 run #155 移除（与 #154 同口径：
                // 只删 UI 呈现，vm.passthmFlashLog 的底层收集保留）。
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .navigationTitle("密码盘主题")
            .onAppear { vm.scanDocumentsDirectory() }
        }
    }
}

// MARK: Apply Theme section

struct ApplyThemeSection: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showDocumentPicker = false

    var body: some View {
        // Themes dropped directly into Documents folder
        if !vm.documentsThemes.isEmpty {
            Section("App 文件夹中的主题（我的 iPhone › CocoWall）") {
                ForEach(vm.documentsThemes, id: \.self) { file in
                    HStack {
                        Image(systemName: "paintpalette.fill")
                            .foregroundStyle(.pink)
                        Text(file)
                            .font(.system(size: 13, design: .monospaced))
                        Spacer()
                        Button("载入") {
                            vm.loadPassthmFromDocuments(filename: file)
                        }
                        .font(.caption.bold())
                        .glassProminentButton()
                        .controlSize(.small)
                    }
                }
            }
        }

        Section("浏览文件") {
            HStack {
                Button {
                    showDocumentPicker = true
                } label: {
                    Label(vm.loadedTheme == nil ? "从文件选择 .passthm…" : "更换 .passthm…",
                          systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if vm.loadedTheme != nil {
                    Button {
                        vm.clearLoadedTheme()
                    } label: {
                        Text("清除")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPickerView(allowedContentTypes: [
                    UTType(filenameExtension: "passthm") ?? .archive,
                    UTType.zip,
                    UTType.archive
                ]) { url in
                    vm.loadPassthm(url: url)
                }
            }
        }

        if let theme = vm.loadedTheme {
            Section("锁屏交互预览") {
                KeypadPreviewView(keys: theme.keysPreview)
                    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                    .listRowBackground(Color.clear)
            }

            Section("主题信息") {
                LabeledContent("主题内文件", value: "\(theme.fileCount)")
                LabeledContent("已设置样式的数字", value: "\(theme.keysPreview.count) 个按键")

                Button {
                    vm.adoptThemeIntoCreator()
                } label: {
                    Label("在主题制作中编辑", systemImage: "pencil")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .glassButton()
            }

            // run #151: 「刷入与语言目标」整卡已删——三个选择器
            // 背后的 vm 存储值/默认值与刷入读取路径原样保留
            // （现行解析 TelephonyUI-10 / 检测语言 / 通用字重），
            // 只是不再有 UI 可改。

            Section {
                VStack(spacing: 12) {
                    flashButton

                    Button(role: .destructive) {
                        vm.clearLoadedTheme()
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "trash")
                            Text("移除 / 卸载主题")
                            Spacer()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .glassButton(tint: .red)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            }
        }
    }

    @ViewBuilder
    private var flashButton: some View {
        if case .running = vm.passthmFlashPhase {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在刷入主题…").font(.subheadline.bold())
                    ProgressView(value: vm.passthmFlashProgress)
                }
            }
            .padding(.vertical, 4)
        } else if case .done(let ok) = vm.passthmFlashPhase, !ok {
            Button {
                vm.flashPassthm()
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                    Text("重试刷入主题")
                    Spacer()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .glassProminentButton(tint: .orange)
            .disabled(!vm.canFlashPassthm)
        } else {
            Button {
                vm.flashPassthm()
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bolt.fill")
                    Text("刷入主题到 iPhone")
                    Spacer()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .glassProminentButton()
            .disabled(!vm.canFlashPassthm)
        }
    }
}

// MARK: Theme Creator section

struct ThemeCreatorSection: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var selectedDigitForPicker: String? = nil
    @State private var showKeySourceDialog: Bool = false
    @State private var isKeyPhotosPickerPresented: Bool = false
    @State private var isKeyDocumentPickerPresented: Bool = false
    @State private var selectedKey: [PhotosPickerItem] = []

    @State private var showPosterSourceDialog: Bool = false
    @State private var isPosterPhotosPickerPresented: Bool = false
    @State private var isPosterDocumentPickerPresented: Bool = false
    @State private var selectedPoster: [PhotosPickerItem] = []

    var body: some View {
        Section("切片模式") {
            Picker("", selection: $vm.sliceMode) {
                ForEach(SliceMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
        }

        if vm.sliceMode == .posterSlice {
            posterSliceSection
        } else {
            individualKeysSection
        }

        // Preview
        Section("锁屏交互预览") {
            KeypadPreviewView(keys: vm.effectiveKeys)
                .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                .listRowBackground(Color.clear)
        }

        // （「刷入与语言目标」卡已随 run #151 整卡删除，见上。）

        // Action Section
        Section {
            VStack(spacing: 12) {
                flashButton

                if !vm.effectiveKeys.isEmpty {
                    Button {
                        _ = vm.exportPassthm()
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                            Text("导出 .passthm…")
                            Spacer()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .glassButton()

                    Button(role: .destructive) {
                        vm.clearAllCreator()
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "trash")
                            Text("清空全部")
                            Spacer()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .glassButton(tint: .red)
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        }
    }

    private var posterSliceSection: some View {
        Group {
            Section("整图") {
                Button {
                    showPosterSourceDialog = true
                } label: {
                    Label(vm.posterImage == nil ? "为键盘选择照片…" : "更换照片…",
                          systemImage: "photo")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .confirmationDialog("选择整图来源", isPresented: $showPosterSourceDialog, titleVisibility: .visible) {
                Button {
                    isPosterPhotosPickerPresented = true
                } label: {
                    Label("照片图库", systemImage: "photo.on.rectangle")
                }
                Button {
                    isPosterDocumentPickerPresented = true
                } label: {
                    Label("从文件选择…", systemImage: "folder")
                }
                Button("取消", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $isPosterPhotosPickerPresented,
                selection: $selectedPoster,
                maxSelectionCount: 1,
                matching: .images
            )
            .onChange(of: selectedPoster) { _, items in
                guard let item = items.first else { return }
                Task {
                    if let image = await item.loadUIImage(maxDimension: 2560) {
                        await MainActor.run { vm.setPosterImage(image) }
                    }
                    await MainActor.run { selectedPoster = [] }
                }
            }
            .sheet(isPresented: $isPosterDocumentPickerPresented) {
                DocumentPickerView(allowedContentTypes: [
                    .image, .png, .jpeg, .heic,
                    UTType(filenameExtension: "webp") ?? .image,
                    UTType(filenameExtension: "tiff") ?? .image
                ]) { url in
                    if let data = try? Data(contentsOf: url),
                       let image = ImageEngine.safeImageFromData(data, maxDimension: 2560) {
                        vm.setPosterImage(image)
                    }
                }
            }

            if vm.posterImage != nil {
                Section("切片样式") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $vm.maskToCircles) {
                            Text("无缝整图").tag(false)
                            Text("圆形按钮").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: vm.maskToCircles) { _, _ in
                            vm.updatePosterSlicing()
                        }

                        Text(vm.maskToCircles ? "图稿会被裁成单个圆形按钮图标。" : "无缝图稿横贯整个拨号键盘，不做圆形裁切（Adobe Dog 风格）。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("缩放与构图")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("重置位置") {
                                withAnimation(.spring()) {
                                    vm.resetPosterPosition()
                                }
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "minus.magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.caption)

                            Slider(value: $vm.posterZoom, in: 0.5...3.0, step: 0.05)
                                .onChange(of: vm.posterZoom) { _, _ in
                                    vm.updatePosterSlicing()
                                }

                            Image(systemName: "plus.magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.caption)

                            Text(String(format: "%.1fx", vm.posterZoom))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(width: 38, alignment: .trailing)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "hand.draw")
                                .foregroundColor(.secondary)
                                .font(.caption2)
                            Text("在拨号预览上任意拖动即可调整位置")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var individualKeysSection: some View {
        Section("单个按键") {
            Text("点按任意一行，为该按键设置自定义图片。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(KeypadLayout.allButtons) { btn in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color(uiColor: .secondarySystemBackground))
                            .frame(width: 44, height: 44)
                        if let img = vm.customKeys[btn.digit] {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                        } else {
                            Text(btn.digit)
                                .font(.title3.bold())
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("按键 \(btn.digit)")
                            .font(.subheadline.weight(.medium))
                        if !btn.letters.isEmpty {
                            Text(btn.letters)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if vm.customKeys[btn.digit] != nil {
                        Button(role: .destructive) {
                            vm.clearIndividualKey(digit: btn.digit)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedDigitForPicker = btn.digit
                    showKeySourceDialog = true
                }
            }
        }
        .confirmationDialog("选择按键 \(selectedDigitForPicker ?? "") 的图片来源", isPresented: $showKeySourceDialog, titleVisibility: .visible) {
            Button {
                isKeyPhotosPickerPresented = true
            } label: {
                Label("照片图库", systemImage: "photo.on.rectangle")
            }
            Button {
                isKeyDocumentPickerPresented = true
            } label: {
                Label("从文件选择…", systemImage: "folder")
            }
            Button("取消", role: .cancel) {
                selectedDigitForPicker = nil
            }
        }
        .photosPicker(
            isPresented: $isKeyPhotosPickerPresented,
            selection: $selectedKey,
            maxSelectionCount: 1,
            matching: .images
        )
        .onChange(of: selectedKey) { _, items in
            guard let item = items.first,
                  let digit = selectedDigitForPicker else {
                if items.isEmpty { selectedDigitForPicker = nil }
                return
            }
            let currentDigit = digit
            Task {
                if let image = await item.loadUIImage(maxDimension: 1024) {
                    await MainActor.run { vm.setIndividualKey(digit: currentDigit, image: image) }
                }
                await MainActor.run {
                    selectedKey = []
                    selectedDigitForPicker = nil
                }
            }
        }
        .sheet(isPresented: $isKeyDocumentPickerPresented) {
            DocumentPickerView(allowedContentTypes: [
                .image, .png, .jpeg, .heic,
                UTType(filenameExtension: "webp") ?? .image,
                UTType(filenameExtension: "tiff") ?? .image
            ]) { url in
                guard let digit = selectedDigitForPicker else { return }
                if let data = try? Data(contentsOf: url),
                   let image = ImageEngine.safeImageFromData(data, maxDimension: 1024) {
                    vm.setIndividualKey(digit: digit, image: image)
                }
                selectedDigitForPicker = nil
            }
        }
    }

    @ViewBuilder
    private var flashButton: some View {
        if case .running = vm.passthmFlashPhase {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在刷入主题…").font(.subheadline.bold())
                    ProgressView(value: vm.passthmFlashProgress)
                }
            }
            .padding(.vertical, 4)
        } else if case .done(let ok) = vm.passthmFlashPhase, !ok {
            Button {
                vm.flashPassthm()
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                    Text("重试刷入主题")
                    Spacer()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .glassProminentButton(tint: .orange)
            .disabled(!vm.canFlashPassthm)
        } else {
            Button {
                vm.flashPassthm()
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bolt.fill")
                    Text("刷入主题到 iPhone")
                    Spacer()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .glassProminentButton()
            .disabled(!vm.canFlashPassthm)
        }
    }
}

// MARK: - Keypad Preview (clean modern lock screen dialer preview)

struct KeypadPreviewView: View {
    @EnvironmentObject var vm: AppViewModel
    let keys: [String: UIImage]

    @State private var dragOffsetStart: CGPoint = .zero
    @State private var isDragging: Bool = false

    private func scaledPosterDimensions(for poster: UIImage, gridW: CGFloat, gridH: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let imgW = poster.size.width
        let imgH = poster.size.height
        guard imgW > 0, imgH > 0 else { return (gridW, gridH) }

        let imgAspect = imgW / imgH
        let gridAspect = gridW / gridH

        if imgAspect > gridAspect {
            let h = gridH * vm.posterZoom
            return (width: h * imgAspect, height: h)
        } else {
            let w = gridW * vm.posterZoom
            return (width: w, height: w / imgAspect)
        }
    }

    var body: some View {
        let scale: CGFloat = 0.68
        let btnD: CGFloat = KeypadLayout.buttonDiameter * scale
        let colW: CGFloat = KeypadLayout.colWidth * scale
        let rowH: CGFloat = KeypadLayout.rowHeight * scale
        let gridW: CGFloat = KeypadLayout.gridWidth * scale
        let gridH: CGFloat = KeypadLayout.gridHeight * scale

        let isSeamlessPoster = (vm.passcodeMode == .themeCreator && vm.sliceMode == .posterSlice && !vm.maskToCircles && vm.posterImage != nil)

        ZStack {
            // Dark luxury frosted card backdrop
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))

            LinearGradient(
                colors: [Color.white.opacity(0.06), Color.clear, Color.black.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(spacing: 12) {
                // Keypad grid
                ZStack {
                    // Layer 1: Background wallpaper in Seamless Poster mode
                    if isSeamlessPoster, let poster = vm.posterImage {
                        let dims = scaledPosterDimensions(for: poster, gridW: gridW, gridH: gridH)
                        Image(uiImage: poster)
                            .resizable()
                            .frame(width: dims.width, height: dims.height)
                            .position(
                                x: gridW / 2.0 + (vm.posterOffset.x * scale),
                                y: gridH / 2.0 + (vm.posterOffset.y * scale)
                            )
                    }

                    // Layer 2: 10 Keypad buttons
                    ForEach(KeypadLayout.allButtons) { btn in
                        let cx = CGFloat(btn.col) * colW + colW / 2
                        let cy = CGFloat(btn.row) * rowH + rowH / 2

                        keypadButton(btn: btn, btnD: btnD, scale: scale, isSeamlessPoster: isSeamlessPoster)
                            .position(x: cx, y: cy)
                    }
                }
                .frame(width: gridW, height: gridH)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if vm.passcodeMode == .themeCreator && vm.sliceMode == .posterSlice && vm.posterImage != nil {
                                if !isDragging {
                                    isDragging = true
                                    dragOffsetStart = vm.posterOffset
                                }
                                vm.posterOffset = CGPoint(
                                    x: dragOffsetStart.x + value.translation.width / scale,
                                    y: dragOffsetStart.y + value.translation.height / scale
                                )
                                vm.updatePosterSlicing()
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            dragOffsetStart = vm.posterOffset
                        }
                )

                // Drag hint pill (only shown when dragging poster is possible)
                if vm.passcodeMode == .themeCreator && vm.sliceMode == .posterSlice && vm.posterImage != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.draw.fill")
                            .font(.system(size: 10))
                        Text("拖动预览调整位置")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: (vm.passcodeMode == .themeCreator && vm.sliceMode == .posterSlice && vm.posterImage != nil) ? 320 : 295)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func keypadButton(btn: KeypadButtonGeometry, btnD: CGFloat, scale: CGFloat, isSeamlessPoster: Bool) -> some View {
        ZStack {
            if isSeamlessPoster {
                // Seamless mode: Frosted glass touch target ring
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: btnD, height: btnD)

                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.0)
                    .frame(width: btnD, height: btnD)

                VStack(spacing: 0) {
                    Text(btn.digit)
                        .font(.system(size: 26 * scale, weight: .light))
                        .foregroundStyle(.white.opacity(0.95))
                    if !btn.letters.isEmpty {
                        Text(btn.letters)
                            .font(.system(size: 8.5 * scale, weight: .semibold))
                            .tracking(0.8 * scale)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            } else if let img = keys[btn.digit] {
                // Custom theme button: Pure artwork without clashing superimposed text!
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: btnD, height: btnD)

                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: btnD, height: btnD)
                    .clipShape(Circle())

                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                    .frame(width: btnD, height: btnD)
            } else {
                // Default iOS dialer style for unstyled buttons
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: btnD, height: btnD)

                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                    .frame(width: btnD, height: btnD)

                VStack(spacing: 0) {
                    Text(btn.digit)
                        .font(.system(size: 26 * scale, weight: .light))
                        .foregroundStyle(.white)
                    if !btn.letters.isEmpty {
                        Text(btn.letters)
                            .font(.system(size: 8.5 * scale, weight: .semibold))
                            .tracking(0.8 * scale)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
        .frame(width: btnD, height: btnD)
    }
}

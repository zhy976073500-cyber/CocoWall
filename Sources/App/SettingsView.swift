import SwiftUI
import UIKit

/// 设置页：按网页版的卡片版式重排。内容还是原来那套——
/// 配对（PairingService）、回环隧道（TunnelManager）、核心检测
/// （DeviceService）——服务层接口一个没动，只是换了容器。
struct SettingsView: View {
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject var pairing: PairingService
    @State private var showPairingImporter = false
    @State private var deviceMessage: String?

    private let deviceService: DeviceService = FFIDeviceService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    pairingCard
                    tunnelCard
                    localDevVPNCard
                    coreCard
                }
                .padding(20)
            }
            .background(Color.white)
            .navigationTitle("设置")
            .onAppear { pairing.refreshFromDisk() }
            .sheet(isPresented: $showPairingImporter) {
                DocumentPicker { url in
                    showPairingImporter = false
                    handlePairingPick(url)
                } onCancel: {
                    showPairingImporter = false
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - 配对卡

    private var pairingCard: some View {
        SettingsCard(title: "本机配对（iOS 27）") {
            switch pairing.state {
            case .unpaired:
                Text("尚未配对").foregroundStyle(.secondary)
            case .hosting(let pin):
                if let pin {
                    // The core only issues a PIN once the
                    // system has connected and pair-setup has
                    // begun — this phase is proof of connection.
                    Text("系统已连接，配对进行中")
                        .foregroundStyle(.green)
                    Text("配对码（配对结束前会一直显示在这里）")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(pin)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .tracking(6)
                    Text("切回 系统设置 › 隐私与安全性 › 开发者模式，把这串配对码填进刚才点的配对设备里。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let serviceID = pairing.hostServiceID {
                    Text("广播中，等待系统连接…")
                    Text("去 系统设置 › 隐私与安全性 › 开发者模式 ›「配对设备」，点「\(serviceID)」；系统连上后，这里会给出配对码。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("正在启动配对广播…")
                        .foregroundStyle(.secondary)
                }
            case .paired:
                Text("已配对").foregroundStyle(.green)
                if let path = pairing.pairingFilePath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Text(msg).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 打开「开发者模式」：系统设置 → 隐私与安全性 → 开发者模式，打开后按提示重启确认（首次才需要）。")
                Text("2. 先开回环：在下方「回环隧道」里点「连接回环隧道」，看到状态栏 VPN 标志后再回来。")
                Text("3. 点下方「开始配对」，切到开发者模式的「配对设备」，点以 idevice_pair 开头的那一条。")
                Text("4. 回到本 App，配对码会大字显示且全程保留；再回设置把码填进去。成功后配对记录保存在本机，以后不用重复配对。")
            }
            .font(.caption).foregroundStyle(.secondary)
            if #available(iOS 27.0, *) {
                Button("开始配对") { pairing.startOnDevicePairing() }
            } else {
                Text("机内配对需 iOS 27 及以上；系统低于 iOS 27 请用下方导入配对文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("导入配对文件…") { showPairingImporter = true }
            if pairing.pairingFilePath != nil {
                Button("删除配对文件", role: .destructive) { pairing.forget() }
            }
        }
    }

    // MARK: - 回环隧道卡

    private var tunnelCard: some View {
        SettingsCard(title: "回环隧道") {
            switch tunnel.state {
            case .disconnected: Text("未连接").foregroundStyle(.secondary)
            case .connecting: Text("正在连接…")
            case .connected: Text("已连接").foregroundStyle(.green)
            case .failed(let msg): Text(msg).foregroundStyle(.red)
            }
            Button("连接回环隧道") { Task { await tunnel.connect() } }
            Button("断开回环隧道") { tunnel.disconnect() }
        }
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
            Text("Rust 核心已链接：\(FFIDeviceService.coreVersion)")
                .font(.caption).foregroundStyle(.secondary)
            Text("注入环（AFC 暂存 + AirTraffic 同步）尚未落地：检测与写入会由核心返回明确的「注入环未落地」错误，不会假装成功。")
                .font(.caption).foregroundStyle(.secondary)
            Button("检测 PosterBoard 容器") { Task { await probeContainer() } }
            if let deviceMessage {
                Text(deviceMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 动作

    private func handlePairingPick(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            pairing.importPairing(data: data)
        } catch {
            pairing.importFailed(error)
        }
    }

    private func probeContainer() async {
        guard let path = pairing.pairingFilePath else {
            deviceMessage = "请先导入配对文件。"
            return
        }
        do {
            let container = try await deviceService.detectPosterBoardContainer(
                pairingFile: URL(fileURLWithPath: path))
            deviceMessage = "PosterBoard 容器：\(container)"
        } catch {
            deviceMessage = error.localizedDescription
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

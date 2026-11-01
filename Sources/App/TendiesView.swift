//
//  TendiesView.swift
//  AirCard-iOS
//
//  Dedicated UI for importing, previewing, and flashing PosterBoard .tendies wallpapers.
//  Unified Form design matching the Passcode Theme tab.
//

import SwiftUI
import UniformTypeIdentifiers
import NetworkExtension

// MARK: - 状态区回环呈现（run #127，纯逻辑，可离线断言）

/// 内置回环隧道状态的纯枚举镜像，与 NEVPNStatus 一一对应。
/// 下面的映射逻辑只依赖这个镜像（不依赖 NetworkExtension），
/// 因此可原文抽出、在离线 harness 里跑断言。
enum LoopbackPhase {
    case connected
    case connecting
    case disconnecting
    case reasserting
    case disconnected
    case invalid
    case unknown
}

/// 壁纸页状态区回环按钮与「回环连接」状态行的呈现结果。
/// 可发现性纪律（run #127，Sage 2026-11-02 真机反馈：设置页的
/// 内置回环开关他根本没找到）：壁纸页这一处就是唯一入口的心智
/// 模型——按钮标题在任何状态下都必须写明「内置回环」，不许只
/// 写含糊的「连接」二字让人分不清连的是内是外；连接状态紧贴
/// 按钮下方一行显示（见状态区排版）。
struct LoopbackPresentation {
    let buttonTitle: String
    let buttonSubtitle: String
    let buttonEnabled: Bool
    let lineValue: String
    let lineOK: Bool
    let lineWarn: Bool
}

/// 纯映射（run #127）：隧道相位 + 保存配置忙碌位 + 外部回环探活
/// → 按钮标题/副文案/可用性与状态行文案。
///
/// 「回环连接」一行的口径：以内置隧道状态为主——内置已连接 /
/// 连接中 / 断开中都据实显示；内置不在场（未连接 / 未配置）时，
/// 外部 LocalDevVPN 在跑（externalUp = vm.vpnUp 的接口扫描结果）
/// 仍显示「已连接」，因为刷入照样走得通。isBusy 表示 start() 正
/// 在保存 VPN 配置（NEVPNStatus 尚未翻到 connecting），此时按
/// 连接中呈现，避免按钮在授权弹窗前后闪回可点状态。
func loopbackPresentation(phase: LoopbackPhase,
                          isBusy: Bool,
                          externalUp: Bool) -> LoopbackPresentation {
    let effective: LoopbackPhase =
        (isBusy && (phase == .disconnected || phase == .invalid || phase == .unknown))
        ? .connecting : phase
    switch effective {
    case .connected:
        return LoopbackPresentation(
            buttonTitle: "断开内置回环",
            buttonSubtitle: "内置回环已连接，点击断开",
            buttonEnabled: true,
            lineValue: "已连接（内置回环）",
            lineOK: true, lineWarn: false)
    case .connecting, .reasserting:
        return LoopbackPresentation(
            buttonTitle: "内置回环连接中…",
            buttonSubtitle: "正在建立内置回环…",
            buttonEnabled: false,
            lineValue: "连接中…",
            lineOK: false, lineWarn: true)
    case .disconnecting:
        return LoopbackPresentation(
            buttonTitle: "内置回环断开中…",
            buttonSubtitle: "正在断开内置回环…",
            buttonEnabled: false,
            lineValue: "断开中…",
            lineOK: false, lineWarn: true)
    case .disconnected, .invalid, .unknown:
        return LoopbackPresentation(
            buttonTitle: "连接内置回环",
            buttonSubtitle: phase == .invalid
                ? "CocoWall 自带回环；首次连接会弹出系统提示，允许添加 VPN 配置"
                : "CocoWall 自带回环，点按直接连接，无需其他 App",
            buttonEnabled: true,
            lineValue: externalUp ? "已连接" : "未连接",
            lineOK: externalUp, lineWarn: false)
    }
}

struct TendiesView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showFilePicker = false
    @State private var selectedDetailItem: TendieItem? = nil
    @State private var isNeoSpringing = false

    private var selectedCount: Int {
        vm.tendieItems.filter { $0.isSelected }.count
    }

    private var selectedAll: Bool {
        !vm.tendieItems.isEmpty && vm.tendieItems.allSatisfy { $0.isSelected }
    }

    // MARK: - 状态区（run #124 / #127）

    /// 与设置页 VPNStatusRow 共用同一 LoopbackTunnelManager 共享
    /// 实例（run #127 收敛）：同一份 VPN 配置档案、同一状态源，
    /// 两处启停互通、状态一致。
    @ObservedObject private var loopback = LoopbackTunnelManager.shared

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

    private var loopbackUI: LoopbackPresentation {
        loopbackPresentation(phase: loopbackPhase,
                             isBusy: loopback.isBusy,
                             externalUp: vm.vpnUp)
    }

    private var systemStatusLevel: SystemSupportLevel {
        AppViewModel.systemSupportLevel(version: UIDevice.current.systemVersion)
    }

    private var systemStatusText: String {
        let v = UIDevice.current.systemVersion
        switch systemStatusLevel {
        case .supported:
            return "iOS \(v) · 支持"
        case .patchedRisk:
            return "iOS \(v) · 风险提示（27.2 起通道被修补）"
        case .tooOld:
            return "iOS \(v) · 不支持（需 iOS 17.0 起）"
        }
    }

    private func statusLine(title: String, value: String, ok: Bool, warn: Bool = false) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ok ? Color.green : (warn ? Color.orange : Color.secondary))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Notice Banners
                if let err = vm.errorMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                            Spacer()
                            Button {
                                vm.errorMessage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Section -1: 状态区（run #124 追加、run #127 改回环
                // 接线，页面最上方）：「连接回环」按钮 + 配对文件 /
                // 本机系统 / 回环连接三项状态。配对文件 =
                // vm.hasPairingFile（refreshPairingFile 校验规范配对
                // 文件存在且非空）；本机系统 = UIDevice 系统版本 +
                // AppViewModel.systemSupportLevel 判定。「连接回环」
                // 按钮与「回环连接」一行自 run #127 起改接内置回环
                // （LoopbackTunnelManager 共享实例，与设置页同一份
                // VPN 配置）：按钮点按直接启停 CocoWall 自己的隧道
                // 扩展、任何状态下都不跳转外部 App；状态行以内置
                // NEVPNStatus 为主口径，内置不在场时外部回环在跑
                // （vm.vpnUp 接口扫描）仍显示已连接（口径详见文件
                // 顶部 loopbackPresentation）。进页面时查一次（见
                // onAppear），区标题右侧按钮手动刷新。
                Section {
                    Button {
                        // run #127：未连接时点按 = 保存 VPN 配置
                        // （首次触发系统「添加 VPN 配置」授权弹窗，
                        // 属预期）并启动内置隧道；已连接时点按断开。
                        // 连接中/断开中按钮禁用，不重复触发。
                        if loopbackPhase == .connected {
                            loopback.stop()
                        } else {
                            loopback.start()
                        }
                        // 外部口径（vm.vpnUp）顺手刷新一次；内置
                        // 状态由共享实例的 NEVPNStatus 观察自动
                        // 跟随，不用手刷、不用猜。
                        vm.refreshNetworkStatus()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "network")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loopbackUI.buttonTitle)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(loopbackUI.buttonSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !loopbackUI.buttonEnabled {
                                ProgressView()
                                    .controlSize(.small)
                            } else if loopbackPhase == .connected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(Color.green)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!loopbackUI.buttonEnabled)

                    // run #127：回环状态紧贴按钮显示（Sage 真机
                    // 反馈：设置页的内置开关根本没被找到——壁纸页
                    // 这一处就是唯一入口，状态必须一眼可见）。
                    statusLine(title: "回环连接",
                               value: loopbackUI.lineValue,
                               ok: loopbackUI.lineOK,
                               warn: loopbackUI.lineWarn)
                    statusLine(title: "配对文件",
                               value: vm.hasPairingFile ? "已识别" : "未识别",
                               ok: vm.hasPairingFile)
                    statusLine(title: "本机系统",
                               value: systemStatusText,
                               ok: systemStatusLevel == .supported,
                               warn: systemStatusLevel != .supported)

                    // run #127：启停失败（尤其签名 / entitlement
                    // 类错误）原样显示在状态区内——管理器文案已是
                    // 「中文前缀 + 系统错误原文」，是下一步诊断
                    // 签名链的关键证据，不许吞成一句「失败」。
                    if let loopbackError = loopback.lastError {
                        Text(loopbackError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    HStack {
                        Text("状态")
                        Spacer()
                        Button {
                            vm.refreshPairingFile()
                            vm.refreshNetworkStatus()
                            Task { await loopback.reload() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }

                // Section 0: 获取更多壁纸（点击用系统浏览器打开飞书合集）
                Section {
                    Button {
                        if let url = URL(string: "https://my.feishu.cn/wiki/Oi6pwrRp9i8wd2kBl0Lc4bn9nTb") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("获取更多壁纸")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("在浏览器打开飞书合集，持续更新")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Section 1: Flash Action & Respring（原底部动作卡上移到此处；
                // 导入入口只保留工具栏右上角 + 号）
                Section {
                    VStack(spacing: 12) {
                        if case .running = vm.tendiesFlashPhase {
                            HStack(spacing: 10) {
                                ProgressView()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("正在刷入壁纸…").font(.subheadline.bold())
                                    ProgressView(value: vm.tendiesFlashProgress)
                                }
                            }
                            .padding(.vertical, 4)
                        } else {
                            Button {
                                Task {
                                    await vm.flashSelectedTendies()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Spacer()
                                    Image(systemName: "sparkles")
                                    Text("刷入 \(selectedCount) 张壁纸")
                                    Spacer()
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(selectedCount == 0)
                        }

                        Button(role: .destructive) {
                            // 先试免注销刷新（只重启 PosterBoard 守护进程）；未确认才回退 NeoSpring 注销整机。
                            PosterRefreshHelper.attemptRefresh(
                                pairingPath: PairingController.pairingFilePath(),
                                log: { _ in }
                            ) { confirmed, _ in
                                if !confirmed {
                                    vm.isNeoSpringing = true
                                    isNeoSpringing = true
                                    RespringHelper.triggerNeoSpring()
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "bolt.fill")
                                Text("注销（NeoSpring）")
                                Spacer()
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if vm.posterBoardContainer.isEmpty {
                            Text("刷入时将自动检测 PosterBoard 容器。")
                        } else {
                            Text("目标：已检测到 PosterBoard 容器 ✅")
                        }
                        Text("刷入后将先尝试免注销刷新系统壁纸；本版不会自动注销，如未生效可手动点注销。")
                    }
                }

                // Section 2: PosterBoard Options
                Section {
                    Toggle(isOn: $vm.resetPBProtections) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("强制刷新 PosterBoard 缓存")
                                .font(.subheadline.weight(.medium))
                            Text("重置文件保护，让 iOS 立即重新索引壁纸")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Section 3: Wallpapers Gallery
                if !vm.tendieItems.isEmpty {
                    Section {
                        HStack {
                            Text("已导入 \(vm.tendieItems.count) 张壁纸")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(selectedAll ? "取消全选" : "全选") {
                                let target = !selectedAll
                                for i in 0..<vm.tendieItems.count {
                                    vm.tendieItems[i].isSelected = target
                                }
                            }
                            .font(.caption)
                        }

                        ForEach($vm.tendieItems) { $item in
                            TendieRowView(item: $item) {
                                selectedDetailItem = item
                            } onDelete: {
                                vm.deleteTendie(item: item)
                            }
                        }
                    } header: {
                        Text("壁纸库")
                    }
                } else {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("还没有载入 .tendies 壁纸")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("点右上角「+」从文件选择 .tendies，或把壁纸拷到 我的 iPhone › CocoWall。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                }

                // Section 3.5: 检测本机已导入的壁纸（设备 PosterBoard 数据仓
                // 的真实存量，与上方 App 本地导入列表是两回事，可勾选清理）
                Section {
                    Button {
                        vm.showDevicePosterSheet = true
                        Task { await vm.detectDevicePosters() }
                    } label: {
                        Label("检测本机已导入的壁纸", systemImage: "checklist")
                    }
                    if !vm.devicePosterStatus.isEmpty {
                        Text(vm.devicePosterStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("检测设备 PosterBoard 数据仓中实际存在的壁纸（包括其他工具导入的），可勾选后清理。")
                }

                // Section 4: Flash Log (CompactLogView)
                if !vm.tendiesFlashLog.isEmpty {
                    Section {
                        CompactLogView(
                            title: "刷入日志（\(vm.tendiesFlashLog.count) 行）",
                            lines: vm.tendiesFlashLog,
                            onClear: { vm.tendiesFlashLog.removeAll() }
                        )
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .navigationTitle("壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                    }
                }
            }
            .sheet(isPresented: $showFilePicker) {
                TendiesDocumentPickerView { urls in
                    Task {
                        await vm.importTendieFiles(urls: urls)
                    }
                }
            }
            .sheet(item: $selectedDetailItem) { item in
                TendieDetailSheet(item: item)
            }
            .sheet(isPresented: $vm.showDevicePosterSheet) {
                DevicePosterCleanupView()
            }
            .onAppear {
                vm.isNeoSpringing = false
                isNeoSpringing = false
                vm.showSuccessAlert = false
                vm.successAlertMessage = ""
                vm.scanDocumentsForTendies()
                // 状态区（run #124）：进页面查一次配对文件与回环
                // 探活状态（均为现成只读轻量检查，不开新连接）。
                vm.refreshPairingFile()
                vm.refreshNetworkStatus()
                // 状态区回环（run #127）：进页面再对一次内置回环
                // 的已保存配置与状态（共享实例 init 已载入过，
                // 这里只读对齐，不触发任何启停）。
                Task { await loopback.reload() }
            }
            .task {
                if vm.posterBoardContainer.isEmpty {
                    await vm.autoDetectPosterBoardContainer(silent: true)
                }
            }
            .overlay {
                if isNeoSpringing || vm.isNeoSpringing {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        NeoSpringView()
                            .brightness(-1.0)
                            .ignoresSafeArea()
                    }
                }
            }
        }
    }
}

// MARK: - Tendie Row View

struct TendieRowView: View {
    @EnvironmentObject var vm: AppViewModel
    @Binding var item: TendieItem
    let onInspect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $item.isSelected)
                .labelsHidden()

            if let imgData = item.previewImageData, let uiImg = UIImage(data: imgData) {
                Image(uiImage: uiImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 60)
                    .cornerRadius(6)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: 44, height: 60)
                    .overlay {
                        Image(systemName: item.posterType.systemIcon)
                            .foregroundColor(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.posterType.rawValue)
                        .font(.caption2.bold())
                        .foregroundColor(item.posterType.badgeColor)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("\(item.descriptorCount) 个描述符")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                onInspect()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .task {
            // 已存预览缺失或解码失败时，从包内重新提取（导入时只提取一次且不重试）。
            vm.regenerateTendiePreview(itemID: item.id)
        }
    }
}

// MARK: - Tendie Detail Sheet

struct TendieDetailSheet: View {
    let item: TendieItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let imgData = item.previewImageData, let uiImg = UIImage(data: imgData) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 300)
                            .cornerRadius(12)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                            .listRowBackground(Color.clear)
                    }
                }

                Section("信息") {
                    detailRow(title: "名称", value: item.name)
                    detailRow(title: "文件名", value: item.fileName)
                    detailRow(title: "类型", value: item.posterType.rawValue)
                    detailRow(title: "描述符", value: "\(item.descriptorCount)")
                    detailRow(title: "目标扩展", value: item.posterType.extensionBundleId)
                    detailRow(title: "格式", value: item.isContainer ? "App 容器" : "描述符包")
                    if item.unsafeContainer {
                        detailRow(title: "警告", value: "包含 SQLite 数据库")
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Tendies Document Picker

struct TendiesDocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var contentTypes: [UTType] = []
        if let customType = UTType("com.aircard.tendies") {
            contentTypes.append(customType)
        }
        if let extType = UTType(filenameExtension: "tendies") {
            contentTypes.append(extType)
        }
        contentTypes.append(contentsOf: [.archive, .zip, .data, .item])

        // asCopy: true ensures iOS safely copies documents into app sandbox tmp directory
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: TendiesDocumentPickerView

        init(_ parent: TendiesDocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            parent.onPick(urls)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Device Poster Cleanup Sheet

/// Lists the descriptors actually present in the device's PosterBoard
/// data store (via PosterStoreHelper), lets the user tick items, and —
/// after an explicit confirmation — deletes the selected ones from the
/// device, then shows the refreshed list and the cleanup result.
struct DevicePosterCleanupView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCleanupConfirm = false

    private var selectedItems: [DevicePosterItem] {
        vm.devicePosters.filter { vm.devicePosterSelection.contains($0.id) }
    }

    private var allSelected: Bool {
        !vm.devicePosters.isEmpty && vm.devicePosterSelection.count == vm.devicePosters.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isScanningDevicePosters {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在检测设备数据仓…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if vm.devicePosters.isEmpty {
                            Section {
                                VStack(spacing: 10) {
                                    Image(systemName: "photo.stack")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.secondary)
                                    Text(vm.devicePosterStatus.isEmpty ? "设备数据仓里没有检测到已导入的壁纸。" : vm.devicePosterStatus)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 24)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .listRowSeparator(.hidden)
                            }
                        }
                        if !vm.devicePosters.isEmpty {
                        Section {
                            ForEach(vm.devicePosters) { item in
                                Button {
                                    if vm.devicePosterSelection.contains(item.id) {
                                        vm.devicePosterSelection.remove(item.id)
                                    } else {
                                        vm.devicePosterSelection.insert(item.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: vm.devicePosterSelection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(vm.devicePosterSelection.contains(item.id) ? Color.accentColor : Color.secondary)
                                        // Runs #122/#124: thumbnail borrowed
                                        // from the matching local library
                                        // entry (flash registry first, then
                                        // package-name matching in
                                        // AppViewModel), so a row can be
                                        // recognised by its picture.
                                        if let thumbData = vm.devicePosterThumbs[item.id],
                                           let thumb = UIImage(data: thumbData) {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 34, height: 46)
                                                .cornerRadius(6)
                                                .clipped()
                                                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                                        } else {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color(UIColor.tertiarySystemFill))
                                                .frame(width: 34, height: 46)
                                                .overlay {
                                                    Image(systemName: "photo")
                                                        .foregroundStyle(.secondary)
                                                }
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            // Run #124: prefer the local
                                            // library display name when the
                                            // row's source entry is known —
                                            // the store-reported name carries
                                            // the rewritten packaged base
                                            // (e.g. "1572.WWDC_2022-…"), which
                                            // identifies nothing.
                                            Text(vm.devicePosterDisplayNames[item.id] ?? item.name)
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("\(item.extensionId) · \(String(item.uuid.prefix(8)))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text("设备数据仓中共 \(vm.devicePosters.count) 张")
                                Spacer()
                                Button(allSelected ? "取消全选" : "全选") {
                                    if allSelected {
                                        vm.devicePosterSelection = []
                                    } else {
                                        vm.devicePosterSelection = Set(vm.devicePosters.map { $0.id })
                                    }
                                }
                                .font(.caption)
                                .textCase(nil)
                            }
                        }
                        }
                    }
                }
            }
            .onChange(of: vm.tendieItems) { _, _ in
                // A library preview regenerated after the cleanup
                // list was built can fill in a row thumbnail that
                // was missing (run #122).
                vm.prepareDevicePosterThumbnails()
            }
            .navigationTitle("本机已导入的壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            await vm.detectDevicePosters()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isScanningDevicePosters || vm.isCleaningDevicePosters)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !vm.devicePosters.isEmpty {
                    VStack(spacing: 8) {
                        if !vm.devicePosterStatus.isEmpty {
                            Text(vm.devicePosterStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button(role: .destructive) {
                            showCleanupConfirm = true
                        } label: {
                            HStack(spacing: 8) {
                                Spacer()
                                if vm.isCleaningDevicePosters {
                                    ProgressView()
                                    Text("正在清理…")
                                } else {
                                    Image(systemName: "trash")
                                    Text("清理所选（\(selectedItems.count)）")
                                }
                                Spacer()
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(selectedItems.isEmpty || vm.isCleaningDevicePosters || vm.isScanningDevicePosters)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
            .confirmationDialog(
                "清理所选壁纸？",
                isPresented: $showCleanupConfirm,
                titleVisibility: .visible
            ) {
                Button("清理 \(selectedItems.count) 张", role: .destructive) {
                    Task { await vm.cleanupSelectedDevicePosters() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所选 \(selectedItems.count) 张壁纸将从设备 PosterBoard 数据仓中移除。")
            }
        }
    }
}

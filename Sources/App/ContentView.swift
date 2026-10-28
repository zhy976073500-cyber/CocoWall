import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// v1 shell: 壁纸 (import / apply / manage) + 设置 (pairing / tunnel).
struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()
    @StateObject private var pairing = PairingService()

    var body: some View {
        TabView {
            WallpaperListView(pairing: pairing, tunnel: tunnel)
                .tabItem { Label("壁纸", systemImage: "photo.on.rectangle.angled") }
            SettingsView(tunnel: tunnel, pairing: pairing)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .task { await tunnel.refresh() }
    }
}

struct WallpaperListView: View {
    @ObservedObject var pairing: PairingService
    @ObservedObject var tunnel: TunnelManager
    @State private var records: [ImportedWallpaper] = []
    @State private var showImporter = false
    @State private var selectedRecord: ImportedWallpaper?
    @State private var errorMessage: String?

    @State private var scanMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty {
                    Text("尚未导入壁纸。从“文件”选择 .tendies，或在其他 App 中用 CocoWall 打开。")
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    Button {
                        selectedRecord = record
                    } label: {
                        HStack(spacing: 12) {
                            WallpaperThumbnail(record: record)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.displayName).font(.headline)
                                Text("编号 \(record.descriptorIdentifier) · \(record.fileName)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("壁纸")
            .toolbar {
                Menu {
                    Button("从文件选择…") { showImporter = true }
                    Button("扫描文稿目录") { scanDocuments() }
                } label: {
                    Text("导入 .tendies")
                }
            }
            .onAppear {
                records = ImportedWallpaperStore.load()
                backfillPreviews()
            }
            .fullScreenCover(item: $selectedRecord) { record in
                WallpaperPreviewView(record: record) {
                    selectedRecord = nil
                }
            }
            .sheet(isPresented: $showImporter) {
                DocumentPicker { url in
                    showImporter = false
                    importPicked(url)
                } onCancel: {
                    showImporter = false
                }
                .ignoresSafeArea()
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("扫描结果", isPresented: Binding(
                get: { scanMessage != nil },
                set: { if !$0 { scanMessage = nil } }
            )) {
                Button("好") { scanMessage = nil }
            } message: {
                Text(scanMessage ?? "")
            }
        }
    }

    private func importPicked(_ url: URL) {
        // DocumentPicker is asCopy, so the URL is a local copy already.
        do {
            let record = try ImportedWallpaperStore.importArchive(from: url)
            records.append(record)
            ImportedWallpaperStore.save(records)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scanDocuments() {
        let result = ImportedWallpaperStore.scanDocuments(existing: records)
        if !result.added.isEmpty {
            records.append(contentsOf: result.added)
            ImportedWallpaperStore.save(records)
        }
        if result.added.isEmpty && result.failed.isEmpty {
            scanMessage = "文稿目录里没有新的 .tendies。把文件放进「文件 ▸ 我的 iPhone ▸ CocoWall」后再扫一次。"
        } else if result.failed.isEmpty {
            scanMessage = "已导入 \(result.added.count) 个壁纸。"
        } else {
            scanMessage = "导入 \(result.added.count) 个；解析失败：\(result.failed.joined(separator: "、"))"
        }
    }

    /// Wallpapers imported by older builds have no preview files yet;
    /// generate them once from the stored archives. Records that already
    /// have either preview field set are skipped, so a package that
    /// legitimately has no background still (floating only, or none) is
    /// not re-parsed on every appearance.
    private func backfillPreviews() {
        var changed = false
        for index in records.indices
        where records[index].previewFileName == nil
            && records[index].floatingPreviewFileName == nil {
            if let updated = ImportedWallpaperStore.ensurePreview(for: records[index]) {
                records[index] = updated
                changed = true
            }
        }
        if changed { ImportedWallpaperStore.save(records) }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            ImportedWallpaperStore.removeFile(for: records[index])
        }
        records.remove(atOffsets: offsets)
        ImportedWallpaperStore.save(records)
    }
}

struct SettingsView: View {
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject var pairing: PairingService
    @State private var showPairingImporter = false
    @State private var deviceMessage: String?

    private let deviceService: DeviceService = FFIDeviceService()

    var body: some View {
        NavigationStack {
            List {
                Section("本机配对（iOS 27）") {
                    switch pairing.state {
                    case .unpaired:
                        Text("尚未配对").foregroundStyle(.secondary)
                    case .hosting(let pin):
                        if let pin {
                            Text("配对码")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(pin)
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .tracking(6)
                            Text("在 系统设置 › 隐私与安全性 › 开发者模式 里点「与 CocoWall 配对」，填入这串配对码。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("正在广播配对服务，等待本机系统连接…")
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
                        Text("3. 点下方「开始配对」，本 App 会显示一串 6 位配对码。")
                        Text("4. 在开发者模式里点「与 CocoWall 配对」填入配对码；成功后配对记录保存在本机，以后不用重复配对。")
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
                Section("回环隧道") {
                    switch tunnel.state {
                    case .disconnected: Text("未连接").foregroundStyle(.secondary)
                    case .connecting: Text("正在连接…")
                    case .connected: Text("已连接").foregroundStyle(.green)
                    case .failed(let msg): Text(msg).foregroundStyle(.red)
                    }
                    Button("连接回环隧道") { Task { await tunnel.connect() } }
                    Button("断开回环隧道") { tunnel.disconnect() }
                }
                Section("壁纸写入") {
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
            .navigationTitle("设置")
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

/// 46×62 portrait thumbnail for a wallpaper row: the stored background
/// preview when there is one, otherwise a placeholder symbol. Clipped
/// rounded rect with a soft shadow and deliberately no stroke — matches
/// the cover style Sage settled on for his other projects.
struct WallpaperThumbnail: View {
    let record: ImportedWallpaper

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
            if let url = ImportedWallpaperStore.previewURL(for: record),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
    }
}

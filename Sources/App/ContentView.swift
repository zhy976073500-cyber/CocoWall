import SwiftUI
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
    @State private var errorMessage: String?

    /// Deliberately broad: on-device .tendies files often carry a dynamic /
    /// unregistered UTI (Files shows them as unknown), so restricting the
    /// picker to the exported com.coco.tendies type leaves them greyed out.
    /// Accept anything and let the importer validate by parsing.
    private var tendiesContentTypes: [UTType] { [.item, .data] }

    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty {
                    Text("尚未导入壁纸。从“文件”选择 .tendies，或在其他 App 中用 CocoWall 打开。")
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName).font(.headline)
                        Text("编号 \(record.descriptorIdentifier) · \(record.fileName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("壁纸")
            .toolbar {
                Button("导入 .tendies…") { showImporter = true }
            }
            .onAppear { records = ImportedWallpaperStore.load() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: tendiesContentTypes,
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let record = try ImportedWallpaperStore.importArchive(from: url)
                records.append(record)
                ImportedWallpaperStore.save(records)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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

    private let deviceService: DeviceService = UnavailableDeviceService()

    var body: some View {
        NavigationStack {
            List {
                Section("配对与设备连接") {
                    switch pairing.state {
                    case .unpaired:
                        Text("尚未配对").foregroundStyle(.secondary)
                    case .hosting(let pin):
                        Text(pin.map { "在本机输入 PIN：\($0)" } ?? "正在广播配对服务…")
                    case .paired:
                        Text("已导入配对文件").foregroundStyle(.green)
                        if let path = pairing.pairingFilePath {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .failed(let msg):
                        Text(msg).foregroundStyle(.red)
                    }
                    if #available(iOS 27.0, *) {
                        Button("在这台 iPhone 上配对") { pairing.startOnDevicePairing() }
                    } else {
                        Text("机内配对需 iOS 27 及以上，此版本请导入配对文件。")
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
                    Text("设备写入服务尚未链接（idevice FFI 未集成到本 App），导入的壁纸目前只能保存在 App 内，还不能注入 PosterBoard。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("检测 PosterBoard 容器") { Task { await probeContainer() } }
                    if let deviceMessage {
                        Text(deviceMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $showPairingImporter,
                          allowedContentTypes: [.item, .data],
                          allowsMultipleSelection: false) { result in
                handlePairingImport(result)
            }
        }
    }

    private func handlePairingImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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

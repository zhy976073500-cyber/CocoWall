import SwiftUI

/// v1 shell: 壁纸 (import / apply / manage) + 设置 (pairing / tunnel).
/// Device-layer calls land behind DeviceService once the idevice FFI bridge is in.
struct ContentView: View {
    var body: some View {
        TabView {
            WallpaperListView()
                .tabItem { Label("壁纸", systemImage: "photo.on.rectangle.angled") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

struct WallpaperListView: View {
    @State private var imported: [TendiesPackage] = []

    var body: some View {
        NavigationStack {
            List {
                if imported.isEmpty {
                    Text("尚未导入壁纸。从“文件”选择 .tendies，或在其他 App 中用 CocoWall 打开。")
                        .foregroundStyle(.secondary)
                }
                ForEach(imported) { pkg in
                    VStack(alignment: .leading) {
                        Text(pkg.displayName).font(.headline)
                        Text(pkg.descriptorIdentifier)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("壁纸")
            .toolbar {
                Button("导入 .tendies…") { /* TODO: file importer */ }
            }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("配对与设备连接") {
                    Text("尚未配对") // TODO: pairing state from DeviceService
                    Button("在这台 iPhone 上配对") { /* TODO: RemotePairing PIN flow */ }
                    Button("导入配对文件…") { /* TODO: .mobiledevicepairing / .plist import */ }
                }
                Section("回环隧道") {
                    Text("未连接") // TODO: NETunnelProviderManager status
                    Button("连接回环隧道") { /* TODO: start tunnel */ }
                }
            }
            .navigationTitle("设置")
        }
    }
}

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// App 根视图：四个页签——壁纸｜壁纸库｜制作｜设置。
///
/// 底栏用系统 TabView，不自绘：用 iOS 26 SDK 编译后，系统自带
/// 液态玻璃悬浮胶囊和选中胶囊滑动（旧系统上就是系统原生的栏）。
/// 在此之上给每个页签图标加一次点击反馈：选中变化时对应图标
/// 用 symbolEffect 的 bounce 弹跳一下（系统符号动画，不自绘）。
struct ContentView: View {
    @StateObject private var tunnel = TunnelManager()
    @StateObject private var pairing = PairingService()
    @Environment(\.scenePhase) private var scenePhase

    private enum Tab: Hashable {
        case wallpaper, library, maker, settings
    }

    @State private var selection: Tab = .wallpaper
    /// 每个页签图标的弹跳计数：选中哪个页签，就把它的计数 +1，
    /// 绑定这个值的 symbolEffect 随之播一次 bounce。
    @State private var bounceCounts: [Tab: Int] = [:]

    var body: some View {
        TabView(selection: $selection) {
            WallpaperListView(pairing: pairing, tunnel: tunnel)
                .tabItem {
                    Label {
                        Text("壁纸")
                    } icon: {
                        Image(systemName: "photo.on.rectangle.angled")
                            .symbolEffect(.bounce, value: bounceCounts[.wallpaper, default: 0])
                    }
                }
                .tag(Tab.wallpaper)

            LibraryView()
                .tabItem {
                    Label {
                        Text("壁纸库")
                    } icon: {
                        Image(systemName: "photo.stack")
                            .symbolEffect(.bounce, value: bounceCounts[.library, default: 0])
                    }
                }
                .tag(Tab.library)

            MakerView()
                .tabItem {
                    Label {
                        Text("制作")
                    } icon: {
                        Image(systemName: "wand.and.stars")
                            .symbolEffect(.bounce, value: bounceCounts[.maker, default: 0])
                    }
                }
                .tag(Tab.maker)

            SettingsView(tunnel: tunnel, pairing: pairing)
                .tabItem {
                    Label {
                        Text("设置")
                    } icon: {
                        Image(systemName: "gearshape")
                            .symbolEffect(.bounce, value: bounceCounts[.settings, default: 0])
                    }
                }
                .tag(Tab.settings)
        }
        .onChange(of: selection) { _, newTab in
            bounceCounts[newTab, default: 0] += 1
        }
        .task { await tunnel.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Pairing sends the user into the system Settings app; the
            // host may have finished and written the pairing file
            // while we were backgrounded, with its completion hop
            // lost. Reconcile with the disk instead of trusting a
            // possibly stale in-memory state.
            if phase == .active {
                pairing.refreshFromDisk()
            }
        }
    }
}

/// 壁纸页：和网页版对齐的版式——纯白底、大标题、卡片式列表。
/// 数据与功能沿用原有实现：ImportedWallpaperStore 的记录、
/// DocumentPicker 导入、文稿目录扫描、点开进 WallpaperPreviewView。
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
            ScrollView {
                LazyVStack(spacing: 14) {
                    if records.isEmpty {
                        Text("尚未导入壁纸。从“文件”选择 .tendies，或在其他 App 中用 CocoWall 打开。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
                    }
                    ForEach(records) { record in
                        Button {
                            selectedRecord = record
                        } label: {
                            HStack(spacing: 14) {
                                WallpaperThumbnail(record: record)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("编号 \(record.descriptorIdentifier) · \(record.fileName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("删除", role: .destructive) { deleteRecord(record) }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.white)
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
                WallpaperPreviewView(record: record, pairing: pairing) {
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

    private func deleteRecord(_ record: ImportedWallpaper) {
        ImportedWallpaperStore.removeFile(for: record)
        records.removeAll { $0.id == record.id }
        ImportedWallpaperStore.save(records)
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

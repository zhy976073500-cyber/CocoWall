import SwiftUI

/// The wallpaper apply sheet: runs the core's full sequence
/// (隧道 → 配对文件 → AFC 暂存 → AirTraffic 同步 → gallery 计数校验 →
/// 刷新 plist) and renders its log lines as they stream in, so the
/// segment a failure stops at is visible with the core's own error
/// wording. On success it offers the respring step explicitly —
/// nothing is restarted without the user tapping it.
struct WallpaperApplyView: View {
    let record: ImportedWallpaper
    let pairingFile: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WallpaperApplyModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHeader
                Divider()
                logList
                Divider()
                actionBar
            }
            .navigationTitle("应用壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .idle:
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .running, .respringing:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .idle: return record.displayName
        case .running: return "正在写入设备…"
        case .respringing: return "正在重启设备…"
        case .succeeded: return "已写入，重启后生效"
        case .failed: return "写入失败"
        }
    }

    private var statusSubtitle: String {
        switch model.phase {
        case .idle:
            return "将把这个壁纸包注入 PosterBoard，过程约需数十秒。"
        case .running:
            return "分段日志实时显示进度，失败会停在出错的那一段。"
        case .respringing:
            return "设备会黑屏重启一次，属正常现象。"
        case .succeeded(let report):
            return "新壁纸编号 \(report.uuid)，gallery \(report.primaryBefore) → \(report.primaryAfter)，双写：\(report.dual)。重启后到锁屏长按选择新壁纸。"
        case .failed(let message):
            return message
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.lines.count) { _, _ in
                if let last = model.lines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .idle, .failed:
                Button {
                    model.start(record: record, pairingFile: pairingFile)
                } label: {
                    Text(model.phase == .idle ? "开始应用" : "重试")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .running, .respringing:
                Button("进行中…") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .frame(maxWidth: .infinity)
            case .succeeded:
                Button {
                    model.respring(pairingFile: pairingFile)
                } label: {
                    Text("重启设备以生效")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

@MainActor
final class WallpaperApplyModel: ObservableObject {
    enum Phase {
        case idle
        case running
        case respringing
        case succeeded(WallpaperApplyReport)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [String] = []

    func start(record: ImportedWallpaper, pairingFile: URL) {
        phase = .running
        lines = []
        let service = FFIDeviceService(logSink: { [weak self] line in
            DispatchQueue.main.async {
                self?.lines.append(line)
            }
        })
        Task {
            do {
                // Re-extract the stored archive to get a pristine
                // descriptor folder; the core preps its own copy and
                // never mutates this one either.
                let stored = ImportedWallpaperStore.importedDirectory
                    .appendingPathComponent(record.storedFileName)
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ApplyStage-\(UUID().uuidString)", isDirectory: true)
                let pkg = try TendiesPackage.load(from: stored, into: staging)
                let descriptorDir = pkg.extractedURL
                    .appendingPathComponent("descriptors")
                    .appendingPathComponent(pkg.descriptorUUID)
                defer { try? FileManager.default.removeItem(at: staging) }
                let report = try await service.applyWallpaper(
                    descriptorDir: descriptorDir, pairingFile: pairingFile)
                phase = .succeeded(report)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func respring(pairingFile: URL) {
        guard case .succeeded = phase else { return }
        // Keep the success state reachable again if respring fails:
        // the device simply stays on, and the error is shown inline.
        let previous = phase
        phase = .respringing
        let service = FFIDeviceService(logSink: { [weak self] line in
            DispatchQueue.main.async {
                self?.lines.append(line)
            }
        })
        Task {
            do {
                try await service.respring(pairingFile: pairingFile)
                lines.append("重启指令已发送，设备即将黑屏重启。")
                phase = previous
            } catch {
                lines.append("重启失败：\(error.localizedDescription)")
                phase = previous
            }
        }
    }
}

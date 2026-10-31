import SwiftUI
import PhotosUI

/// 关键帧壁纸编辑器（制作页 v1）：AE 式位置关键帧——
/// 选背景图 + 浮动图，在画布上拖图层、在时间轴上打帧，
/// 预览插值与导出编译共用 KeyframeProject 的同一套段/缓动计算，
/// 导出经 TendiesExporter 生成 .tendies，再走现有的导入通道进壁纸库。
struct KeyframeEditorView: View {
    @EnvironmentObject var vm: AppViewModel

    // 素材
    @State private var backgroundItem: PhotosPickerItem? = nil
    @State private var floatingItem: PhotosPickerItem? = nil
    @State private var backgroundImage: UIImage? = nil
    @State private var floatingImage: UIImage? = nil
    @State private var floatingExportData: Data? = nil
    @State private var floatingPixelSize: CGSize = .zero

    // 工程与播放
    @State private var project = KeyframeProject()
    @State private var playhead: Double = 0
    @State private var isPlaying = false
    /// 当前画布上图层的中心位置（画布坐标：原点左上、y 向下；
    /// 导出时由 TendiesExporter 换算为 CAML 坐标）。
    @State private var livePosition = CGPoint(x: 195, y: 422)
    @State private var selectedKeyframeID: UUID? = nil
    @State private var lastTickDate = Date()
    @State private var dragBase: CGPoint? = nil

    // 导出
    @State private var exportName = "关键帧壁纸"
    @State private var statusMessage: String? = nil
    @State private var isExporting = false

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                introText
                materialRow
                canvasSection
                transportRow
                timelineCard
                exportCard
            }
            .padding(16)
        }
        .background(Color(UIColor.systemBackground))
        .onReceive(ticker) { now in
            let dt = now.timeIntervalSince(lastTickDate)
            lastTickDate = now
            guard isPlaying, project.duration > 0 else { return }
            var t = playhead + dt
            if t >= project.duration {
                t = t.truncatingRemainder(dividingBy: project.duration)
            }
            playhead = t
            if let p = project.position(at: t) {
                livePosition = p
            }
        }
    }

    // MARK: - 顶部说明

    private var introText: some View {
        Text("给浮动图层打位置关键帧，像 AE 一样让它沿时间轴动起来。生成后会直接加入壁纸库，去「壁纸」页勾选即可刷入。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 素材

    private var materialRow: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $backgroundItem, matching: .images, photoLibrary: .shared()) {
                pickerLabel(title: "背景图", image: backgroundImage, icon: "photo.fill")
            }
            .onChange(of: backgroundItem) { _, newItem in
                loadBackground(newItem)
            }

            PhotosPicker(selection: $floatingItem, matching: .images, photoLibrary: .shared()) {
                pickerLabel(title: "浮动图", image: floatingImage, icon: "square.3.layers.3d")
            }
            .onChange(of: floatingItem) { _, newItem in
                loadFloating(newItem)
            }
        }
    }

    private func pickerLabel(title: String, image: UIImage?, icon: String) -> some View {
        HStack(spacing: 10) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(Color(UIColor.tertiarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(image == nil ? "点按选择" : "点按更换")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadBackground(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            await MainActor.run {
                if let data, let image = UIImage(data: data) {
                    backgroundImage = image
                }
            }
        }
    }

    private func loadFloating(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            await MainActor.run {
                guard let data, let image = UIImage(data: data) else { return }
                floatingImage = image
                if let cg = image.cgImage {
                    floatingPixelSize = CGSize(width: cg.width, height: cg.height)
                } else {
                    floatingPixelSize = CGSize(width: image.size.width * image.scale,
                                               height: image.size.height * image.scale)
                }
                floatingExportData = Self.cappedPNGData(image)
            }
        }
    }

    /// 浮动图导出数据：最长边压到 1200px（保 alpha 的 PNG），与画布上的 pt 尺寸解耦。
    private static func cappedPNGData(_ image: UIImage) -> Data? {
        let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let maxSide = max(pixelWidth, pixelHeight)
        guard maxSide > 1200 else { return image.pngData() }
        let scale = 1200.0 / Double(maxSide)
        let newSize = CGSize(width: Double(pixelWidth) * scale, height: Double(pixelHeight) * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.pngData()
    }

    /// 浮动图层在画布上的尺寸（pt）：像素 /3，再钳进画布留边范围。
    private var floatingSizePt: CGSize {
        guard floatingPixelSize.width > 0, floatingPixelSize.height > 0 else {
            return CGSize(width: 200, height: 200)
        }
        var size = CGSize(width: floatingPixelSize.width / 3, height: floatingPixelSize.height / 3)
        let maxW: CGFloat = 350, maxH: CGFloat = 800
        if size.width > maxW || size.height > maxH {
            let s = min(maxW / size.width, maxH / size.height)
            size = CGSize(width: size.width * s, height: size.height * s)
        }
        return size
    }

    // MARK: - 画布

    private var canvasSection: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = w * KeyframeProject.canvasSize.height / KeyframeProject.canvasSize.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))

                if let bg = backgroundImage {
                    Image(uiImage: bg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: h)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                        Text("先选一张背景图")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: w, height: h)
                }

                if let fl = floatingImage {
                    let displaySize = CGSize(
                        width: floatingSizePt.width * w / KeyframeProject.canvasSize.width,
                        height: floatingSizePt.height * w / KeyframeProject.canvasSize.width)
                    Image(uiImage: fl)
                        .resizable()
                        .scaledToFit()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .position(screenPoint(for: livePosition, canvasWidth: w, canvasHeight: h))
                        .gesture(layerDragGesture(canvasWidth: w, canvasHeight: h))
                } else {
                    Text("选一张浮动图后，在这里拖动它摆位")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: w, height: h, alignment: .bottom)
                        .padding(.bottom, 12)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        }
        .aspectRatio(KeyframeProject.canvasSize.width / KeyframeProject.canvasSize.height,
                     contentMode: .fit)
    }

    /// 画布坐标（原点左上、y 向下）→ 画布的屏幕坐标（同向等比缩放）。
    private func screenPoint(for ca: CGPoint, canvasWidth w: CGFloat, canvasHeight h: CGFloat) -> CGPoint {
        CGPoint(x: ca.x / KeyframeProject.canvasSize.width * w,
                y: ca.y / KeyframeProject.canvasSize.height * h)
    }

    private func layerDragGesture(canvasWidth w: CGFloat, canvasHeight h: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragBase == nil { dragBase = livePosition }
                guard let base = dragBase else { return }
                let dx = value.translation.width / w * KeyframeProject.canvasSize.width
                let dy = value.translation.height / h * KeyframeProject.canvasSize.height
                livePosition = CGPoint(
                    x: min(max(base.x + dx, 0), KeyframeProject.canvasSize.width),
                    y: min(max(base.y + dy, 0), KeyframeProject.canvasSize.height))
            }
            .onEnded { _ in dragBase = nil }
    }

    // MARK: - 播放 / 打帧

    private var transportRow: some View {
        HStack(spacing: 12) {
            Button {
                isPlaying.toggle()
                lastTickDate = Date()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .disabled(project.keyframes.count < 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(TendiesExporter.fmt(playhead)) / \(TendiesExporter.fmt(project.duration)) 秒")
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Text("位置 x \(Int(livePosition.x.rounded())) · y \(Int(livePosition.y.rounded()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                recordKeyframe()
            } label: {
                Label("打关键帧", systemImage: "diamond.circle.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(floatingImage == nil)
        }
    }

    private func recordKeyframe() {
        let t = (playhead * 100).rounded() / 100
        let frame = project.recordKeyframe(time: t, position: livePosition)
        selectedKeyframeID = frame.id
    }

    private func selectKeyframe(_ frame: AnimKeyframe) {
        selectedKeyframeID = frame.id
        isPlaying = false
        playhead = frame.time
        livePosition = frame.position
    }

    private var selectedKeyframe: AnimKeyframe? {
        project.keyframes.first { $0.id == selectedKeyframeID }
    }

    private var easingBinding: Binding<KeyframeEasing> {
        Binding(
            get: { selectedKeyframe?.easing ?? .easeInEaseOut },
            set: { newValue in
                guard let id = selectedKeyframeID,
                      let idx = project.keyframes.firstIndex(where: { $0.id == id }) else { return }
                project.keyframes[idx].easing = newValue
            })
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { project.duration },
            set: { newValue in
                project.duration = newValue
                project.clampKeyframesToDuration()
                playhead = min(playhead, newValue)
                if let sel = selectedKeyframeID,
                   !project.keyframes.contains(where: { $0.id == sel }) {
                    selectedKeyframeID = nil
                }
                if let p = project.position(at: playhead) {
                    livePosition = p
                }
            })
    }

    // MARK: - 时间轴

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            timelineTrack

            HStack(spacing: 10) {
                Text("总时长")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Slider(value: durationBinding, in: 2...10, step: 0.5)
                Text("\(TendiesExporter.fmt(project.duration)) 秒")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }

            if project.keyframes.isEmpty {
                Text("还没有关键帧：把浮动图拖到想要的位置，点「打关键帧」记录；换个时刻再拖、再打，中间会自动补间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let selected = selectedKeyframe {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("已选关键帧 · \(TendiesExporter.fmt(selected.time)) 秒")
                            .font(.caption.bold())
                        Spacer()
                        Button(role: .destructive) {
                            project.removeKeyframe(id: selected.id)
                            selectedKeyframeID = nil
                        } label: {
                            Label("删除此帧", systemImage: "trash")
                                .font(.caption.bold())
                        }
                    }
                    HStack(spacing: 8) {
                        Text("本帧→下一帧")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("缓动", selection: easingBinding) {
                            ForEach(KeyframeEasing.allCases) { easing in
                                Text(easing.displayName).tag(easing)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            } else {
                Text("点时间轴上的菱形选中关键帧，可改它的缓动或删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var timelineTrack: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemBackground))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isPlaying = false
                                let t = min(max(Double(value.location.x / w) * project.duration, 0),
                                            project.duration)
                                playhead = t
                                if let p = project.position(at: t) {
                                    livePosition = p
                                }
                            })

                ForEach(project.keyframes) { frame in
                    let x = CGFloat(frame.time / project.duration) * w
                    Image(systemName: "diamond.fill")
                        .font(.system(size: frame.id == selectedKeyframeID ? 17 : 13))
                        .foregroundStyle(frame.id == selectedKeyframeID ? Color.orange : Color.blue)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .offset(x: x - 14)
                        .onTapGesture { selectKeyframe(frame) }
                }

                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: 46)
                    .offset(x: CGFloat(playhead / project.duration) * w - 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 46)
    }

    // MARK: - 导出

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("生成壁纸")
                .font(.headline)

            TextField("壁纸名称", text: $exportName)
                .textFieldStyle(.roundedBorder)

            Button {
                exportAndImport()
            } label: {
                HStack {
                    Spacer()
                    if isExporting {
                        ProgressView()
                            .padding(.trailing, 6)
                    }
                    Image(systemName: "shippingbox.fill")
                    Text("生成并加入壁纸库")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExporting || backgroundImage == nil || floatingImage == nil
                      || project.keyframes.isEmpty)

            if backgroundImage == nil || floatingImage == nil {
                Text("先选好背景图和浮动图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if project.keyframes.isEmpty {
                Text("先打至少一个关键帧（只有一个帧时生成静态浮动层）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func exportAndImport() {
        guard let bg = backgroundImage, let floatingData = floatingExportData else { return }
        guard !project.keyframes.isEmpty else { return }
        isExporting = true
        statusMessage = nil

        let trimmed = exportName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "关键帧壁纸" : trimmed
        let identifier = TendiesExporter.makeIdentifier()
        let fileBase = Self.sanitizedFileBase(name)
        let fileName = "\(fileBase)-\(identifier).tendies"
        let proj = project
        let sizePt = floatingSizePt
        let bgData = Self.renderBackgroundPNG(bg)

        Task {
            do {
                guard let bgData else {
                    await MainActor.run {
                        statusMessage = "背景图处理失败，换一张图再试。"
                        isExporting = false
                    }
                    return
                }
                let output = try await Task.detached(priority: .userInitiated) {
                    try TendiesExporter.build(
                        input: TendiesExporter.Input(
                            name: name, project: proj,
                            backgroundPNG: bgData, floatingPNG: floatingData,
                            floatingSizePt: sizePt),
                        identifier: identifier,
                        descriptorUUID: UUID().uuidString)
                }.value

                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(fileName)
                try output.data.write(to: tmpURL)
                await vm.importTendieFiles(urls: [tmpURL])
                try? FileManager.default.removeItem(at: tmpURL)

                await MainActor.run {
                    if vm.tendieItems.contains(where: { $0.fileName == fileName }) {
                        statusMessage = "已加入壁纸库 ✅ 去「壁纸」页勾选「\(name)」后就能刷入。"
                    } else {
                        statusMessage = "导入失败：\(vm.errorMessage ?? "未知错误")"
                    }
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "生成失败：\(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }

    /// 背景图导出处理：按 390×844@3x（1170×2532）等比填充、居中裁剪，与画布预览同构图。
    private static func renderBackgroundPNG(_ image: UIImage) -> Data? {
        let target = CGSize(width: 1170, height: 2532)
        let pixelSize = CGSize(
            width: image.cgImage?.width ?? Int(image.size.width * image.scale),
            height: image.cgImage?.height ?? Int(image.size.height * image.scale))
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in
            let scale = max(target.width / pixelSize.width, target.height / pixelSize.height)
            let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
            let origin = CGPoint(x: (target.width - size.width) / 2,
                                 y: (target.height - size.height) / 2)
            image.draw(in: CGRect(origin: origin, size: size))
        }
        return rendered.pngData()
    }

    /// 文件名只保留字母/数字/连字符/下划线（中文属字母集，保留）。
    private static func sanitizedFileBase(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned.isEmpty ? "Keyframe" : cleaned
    }
}

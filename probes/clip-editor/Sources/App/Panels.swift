import SwiftUI

// MARK: - 选中图层面板（模板 chips + 滑杆）
//
// 选中图层后出现在时间轴与工具坞之间：
//  · 动作槽 chips：无 / 漂浮 / 摇摆 / 慢放大平移（仅背景可选）
//  · 缩放旋转槽 chips：无 / 呼吸缩放 / 旋转摇摆
//  · 每激活一个槽，出它自己的幅度/速度滑杆
//  · 通用：当前部分的不透明度、尺寸（等比）、淡入/淡出帧数、
//    把摆位复制到另一部分、删除
struct SelectionPanelView: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        if let layer = vm.selectedLayer {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(layer.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(layer.group.displayName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(white: 0.55)))
                    Spacer()
                    Button {
                        vm.updateSelected { l in
                            let other: PartTab = vm.currentTab == .locked ? .unlock : .locked
                            l.setLayout(l.layout(for: vm.currentTab), for: other)
                        }
                    } label: {
                        Text("摆位复制到\(vm.currentTab == .locked ? "主屏" : "开屏")")
                            .font(.system(size: 11.5))
                    }
                    Button(role: .destructive) {
                        vm.deleteLayer(id: layer.id)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 12.5))
                    }
                    Button { vm.select(nil) } label: {
                        Image(systemName: "xmark").font(.system(size: 12.5)).foregroundStyle(.gray)
                    }
                }

                if layer.isSweep {
                    Text("扫光自带「斜扫」动画（每圈扫过一次），只调摆位与透明度。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.gray)
                } else {
                    slotRow(title: "动作", kinds: actionKinds(for: layer),
                            current: layer.actionMotion) { kind in
                        vm.updateSelected { l in
                            l.actionMotion = kind.map { MotionSetting(kind: $0, amplitude: 0.5, speed: 1) }
                        }
                    }
                    if let motion = layer.actionMotion {
                        sliders(for: motion, isActionSlot: true)
                    }
                    slotRow(title: "缩放旋转", kinds: MotionKind.transformSlotKinds,
                            current: layer.transformMotion) { kind in
                        vm.updateSelected { l in
                            l.transformMotion = kind.map { MotionSetting(kind: $0, amplitude: 0.5, speed: 1) }
                        }
                    }
                    if let motion = layer.transformMotion {
                        sliders(for: motion, isActionSlot: false)
                    }
                }

                HStack(spacing: 14) {
                    sliderBlock(title: "透明度", value: opacityBinding(layer: layer), range: 0...1)
                    sliderBlock(title: "大小", value: sizeBinding(layer: layer), range: 20...800)
                }
                HStack(spacing: 18) {
                    Stepper("淡入 \(layer.fadeInFrames) 帧", value: fadeBinding(layer: layer, isIn: true), in: 0...120, step: 6)
                        .font(.system(size: 12))
                    Stepper("淡出 \(layer.fadeOutFrames) 帧", value: fadeBinding(layer: layer, isIn: false), in: 0...120, step: 6)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.965)))
            .padding(.horizontal, 10)
        }
    }

    // MARK: chips 与滑杆

    private func actionKinds(for layer: EditorLayer) -> [MotionKind] {
        MotionKind.actionSlotKinds.filter { $0 != .kenburns || layer.group == .background }
    }

    private func slotRow(title: String, kinds: [MotionKind], current: MotionSetting?,
                         onPick: @escaping (MotionKind?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.gray)
                .frame(width: 52, alignment: .leading)
            chip(label: "无", active: current == nil) { onPick(nil) }
            ForEach(kinds) { kind in
                chip(label: kind.displayName, active: current?.kind == kind) { onPick(kind) }
            }
            Spacer()
        }
    }

    private func chip(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(active ? Color(red: 0, green: 0.44, blue: 0.89) : Color(white: 0.9)))
                .foregroundStyle(active ? .white : Color(white: 0.3))
        }
    }

    private func sliders(for motion: MotionSetting, isActionSlot: Bool) -> some View {
        HStack(spacing: 14) {
            sliderBlock(title: "幅度", value: motionBinding(isActionSlot: isActionSlot, keyPath: \.amplitude), range: 0...1)
            sliderBlock(title: "速度", value: motionBinding(isActionSlot: isActionSlot, keyPath: \.speed), range: 0.5...2)
        }
        .padding(.leading, 58)
    }

    private func sliderBlock(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.gray)
            Slider(value: value, in: range)
        }
    }

    // MARK: Bindings（全部经 vm.updateSelected 写回）

    private func motionBinding(isActionSlot: Bool, keyPath: WritableKeyPath<MotionSetting, Double>) -> Binding<Double> {
        Binding(
            get: {
                let layer = vm.selectedLayer
                let motion = isActionSlot ? layer?.actionMotion : layer?.transformMotion
                return motion?[keyPath: keyPath] ?? 0
            },
            set: { newValue in
                vm.updateSelected { l in
                    if isActionSlot { l.actionMotion?[keyPath: keyPath] = newValue }
                    else { l.transformMotion?[keyPath: keyPath] = newValue }
                }
            })
    }

    private func opacityBinding(layer: EditorLayer) -> Binding<Double> {
        Binding(
            get: { vm.selectedLayer?.layout(for: vm.currentTab).opacity ?? 1 },
            set: { newValue in
                vm.updateSelected { l in
                    var layout = l.layout(for: vm.currentTab)
                    layout.opacity = newValue
                    l.setLayout(layout, for: vm.currentTab)
                }
            })
    }

    /// 大小滑杆：绑定图层当前部分摆位的宽度，高度按原比例跟随。
    private func sizeBinding(layer: EditorLayer) -> Binding<Double> {
        Binding(
            get: { Double(vm.selectedLayer?.layout(for: vm.currentTab).size.width ?? 100) },
            set: { newWidth in
                vm.updateSelected { l in
                    var layout = l.layout(for: vm.currentTab)
                    let ratio = newWidth / max(Double(layout.size.width), 1)
                    layout.size = CGSize(width: CGFloat(newWidth),
                                         height: CGFloat(min(max(Double(layout.size.height) * ratio, 12), 1600)))
                    l.setLayout(layout, for: vm.currentTab)
                }
            })
    }

    private func fadeBinding(layer: EditorLayer, isIn: Bool) -> Binding<Int> {
        Binding(
            get: { isIn ? (vm.selectedLayer?.fadeInFrames ?? 0) : (vm.selectedLayer?.fadeOutFrames ?? 0) },
            set: { newValue in
                vm.updateSelected { l in
                    if isIn { l.fadeInFrames = newValue } else { l.fadeOutFrames = newValue }
                }
            })
    }
}

// MARK: - 图层列表页（选中/删除/改名/调序，不限数量）

struct LayerListView: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: EditorLayer?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("背景（底图 1 张）") {
                    if let bg = vm.project.background {
                        layerRow(bg)
                    } else {
                        Text("未选背景图").foregroundStyle(.gray)
                    }
                }
                Section("浮动（可多层）") {
                    ForEach(vm.project.floating) { layer in layerRow(layer) }
                        .onMove { vm.moveFloating(from: $0, to: $1) }
                        .onDelete { offsets in
                            let ids = offsets.map { vm.project.floating[$0].id }
                            ids.forEach { vm.deleteLayer(id: $0) }
                        }
                }
                Section("前景（文字 / 特效）") {
                    ForEach(vm.project.foreground) { layer in layerRow(layer) }
                        .onMove { vm.moveForeground(from: $0, to: $1) }
                        .onDelete { offsets in
                            let ids = offsets.map { vm.project.foreground[$0].id }
                            ids.forEach { vm.deleteLayer(id: $0) }
                        }
                }
            }
            .navigationTitle("图层")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("重命名", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } })) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let layer = renaming { vm.renameLayer(id: layer.id, to: renameText) }
                    renaming = nil
                }
            }
        }
    }

    private func layerRow(_ layer: EditorLayer) -> some View {
        HStack {
            Button {
                vm.select(layer.id)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: vm.selectedLayerID == layer.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(vm.selectedLayerID == layer.id ? Color(red: 0, green: 0.44, blue: 0.89) : .gray)
                    Text(layer.name).foregroundStyle(.primary)
                }
            }
            Spacer()
            Button("改名") {
                renaming = layer
                renameText = layer.name
            }
            .font(.system(size: 13))
            Button(role: .destructive) {
                vm.deleteLayer(id: layer.id)
            } label: {
                Image(systemName: "trash")
            }
        }
    }
}

// MARK: - 状态设置页（底部工具坞「状态」）

struct StateSettingsView: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("壁纸") {
                    TextField("名称", text: $vm.project.name)
                }
                Section("循环（一圈）") {
                    Picker("循环帧数", selection: $vm.project.loopFrames) {
                        Text("180 帧 · 3s").tag(180)
                        Text("240 帧 · 4s").tag(240)
                        Text("360 帧 · 6s").tag(360)
                    }
                    .pickerStyle(.segmented)
                }
                Section("过渡（部分之间）") {
                    HStack {
                        Text("过渡帧数")
                        Spacer()
                        Text("\(vm.project.transitionFrames) 帧 · \(String(format: "%.2f", vm.project.transitionSeconds))s")
                            .foregroundStyle(.gray)
                    }
                    Slider(value: Binding(
                        get: { Double(vm.project.transitionFrames) },
                        set: { vm.project.transitionFrames = Int($0.rounded()) }),
                        in: 24...60, step: 1)
                    Picker("弹簧手感", selection: $vm.project.spring) {
                        ForEach(SpringSpec.all) { spec in
                            Text(spec.name).tag(spec)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("熄屏部分不用做：导出时自动生成（照抄开屏摆位，整体透明度 ×0.5 压暗）。淡入/淡出（clip 两头）目前只在编辑器预览里生效，暂不写进导出包。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.gray)
                }
            }
            .navigationTitle("状态设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 加文字面板

struct AddTextView: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var string = ""
    @State private var fontSize: Double = 54
    @State private var colorHex = "#FFFFFF"

    var body: some View {
        NavigationStack {
            Form {
                TextField("输入文字", text: $string)
                Section("字号 \(Int(fontSize))") {
                    Slider(value: $fontSize, in: 24...96, step: 1)
                }
                Section("颜色") {
                    HStack(spacing: 12) {
                        ForEach(EditorViewModel.textColors) { entry in
                            Circle()
                                .fill(Color(hex: entry.hex))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color(white: 0.8), lineWidth: 1))
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(entry.hex == "#FFFFFF" || entry.hex == "#FFD60A" ? .black : .white)
                                        .opacity(colorHex == entry.hex ? 1 : 0))
                                .onTapGesture { colorHex = entry.hex }
                        }
                    }
                }
                Button("添加文字图层") {
                    vm.addTextLayer(string: string, fontSize: fontSize, colorHex: colorHex)
                    dismiss()
                }
                .disabled(string.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("加文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

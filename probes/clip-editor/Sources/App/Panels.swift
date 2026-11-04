import SwiftUI

// MARK: - 选中图层面板（模板 chips + 滑杆 / 动画段关键帧区）
//
// 选中图层后出现在时间轴与工具坞之间，按当前时间线段分工：
//  · 循环段：动作槽 chips（无 / 漂浮 / 摇摆 / 慢放大平移，仅背景
//    可选慢放大平移）、缩放旋转槽 chips（无 / 呼吸缩放 / 旋转
//    摇摆），每槽幅度/速度滑杆；通用不透明度、尺寸、淡入/淡出
//    帧数、摆位复制、删除。
//  · 动画段（开屏动画 / 解锁动画）：关键帧区——缩放/旋转/透明度
//    滑杆 + 前移/后移（层级）先改操作姿态，点「打关键帧」记下
//    当前时刻的整套属性；已选中菱形或播放头压着帧时可删除。
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
                    // 两张背景都设时背景图层只有自己那套摆位，复制无意义，隐藏；
                    // 动画段里摆位由关键帧管，同样隐藏。
                    if !vm.segment.isAnimation
                        && !(layer.group == .background && vm.project.hasBothBackgrounds) {
                        Button {
                            vm.updateSelected { l in
                                let other: PartTab = vm.currentTab == .locked ? .unlock : .locked
                                l.setLayout(l.layout(for: vm.currentTab), for: other)
                            }
                        } label: {
                            Text("摆位复制到\(vm.currentTab == .locked ? "主屏" : "开屏")")
                                .font(.system(size: 11.5))
                        }
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

                if vm.segment.isAnimation {
                    keyframeSection(layer: layer)
                } else if layer.isSweep {
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

                if !vm.segment.isAnimation {
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
            get: {
                guard let current = vm.selectedLayer else { return 1 }
                return current.layout(for: vm.editingTab(for: current)).opacity
            },
            set: { newValue in
                vm.updateSelected { l in
                    let tab = vm.editingTab(for: l)
                    var layout = l.layout(for: tab)
                    layout.opacity = newValue
                    l.setLayout(layout, for: tab)
                }
            })
    }

    /// 大小滑杆：绑定图层应编部分摆位的宽度，高度按原比例跟随。
    private func sizeBinding(layer: EditorLayer) -> Binding<Double> {
        Binding(
            get: {
                guard let current = vm.selectedLayer else { return 100 }
                return Double(current.layout(for: vm.editingTab(for: current)).size.width)
            },
            set: { newWidth in
                vm.updateSelected { l in
                    let tab = vm.editingTab(for: l)
                    var layout = l.layout(for: tab)
                    let ratio = newWidth / max(Double(layout.size.width), 1)
                    layout.size = CGSize(width: CGFloat(newWidth),
                                         height: CGFloat(min(max(Double(layout.size.height) * ratio, 12), 1600)))
                    l.setLayout(layout, for: tab)
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

    // MARK: 关键帧区（动画段专用）

    @ViewBuilder
    private func keyframeSection(layer: EditorLayer) -> some View {
        let pose = vm.workingPose(for: layer)
        let hasDeletable = (vm.selectedKeyframe?.layerID == layer.id
            && vm.selectedKeyframe?.segment == vm.segment)
            || vm.keyframeNearPlayhead(of: layer) != nil
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.85, green: 0.5, blue: 0.1))
                Text("\(vm.segment.displayName) · 关键帧")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("进度 \(Int((vm.segmentProgress * 100).rounded()))%")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.gray)
            }
            Text("在画布上拖位置、用滑杆调好，点「打关键帧」记下这一刻。关键帧只定轨迹，导出时长按过渡速度重算。")
                .font(.system(size: 11.5))
                .foregroundStyle(.gray)
            HStack(spacing: 14) {
                sliderBlock(title: "缩放", value: poseScaleBinding(), range: 0.2...3)
                sliderBlock(title: "旋转", value: poseRotationBinding(), range: -180...180)
            }
            HStack(spacing: 14) {
                sliderBlock(title: "透明度", value: poseOpacityBinding(), range: 0...1)
                HStack(spacing: 6) {
                    Text("层级").font(.system(size: 11.5)).foregroundStyle(.gray)
                    Button("后移") {
                        if let current = vm.selectedLayer {
                            vm.updateWorkingPose(for: current) { $0.zIndex -= 1 }
                        }
                    }
                    .font(.system(size: 12))
                    Text("\(pose.zIndex)")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minWidth: 18)
                    Button("前移") {
                        if let current = vm.selectedLayer {
                            vm.updateWorkingPose(for: current) { $0.zIndex += 1 }
                        }
                    }
                    .font(.system(size: 12))
                }
            }
            HStack(spacing: 10) {
                Button {
                    vm.stampKeyframe()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "diamond.fill").font(.system(size: 10))
                        Text("打关键帧").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0, green: 0.44, blue: 0.89)))
                }
                if hasDeletable {
                    Button(role: .destructive) {
                        if vm.selectedKeyframe?.layerID == layer.id
                            && vm.selectedKeyframe?.segment == vm.segment {
                            vm.deleteSelectedKeyframe()
                        } else {
                            vm.deleteKeyframeNearPlayhead()
                        }
                    } label: {
                        Text("删除关键帧").font(.system(size: 12.5))
                    }
                }
                Spacer()
                Text("本段 \(keyframeCount(of: layer)) 帧")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.gray)
            }
        }
    }

    private func keyframeCount(of layer: EditorLayer) -> Int {
        vm.segment == .entrance ? layer.entranceKeyframes.count : layer.unlockKeyframes.count
    }

    /// 缩放倍率的基准尺寸：该图层开屏侧摆位（开屏动画段末帧与开屏
    /// 摆位同步，倍率以它为 1.0 的参照，探针口径）。
    private func poseBaseSize(for layer: EditorLayer) -> CGSize {
        vm.displayLayout(of: layer, for: .locked).size
    }

    private func poseScaleBinding() -> Binding<Double> {
        Binding(
            get: {
                guard let current = vm.selectedLayer else { return 1 }
                let base = poseBaseSize(for: current)
                return Double(vm.workingPose(for: current).size.width) / max(Double(base.width), 1)
            },
            set: { mult in
                guard let current = vm.selectedLayer else { return }
                let base = poseBaseSize(for: current)
                vm.updateWorkingPose(for: current) { p in
                    p.size = CGSize(width: base.width * CGFloat(mult),
                                    height: base.height * CGFloat(mult))
                }
            })
    }

    /// 旋转滑杆：度，+ = 屏幕顺时针（内部存 CAML 语义弧度，取负换算）。
    private func poseRotationBinding() -> Binding<Double> {
        Binding(
            get: {
                guard let current = vm.selectedLayer else { return 0 }
                return -vm.workingPose(for: current).rotation * 180 / .pi
            },
            set: { degrees in
                guard let current = vm.selectedLayer else { return }
                vm.updateWorkingPose(for: current) { p in
                    p.rotation = -degrees * .pi / 180
                }
            })
    }

    private func poseOpacityBinding() -> Binding<Double> {
        Binding(
            get: {
                guard let current = vm.selectedLayer else { return 1 }
                return vm.workingPose(for: current).opacity
            },
            set: { newValue in
                guard let current = vm.selectedLayer else { return }
                vm.updateWorkingPose(for: current) { p in p.opacity = newValue }
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
                Section("背景（开屏 / 主屏各一张，只设一张时另一侧共用）") {
                    backgroundSlotRow(part: .locked)
                    backgroundSlotRow(part: .unlock)
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

    @ViewBuilder
    private func backgroundSlotRow(part: PartTab) -> some View {
        let own = part == .locked ? vm.project.backgroundLocked : vm.project.backgroundUnlock
        let other = part == .locked ? vm.project.backgroundUnlock : vm.project.backgroundLocked
        if let own {
            layerRow(own)
        } else if other != nil {
            Text("\(part.displayName)背景：与\(part == .locked ? "主屏" : "开屏")共用同一张")
                .foregroundStyle(.gray)
        } else {
            Text("\(part.displayName)背景：未设置")
                .foregroundStyle(.gray)
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

// MARK: - 开屏入场设置段（状态页与独立编辑面共用同一份数据）

struct EntranceFields: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        HStack {
            Text("动画段编辑长度")
            Spacer()
            Text("\(String(format: "%.1f", vm.project.entranceRulerSeconds)) 秒")
                .foregroundStyle(.gray)
        }
        Slider(value: $vm.project.entranceRulerSeconds, in: 1...8, step: 0.5)
        Text("时间线上「开屏动画」段的长度，只是排关键帧用的尺子；导出时动画时长按下边的入场帧数重算，不按这个长度。")
            .font(.system(size: 12.5))
            .foregroundStyle(.gray)
        Picker("入场类型", selection: $vm.project.entrance.kind) {
            ForEach(EntranceKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        if vm.project.entrance.kind != .none {
            HStack {
                Text("入场帧数")
                Spacer()
                Text("\(vm.project.entrance.frames) 帧 · \(String(format: "%.2f", vm.project.entrance.seconds))s")
                    .foregroundStyle(.gray)
            }
            Slider(value: Binding(
                get: { Double(vm.project.entrance.frames) },
                set: { vm.project.entrance.frames = Int($0.rounded()) }),
                in: 24...60, step: 1)
            Picker("弹簧手感", selection: $vm.project.entrance.spring) {
                ForEach(SpringSpec.all) { spec in
                    Text(spec.name).tag(spec)
                }
            }
            .pickerStyle(.segmented)
            Text("亮屏时画面从熄屏的压暗样子淡入到开屏画面，就是这段动画。用上方「预览开屏」可以先看效果。")
                .font(.system(size: 12.5))
                .foregroundStyle(.gray)
        } else {
            Text("亮屏时不做入场动画，画面直接切到开屏。")
                .font(.system(size: 12.5))
                .foregroundStyle(.gray)
        }
    }
}

// MARK: - 解锁过渡设置段（状态页与独立编辑面共用同一份数据）

struct UnlockTransitionFields: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        HStack {
            Text("动画段编辑长度")
            Spacer()
            Text("\(String(format: "%.1f", vm.project.unlockRulerSeconds)) 秒")
                .foregroundStyle(.gray)
        }
        Slider(value: $vm.project.unlockRulerSeconds, in: 1...8, step: 0.5)
        Text("时间线上「解锁动画」段的长度，只是排关键帧用的尺子；导出时过渡时长按下边的过渡帧数走。注意：解锁动画段里打的中间关键帧目前只在编辑器预览生效，导出只保证起点（开屏摆位）与终点（主屏摆位）+ 过渡。")
            .font(.system(size: 12.5))
            .foregroundStyle(.gray)
        Picker("过渡类型", selection: $vm.project.transitionKind) {
            ForEach(TransitionKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)
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
        Text(unlockNote)
            .font(.system(size: 12.5))
            .foregroundStyle(.gray)
    }

    private var unlockNote: String {
        switch vm.project.transitionKind {
        case .fade:
            return "渐变：开锁时两张画面交叉淡变（开屏背景淡出、主屏背景淡入），图层位置直接切换。样本包就是这种，已验证的写法。"
        case .layoutSpring:
            return "摆位弹簧：开锁时图层用弹簧从开屏摆位滑到主屏摆位，画面不淡变。注意：这是实验写法，还没在真机上验证过。"
        case .fadeAndLayout:
            return "渐变+摆位：淡变和摆位滑动一起来。注意：其中的摆位弹簧是实验写法，还没在真机上验证过。"
        }
    }
}

// MARK: - 开屏入场编辑面（时间轴上方 chip 打开）

struct EntranceEditorView: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("开屏入场（亮屏时的动画）") {
                    EntranceFields(vm: vm)
                }
            }
            .navigationTitle("开屏入场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 解锁过渡编辑面（时间轴上方 chip / 背景轨过渡段打开）

struct TransitionEditorView: View {
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("解锁过渡（开屏 → 主屏）") {
                    UnlockTransitionFields(vm: vm)
                }
            }
            .navigationTitle("解锁过渡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 状态设置页（底部工具坞「状态」，与 chip 编辑面共用同一份数据）

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
                Section("开屏入场（亮屏时的动画）") {
                    EntranceFields(vm: vm)
                }
                Section("解锁过渡（开屏 → 主屏）") {
                    UnlockTransitionFields(vm: vm)
                }
                Section {
                    Text("熄屏部分不用做：导出时自动生成（照抄开屏摆位，整体透明度 ×0.5 压暗）。开屏动画段的关键帧轨迹会写进导出包（时长按开屏入场帧数重算）；解锁动画的中间关键帧暂只在预览生效；淡入/淡出（clip 两头）也只在预览生效。")
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

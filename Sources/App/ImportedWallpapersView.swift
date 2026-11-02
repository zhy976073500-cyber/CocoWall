//
//  ImportedWallpapersView.swift
//  CocoWall
//
//  全屏「已导入的壁纸」选择页（run #128 新增）：从壁纸页右上角
//  展开按钮 push 进入。与壁纸页扇形区共用同一份选择状态
//  （vm.tendieItems[i].isSelected），两边点按实时一致；底部
//  「完成」pop 回壁纸页。
//

import SwiftUI

struct ImportedWallpapersView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDetailItem: TendieItem? = nil
    /// 格子长按菜单的目标项（run #130，与壁纸页扇形同标处理：
    /// 手势设目标 + 页面根 confirmationDialog，不用 contextMenu）。
    @State private var menuTarget: TendieItem? = nil
    /// 底部栏「删除」批量删除的确认（run #130）。
    @State private var showDeleteConfirm = false

    private var selectedCount: Int {
        vm.tendieItems.filter { $0.isSelected }.count
    }

    private var allSelected: Bool {
        !vm.tendieItems.isEmpty && vm.tendieItems.allSatisfy { $0.isSelected }
    }

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("共 \(vm.tendieItems.count) 张 · 已选 \(selectedCount) 张，点按勾选要刷入的壁纸")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(vm.tendieItems) { item in
                        cell(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
        }
        // 长按菜单呈现期间冻结滚动（run #130，与扇形同标）。
        .scrollDisabled(menuTarget != nil)
        .background(Color(UIColor.systemBackground))
        .navigationTitle("已导入的壁纸")
        .navigationBarTitleDisplayMode(.inline)
        // run #148：本页是 push 页，底部「已选/删除/完成」
        // 条要锚到真正的底部安全区——原实现没藏 tab 栏，
        // 系统 tab 栏仍占着底部，页内底条只能叠在它上方
        // （Sage 截图：底条贴着导航栏、位置尴尬）。push
        // 期间隐藏 tab 栏，pop 回壁纸页后自动恢复（该修
        // 饰只作用于本页在导航栈中的呈现）。
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                sortMenu
                Button(allSelected ? "取消全选" : "全选") {
                    let target = !allSelected
                    for i in vm.tendieItems.indices {
                        vm.tendieItems[i].isSelected = target
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            GlassGroup {
                HStack {
                    Text("已选 \(selectedCount) 张")
                        .font(.subheadline)
                    Spacer()
                    deleteButton
                    doneButton
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .glassSurface(Rectangle())
            }
        }
        .sheet(item: $selectedDetailItem) { item in
            TendieDetailSheet(item: item)
        }
        // 格子长按菜单（run #130）：与壁纸页扇形同一实现——
        // contextMenu 在滚动网格里同样有脱锚风险，改手势设
        // 目标 + 此处 confirmationDialog 呈现「详情/删除」。
        .confirmationDialog(
            menuTarget?.name ?? "",
            isPresented: Binding(
                get: { menuTarget != nil },
                set: { if !$0 { menuTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: menuTarget
        ) { item in
            Button("详情") {
                selectedDetailItem = item
            }
            Button("删除", role: .destructive) {
                vm.deleteTendie(item: item)
            }
            Button("取消", role: .cancel) {}
        }
        // 底部栏「删除」批量确认（run #130）。
        .confirmationDialog(
            "删除所选壁纸",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedCount) 张", role: .destructive) {
                deleteSelected()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把所选 \(selectedCount) 张壁纸从本机库中移除，本地文件一并删除。")
        }
    }

    /// 排序菜单（run #148 第五件）：三键单选（Picker 在
    /// Menu 内自带当前项打勾）+ 倒序开关；选择经
    /// AppViewModel 的 didSet 持久化并立即重排
    /// tendieItems（展开页与轮播共用同一顺序）。入口只
    /// 占一个图标钮，与「全选」并列、不挤标题。
    private var sortMenu: some View {
        Menu {
            Picker("排序方式", selection: Binding(
                get: { vm.tendieSortOrder },
                set: { vm.tendieSortOrder = $0 }
            )) {
                ForEach(TendieSortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            Divider()
            Toggle("倒序排列", isOn: Binding(
                get: { vm.tendieSortReversed },
                set: { vm.tendieSortReversed = $0 }
            ))
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    /// 底部栏「删除」（run #130）：红色玻璃次级按钮，与 #129
    /// 共用 glassButton 路数；已选 0 张时禁用。
    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Text("删除")
                .font(.headline)
                .padding(.horizontal, 6)
        }
        .glassButton(tint: .red)
        .disabled(selectedCount == 0)
        .opacity(selectedCount == 0 ? 0.45 : 1)
    }

    /// 批量删除当前勾选（run #130）：逐项走与长按单删相同的
    /// vm.deleteTendie（删条目 + 本地文件 + 存盘），删后选择集
    /// 随条目消失自动剔除，计数与壁纸页扇形同步刷新。
    private func deleteSelected() {
        let targets = vm.tendieItems.filter { $0.isSelected }
        for item in targets {
            vm.deleteTendie(item: item)
        }
    }

    /// 「完成」按钮双路（run #128 液态玻璃，与壁纸页刷入主按钮
    /// 同口径）：iOS 26 用系统 glassProminent（蓝），旧系统
    /// 回退自绘蓝胶囊；行为均为 pop 回壁纸页。
    @ViewBuilder
    private var doneButton: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Button {
                dismiss()
            } label: {
                Text("完成")
                    .font(.headline)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .controlSize(.large)
        } else {
            legacyDoneButton
        }
        #else
        legacyDoneButton
        #endif
    }

    private var legacyDoneButton: some View {
        Button {
            dismiss()
        } label: {
            Text("完成")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .frame(height: 46)
                .background(Color.blue, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func cell(_ item: TendieItem) -> some View {
        // run #148：格子视觉拆为独立的 Equatable 子视图
        // PickerCellContent 并挂 .equatable()——vm.tendieItems
        // 是整体发布的数组，任一格点选都会让数组重新发布，
        // 原实现下全网格每格 body 跟着重算（含缩略图缓存查
        // 询与整串 overlay 构建）；隔离后只有 item 真正变
        // 化的格子（TendieItem.== 比 id/名称/选中态/描述符
        // 数/预览数据长度，正是格子的全部视觉输入）才重绘，
        // 其余格子跳过。手势与 .task 留在外层，不受隔离影响。
        PickerCellContent(item: item)
            .equatable()
        // 点按勾选（run #130：手势实现取代原 Button+contextMenu）。
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let idx = vm.tendieItems.firstIndex(where: { $0.id == item.id }) {
                vm.tendieItems[idx].isSelected.toggle()
            }
        }
        // 长按出菜单（run #130）：只设目标项，菜单由页面根部的
        // confirmationDialog 呈现，滚动同时冻结。
        .onLongPressGesture(minimumDuration: 0.45) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            menuTarget = item
        }
        .task {
            vm.regenerateTendiePreview(itemID: item.id)
        }
    }
}

/// 展开页格子的纯视觉（run #148 自 ImportedWallpapersView.cell
/// 拆出）：输入只有 item，Equatable 隔离点选引发的全网格重算。
/// 定尺寸口径沿 run #133 定稿一字未动：无内容尺寸的盒子打底
/// 定尺寸、内容全部走 overlay——底 = Color.clear +
/// aspectRatio(3/4, .fit)（竖 3:4 为 Sage 2026-11-02 所定
/// 「暂时」规格），格子尺寸只由它决定；缩略图、渐变、名字、
/// 勾选徽章全用 overlay 叠上，视觉与 #132/#133 一致（圆角
/// 18、选中蓝描边）。
private struct PickerCellContent: View, Equatable {
    let item: TendieItem

    static func == (lhs: PickerCellContent, rhs: PickerCellContent) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                TendieThumbnailView(item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.38)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(item.name)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.leading, 9)
                    .padding(.bottom, 8)
                    .padding(.trailing, 32)
            }
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if item.isSelected {
                        ZStack {
                            Circle().fill(Color.blue)
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    } else {
                        Circle()
                            .fill(Color.black.opacity(0.08))
                            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 2))
                    }
                }
                .frame(width: 21, height: 21)
                .padding(7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if item.isSelected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.blue, lineWidth: 3)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

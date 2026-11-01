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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
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
        // 格子定尺寸（run #133，第三次修）：#130 固定高 172、
        // #132 在 ZStack 外挂 aspectRatio 两轮都没约束住格子，
        // Sage 截图实锤真机仍是瀑布流。根因：cell 为 ZStack，
        // 内含无硬框的 TendieThumbnailView（Image resizable +
        // aspectRatio(contentMode: .fill)、无自有尺寸）再套
        // frame(maxWidth/maxHeight: .infinity) 贪婪框——
        // LazyVGrid 测量时格子尺寸被图片原生比例反推（漫画
        // 长图撑高、横图压扁），外层 aspectRatio 在高度未设
        // 限的提案下让位于子视图的原生比例需求。同组件在
        // 扇形页的硬框 frame(150×200) 里一直正常，差别就在
        // 格子没有硬盒子。修法：无内容尺寸的盒子打底定尺
        // 寸、内容全部走 overlay（overlay 永不影响底视图尺
        // 寸）——底 = Color.clear + aspectRatio(3/4, .fit)
        // （竖 3:4 仍为 Sage 2026-11-02 所定「暂时」规格），
        // 格子尺寸只由它决定（三列列宽定宽、高 = 宽×4/3）；
        // 缩略图、渐变、名字、勾选徽章全用 overlay 叠上，
        // 视觉与 #132 一致（圆角 18、选中蓝描边、手势不变）。
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

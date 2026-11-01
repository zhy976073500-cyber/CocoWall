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
        Button {
            if let idx = vm.tendieItems.firstIndex(where: { $0.id == item.id }) {
                vm.tendieItems[idx].isSelected.toggle()
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                TendieThumbnailView(item: item)
                LinearGradient(colors: [.clear, .black.opacity(0.38)],
                               startPoint: .center, endPoint: .bottom)
                Text(item.name)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.leading, 9)
                    .padding(.bottom, 8)
                    .padding(.trailing, 32)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .aspectRatio(0.72, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if item.isSelected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.blue, lineWidth: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                selectedDetailItem = item
            } label: {
                Label("详情", systemImage: "info.circle")
            }
            Button(role: .destructive) {
                vm.deleteTendie(item: item)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .task {
            vm.regenerateTendiePreview(itemID: item.id)
        }
    }
}

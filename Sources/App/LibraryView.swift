import SwiftUI

/// 壁纸库页：照网页版版式——「主播推荐」横排 + 编号网格。
/// 数据全部来自 LibraryCatalog（占位），真实素材到位后只换数据。
struct LibraryView: View {
    @State private var selectedItem: LibraryItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    recommendedSection
                    gridSection
                }
                .padding(.vertical, 16)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("壁纸库")
            .sheet(item: $selectedItem) { item in
                LibraryDetailView(item: item)
            }
        }
    }

    // MARK: - 主播推荐

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("主播推荐")
                    .font(.title3.weight(.bold))
                Spacer()
                NavigationLink {
                    LibraryRecommendedView()
                } label: {
                    HStack(spacing: 2) {
                        Text("更多")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(LibraryCatalog.recommended) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                LibraryCover(item: item, asset: item.coverAsset)
                                    .frame(width: 150, height: 200)
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(item.numberText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - 全部壁纸网格

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("全部壁纸")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 20)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14),
                          GridItem(.flexible(), spacing: 14)],
                spacing: 18
            ) {
                ForEach(LibraryCatalog.items) { item in
                    Button {
                        selectedItem = item
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            LibraryCover(item: item, asset: item.coverAsset)
                                .aspectRatio(3.0 / 4.0, contentMode: .fill)
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(item.numberText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// 主播推荐全屏页：从壁纸库「主播推荐」标题行的「更多 ›」进入。
/// 版式与壁纸库网格一致（两列、封面统一 3:4 fill），数据是推荐集合的全部壁纸；
/// 点单张与主页点卡行为一致，打开 LibraryDetailView。返回走系统导航返回。
struct LibraryRecommendedView: View {
    @State private var selectedItem: LibraryItem?

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14),
                          GridItem(.flexible(), spacing: 14)],
                spacing: 18
            ) {
                ForEach(LibraryCatalog.recommended) { item in
                    Button {
                        selectedItem = item
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            LibraryCover(item: item, asset: item.coverAsset)
                                .aspectRatio(3.0 / 4.0, contentMode: .fill)
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(item.numberText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("主播推荐")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedItem) { item in
            LibraryDetailView(item: item)
        }
    }
}

/// 一张壁纸库封面：有图用图，没图用该条目的渐变占位。
/// 左上角带「3s 交互」小徽标（和网页版一致）。圆角软阴影、无描边。
struct LibraryCover: View {
    let item: LibraryItem
    /// 用哪张图（封面或详情大图）；为 nil 时走渐变。
    let asset: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            coverContent
            Text("3s 交互")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.35), in: Capsule())
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
    }

    @ViewBuilder
    private var coverContent: some View {
        if let asset {
            Image(asset)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LinearGradient(
                colors: [item.gradientTop, item.gradientBottom],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 壁纸库详情：居中手机框式大预览 + 三个变体切换（色调真变）
/// + 移动云盘 / 打赏入口（都还是占位，点了给提示）。
struct LibraryDetailView: View {
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var variant: LibraryVariant = .original
    @State private var showCloudNote = false
    @State private var showTipNote = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    preview
                        .frame(width: 230, height: 400)
                        .padding(.top, 8)

                    VStack(spacing: 4) {
                        Text(item.name)
                            .font(.title3.weight(.bold))
                        Text(item.numberText + " · 交互壁纸")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("变体", selection: $variant) {
                        ForEach(LibraryVariant.allCases) { v in
                            Text(v.rawValue).tag(v)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 44)

                    VStack(spacing: 12) {
                        Button {
                            showCloudNote = true
                        } label: {
                            Text("移动云盘下载")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            showTipNote = true
                        } label: {
                            Text("打赏支持")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle(item.numberText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("移动云盘", isPresented: $showCloudNote) {
                Button("好") { showCloudNote = false }
            } message: {
                Text(LibraryCatalog.cloudDriveNote)
            }
            .alert("打赏", isPresented: $showTipNote) {
                Button("好") { showTipNote = false }
            } message: {
                Text(LibraryCatalog.tipNote)
            }
        }
    }

    /// 大预览：变体切换通过饱和度 + 色调覆层实现，肉眼可见地变。
    private var preview: some View {
        ZStack {
            LibraryCover(item: item, asset: item.previewAsset ?? item.coverAsset)
        }
        .saturation(variant.saturation)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(variant.overlayColor.opacity(variant.overlayOpacity)))
        .animation(.easeInOut(duration: 0.25), value: variant)
    }
}

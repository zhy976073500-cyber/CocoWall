//
//  TendiesModel.swift
//  AirCard-iOS
//
//  Models and data structures for PosterBoard .tendies wallpapers.
//

import SwiftUI

public enum TendiePosterType: String, Codable, CaseIterable {
    case collections = "Collections"
    case suggestedPhotos = "Suggested Photos"
    case mercury = "Mercury"
    case container = "App Container"

    public var systemIcon: String {
        switch self {
        case .collections: return "paintpalette.fill"
        case .suggestedPhotos: return "photo.fill"
        case .mercury: return "sparkles"
        case .container: return "shippingbox.fill"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .collections: return .purple
        case .suggestedPhotos: return .blue
        case .mercury: return .orange
        case .container: return .indigo
        }
    }

    public var extensionBundleId: String {
        switch self {
        case .collections:
            return "com.apple.WallpaperKit.CollectionsPoster"
        case .suggestedPhotos:
            return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        case .mercury:
            return "com.apple.MercuryPoster"
        case .container:
            return "com.apple.PosterBoard"
        }
    }
}

public struct TendieItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var fileName: String
    public var relativePath: String
    public var isContainer: Bool
    public var unsafeContainer: Bool
    public var descriptorCount: Int
    public var posterType: TendiePosterType
    public var previewImageData: Data?
    public var dateImported: Date
    public var isSelected: Bool
    /// run #175：导入时检测到的旧包 family（iOS 27 之前做的包）。
    /// 空 = 不是旧包（或导入时未检测）。仅作提示与刷入决策用。
    public var legacyFamilies: [String] = []
    /// run #175：iOS 27+ 上刷入时是否把旧包重写成 Clownfish 布局。
    /// 默认 true（GoldenNugget 的默认也是转换）；用户在导入提示里
    /// 选「原样安装」后记 false。非旧包时此值无意义。
    public var convertToClownfish: Bool = true

    public init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        relativePath: String,
        isContainer: Bool = false,
        unsafeContainer: Bool = false,
        descriptorCount: Int = 1,
        posterType: TendiePosterType = .collections,
        previewImageData: Data? = nil,
        dateImported: Date = Date(),
        isSelected: Bool = true,
        legacyFamilies: [String] = [],
        convertToClownfish: Bool = true
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.relativePath = relativePath
        self.isContainer = isContainer
        self.unsafeContainer = unsafeContainer
        self.descriptorCount = descriptorCount
        self.posterType = posterType
        self.previewImageData = previewImageData
        self.dateImported = dateImported
        self.isSelected = isSelected
        self.legacyFamilies = legacyFamilies
        self.convertToClownfish = convertToClownfish
    }

    public var fileURL: URL {
        TendiesEngine.tendiesStorageDirectory.appendingPathComponent(relativePath)
    }

    public var uiPreview: UIImage? {
        guard let data = previewImageData else { return nil }
        return UIImage(data: data)
    }

    public static func == (lhs: TendieItem, rhs: TendieItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.isSelected == rhs.isSelected &&
        lhs.descriptorCount == rhs.descriptorCount &&
        lhs.previewImageData?.count == rhs.previewImageData?.count
    }
}

// MARK: - 解码兼容（run #175）

extension TendieItem {
    /// 旧版存盘数据没有 legacyFamilies / convertToClownfish 两个键；
    /// 逐项 decodeIfPresent、缺失给默认值，旧库绝不因缺键解码失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath) ?? fileName
        isContainer = try c.decodeIfPresent(Bool.self, forKey: .isContainer) ?? false
        unsafeContainer = try c.decodeIfPresent(Bool.self, forKey: .unsafeContainer) ?? false
        descriptorCount = try c.decodeIfPresent(Int.self, forKey: .descriptorCount) ?? 1
        posterType = try c.decodeIfPresent(TendiePosterType.self, forKey: .posterType) ?? .collections
        previewImageData = try c.decodeIfPresent(Data.self, forKey: .previewImageData)
        dateImported = try c.decodeIfPresent(Date.self, forKey: .dateImported) ?? Date()
        isSelected = try c.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
        legacyFamilies = try c.decodeIfPresent([String].self, forKey: .legacyFamilies) ?? []
        convertToClownfish = try c.decodeIfPresent(Bool.self, forKey: .convertToClownfish) ?? true
    }
}

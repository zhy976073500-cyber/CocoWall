import SwiftUI
import UIKit

/// Liquid-glass chrome for the preview screen: real SwiftUI glass on
/// iOS 26+, ultra-thin material everywhere else. Every glassEffect use
/// stays inside the availability branch — deployment target is iOS 17.
struct GlassChrome<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func glassChrome<S: Shape>(in shape: S) -> some View {
        modifier(GlassChrome(shape: shape))
    }
}

/// Full-screen lock-screen style preview of one imported wallpaper:
/// background still full bleed, floating layer composited above it,
/// clock and glass controls on top. When the package ships no static
/// imagery at all (programmatic CA animation), an honest placeholder
/// card is shown instead of a faked picture.
struct WallpaperPreviewView: View {
    let record: ImportedWallpaper
    let onDismiss: () -> Void

    private var backgroundImage: UIImage? {
        guard let url = ImportedWallpaperStore.previewURL(for: record) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private var floatingImage: UIImage? {
        guard let url = ImportedWallpaperStore.floatingPreviewURL(for: record) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        let background = backgroundImage
        let floating = floatingImage
        ZStack {
            Color.black.ignoresSafeArea()

            if background != nil || floating != nil {
                if let background {
                    Image(uiImage: background)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                }
                if let floating {
                    Image(uiImage: floating)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                }
                clockOverlay
            } else {
                noPreviewCard
            }

            VStack {
                topChrome
                Spacer()
                bottomChrome(showLockButtons: background != nil || floating != nil)
            }
        }
    }

    // MARK: - Chrome

    private var topChrome: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            .glassChrome(in: Circle())

            HStack(spacing: 6) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(record.descriptorIdentifier)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassChrome(in: Capsule())

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var clockOverlay: some View {
        VStack(spacing: 2) {
            Text(Self.dateText)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(Self.timeText)
                .font(.system(size: 76, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 84)
    }

    private func bottomChrome(showLockButtons: Bool) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 5) {
                Button {
                    // Write path is not implemented yet; button stays
                    // disabled rather than pretending to apply.
                } label: {
                    Text("设为壁纸")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .glassChrome(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .disabled(true)
                .opacity(0.75)

                Text("写入功能开发中")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 24)

            if showLockButtons {
                HStack {
                    lockButton(systemName: "flashlight.fill")
                    Spacer()
                    lockButton(systemName: "camera.fill")
                }
                .padding(.horizontal, 46)
            }

            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.white)
                .frame(width: 134, height: 5)
                .padding(.top, 2)
        }
        .padding(.bottom, 8)
    }

    private func lockButton(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .glassChrome(in: Circle())
    }

    private var noPreviewCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
            Text(record.displayName)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("编号 \(record.descriptorIdentifier) · \(record.role)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Text("这个包是程序化动画、没有静态图，动态预览还在做。")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 300)
        .glassChrome(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Clock text

    private static var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日EEEE"
        return formatter.string(from: Date())
    }

    private static var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}

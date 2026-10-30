import SwiftUI
import UIKit

/// Glass chrome for the preview screen, with two build paths.
///
/// New path — Swift 6.2 compiler (Xcode 26, iOS 26 SDK): on iOS 26+
/// devices the real Liquid Glass material is applied with
/// `glassEffect`; on older systems it falls back to the legacy look
/// below. The compiler gate is what makes this safe: `glassEffect`
/// does not exist at all in older SDKs, and `#available` guards
/// runtime, not SDK presence, so without the gate the symbol fails
/// to compile (runs #11/#12 died on exactly this). Every use of the
/// iOS 26 glass APIs in this file sits inside `#if compiler(>=6.2)`
/// with the `#available` check nested inside it.
///
/// Legacy path — older compilers (e.g. Xcode 16.4 / Swift 6.1): fake
/// glass with ultra-thin material + a light edge highlight + soft
/// shadow, exactly as originally implemented.
struct GlassChrome<Content: View, S: Shape>: View {
    let shape: S
    @ViewBuilder let content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        } else {
            legacyBody
        }
        #else
        legacyBody
        #endif
    }

    /// The original fake-glass rendering, kept for the legacy build
    /// path and for pre-iOS 26 systems on the new build path.
    private var legacyBody: some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.28), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}

/// Groups nearby glass elements into one GlassEffectContainer on the
/// new build path (iOS 26 SDK + iOS 26 device) so their glass renders
/// as a coordinated group; a plain pass-through everywhere else.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Background of the preview screen's floating bottom dock.
/// New build path: real glass (regular variant; the same dark tint
/// the legacy stack used, so the dock stays legible over bright
/// wallpapers) in the same rounded-rect shape. Legacy path: the
/// original darkened ultra-thin material stack, unchanged.
private struct PreviewDockBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            shape
                .fill(Color.clear)
                .glassEffect(.regular.tint(Color.black.opacity(0.22)), in: shape)
                .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
        } else {
            legacyBody(shape: shape)
        }
        #else
        legacyBody(shape: shape)
        #endif
    }

    private func legacyBody(shape: RoundedRectangle) -> some View {
        shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(Color.black.opacity(0.22)))
            .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
    }
}

extension View {
    func glassChrome<S: Shape>(in shape: S) -> some View {
        GlassChrome(shape: shape) { self }
    }

    /// Main-action button style: the real glass prominent style on
    /// the new build path (iOS 26 SDK) running on iOS 26+; the
    /// default button style everywhere else.
    @ViewBuilder
    func primaryGlassButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Full-screen lock-screen style preview of one imported wallpaper:
/// background still full bleed, floating layer composited above it,
/// clock and glass controls on top. When the package ships no static
/// imagery at all (programmatic CA animation), an honest placeholder
/// card is shown instead of a faked picture.
struct WallpaperPreviewView: View {
    let record: ImportedWallpaper
    @ObservedObject var pairing: PairingService
    let onDismiss: () -> Void
    @State private var showApply = false

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
        // Chrome must respect the device safe area explicitly: the image
        // layers ignore it, which used to stretch the whole ZStack and
        // push the close button under the status bar / Dynamic Island.
        GeometryReader { geo in
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
                .padding(.top, geo.safeAreaInsets.top + 2)
                .padding(.bottom, geo.safeAreaInsets.bottom + 4)
            }
        }
        .sheet(isPresented: $showApply) {
            if let path = pairing.pairingFilePath {
                WallpaperApplyView(
                    record: record,
                    pairingFile: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Chrome

    private var topChrome: some View {
        // The close button and the title pill sit side by side; on
        // the new build path they render as one glass group.
        GlassGroup(spacing: 8) {
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
        VStack(spacing: 14) {
            if showLockButtons {
                HStack {
                    lockButton(systemName: "flashlight.fill")
                    Spacer()
                    lockButton(systemName: "camera.fill")
                }
                .padding(.horizontal, 46)
            }

            // Floating glass dock: darkened material so it stays legible
            // (and visibly glassy) over bright wallpapers.
            VStack(spacing: 4) {
                Button {
                    showApply = true
                } label: {
                    Text("设为壁纸")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .primaryGlassButtonStyle()
                .disabled(pairing.pairingFilePath == nil)

                Text(pairing.pairingFilePath == nil
                     ? "先在设置页完成本机配对后可写入"
                     : "经本机配对写入 PosterBoard")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                PreviewDockBackground()
            }
            .padding(.horizontal, 20)
        }
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

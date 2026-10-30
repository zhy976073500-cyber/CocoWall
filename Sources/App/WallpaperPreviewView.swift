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

/// Preview of one imported wallpaper, laid out the way the accepted
/// web prototype does it: white page, the lock-screen composite
/// rendered inside a centred phone-frame card (about 78% of the
/// screen width, iPhone screen proportions, corner radius ~13% of
/// the frame width, soft shadow, no black border), a three-step
/// strip below the frame and the big apply button below that.
///
/// The previous full-bleed layout sized its content from the safe
/// area inside a full-screen cover, which overflowed the right edge
/// once the view lived in the tab bar's navigation stack (clock,
/// date and dock all clipped off-screen). Here everything inside the
/// frame is sized from the frame's own width and clipped to it, so
/// nothing can stick out of the frame or the screen.
struct WallpaperPreviewView: View {
    let record: ImportedWallpaper
    @ObservedObject var pairing: PairingService
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
        GeometryReader { geo in
            let frameWidth = geo.size.width * 0.78
            let frameHeight = frameWidth * 19.5 / 9.0
            ScrollView {
                VStack(spacing: 18) {
                    // Name / identifier small print above the frame.
                    HStack(spacing: 6) {
                        Text(record.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("编号 \(record.descriptorIdentifier)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    phoneFrame(width: frameWidth, height: frameHeight)

                    stepsStrip

                    applySection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .background(Color.white)
        }
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showApply) {
            if let path = pairing.pairingFilePath {
                WallpaperApplyView(
                    record: record,
                    pairingFile: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Phone frame

    /// The lock-screen composite, clipped to the phone frame: still
    /// background cover-filled, floating layer above it, clock and
    /// the two round lock buttons — all sized from the frame width.
    /// Packages without any static imagery get the honest no-preview
    /// card inside the frame instead of a faked picture.
    private func phoneFrame(width: CGFloat, height: CGFloat) -> some View {
        let background = backgroundImage
        let floating = floatingImage
        let corner = width * 0.13
        return ZStack {
            Color.black

            if background != nil || floating != nil {
                if let background {
                    Image(uiImage: background)
                        .resizable()
                        .scaledToFill()
                }
                if let floating {
                    Image(uiImage: floating)
                        .resizable()
                        .scaledToFill()
                }
                frameClock(width: width)
                frameLockButtons(width: width)
            } else {
                noPreviewCard(maxWidth: width * 0.86)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    private func frameClock(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(Self.dateText)
                .font(.system(size: width * 0.052, weight: .semibold, design: .rounded))
            Text(Self.timeText)
                .font(.system(size: width * 0.185, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, width * 0.16)
    }

    private func frameLockButtons(width: CGFloat) -> some View {
        HStack {
            lockButton(systemName: "flashlight.fill", diameter: width * 0.115)
            Spacer()
            lockButton(systemName: "camera.fill", diameter: width * 0.115)
        }
        .padding(.horizontal, width * 0.10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, width * 0.075)
    }

    private func lockButton(systemName: String, diameter: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .glassChrome(in: Circle())
    }

    private func noPreviewCard(maxWidth: CGFloat) -> some View {
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
        .padding(20)
        .frame(maxWidth: maxWidth)
        .glassChrome(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Steps strip

    /// 1 连接隧道 → 2 完成配对 → 3 应用壁纸. The pairing step shows a
    /// check once a pairing file exists; the strip reflects state, it
    /// is not itself a control.
    private var stepsStrip: some View {
        HStack(alignment: .top, spacing: 4) {
            stepItem(number: 1, title: "连接隧道", done: false)
            stepChevron
            stepItem(number: 2, title: "完成配对", done: pairing.pairingFilePath != nil)
            stepChevron
            stepItem(number: 3, title: "应用壁纸", done: false)
        }
    }

    private func stepItem(number: Int, title: String, done: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.15))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(minWidth: 64)
    }

    private var stepChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
    }

    // MARK: - Apply

    private var applySection: some View {
        VStack(spacing: 8) {
            Button {
                showApply = true
            } label: {
                Text("设为壁纸")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .primaryGlassButtonStyle()
            .disabled(pairing.pairingFilePath == nil)

            Text(pairing.pairingFilePath == nil
                 ? "先在设置页完成本机配对后可写入"
                 : "经本机配对写入 PosterBoard")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

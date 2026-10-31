import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PairingLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        PairingLiveActivityWidget()
    }
}

struct PairingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            // Lock-screen / banner presentation.
            PairingActivityBannerView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("CocoWall", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.statusText)
                        .font(.caption.bold())
                        .foregroundStyle(context.state.phase == .succeeded ? .green :
                            context.state.phase == .failed ? .red : .primary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .pinReady, let pin = context.state.pin {
                        VStack(spacing: 2) {
                            Text(pin)
                                .font(.system(size: 36, weight: .black, design: .monospaced))
                            Text(context.state.detailText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(context.state.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.iconName)
            } compactTrailing: {
                Text(context.state.compactText)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } minimal: {
                Image(systemName: context.state.iconName)
            }
        }
    }
}

/// Lock-screen banner: same information as the expanded island —
/// status line, guidance, and the big PIN once it exists.
struct PairingActivityBannerView: View {
    let state: PairingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.iconName)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("CocoWall 配对 · \(state.statusText)")
                    .font(.headline)
                    .lineLimit(1)
                Text(state.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.phase == .pinReady, let pin = state.pin {
                Text(pin)
                    .font(.system(size: 24, weight: .black, design: .monospaced))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

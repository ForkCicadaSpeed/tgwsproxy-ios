import SwiftUI
import WidgetKit
import ActivityKit

// MARK: - Live Activity Widget for Dynamic Island

@available(iOS 17.0, *)
struct ProxyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProxyActivityAttributes.self) { context in
            // Lock Screen / banner presentation
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("TG Proxy")
                                .font(.caption.bold())
                            Text("\(context.attributes.host):\(context.attributes.port)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(context.state.isRunning ? "ACTIVE" : "OFF")
                            .font(.caption2.bold())
                            .foregroundStyle(context.state.isRunning ? .green : .red)
                        if context.state.isRunning {
                            Text(timerInterval: context.state.startedAt...Date.distantFuture,
                                 countsDown: false)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 60)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 14) {
                        statBlock(title: "Conn", value: "\(context.state.connectionsActive)")
                        statBlock(title: "Total", value: "\(context.state.connectionsTotal)")
                        statBlock(title: "↑", value: formatBytes(context.state.bytesUp))
                        statBlock(title: "↓", value: formatBytes(context.state.bytesDown))
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(context.state.isRunning ? .cyan : .gray)
            } compactTrailing: {
                Text("\(context.state.connectionsActive)")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(context.state.isRunning ? .green : .gray)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(context.state.isRunning ? .cyan : .gray)
            }
            .keylineTint(.cyan)
        }
    }

    private func lockScreenView(context: ActivityViewContext<ProxyActivityAttributes>) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TG WS Proxy")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("\(context.attributes.host):\(context.attributes.port) · dd…\(context.attributes.secretSuffix)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(context.state.isRunning ? "ACTIVE" : "OFF")
                        .font(.caption.bold())
                        .foregroundStyle(context.state.isRunning ? .green : .red)
                    if context.state.isRunning {
                        Text(timerInterval: context.state.startedAt...Date.distantFuture,
                             countsDown: false)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 70)
                    }
                }
            }
            HStack(spacing: 12) {
                statBlock(title: "Conn", value: "\(context.state.connectionsActive)")
                statBlock(title: "Total", value: "\(context.state.connectionsTotal)")
                statBlock(title: "↑", value: formatBytes(context.state.bytesUp))
                statBlock(title: "↓", value: formatBytes(context.state.bytesDown))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.white)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G"]
        var value = Double(bytes)
        for unit in units {
            if value < 1024 { return String(format: "%.0f%@", value, unit) }
            value /= 1024
        }
        return String(format: "%.0fT", value)
    }
}

// MARK: - Widget Bundle

@main
struct ProxyWidgetBundle: WidgetBundle {
    var body: some Widget {
        ProxyLiveActivity()
    }
}

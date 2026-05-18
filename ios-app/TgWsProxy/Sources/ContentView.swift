import SwiftUI
import NetworkExtension

@available(iOS 17.0, *)
struct ContentView: View {
    @EnvironmentObject var proxy: ProxyManager
    @State private var showSettings = false
    @State private var showLink = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status header
                statusHeader
                    .padding(.bottom, 16)

                // Stats card
                if proxy.isRunning {
                    statsCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                // Connect info
                if proxy.isRunning {
                    connectCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                Spacer()

                // Start/Stop button
                startStopButton
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("TG WS Proxy")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(proxy)
            }
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: proxy.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(proxy.isRunning ? .green : .secondary)
                .symbolEffect(.pulse, isActive: proxy.isRunning)

            Text(vpnStatusText)
                .font(.headline)
                .foregroundStyle(proxy.isRunning ? .primary : .secondary)

            if proxy.isRunning {
                Text("\(proxy.config.host):\(proxy.config.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
        }
        .padding(.top, 16)
    }

    private var statsCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Статистика")
                    .font(.subheadline.bold())
                Spacer()
            }
            HStack(spacing: 16) {
                statItem(
                    "Подключений",
                    value: "\(proxy.stats.connectionsActive)/\(proxy.stats.connectionsTotal)"
                )
                statItem("WS", value: "\(proxy.stats.connectionsWS)")
                statItem("↑", value: formatBytes(proxy.stats.bytesUp))
                statItem("↓", value: formatBytes(proxy.stats.bytesDown))
            }
            // Diagnostic row — exposes why a session might not flow.
            // If connectionsTotal > 0 but WS == 0 and wsErrors > 0, the
            // upstream WS handshake is failing (RF blocks direct Telegram
            // WS edges; configure a Cloudflare Worker in settings).
            // bad = client handshake failed (wrong secret / not MTProto).
            // tcpFB = WS failed but a direct-TCP fallback path took over.
            HStack(spacing: 16) {
                statItem("WS err", value: "\(proxy.stats.wsErrors)")
                statItem("Bad", value: "\(proxy.stats.connectionsBad)")
                statItem("TCP FB", value: "\(proxy.stats.connectionsTCPFallback)")
                statItem(
                    "CF",
                    value: proxy.config.cfWorkerDomain.isEmpty ? "off" : "on"
                )
            }
            .opacity(0.85)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statItem(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced).bold())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Подключение")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    UIPasteboard.general.string = proxy.tgLink
                } label: {
                    Label("Копировать", systemImage: "doc.on.doc")
                        .font(.caption)
                }
            }

            Text("MTProto прокси для Telegram:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                infoRow("Сервер", value: proxy.config.host)
                infoRow("Порт", value: "\(proxy.config.port)")
                infoRow("Secret", value: "dd\(proxy.config.secret)")
            }
            .font(.system(.caption, design: .monospaced))

            Button {
                if let url = URL(string: proxy.tgLink) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Открыть в Telegram", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private var vpnStatusText: String {
        switch proxy.vpnStatus {
        case .connected: return "Прокси активен (VPN)"
        case .connecting: return "Подключение..."
        case .disconnecting: return "Отключение..."
        case .reasserting: return "Переподключение..."
        case .invalid: return "VPN не настроен"
        default: return "Прокси остановлен"
        }
    }

    private var isTransitioning: Bool {
        proxy.vpnStatus == .connecting || proxy.vpnStatus == .disconnecting || proxy.vpnStatus == .reasserting
    }

    private var startStopButton: some View {
        Button {
            if proxy.isRunning {
                proxy.stopProxy()
            } else {
                proxy.startProxy()
            }
        } label: {
            HStack {
                if isTransitioning {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: proxy.isRunning ? "stop.fill" : "play.fill")
                }
                Text(proxy.isRunning ? "Остановить" : "Запустить")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(proxy.isRunning ? .red : .green)
        .controlSize(.large)
        .disabled(isTransitioning)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        for unit in units {
            if value < 1024 { return String(format: "%.1f%@", value, unit) }
            value /= 1024
        }
        return String(format: "%.1f TB", value)
    }
}

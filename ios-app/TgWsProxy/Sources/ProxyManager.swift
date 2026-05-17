import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.tgwsproxy.app", category: "ProxyManager")

// MARK: - Proxy Stats
struct ProxyStats {
    var connectionsTotal: Int = 0
    var connectionsActive: Int = 0
    var connectionsWS: Int = 0
    var connectionsTCPFallback: Int = 0
    var connectionsBad: Int = 0
    var wsErrors: Int = 0
    var bytesUp: UInt64 = 0
    var bytesDown: UInt64 = 0
}

// MARK: - Proxy Manager
@MainActor
@available(iOS 17.0, *)
final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var isRunning = false
    @Published var stats = ProxyStats()
    @Published var config = ProxyConfig.load()

    private var server: MTProtoProxyServer?

    var tgLink: String {
        "tg://proxy?server=\(config.host)&port=\(config.port)&secret=dd\(config.secret)"
    }

    func startProxy() {
        guard !isRunning else { return }

        logger.info("Starting proxy on \(self.config.host):\(self.config.port)")

        // Persist the exact config we're about to run with. This guarantees
        // that the `secret` the proxy listens on at runtime is the same one
        // we'll advertise in the tg:// link AND the same one we'll load on
        // the next cold start — otherwise the secret rotates per launch and
        // any proxy entry the user already added in Telegram immediately
        // starts producing only "Bad" handshakes.
        config.save()

        // Background keep-alive (silent audio + location + UIBackgroundTask).
        BackgroundKeeper.shared.start()

        // Live Activity on Dynamic Island / Lock Screen.
        LiveActivityManager.shared.startActivity(
            host: config.host,
            port: config.port,
            secret: config.secret
        )

        let configSnapshot = config
        server = MTProtoProxyServer(config: configSnapshot, statsCallback: { [weak self] newStats in
            Task { @MainActor in
                guard let self else { return }
                self.stats = newStats
                LiveActivityManager.shared.updateActivity(
                    connections: newStats.connectionsActive,
                    totalConnections: newStats.connectionsTotal,
                    bytesUp: newStats.bytesUp,
                    bytesDown: newStats.bytesDown
                )
            }
        })

        Task {
            do {
                try await server?.start()
                isRunning = true
                logger.info("Proxy started successfully")
            } catch {
                logger.error("Failed to start proxy: \(error.localizedDescription)")
                isRunning = false
                BackgroundKeeper.shared.stop()
                LiveActivityManager.shared.stopActivity()
                server = nil
            }
        }
    }

    func stopProxy() {
        guard isRunning else { return }
        logger.info("Stopping proxy")

        BackgroundKeeper.shared.stop()
        LiveActivityManager.shared.stopActivity()

        server?.stop()
        server = nil
        isRunning = false
        stats = ProxyStats()
    }

    func saveConfig() {
        config.save()
        if isRunning {
            stopProxy()
            startProxy()
        }
    }
}

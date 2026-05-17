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
    private var shouldBeRunning = false

    var tgLink: String {
        "tg://proxy?server=\(config.host)&port=\(config.port)&secret=dd\(config.secret)"
    }

    func startProxy() {
        guard !isRunning else { return }

        logger.info("Starting proxy on \(self.config.host):\(self.config.port)")

        config.save()
        shouldBeRunning = true

        BackgroundKeeper.shared.start()

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
        }, onListenerFailed: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                logger.warning("Listener failed, will attempt restart")
                self.isRunning = false
                self.server?.stop()
                self.server = nil
                if self.shouldBeRunning {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.startProxy()
                }
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
        guard isRunning || shouldBeRunning else { return }
        logger.info("Stopping proxy")

        shouldBeRunning = false

        BackgroundKeeper.shared.stop()
        LiveActivityManager.shared.stopActivity()

        server?.stop()
        server = nil
        isRunning = false
        stats = ProxyStats()
    }

    func handleBecameActive() {
        guard shouldBeRunning else { return }
        BackgroundKeeper.shared.reactivateAudioSession()
        if server == nil || !server!.isListenerReady {
            logger.info("Proxy was running but listener died, restarting")
            isRunning = false
            server?.stop()
            server = nil
            startProxy()
        }
    }

    func saveConfig() {
        config.save()
        if isRunning {
            stopProxy()
            startProxy()
        }
    }
}

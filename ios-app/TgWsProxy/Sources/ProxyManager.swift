import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.tgwsproxy.app", category: "ProxyManager")

// MARK: - Proxy Manager (direct mode with background keep-alive)
@MainActor
@available(iOS 17.0, *)
final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var isRunning = false
    @Published var stats = ProxyStats()
    @Published var config = ProxyConfig.load()

    private var server: MTProtoProxyServer?
    private var startGeneration = 0

    private var shouldBeRunning: Bool {
        get { UserDefaults.standard.bool(forKey: "proxyShouldBeRunning") }
        set { UserDefaults.standard.set(newValue, forKey: "proxyShouldBeRunning") }
    }

    var tgLink: String {
        "tg://proxy?server=\(config.host)&port=\(config.port)&secret=dd\(config.secret)"
    }

    // MARK: - Start / Stop

    func startProxy() {
        guard !isRunning else { return }

        config.save()
        shouldBeRunning = true
        startGeneration += 1
        let gen = startGeneration

        logger.info("Starting proxy gen=\(gen) on \(self.config.host):\(self.config.port)")

        BackgroundKeeper.shared.start()
        LiveActivityManager.shared.startActivity(
            host: config.host,
            port: config.port,
            secret: config.secret
        )

        let srv = MTProtoProxyServer(config: config, statsCallback: { [weak self] newStats in
            Task { @MainActor in
                guard let self, gen == self.startGeneration else { return }
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
                guard let self, gen == self.startGeneration else { return }
                logger.warning("Listener failed gen=\(gen), will restart on next foreground")
                self.server = nil
                self.isRunning = false
            }
        })
        self.server = srv

        Task {
            do {
                try await srv.start()
                guard gen == self.startGeneration else { return }
                isRunning = true
                logger.info("Proxy started successfully gen=\(gen)")
            } catch {
                guard gen == self.startGeneration else { return }
                logger.error("Proxy start failed gen=\(gen): \(error.localizedDescription)")
                isRunning = false
                server = nil
            }
        }
    }

    func stopProxy() {
        logger.info("Stopping proxy")
        shouldBeRunning = false
        startGeneration += 1

        BackgroundKeeper.shared.stop()
        LiveActivityManager.shared.stopActivity()

        server = nil
        isRunning = false
        stats = ProxyStats()
    }

    func handleBecameActive() {
        guard shouldBeRunning else { return }

        BackgroundKeeper.shared.reactivateAudioSession()

        // After iOS freezes the process the NWListener is dead but our
        // state still says isRunning. Force a clean restart every time.
        logger.info("Returning to foreground, restarting proxy")
        startGeneration += 1
        server = nil
        isRunning = false
        startProxy()
    }

    func saveConfig() {
        config.save()
        if isRunning || shouldBeRunning {
            stopProxy()
            startProxy()
        }
    }
}

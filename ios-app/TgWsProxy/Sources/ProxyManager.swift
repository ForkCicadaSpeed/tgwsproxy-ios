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
    private var restartAttempts = 0
    private static let maxRestartAttempts = 5

    private var shouldBeRunning: Bool {
        get { UserDefaults.standard.bool(forKey: "proxyShouldBeRunning") }
        set { UserDefaults.standard.set(newValue, forKey: "proxyShouldBeRunning") }
    }

    var tgLink: String {
        "tg://proxy?server=\(config.host)&port=\(config.port)&secret=dd\(config.secret)"
    }

    private init() {
        if UserDefaults.standard.bool(forKey: "proxyShouldBeRunning") {
            logger.info("Cold start: proxy was running before, auto-starting")
            Task { @MainActor in
                self.startProxy()
            }
        }
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
                self.isRunning = false
                self.server?.stop()
                self.server = nil
                guard self.shouldBeRunning else { return }
                self.restartAttempts += 1
                if self.restartAttempts > ProxyManager.maxRestartAttempts {
                    logger.error("Listener failed \(self.restartAttempts) times, giving up")
                    self.shouldBeRunning = false
                    BackgroundKeeper.shared.stop()
                    LiveActivityManager.shared.stopActivity()
                    return
                }
                let delay = UInt64(self.restartAttempts) * 1_000_000_000
                logger.warning("Listener failed, restart attempt \(self.restartAttempts) in \(self.restartAttempts)s")
                try? await Task.sleep(nanoseconds: delay)
                self.startProxy()
            }
        })

        Task {
            do {
                try await server?.start()
                isRunning = true
                restartAttempts = 0
                logger.info("Proxy started successfully")
            } catch {
                logger.error("Failed to start proxy: \(error.localizedDescription)")
                isRunning = false
                server = nil
                if shouldBeRunning && restartAttempts < ProxyManager.maxRestartAttempts {
                    restartAttempts += 1
                    let delay = UInt64(restartAttempts) * 1_000_000_000
                    logger.info("Retrying start in \(restartAttempts)s (attempt \(restartAttempts))")
                    try? await Task.sleep(nanoseconds: delay)
                    startProxy()
                } else {
                    shouldBeRunning = false
                    BackgroundKeeper.shared.stop()
                    LiveActivityManager.shared.stopActivity()
                }
            }
        }
    }

    func stopProxy() {
        guard isRunning || shouldBeRunning else { return }
        logger.info("Stopping proxy")

        shouldBeRunning = false
        restartAttempts = 0

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
        if !isRunning || server == nil || !server!.isListenerReady {
            logger.info("Returning to foreground, proxy needs restart")
            isRunning = false
            server?.stop()
            server = nil
            restartAttempts = 0
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

import Foundation
import NetworkExtension
import Combine
import os.log

private let logger = Logger(subsystem: "com.tgwsproxy.app", category: "ProxyManager")

// MARK: - Proxy Manager (VPN-based)
@MainActor
@available(iOS 17.0, *)
final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var isRunning = false
    @Published var stats = ProxyStats()
    @Published var config = ProxyConfig.load()
    @Published var vpnStatus: NEVPNStatus = .disconnected

    private var vpnManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var statsTimer: Timer?

    private static let tunnelBundleID = "com.tgwsproxy.app.tunnel"

    var tgLink: String {
        "tg://proxy?server=\(config.host)&port=\(config.port)&secret=dd\(config.secret)"
    }

    init() {
        loadVPNConfiguration()
    }

    // MARK: - VPN Configuration

    private func loadVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    logger.error("Failed to load VPN preferences: \(error.localizedDescription)")
                }
                if let existing = managers?.first {
                    self.vpnManager = existing
                } else {
                    self.vpnManager = self.makeVPNManager()
                }
                self.observeVPNStatus()
                self.syncRunningState()
            }
        }
    }

    private func makeVPNManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = "\(config.host):\(config.port)"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "TG WS Proxy"
        manager.isEnabled = true
        return manager
    }

    // MARK: - Start / Stop

    func startProxy() {
        guard !isRunning else { return }
        config.save()
        logger.info("Starting VPN tunnel for proxy on \(self.config.host):\(self.config.port)")

        guard let manager = vpnManager else {
            logger.error("VPN manager not loaded yet")
            return
        }

        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            proto.serverAddress = "\(config.host):\(config.port)"
        }
        manager.isEnabled = true

        manager.saveToPreferences { [weak self] error in
            if let error {
                logger.error("Save VPN prefs failed: \(error.localizedDescription)")
                return
            }
            manager.loadFromPreferences { error in
                if let error {
                    logger.error("Reload VPN prefs failed: \(error.localizedDescription)")
                    return
                }
                do {
                    try (manager.connection as? NETunnelProviderSession)?.startTunnel()
                    logger.info("VPN tunnel start requested")
                } catch {
                    logger.error("Start tunnel failed: \(error.localizedDescription)")
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                LiveActivityManager.shared.startActivity(
                    host: self.config.host,
                    port: self.config.port,
                    secret: self.config.secret
                )
            }
        }
    }

    func stopProxy() {
        logger.info("Stopping VPN tunnel")
        vpnManager?.connection.stopVPNTunnel()
        LiveActivityManager.shared.stopActivity()
        stats = ProxyStats()
    }

    func handleBecameActive() {
        syncRunningState()
        if isRunning {
            fetchStats()
        }
    }

    func saveConfig() {
        config.save()
        if isRunning {
            stopProxy()
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                startProxy()
            }
        }
    }

    // MARK: - VPN Status

    private func observeVPNStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: vpnManager?.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncRunningState()
            }
        }
    }

    private func syncRunningState() {
        let status = vpnManager?.connection.status ?? .disconnected
        vpnStatus = status
        let running = (status == .connected)
        if running != isRunning {
            isRunning = running
            if running {
                startStatsPolling()
                LiveActivityManager.shared.startActivity(
                    host: config.host, port: config.port, secret: config.secret
                )
            } else {
                stopStatsPolling()
                if status == .disconnected || status == .invalid {
                    LiveActivityManager.shared.stopActivity()
                }
            }
        }
    }

    // MARK: - Stats IPC

    private func startStatsPolling() {
        stopStatsPolling()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchStats()
            }
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func fetchStats() {
        guard let session = vpnManager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return }
        do {
            try session.sendProviderMessage(Data([0x01])) { [weak self] response in
                guard let data = response,
                      let decoded = try? JSONDecoder().decode(ProxyStats.self, from: data) else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.stats = decoded
                    LiveActivityManager.shared.updateActivity(
                        connections: decoded.connectionsActive,
                        totalConnections: decoded.connectionsTotal,
                        bytesUp: decoded.bytesUp,
                        bytesDown: decoded.bytesDown
                    )
                }
            }
        } catch {
            logger.debug("Stats IPC failed: \(error.localizedDescription)")
        }
    }
}

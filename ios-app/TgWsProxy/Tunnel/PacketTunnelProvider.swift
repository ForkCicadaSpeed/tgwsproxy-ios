import Foundation
import NetworkExtension
import Network
import os.log

private let logger = Logger(subsystem: "com.tgwsproxy.tunnel", category: "Tunnel")

@available(iOS 17.0, *)
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var server: MTProtoProxyServer?
    private var latestStats = ProxyStats()
    private let statsLock = NSLock()

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let config = ProxyConfig.load()
        logger.info("Starting tunnel, proxy on \(config.host):\(config.port)")

        // Mark VPN as connected IMMEDIATELY — do not wait for
        // setTunnelNetworkSettings callback which may hang on some devices.
        completionHandler(nil)
        logger.info("completionHandler(nil) called, VPN should show connected")

        // Configure minimal tunnel settings asynchronously.
        // Use different local/remote addresses and exclude all traffic
        // so the tunnel is a no-op (we only need the process kept alive).
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500 as NSNumber

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                logger.error("Tunnel network settings failed: \(error.localizedDescription)")
            } else {
                logger.info("Tunnel network settings applied")
            }
            self?.startReadingPackets()
        }

        // Start the proxy server immediately (don't wait for tunnel settings).
        let srv = MTProtoProxyServer(config: config, statsCallback: { [weak self] stats in
            self?.setStats(stats)
        }, onListenerFailed: { [weak self] in
            logger.error("Listener failed inside tunnel, restarting proxy")
            self?.restartProxy()
        })
        self.server = srv

        Task {
            do {
                try await srv.start()
                logger.info("Proxy server started successfully in tunnel")
            } catch {
                logger.error("Proxy server start failed: \(error.localizedDescription)")
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Stopping tunnel, reason: \(String(describing: reason))")
        server?.stop()
        server = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let stats = getStats()
        let response = try? JSONEncoder().encode(stats)
        completionHandler?(response)
    }

    private func startReadingPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            self?.startReadingPackets()
        }
    }

    private func restartProxy() {
        server?.stop()
        server = nil
        let config = ProxyConfig.load()
        let srv = MTProtoProxyServer(config: config, statsCallback: { [weak self] stats in
            self?.setStats(stats)
        }, onListenerFailed: { [weak self] in
            logger.error("Listener failed again, restarting")
            self?.restartProxy()
        })
        self.server = srv
        Task {
            do {
                try await srv.start()
                logger.info("Proxy server restarted successfully")
            } catch {
                logger.error("Proxy restart failed: \(error.localizedDescription)")
            }
        }
    }

    private func setStats(_ stats: ProxyStats) {
        statsLock.lock()
        latestStats = stats
        statsLock.unlock()
    }

    private func getStats() -> ProxyStats {
        statsLock.lock()
        let s = latestStats
        statsLock.unlock()
        return s
    }
}

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

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { completionHandler(error); return }
            if let error {
                logger.error("Tunnel network settings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            let srv = MTProtoProxyServer(config: config, statsCallback: { [weak self] stats in
                self?.setStats(stats)
            }, onListenerFailed: { [weak self] in
                logger.error("Listener failed inside tunnel, cancelling")
                self?.cancelTunnelWithError(NSError(domain: "TgWsProxyTunnel", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Proxy listener failed"]))
            })
            self.server = srv

            Task {
                do {
                    try await srv.start()
                    logger.info("Proxy server started successfully in tunnel")
                    completionHandler(nil)
                } catch {
                    logger.error("Proxy server start failed: \(error.localizedDescription)")
                    completionHandler(error)
                }
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

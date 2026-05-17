import Foundation
import Security

struct ProxyConfig: Codable {
    var host: String = "127.0.0.1"
    var port: Int = 1443
    var secret: String = ProxyConfig.generateSecret()
    var dcRedirects: [Int: String] = [2: "149.154.167.220", 4: "149.154.167.220"]
    var dcOverrides: [Int: Int] = [203: 2]
    var bufferSizeKB: Int = 256
    var poolSize: Int = 4
    var verbose: Bool = false

    // Cloudflare Worker fronting domain, e.g. "random-name.username.workers.dev".
    // When set, the proxy routes WSS via this domain instead of Telegram's
    // direct `kwsN.web.telegram.org` endpoints. This is what makes the
    // Python reference proxy actually work inside restricted regions
    // (Russia / DPI / RST injection) — the direct Telegram WS IPs are
    // RST-injected, Cloudflare Workers are not.
    var cfWorkerDomain: String = ""

    var bufferSize: Int { bufferSizeKB * 1024 }

    private enum CodingKeys: String, CodingKey {
        case host, port, secret, dcRedirects, dcOverrides
        case bufferSizeKB, poolSize, verbose, cfWorkerDomain
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 1443
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ProxyConfig.generateSecret()
        dcRedirects = try c.decodeIfPresent([Int: String].self, forKey: .dcRedirects)
            ?? [2: "149.154.167.220", 4: "149.154.167.220"]
        dcOverrides = try c.decodeIfPresent([Int: Int].self, forKey: .dcOverrides) ?? [203: 2]
        bufferSizeKB = try c.decodeIfPresent(Int.self, forKey: .bufferSizeKB) ?? 256
        poolSize = try c.decodeIfPresent(Int.self, forKey: .poolSize) ?? 4
        verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? false
        cfWorkerDomain = try c.decodeIfPresent(String.self, forKey: .cfWorkerDomain) ?? ""
    }

    static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static let dcDefaultIPs: [Int: String] = [
        1: "149.154.175.50",
        2: "149.154.167.51",
        3: "149.154.175.100",
        4: "149.154.167.91",
        5: "149.154.171.5",
        203: "91.105.192.100"
    ]

    static func load() -> ProxyConfig {
        guard let data = UserDefaults.standard.data(forKey: "proxyConfig"),
              let config = try? JSONDecoder().decode(ProxyConfig.self, from: data) else {
            return ProxyConfig()
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "proxyConfig")
        }
    }
}

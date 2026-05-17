import Foundation

struct ProxyStats: Codable {
    var connectionsTotal: Int = 0
    var connectionsActive: Int = 0
    var connectionsWS: Int = 0
    var connectionsTCPFallback: Int = 0
    var connectionsBad: Int = 0
    var wsErrors: Int = 0
    var bytesUp: UInt64 = 0
    var bytesDown: UInt64 = 0
}

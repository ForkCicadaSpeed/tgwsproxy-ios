import Foundation
import ActivityKit

// MARK: - Live Activity Attributes

struct ProxyActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isRunning: Bool
        var connectionsActive: Int
        var connectionsTotal: Int
        var bytesUp: UInt64
        var bytesDown: UInt64
        var startedAt: Date
    }

    var host: String
    var port: Int
    var secretSuffix: String   // last 4 hex chars of secret for quick visual ID
}

// MARK: - Live Activity Manager

@MainActor
@available(iOS 17.0, *)
final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    private var activity: Activity<ProxyActivityAttributes>?
    private var startedAt: Date = .distantPast

    func startActivity(host: String, port: Int, secret: String) {
        // If an activity is already live, just refresh it instead of spawning a duplicate.
        if activity != nil {
            updateActivity(connections: 0, totalConnections: 0, bytesUp: 0, bytesDown: 0)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("Live Activities are disabled in iOS settings")
            return
        }

        startedAt = Date()
        let suffix = secret.count >= 4 ? String(secret.suffix(4)) : secret
        let attributes = ProxyActivityAttributes(host: host, port: port, secretSuffix: suffix)
        let state = ProxyActivityAttributes.ContentState(
            isRunning: true,
            connectionsActive: 0,
            connectionsTotal: 0,
            bytesUp: 0,
            bytesDown: 0,
            startedAt: startedAt
        )

        do {
            let content = ActivityContent(state: state, staleDate: nil)
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }

    func updateActivity(connections: Int, totalConnections: Int, bytesUp: UInt64, bytesDown: UInt64) {
        guard let activity else { return }
        let state = ProxyActivityAttributes.ContentState(
            isRunning: true,
            connectionsActive: connections,
            connectionsTotal: totalConnections,
            bytesUp: bytesUp,
            bytesDown: bytesDown,
            startedAt: startedAt
        )
        Task {
            let content = ActivityContent(state: state, staleDate: nil)
            await activity.update(content)
        }
    }

    func stopActivity() {
        guard let activity else { return }
        let state = ProxyActivityAttributes.ContentState(
            isRunning: false,
            connectionsActive: 0,
            connectionsTotal: 0,
            bytesUp: 0,
            bytesDown: 0,
            startedAt: startedAt
        )
        Task {
            let content = ActivityContent(state: state, staleDate: nil)
            await activity.end(content, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}

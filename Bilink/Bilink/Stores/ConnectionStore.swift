import Foundation
import Observation

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case failed(ACPError)
}

/// 连接状态机:idle → connecting → connected;失败回 failed(留在连接页)。
@Observable
final class ConnectionStore {
    var state: ConnectionState = .idle
    var config: ConnectionConfig?

    private(set) var client: ACPClient?

    func connect(_ config: ConnectionConfig) async {
        self.config = config
        state = .connecting
        do {
            let client = ACPClient()
            try await client.start(url: config.url, token: config.token)
            self.client = client
            state = .connected
        } catch let error as ACPError {
            state = .failed(error)
        } catch {
            state = .failed(.transport(error.localizedDescription))
        }
    }

    func disconnect() {
        client?.close()
        client = nil
        state = .idle
    }
}

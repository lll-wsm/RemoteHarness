import Foundation
import Observation

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting
    case failed(ACPError)
}

/// 连接状态机:idle → connecting → connected;断线自动重连(reconnecting→connected);
/// 手动断开回 idle;失败回 failed(留在连接页)。
@Observable
final class ConnectionStore {
    var state: ConnectionState = .idle
    var config: ConnectionConfig?
    /// 重连成功后的回调(由 ChatStore 注册,用于重新加载会话)。
    var onReconnected: (() -> Void)?

    private(set) var client: ACPClient?
    private var userDisconnect = true

    var isActive: Bool {
        state == .connected || state == .reconnecting
    }

    func connect(_ config: ConnectionConfig) async {
        self.config = config
        userDisconnect = false
        await establish(config, isReconnect: false)
    }

    func disconnect() {
        userDisconnect = true
        client?.onDisconnect = nil
        client?.close()
        client = nil
        // 清掉旧 ChatStore 注册的重连回调:切换 profile 后防误触发旧会话 reload
        onReconnected = nil
        state = .idle
    }

    // MARK: - 建立连接

    private func establish(_ config: ConnectionConfig, isReconnect: Bool) async {
        state = isReconnect ? .reconnecting : .connecting
        do {
            let client = ACPClient()
            client.onDisconnect = { [weak self, weak client] in
                guard let self, let client, self.client === client else { return }
                Task { await self.reconnect(config) }
            }
            try await client.start(url: config.url, token: config.token, timeout: 8)
            // 连接建立期间用户可能已手动断开/删除 profile:丢弃该连接,不进已连接态
            guard !userDisconnect else {
                client.close()
                return
            }
            self.client = client
            state = .connected
            if isReconnect {
                onReconnected?()
            }
        } catch let error as ACPError {
            if !isReconnect {
                state = .failed(error)
            }
        } catch {
            if !isReconnect {
                state = .failed(.transport(error.localizedDescription))
            }
        }
    }

    /// 断线自动重连:指数退避(1s → 30s 封顶),直到成功或用户手动断开。
    private func reconnect(_ config: ConnectionConfig) async {
        guard !userDisconnect else { return }
        state = .reconnecting
        var delay = 1.0
        while !userDisconnect {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !userDisconnect else { return }
            await establish(config, isReconnect: true)
            if state == .connected { return }
            delay = min(delay * 2, 30)
        }
    }
}

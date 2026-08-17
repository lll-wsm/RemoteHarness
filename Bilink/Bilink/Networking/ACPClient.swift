import Foundation
import Observation

/// ACP JSON-RPC 客户端(URLSessionWebSocketTask 实现)。
/// 职责:
/// - WebSocket 建立(Bearer 鉴权)→ initialize 握手 → 标记 ready;
/// - 请求/响应按 id 配对;通知分发给 handler;
/// - 连接断开时失败所有在途请求。
@Observable
final class ACPClient {
    private(set) var isReady = false
    private(set) var connectionInfo: String?

    var onNotification: ((RPCNotification) -> Void)?
    /// 连接意外断开时回调(主动 close 不触发)。
    var onDisconnect: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var pending: [Int: (Result<AnyCodable?, ACPError>) -> Void] = [:]
    private var receiveTask: Task<Void, Never>?

    // MARK: - 连接与握手

    /// 建立连接并完成 initialize 握手;超时抛 .timeout。
    func start(url: String, token: String, timeout: TimeInterval = 10) async throws {
        guard let wsURL = URL(string: url), let scheme = wsURL.scheme,
              scheme == "ws" || scheme == "wss" else {
            throw ACPError.unreachable
        }

        // 前置探测:桥的 /healthz 与 WebSocket 握手共用同一套 token 鉴权,
        // 用 HTTP 探测精确分类 401(token 错)/ 超时 / 不可达,而非等 WebSocket 的泛化错误。
        try await probe(url: wsURL, token: token)

        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        // 接收循环必须先启动:initialize 的响应也走它分发
        startReceiveLoop()

        do {
            try await withTimeout(seconds: timeout) {
                _ = try await self.send("initialize",
                                        params: .acp(["protocolVersion": "0.10.4",
                                                      "clientCapabilities": [String: Any]()]))
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            self.task = nil
            receiveTask?.cancel()
            receiveTask = nil
            if let acpError = error as? ACPError {
                throw acpError
            }
            throw mapTransport(error)
        }

        isReady = true
        connectionInfo = wsURL.absoluteString
    }

    /// 探测桥的 /healthz:200=可达且 token 正确;401=token 错;网络错误分类为不可达/超时。
    private func probe(url: URL, token: String) async throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ACPError.unreachable
        }
        components.scheme = url.scheme == "wss" ? "https" : "http"
        components.path = "/healthz"
        components.query = nil
        guard let probeURL = components.url else { throw ACPError.unreachable }
        var request = URLRequest(url: probeURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                throw ACPError.unauthorized
            }
        } catch let error as ACPError {
            throw error
        } catch {
            throw mapTransport(error)
        }
    }

    private func mapTransport(_ error: Error) -> ACPError {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet:
            return .unreachable
        case NSURLErrorTimedOut:
            return .timeout
        default:
            return .transport(error.localizedDescription)
        }
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isReady = false
        failAllPending(with: .notConnected)
    }

    // MARK: - 请求

    /// 发送 JSON-RPC 请求,返回 result;错误响应抛 .handshake(message)。
    @discardableResult
    func send(_ method: String, params: [String: AnyCodable]? = nil) async throws -> AnyCodable? {
        guard let task else { throw ACPError.notConnected }
        let id = nextId
        nextId += 1

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = { result in
                switch result {
                case .success(.some(let any)):
                    // 错误响应被包装成含 "message" 的对象,这里转成 handshake 错误
                    if let obj = any.objectValue,
                       let message = obj["message"]?.stringValue {
                        continuation.resume(throwing: ACPError.handshake(message))
                    } else {
                        continuation.resume(returning: any)
                    }
                case .success(.none):
                    continuation.resume(returning: nil)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            let request = RPCRequest(id: id, method: method, params: params)
            do {
                let data = try JSONEncoder().encode(request)
                task.send(.data(data)) { [weak self] error in
                    if let error {
                        self?.pending.removeValue(forKey: id)?(
                            .failure(.transport(error.localizedDescription)))
                    }
                }
            } catch {
                pending.removeValue(forKey: id)?(.failure(.transport(error.localizedDescription)))
            }
        }
    }

    // MARK: - 接收循环

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self, let task = self.task else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self.handleText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleText(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    self.handleDisconnect()
                    return
                }
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let response = try? JSONDecoder().decode(RPCResponse.self, from: data) {
            if let callback = pending.removeValue(forKey: response.id) {
                if let error = response.error {
                    callback(.success(.object(["message": .string(error.message),
                                              "code": .number(Double(error.code))])))
                } else {
                    callback(.success(response.result))
                }
            }
        } else if let notification = try? JSONDecoder().decode(RPCNotification.self, from: data) {
            onNotification?(notification)
        }
    }

    private func handleDisconnect() {
        isReady = false
        failAllPending(with: .transport("连接已断开"))
        onDisconnect?()
    }

    private func failAllPending(with error: ACPError) {
        let callbacks = Array(pending.values)
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(error))
        }
    }
}

// MARK: - 超时辅助

private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ACPError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

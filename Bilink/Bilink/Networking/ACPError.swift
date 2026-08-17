import Foundation

/// ACP 客户端错误分类,展示层按类型给出用户可读文案。
enum ACPError: LocalizedError, Equatable {
    case unauthorized        // 401:token 错误
    case timeout             // 握手超时
    case unreachable         // 无法连接(URL 错 / 桥未启动)
    case handshake(String)   // initialize 返回 error
    case notConnected
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "token 错误(401),请检查 token"
        case .timeout:
            return "连接超时,请检查地址或网络"
        case .unreachable:
            return "无法连接,请检查 URL 或远程桥是否已启动"
        case .handshake(let message):
            return "握手失败: \(message)"
        case .notConnected:
            return "未连接"
        case .transport(let message):
            return "连接错误: \(message)"
        }
    }
}

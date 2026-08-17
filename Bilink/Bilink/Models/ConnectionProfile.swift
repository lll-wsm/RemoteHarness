import Foundation

/// 一台远程机器的连接配置。id 稳定不变;url 可编辑(隧道换地址不影响会话归属)。
struct ConnectionProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String           // ws:// 或 wss://
    var createdAt: Date
    var lastUsedAt: Date?
}
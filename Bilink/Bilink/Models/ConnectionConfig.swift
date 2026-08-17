import Foundation

/// 一个远程连接的配置(连接名 / 地址 / token / agent)。
/// token 不落盘(存 Keychain),name/url/agent 可存 UserDefaults。
struct ConnectionConfig: Codable, Equatable {
    var name: String
    var url: String      // ws:// 或 wss://
    var token: String
    var agent: String = "grok"   // 多 agent 预留(默认 grok)
    var profileID: UUID
    /// 应用层加密密钥(可选;与桥 BRIDGE_ENCRYPT_KEY 一致)。仅内存持有,不落盘。
    var encryptionKey: String?
}

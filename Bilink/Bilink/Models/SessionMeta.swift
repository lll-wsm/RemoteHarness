import Foundation

/// 历史会话元数据:标题、摘要、时间。所有会话目录持久化在
/// BilinkSessions/index.json,消息记录持久化在 BilinkSessions/<chatID>.json。
struct SessionMeta: Identifiable, Codable, Equatable {
    var id: String { chatID }
    var chatID: String
    var title: String
    /// 最后一条消息的摘要(用户/助手前缀)。
    var preview: String?
    var messageCount: Int
    var createdAt: Date
    var updatedAt: Date
    var connectionURL: String
}
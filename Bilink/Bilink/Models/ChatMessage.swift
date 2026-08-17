import Foundation

enum ChatRole: String, Codable, Equatable {
    case user
    case assistant
}

/// 一条聊天消息。助手消息流式期间 text 持续追加,thought 保存思考过程。
/// Codable:本地持久化历史(按 chatID 存文件)。
struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: ChatRole
    var text: String
    var thought: String = ""
    var isStreaming: Bool = false

    init(role: ChatRole, text: String, thought: String = "", isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.thought = thought
        self.isStreaming = isStreaming
    }
}

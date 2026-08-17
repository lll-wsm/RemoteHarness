import Foundation

enum ChatRole: Equatable {
    case user
    case assistant
}

/// 一条聊天消息。助手消息流式期间 text 持续追加,thought 保存思考过程。
struct ChatMessage: Identifiable, Equatable {
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

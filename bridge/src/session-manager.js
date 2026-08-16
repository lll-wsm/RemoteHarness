import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

// chatID(桥生成,稳定标识一个「远程 chat」)→ 远程 grok 会话。
// 持久化到 JSON 文件:桥重启后按 chatID 恢复(经 ACP session/load 重建 grok 会话)。
export class SessionManager {
  constructor(file) {
    this.file = file;
    this.records = new Map();
    this.load();
  }

  load() {
    try {
      const data = JSON.parse(fs.readFileSync(this.file, "utf8"));
      for (const r of data) this.records.set(r.chatID, r);
    } catch {
      // 首次运行无文件
    }
  }

  save() {
    fs.mkdirSync(path.dirname(path.resolve(this.file)), { recursive: true });
    fs.writeFileSync(this.file, JSON.stringify([...this.records.values()], null, 2));
  }

  // 新建一个远程 chat 记录(尚未绑定 grok 会话 id,待 session/new 后 bind)。
  create({ cwd, meta = {} } = {}) {
    const chatID = randomUUID();
    const record = {
      chatID,
      grokSessionId: null,
      cwd: cwd ?? null,
      meta,
      createdAt: new Date().toISOString(),
    };
    this.records.set(chatID, record);
    this.save();
    return record;
  }

  bindGrokSession(chatID, grokSessionId) {
    const r = this.records.get(chatID);
    if (!r) return null;
    r.grokSessionId = grokSessionId;
    this.save();
    return r;
  }

  get(chatID) {
    return this.records.get(chatID);
  }

  list() {
    return [...this.records.values()];
  }

  remove(chatID) {
    const ok = this.records.delete(chatID);
    if (ok) this.save();
    return ok;
  }
}

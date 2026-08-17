import { WebSocketServer, WebSocket } from "ws";
import { isAuthorized, clientIp } from "./auth.js";
import { RateLimiter } from "./rate-limiter.js";

// 对 iPad 暴露的 ACP 服务端(JSON-RPC 2.0 over WebSocket)。
// - initialize:桥本地应答(协议协商);
// - session/new:桥生成 chatID 登记,补 cwd/mcp_servers 后转发 grok,捕获 session_id;
// - session/load:按 chatID 从注册表解析 grok 会话,补 session_id 后转发恢复;
// - session/prompt / session/cancel / session/rewind / session/close:
//   注入 session_id 后转发;prompt 归一为 ContentBlock 数组(ACP 0.10.x 要求);
// - grok 的通知(session/update 等):按 grok 会话 id 路由回对应的 iPad 连接。
const ACP_PROTOCOL_VERSION = "0.10.4";
const SESSION_SCOPED_METHODS = new Set([
  "session/prompt",
  "session/cancel",
  "session/rewind",
  "session/close",
]);

export class AcpServer {
  constructor({ grok, sessions, rateLimiter, defaultCwd }) {
    this.grok = grok;
    this.sessions = sessions;
    this.rateLimiter = rateLimiter ?? new RateLimiter();
    this.defaultCwd = defaultCwd; // session/new、session/load 未带 cwd 时的兜底
    this.conns = new Set(); // 所有 iPad 连接
    this.connSessions = new Map(); // conn -> chatID
    this.sessionConns = new Map(); // chatID -> conn
    this.grokSessionConns = new Map(); // grokSessionId -> conn

    grok.onNotification((notification) => this.routeNotification(notification));
  }

  attach(httpServer) {
    const wss = new WebSocketServer({ noServer: true });
    httpServer.on("upgrade", (req, socket, head) => {
      const url = new URL(req.url, `http://${req.headers.host}`);
      const ip = clientIp(req);
      if (this.rateLimiter.isBanned(ip)) {
        audit("rate-limited", ip);
        rejectUpgrade(socket, 429);
        return;
      }
      if (!isAuthorized(req, Object.fromEntries(url.searchParams))) {
        this.rateLimiter.recordFailure(ip);
        audit("auth-fail", ip);
        rejectUpgrade(socket, 401);
        return;
      }
      this.rateLimiter.recordSuccess(ip);
      audit("auth-ok", ip);
      wss.handleUpgrade(req, socket, head, (ws) => this.handleConnection(ws));
    });
    this.wss = wss;
  }

  handleConnection(ws) {
    this.conns.add(ws);
    ws.on("message", (data) => this.handleMessage(ws, data));
    ws.on("close", () => {
      this.conns.delete(ws);
      const chatID = this.connSessions.get(ws);
      if (chatID) {
        this.sessionConns.delete(chatID);
        this.connSessions.delete(ws);
        for (const [sid, conn] of this.grokSessionConns) {
          if (conn === ws) this.grokSessionConns.delete(sid);
        }
      }
    });
    ws.on("error", () => {});
  }

  async handleMessage(ws, data) {
    let msg;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      return;
    }
    if (!msg.method) return;

    if (msg.method === "initialize") {
      this.reply(ws, msg.id, {
        protocolVersion: ACP_PROTOCOL_VERSION,
        agentCapabilities: { terminal: true, rewind: true, plan: true },
      });
      return;
    }

    try {
      switch (msg.method) {
        case "session/new":
          await this.handleSessionNew(ws, msg);
          break;
        case "session/load":
          await this.handleSessionLoad(ws, msg);
          break;
        case "session/close":
          await this.handleSessionClose(ws, msg);
          break;
        case "sessions/list":
          this.handleSessionsList(ws, msg);
          break;
        case "sessions/remove":
          await this.handleSessionsRemove(ws, msg);
          break;
        default:
          // session/prompt、session/cancel、session/rewind 等直接转发
          await this.forwardToGrok(ws, msg);
      }
    } catch (err) {
      this.replyError(ws, msg.id, -32603, err.message);
    }
  }

  async handleSessionNew(ws, msg) {
    const record = this.sessions.create({ cwd: msg.params?.cwd ?? this.defaultCwd ?? null });
    const params = {
      cwd: msg.params?.cwd ?? this.defaultCwd,
      mcpServers: msg.params?.mcpServers ?? [],
    };
    const resp = await this.grok.request("session/new", params);
    if (resp.error) {
      // 失败回滚:不留 grokSessionId=null 的孤儿记录(永远无法 load)
      this.sessions.remove(record.chatID);
      this.replyError(ws, msg.id, resp.error.code ?? -32603, resp.error.message ?? "grok 错误");
      return;
    }
    const sessionId = resp.result?.sessionId ?? null;
    if (sessionId) this.sessions.bindGrokSession(record.chatID, sessionId);
    this.bindConn(ws, record.chatID, sessionId);
    this.reply(ws, msg.id, { ...(resp.result ?? {}), chatID: record.chatID });
  }

  // 本地扩展:列出桥注册表中可恢复的全部会话(只读,不经 grok;断连时也可用)。
  handleSessionsList(ws, msg) {
    this.reply(ws, msg.id, {
      sessions: this.sessions.list()
        .filter((r) => Boolean(r.grokSessionId))
        .map((r) => ({
          chatID: r.chatID,
          cwd: r.cwd,
          createdAt: r.createdAt,
          restorable: true,
        })),
    });
  }

  // 本地扩展:按 chatID 删除注册表记录并尽力关闭远端 grok 会话(失败不阻塞)。
  async handleSessionsRemove(ws, msg) {
    const chatID = msg.params?.chatID;
    const record = chatID ? this.sessions.get(chatID) : null;
    if (!record) return this.replyError(ws, msg.id, -32602, `未知会话: ${chatID}`);
    if (record.grokSessionId) {
      try {
        await this.grok.request("session/close", { sessionId: record.grokSessionId });
      } catch (err) {
        console.warn(`[bridge] sessions/remove: grok close 失败(忽略): ${err.message}`);
      }
    }
    this.sessions.remove(chatID);
    if (this.connSessions.get(ws) === chatID) this.unbindConn(ws, chatID); // 删的是当前绑定会话时解绑
    this.reply(ws, msg.id, { ok: true });
  }

  async handleSessionLoad(ws, msg) {
    const chatID = msg.params?.chatID;
    const record = chatID ? this.sessions.get(chatID) : null;
    if (!record || !record.grokSessionId) {
      this.replyError(ws, msg.id, -32602, `未知会话: ${chatID}`);
      return;
    }
    const resp = await this.grok.request("session/load", {
      sessionId: record.grokSessionId,
      cwd: msg.params?.cwd ?? this.defaultCwd,
      mcpServers: msg.params?.mcpServers ?? [],
    });
    this.bindConn(ws, chatID, record.grokSessionId);
    if (resp.error) {
      this.replyError(ws, msg.id, resp.error.code ?? -32603, resp.error.message ?? "grok 错误");
      return;
    }
    this.reply(ws, msg.id, resp.result ?? {});
  }

  async handleSessionClose(ws, msg) {
    const record = this.sessionRecordFor(ws);
    const params = record?.grokSessionId ? { sessionId: record.grokSessionId } : (msg.params ?? {});
    const resp = await this.grok.request("session/close", params);
    const chatID = this.connSessions.get(ws);
    if (chatID) {
      this.sessions.remove(chatID);
      this.unbindConn(ws, chatID);
    }
    if (resp.error) {
      this.replyError(ws, msg.id, resp.error.code ?? -32603, resp.error.message ?? "grok 错误");
      return;
    }
    this.reply(ws, msg.id, resp.result ?? {});
  }

  // 转发给 grok 并回传结果(保留 iPad 的请求 id)。
  // session 作用域的方法自动注入 grok session_id;prompt 归一为 ContentBlock 数组。
  async forwardToGrok(ws, msg) {
    const params = { ...(msg.params ?? {}) };
    const record = this.sessionRecordFor(ws);
    if (SESSION_SCOPED_METHODS.has(msg.method) && record?.grokSessionId) {
      params.sessionId = record.grokSessionId;
    }
    if (msg.method === "session/prompt" && params.prompt !== undefined) {
      params.prompt = normalizePrompt(params.prompt);
    }
    const resp = await this.grok.request(msg.method, params);
    if (resp.error) {
      this.replyError(ws, msg.id, resp.error.code ?? -32603, resp.error.message ?? "grok 错误");
    } else {
      this.reply(ws, msg.id, resp.result ?? {});
    }
  }

  sessionRecordFor(ws) {
    const chatID = this.connSessions.get(ws);
    return chatID ? this.sessions.get(chatID) : null;
  }

  routeNotification(notification) {
    const sessionId = notification.params?.sessionId ?? notification.params?.session?.id ?? null;
    let conn = null;
    if (sessionId) {
      const record = this.sessions.list().find((r) => r.grokSessionId === sessionId);
      const chatID = record?.chatID ?? null;
      if (!chatID) return;
      conn = this.sessionConns.get(chatID);
      if (conn) this.grokSessionConns.set(sessionId, conn);
      // 注入桥侧的 chatID,客户端据此只处理当前会话的事件(多会话切换防串流)
      notification = {
        ...notification,
        params: { ...(notification.params ?? {}), chatID },
      };
    }
    if (!conn || conn.readyState !== WebSocket.OPEN) return;
    conn.send(JSON.stringify(notification));
  }

  bindConn(ws, chatID, grokSessionId) {
    const prev = this.connSessions.get(ws);
    if (prev && prev !== chatID) this.sessionConns.delete(prev);
    this.connSessions.set(ws, chatID);
    this.sessionConns.set(chatID, ws);
    if (grokSessionId) this.grokSessionConns.set(grokSessionId, ws);
  }

  unbindConn(ws, chatID) {
    const record = this.sessions.get(chatID);
    if (record?.grokSessionId) this.grokSessionConns.delete(record.grokSessionId);
    if (this.connSessions.get(ws) === chatID) this.connSessions.delete(ws);
    this.sessionConns.delete(chatID);
  }

  reply(ws, id, result) {
    this.send(ws, { jsonrpc: "2.0", id, result });
  }

  replyError(ws, id, code, message) {
    this.send(ws, { jsonrpc: "2.0", id, error: { code, message } });
  }

  send(ws, obj) {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  }
}

function rejectUpgrade(socket, code) {
  const reason = code === 401 ? "Unauthorized" : "Too Many Requests";
  socket.write(`HTTP/1.1 ${code} ${reason}\r\nConnection: close\r\n\r\n`);
  socket.destroy();
}

// ACP 0.10.x 的 prompt 是 ContentBlock 数组;客户端可传字符串或数组,统一归一。
function normalizePrompt(prompt) {
  if (typeof prompt === "string") return [{ type: "text", text: prompt }];
  if (Array.isArray(prompt)) return prompt;
  return [prompt];
}

// 审计日志:只记结果与来源,绝不记录 token。
function audit(result, ip) {
  console.log(`[audit] ${new Date().toISOString()} ${result} ip=${ip}`);
}

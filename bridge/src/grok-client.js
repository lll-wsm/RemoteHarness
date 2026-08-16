import WebSocket from "ws";

// 桥作为 ACP 客户端,维护一条到 grok agent serve 的长连接。
// WebSocket URL 形如 ws://<host>:<port>/ws?server-key=<secret>(grok 启动时打印)。
const RETRY_BASE_MS = 1000;
const RETRY_MAX_MS = 15000;

export class GrokClient {
  constructor({ url, secret, onOpen, onClose }) {
    this.url = url;
    this.secret = secret;
    this.onOpen = onOpen;
    this.onClose = onClose;
    this.ws = null;
    this.nextId = 1;
    this.pending = new Map(); // 内部 requestId -> { resolve, reject, timer }
    this.handlers = new Set(); // 通知处理器(session/update 等)
    this.connected = false;
    this.retryMs = RETRY_BASE_MS;
    this.readyPromise = null;
    this._resolveReady = null;
    this._rejectReady = null;
  }

  connect() {
    const wsUrl = `${this.url}/ws?server-key=${encodeURIComponent(this.secret)}`;
    const ws = new WebSocket(wsUrl);
    this.readyPromise = new Promise((resolve, reject) => {
      this._resolveReady = resolve;
      this._rejectReady = reject;
    });

    ws.on("open", async () => {
      this.connected = true;
      this.retryMs = RETRY_BASE_MS;
      try {
        // ACP 生命周期要求先 initialize(带 protocolVersion);之后才能 session 方法
        const resp = await this._sendRpc("initialize", {
          protocolVersion: "0.10.4",
          clientCapabilities: {},
        });
        if (resp.error) throw new Error(`initialize 失败: ${resp.error.message}`);
        this.onOpen?.();
        this._resolveReady?.();
      } catch (err) {
        console.warn(`[grok] initialize 失败: ${err.message}`);
        this._rejectReady?.(err);
      }
    });

    ws.on("message", (data) => {
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (msg.id !== undefined && msg.id !== null) {
        const p = this.pending.get(msg.id);
        if (!p) return;
        this.pending.delete(msg.id);
        clearTimeout(p.timer);
        p.resolve(msg);
      } else {
        for (const h of this.handlers) h(msg);
      }
    });

    ws.on("close", () => {
      this.connected = false;
      this.ws = null;
      this.readyPromise = null;
      for (const p of this.pending.values()) {
        clearTimeout(p.timer);
        p.reject(new Error("grok 连接断开"));
      }
      this.pending.clear();
      this.onClose?.();
      this.scheduleReconnect();
    });

    ws.on("error", (err) => {
      console.warn(`[grok] 连接错误: ${err.message}`);
    });

    this.ws = ws;
  }

  scheduleReconnect() {
    const delay = this.retryMs;
    this.retryMs = Math.min(this.retryMs * 2, RETRY_MAX_MS);
    setTimeout(() => {
      if (!this.connected) this.connect();
    }, delay);
  }

  // 发 JSON-RPC 请求,返回 Promise<response>;等 initialize 握手完成后才放行。超时 30s。
  request(method, params = {}, timeoutMs = 30000) {
    return (this.readyPromise ?? Promise.resolve()).then(() => this._sendRpc(method, params, timeoutMs));
  }

  _sendRpc(method, params = {}, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      if (!this.connected || !this.ws) {
        reject(new Error("grok 未连接"));
        return;
      }
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`请求超时: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  onNotification(handler) {
    this.handlers.add(handler);
  }

  isConnected() {
    return this.connected;
  }
}
